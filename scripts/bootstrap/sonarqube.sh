#!/usr/bin/env bash
# Bootstrap SonarQube d'une instance déployée (make deploy), locale ou distante. Idempotent :
#   1. vérifie vm.max_map_count sur l'hôte cible (Elasticsearch intégré) ;
#   2. attend que SonarQube soit prêt (statut UP) ;
#   3. remplace le mot de passe par défaut du compte admin par SONARQUBE_ADMIN_PASSWORD ;
#   4. vérifie la présence du plugin community branch ;
#   5. génère le token d'analyse, conservé tant qu'il reste valide : référence dans le stockage de
#      l'instance (volume sonarqube_data, récupérable depuis tout poste), copie locale dans
#      outputs/<env>.sonarqube-token ; l'étape GitLab (scripts/bootstrap/gitlab.sh) le pose en
#      variable CI d'instance SONAR_TOKEN. ROTATION=1 le révoque et le remplace.
# Lancé par `make bootstrap ENV=<env>` (ou seul : `make bootstrap-sonarqube`) via scripts/instance.sh
# bootstrap, qui positionne une seule fois la cible Docker (contexte SSH d'une instance distante) : les
# commandes appellent ensuite docker compose directement. L'API est appelée depuis le conteneur
# sonarqube, identifiants transmis à curl par l'entrée standard (jamais en argument).
# Une seule étape SonarQube à la fois par instance : verrou flock dans le volume sonarqube_data
# (scripts/lib/verrou.sh), pris une fois SonarQube prêt. Documentation : docs/bootstrap-sonarqube.md.
#
# Usage : scripts/bootstrap/sonarqube.sh envs/<env>.env
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/sonarqube.sh
source "$ROOT/scripts/lib/sonarqube.sh"
# shellcheck source=scripts/lib/verrou.sh
source "$ROOT/scripts/lib/verrou.sh"

# Même seuil que scripts/host-prereqs.sh
readonly MAX_MAP_COUNT_MIN=524288
readonly ATTENTE_ESSAIS=60
readonly ATTENTE_PAUSE=10
readonly TOKEN_NOM=devops-platform-analyse # nom du token, pas sa valeur (check-secrets: ignore)
readonly PLUGIN_CLE=communityBranchPlugin
# Stockage du token dans le conteneur sonarqube (volume sonarqube_data, sur l'hôte de l'instance)
readonly STOCKAGE_DIR=/opt/sonarqube/data/devops-platform
readonly STOCKAGE_FICHIER=analyse-token
readonly STOCKAGE="$STOCKAGE_DIR/$STOCKAGE_FICHIER"
# Verrou de l'étape (scripts/lib/verrou.sh), à côté du stockage : sur l'hôte de l'instance, quel que
# soit le poste
readonly FICHIER_VERROU="$STOCKAGE_DIR/.bootstrap.lock"

erreur() { echo "Erreur : $*" >&2; exit 1; }

(($# == 1)) || { echo "Usage : $0 envs/<env>.env" >&2; exit 1; }
env_file="$1"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file"
env="$(basename "$env_file" .env)"
token_fichier="outputs/$env.sonarqube-token"
[[ "${ROTATION:-}" =~ ^1?$ ]] || erreur "ROTATION invalide : $ROTATION (1 ou vide)"

dc() { docker compose --env-file "$env_file" "$@"; }
trap verrou_liberer EXIT

# Garde-fou : lancé hors `make bootstrap`, une instance distante serait cherchée sur le moteur local
# (même nom de projet compose) et une éventuelle instance locale reconfigurée à sa place
if [[ -n "$(env_valeur_fichier "$env_file" DEPLOY_SSH)" && "${DOCKER_CONTEXT:-}" != "devops-platform-$env" ]]; then
  erreur "instance distante (DEPLOY_SSH dans $env_file) : lancer make bootstrap ENV=$env"
fi

# Lu dans le fichier uniquement : une variable exportée par le shell (autre instance) serait posée
# sur SonarQube sans être celle de envs/<env>.env.
admin_mdp="$(env_valeur_fichier "$env_file" SONARQUBE_ADMIN_PASSWORD)"
if [[ -z "$admin_mdp" || "$admin_mdp" == change_me* ]]; then
  erreur "SONARQUBE_ADMIN_PASSWORD absent ou valeur d'exemple dans $env_file"
fi
[[ "$admin_mdp" =~ [[:cntrl:]] ]] && erreur "SONARQUBE_ADMIN_PASSWORD contient un caractère de contrôle ($env_file)"

# --- 1. vm.max_map_count -------------------------------------------------------------------------
# sysctl non namespacé : la base (qui démarre même quand SonarQube échoue faute de ce réglage) lit
# la valeur du noyau de l'hôte cible.
echo "==> vm.max_map_count sur l'hôte cible..."
max_map_count="$(dc exec -T sonarqube-db cat /proc/sys/vm/max_map_count </dev/null 2>/dev/null)" \
  || erreur "service sonarqube-db injoignable : instance non déployée ? (make deploy ENV=$env)"
[[ "$max_map_count" =~ ^[0-9]+$ ]] || erreur "valeur de vm.max_map_count illisible : $max_map_count"
if ((max_map_count < MAX_MAP_COUNT_MIN)); then
  echo "Erreur : vm.max_map_count vaut $max_map_count sur l'hôte cible (minimum : $MAX_MAP_COUNT_MIN)." >&2
  echo "  L'Elasticsearch intégré de SonarQube ne démarre pas avec cette valeur." >&2
  echo "  Correctif : scripts/host-prereqs.sh sur l'hôte (docs/serveur.md), puis make deploy ENV=$env." >&2
  exit 1
fi
echo "    $max_map_count (≥ $MAX_MAP_COUNT_MIN) : OK."

# --- 2. Attente de SonarQube ---------------------------------------------------------------------
echo "==> Attente de SonarQube..."
for ((i = 1; ; i++)); do
  statut=''
  if sonar_api GET /api/system/status ''; then
    statut="$(sed -n 's/.*"status":"\([A-Z_]*\)".*/\1/p' <<<"$CORPS")"
  fi
  [[ "$statut" == UP ]] && { echo "    SonarQube prêt."; break; }
  if [[ "$statut" == DB_MIGRATION_NEEDED ]]; then
    erreur "SonarQube attend une migration de base (montée de version) : voir docs/montee-de-version.md"
  fi
  ((i < ATTENTE_ESSAIS)) || erreur "SonarQube n'a pas atteint le statut UP en $((ATTENTE_ESSAIS * ATTENTE_PAUSE)) s (dernier statut : ${statut:-injoignable})"
  echo "    ($i/$ATTENTE_ESSAIS) statut : ${statut:-injoignable}, nouvel essai dans $ATTENTE_PAUSE s..."
  sleep "$ATTENTE_PAUSE"
done

# Une seule étape SonarQube à la fois par instance (mot de passe admin, rotation du token) : sans
# verrou, deux exécutions concurrentes pourraient laisser dans le stockage un token déjà révoqué
verrou_prendre sonarqube "$FICHIER_VERROU" "make bootstrap ENV=$env"
echo "    Verrou de l'étape pris ($FICHIER_VERROU, conteneur sonarqube)."

# --- 3. Mot de passe admin -----------------------------------------------------------------------
echo "==> Compte admin..."
if identite_valide "admin:$admin_mdp"; then
  echo "    Mot de passe déjà positionné : rien à faire."
elif identite_valide "admin:admin"; then
  sonar_api POST /api/users/change_password "admin:admin" \
    login=admin previousPassword=admin "password=$admin_mdp" \
    || erreur "changement du mot de passe admin impossible (service sonarqube injoignable)"
  case "$CODE" in
    204) echo "    Mot de passe par défaut remplacé par SONARQUBE_ADMIN_PASSWORD." ;;
    400)
      echo "Erreur : SonarQube refuse SONARQUBE_ADMIN_PASSWORD (HTTP 400) : $CORPS" >&2
      echo "  Règles : 12 caractères minimum, avec majuscule, minuscule, chiffre et caractère spécial." >&2
      exit 1 ;;
    *) erreur "HTTP $CODE inattendu au changement du mot de passe admin : $CORPS" ;;
  esac
  identite_valide "admin:$admin_mdp" || erreur "mot de passe admin changé mais refusé à la vérification"
else
  echo "Erreur : le compte admin refuse SONARQUBE_ADMIN_PASSWORD et le mot de passe par défaut." >&2
  echo "  Un autre mot de passe est positionné (par ex. secrets régénérés par make init NOUVEAUX_MDP=1) :" >&2
  echo "  remettre l'ancienne valeur dans $env_file, ou réinitialiser le compte admin" >&2
  echo "  (docs/bootstrap-sonarqube.md, « Mot de passe admin inconnu »)." >&2
  exit 1
fi
admin="admin:$admin_mdp"

# --- 4. Plugin community branch ------------------------------------------------------------------
echo "==> Plugin community branch..."
sonar_api GET /api/plugins/installed "$admin" || erreur "liste des plugins inaccessible (service sonarqube injoignable)"
[[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu sur api/plugins/installed : $CORPS"
if [[ "$CORPS" != *"\"key\":\"$PLUGIN_CLE\""* ]]; then
  echo "Erreur : plugin $PLUGIN_CLE absent de SonarQube." >&2
  echo "  Vérifier l'image du service sonarqube (mc1arke/sonarqube-with-community-branch-plugin," >&2
  echo "  compose/sonarqube.yml) et SONARQUBE_VERSION dans $env_file." >&2
  exit 1
fi
echo "    $PLUGIN_CLE installé : OK."

# --- 5. Token d'analyse --------------------------------------------------------------------------
# SonarQube ne restitue jamais un token : sa référence est le stockage de l'instance (volume
# sonarqube_data, lisible depuis tout poste), outputs/<env>.sonarqube-token n'en est qu'une copie locale.
# Token conservé tant qu'il reste valide ; sinon le token du même nom est révoqué et remplacé.
# Le token ne passe que par des variables et des entrées standard : jamais affiché ni en argument.
echo "==> Token d'analyse ($TOKEN_NOM)..."
sonar_api GET /api/user_tokens/search "$admin" || erreur "liste des tokens inaccessible (service sonarqube injoignable)"
[[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu sur api/user_tokens/search : $CORPS"
token_existe=0
[[ "$CORPS" == *"\"name\":\"$TOKEN_NOM\""* ]] && token_existe=1

# Stockage de l'instance : chaîne vide si le fichier n'existe pas ; un fichier présent mais illisible
# est une erreur (le traiter comme absent ferait révoquer un token valide)
lire_stockage() {
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  dc exec -T sonarqube sh -c '[ -e "$1" ] || exit 0; cat "$1"' sh "$STOCKAGE" </dev/null 2>/dev/null \
    || erreur "lecture de $STOCKAGE impossible dans le conteneur sonarqube (fichier illisible ou service injoignable)"
}

# Écriture atomique dans le stockage de l'instance : répertoire 700, fichier 600, token sur l'entrée standard
ecrire_stockage() { # <token>
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  printf '%s\n' "$1" | dc exec -T sonarqube sh -c '
      umask 077
      mkdir -p "$1" && chmod 700 "$1" && t="$(mktemp "$1/.$2.XXXXXX")" || exit 1
      cat >"$t" && mv -f "$t" "$1/$2" || { rm -f "$t"; exit 1; }' sh "$STOCKAGE_DIR" "$STOCKAGE_FICHIER" \
    || return 1
}

# Écriture atomique de la copie locale : répertoire 700, fichier 600
ecrire_local() { # <token>
  (
    umask 077
    mkdir -p outputs && chmod 700 outputs || exit 1
    tmp="$(mktemp "outputs/.$env.sonarqube-token.XXXXXX")" || exit 1
    if ! { printf '%s\n' "$1" >"$tmp" && mv -f "$tmp" "$token_fichier"; }; then rm -f "$tmp"; exit 1; fi
  )
}

# Token utilisable : format attendu, token du nom présent dans SonarQube et accepté par SonarQube
token_utilisable() { # <token>
  [[ "$1" =~ $MOTIF_TOKEN_SONAR ]] && ((token_existe)) && identite_valide "$1:"
}

token_stocke="$(lire_stockage)"
token_local=''
if [[ -f "$token_fichier" ]]; then IFS= read -r token_local <"$token_fichier" || true; fi

token=''
if [[ "${ROTATION:-}" == 1 ]]; then
  echo "    ROTATION=1 : token révoqué et remplacé."
elif [[ -n "$token_stocke" ]] && token_utilisable "$token_stocke"; then
  token="$token_stocke"
  echo "    Token du stockage de l'instance valide : conservé."
elif [[ -n "$token_local" ]] && token_utilisable "$token_local"; then
  # Instance bootstrappée avant le stockage de l'instance : le token de ce poste devient la référence
  token="$token_local"
  verrou_tenu
  ecrire_stockage "$token" || erreur "écriture du token dans le stockage de l'instance ($STOCKAGE) impossible"
  echo "    Token de $token_fichier valide : recopié dans le stockage de l'instance ($STOCKAGE)."
elif ((token_existe)) && [[ -z "$token_stocke" && -z "$token_local" ]]; then
  # Garde-fou : token créé par un bootstrap antérieur au stockage de l'instance, depuis un autre poste
  echo "Erreur : token $TOKEN_NOM présent dans SonarQube, mais ni dans le stockage de l'instance ni dans" >&2
  echo "  $token_fichier : il a été généré depuis un autre poste, avant le stockage de l'instance." >&2
  echo "  Lancer d'abord make bootstrap-sonarqube ENV=$env depuis le poste qui détient ce fichier : le token" >&2
  echo "  y est recopié dans le stockage de l'instance, puis récupérable depuis tout poste." >&2
  echo "  Fichier perdu : make bootstrap ENV=$env ROTATION=1 révoque et remplace le token (consommateurs" >&2
  echo "  hors plateforme à reconfigurer, docs/bootstrap-sonarqube.md)." >&2
  exit 1
elif ((token_existe)); then
  echo "    Aucun token valide (stockage de l'instance, $token_fichier) : token remplacé."
else
  echo "    Aucun token $TOKEN_NOM dans SonarQube : génération."
fi

if [[ -z "$token" ]]; then
  verrou_tenu
  if ((token_existe)); then
    sonar_api POST /api/user_tokens/revoke "$admin" "name=$TOKEN_NOM" || erreur "révocation du token impossible"
    [[ "$CODE" == 204 ]] || erreur "HTTP $CODE inattendu à la révocation du token : $CORPS"
  fi
  sonar_api POST /api/user_tokens/generate "$admin" "name=$TOKEN_NOM" type=GLOBAL_ANALYSIS_TOKEN \
    || erreur "génération du token impossible (service sonarqube injoignable)"
  [[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu à la génération du token : $CORPS"
  token="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' <<<"$CORPS")"
  CORPS=''
  [[ "$token" =~ $MOTIF_TOKEN_SONAR ]] || erreur "réponse de génération du token sans token reconnaissable"

  # Stockage de l'instance d'abord (la référence), puis copie locale. Un échec arrête l'étape avant la
  # régénération de outputs/<env>.env ; la relance révoque et remplace le token du même nom.
  verrou_tenu
  if ! ecrire_stockage "$token"; then
    echo "Erreur : token généré mais non écrit dans le stockage de l'instance ($STOCKAGE)." >&2
    echo "  outputs/$env.env n'est pas régénéré ; relancer make bootstrap ENV=$env." >&2
    exit 1
  fi
  echo "    Token généré, écrit dans le stockage de l'instance (variable CI SONAR_TOKEN mise à jour par l'étape GitLab)."
fi

# Copie locale rafraîchie (autre poste, fichier supprimé, rotation)
if [[ "$token_local" != "$token" ]]; then
  ecrire_local "$token" || erreur "écriture de $token_fichier impossible (le stockage de l'instance est à jour : relancer)"
  echo "    Copie locale $token_fichier mise à jour."
fi
unset token token_stocke token_local

# --- Récapitulatif -------------------------------------------------------------------------------
url="$(env_valeur "$env_file" SONARQUBE_EXTERNAL_URL)"
if [[ -z "$url" ]]; then
  hote="$(env_valeur "$env_file" SONARQUBE_HOSTNAME)"
  url="http://${hote:-sonarqube.localhost}"
fi
echo
echo "SonarQube de l'instance $env prêt :"
echo "  URL             $url"
echo "  Compte admin    admin / SONARQUBE_ADMIN_PASSWORD de $env_file"
echo "  Token d'analyse type GLOBAL_ANALYSIS_TOKEN, stockage de l'instance ($STOCKAGE),"
echo "                  copie locale $token_fichier"
