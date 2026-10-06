#!/usr/bin/env bash
# Bootstrap SonarQube d'une instance déployée (make deploy), locale ou distante. Idempotent :
#   1. vérifie vm.max_map_count sur l'hôte cible (Elasticsearch intégré) ;
#   2. attend que SonarQube soit prêt (statut UP) ;
#   3. remplace le mot de passe par défaut du compte admin par SONARQUBE_ADMIN_PASSWORD ;
#   4. vérifie la présence du plugin community branch ;
#   5. génère le token d'analyse (outputs/<env>.sonarqube-token), conservé tant qu'il reste valide.
# Toutes les commandes passent par scripts/instance.sh compose (même cible que make deploy) ; l'API est
# appelée depuis le conteneur sonarqube, identifiants transmis à curl par l'entrée standard (jamais
# en argument). Documentation : docs/bootstrap-sonarqube.md.
#
# Usage : scripts/bootstrap-sonarqube.sh <env>   (ou make bootstrap-sonarqube ENV=<env>)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"

# Même seuil que scripts/host-prereqs.sh
readonly MAX_MAP_COUNT_MIN=524288
readonly ATTENTE_ESSAIS=60
readonly ATTENTE_PAUSE=10
readonly TOKEN_NOM=devops-platform-analyse # nom du token, pas sa valeur (check-secrets: ignore)
readonly PLUGIN_CLE=communityBranchPlugin
readonly API=http://localhost:9000

erreur() { echo "Erreur : $*" >&2; exit 1; }

(($# == 1)) || { echo "Usage : $0 <env>" >&2; exit 1; }
env="$1"
[[ "$env" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || erreur "ENV invalide : $env (attendu : minuscules, chiffres, - et _)"
env_file="envs/$env.env"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file (le générer : make init ENV=$env)"
token_fichier="outputs/$env.sonarqube-token"

# Lu dans le fichier uniquement : une variable exportée par le shell (autre instance) serait posée
# sur SonarQube sans être celle de envs/<env>.env.
admin_mdp="$(env_valeur_fichier "$env_file" SONARQUBE_ADMIN_PASSWORD)"
if [[ -z "$admin_mdp" || "$admin_mdp" == change_me* ]]; then
  erreur "SONARQUBE_ADMIN_PASSWORD absent ou valeur d'exemple dans $env_file"
fi
[[ "$admin_mdp" =~ [[:cntrl:]] ]] && erreur "SONARQUBE_ADMIN_PASSWORD contient un caractère de contrôle ($env_file)"

dc() { "$ROOT/scripts/instance.sh" compose "$env" "$@"; }

# Chaîne entre guillemets pour un fichier de config curl (\ et " échappés)
cfg() { local v="${1//\\/\\\\}"; printf '"%s"' "${v//\"/\\\"}"; }

# api <GET|POST> <chemin> <utilisateur:secret | ""> [paramètre=valeur…]
# Positionne CODE (code HTTP, 000 si SonarQube injoignable) et CORPS. Retour non nul si l'exec échoue
# (conteneur arrêté). Paramètres POST encodés (data-urlencode) : un mot de passe contenant + & % reste
# intact.
CODE='' CORPS=''
api() {
  local methode="$1" chemin="$2" identite="$3" config sortie p
  shift 3
  config="url = $(cfg "$API$chemin")"$'\n'
  [[ -n "$identite" ]] && config+="user = $(cfg "$identite")"$'\n'
  [[ "$methode" == POST ]] && config+='request = "POST"'$'\n'
  for p in "$@"; do config+="data-urlencode = $(cfg "$p")"$'\n'; done
  CODE='' CORPS=''
  sortie="$(dc exec -T sonarqube curl -sS -K - -w '\n%{http_code}' <<<"$config" 2>/dev/null)" || {
    # curl injoignable (SonarQube en démarrage) : code 000 en dernière ligne, exec réussi pour nous
    [[ "$sortie" =~ (^|$'\n')000$ ]] || return 1
  }
  CODE="${sortie##*$'\n'}"
  CORPS="${sortie%"$CODE"}"
  CORPS="${CORPS%$'\n'}"
}

# Champ booléen "valid" de api/authentication/validate (toujours HTTP 200)
identite_valide() { api GET /api/authentication/validate "$1" && [[ "$CORPS" == *'"valid":true'* ]]; }

# --- 1. vm.max_map_count -------------------------------------------------------------------------
# sysctl non namespacé : la base (qui démarre même quand SonarQube échoue faute de ce réglage) lit
# la valeur du noyau de l'hôte cible.
echo "==> vm.max_map_count sur l'hôte cible..."
max_map_count="$(dc exec -T sonarqube-db cat /proc/sys/vm/max_map_count 2>/dev/null)" \
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
  if api GET /api/system/status ''; then
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

# --- 3. Mot de passe admin -----------------------------------------------------------------------
echo "==> Compte admin..."
if identite_valide "admin:$admin_mdp"; then
  echo "    Mot de passe déjà positionné : rien à faire."
elif identite_valide "admin:admin"; then
  api POST /api/users/change_password "admin:admin" \
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
api GET /api/plugins/installed "$admin" || erreur "liste des plugins inaccessible (service sonarqube injoignable)"
[[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu sur api/plugins/installed : $CORPS"
if [[ "$CORPS" != *"\"key\":\"$PLUGIN_CLE\""* ]]; then
  echo "Erreur : plugin $PLUGIN_CLE absent de SonarQube." >&2
  echo "  Vérifier l'image du service sonarqube (mc1arke/sonarqube-with-community-branch-plugin," >&2
  echo "  compose/sonarqube.yml) et SONARQUBE_VERSION dans $env_file." >&2
  exit 1
fi
echo "    $PLUGIN_CLE installé : OK."

# --- 5. Token d'analyse --------------------------------------------------------------------------
# SonarQube ne restitue jamais un token : celui du fichier est conservé tant qu'il reste valide,
# sinon le token du même nom est révoqué et remplacé.
echo "==> Token d'analyse ($TOKEN_NOM)..."
api GET /api/user_tokens/search "$admin" || erreur "liste des tokens inaccessible (service sonarqube injoignable)"
[[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu sur api/user_tokens/search : $CORPS"
token_existe=0
[[ "$CORPS" == *"\"name\":\"$TOKEN_NOM\""* ]] && token_existe=1

token=''
if [[ -f "$token_fichier" ]]; then IFS= read -r token <"$token_fichier" || true; fi
if [[ -n "$token" ]] && ((token_existe)) && identite_valide "$token:"; then
  echo "    Token de $token_fichier valide : conservé."
else
  if ((token_existe)); then
    if [[ -n "$token" ]]; then
      echo "    Token de $token_fichier invalide : remplacé."
    else
      echo "Attention : token $TOKEN_NOM présent dans SonarQube mais absent de $token_fichier (autre poste," >&2
      echo "  fichier supprimé) : il est révoqué et remplacé ; ses utilisateurs (CI) sont à reconfigurer." >&2
    fi
    api POST /api/user_tokens/revoke "$admin" "name=$TOKEN_NOM" || erreur "révocation du token impossible"
    [[ "$CODE" == 204 ]] || erreur "HTTP $CODE inattendu à la révocation du token : $CORPS"
  fi
  api POST /api/user_tokens/generate "$admin" "name=$TOKEN_NOM" type=GLOBAL_ANALYSIS_TOKEN \
    || erreur "génération du token impossible (service sonarqube injoignable)"
  [[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu à la génération du token : $CORPS"
  token="$(sed -n 's/.*"token":"\([^"]*\)".*/\1/p' <<<"$CORPS")"
  [[ -n "$token" ]] || erreur "réponse de génération du token sans token"

  # Écriture atomique, répertoire 700 et fichier 600 ; un échec ici se répare au passage suivant
  # (token du même nom révoqué puis régénéré).
  umask 077
  mkdir -p outputs
  chmod 700 outputs
  tmp="$(mktemp "outputs/.$env.sonarqube-token.XXXXXX")"
  trap 'rm -f "$tmp"' EXIT
  printf '%s\n' "$token" >"$tmp"
  mv -f "$tmp" "$token_fichier"
  trap - EXIT
  echo "    Token généré : $token_fichier."
fi

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
echo "  Token d'analyse $token_fichier (type GLOBAL_ANALYSIS_TOKEN)"
