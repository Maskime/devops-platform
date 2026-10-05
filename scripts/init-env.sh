#!/usr/bin/env bash
# Génère le fichier d'environnement d'une instance (`make init ENV=<env>`) à partir du modèle
# envs/.env.example : questions (domaine, hostnames, TLS_MODE, profil) avec valeurs par défaut,
# mots de passe aléatoires, fichier en permissions 600.
#
# Usage : [FORCE=1] [NOUVEAUX_MDP=1] scripts/init-env.sh <env>
#   FORCE=1       régénère un fichier existant (sauvegarde horodatée envs/<env>.env.bak.<date>) ;
#                 ses secrets et ses réponses sont repris comme valeurs par défaut ;
#   NOUVEAUX_MDP=1 avec FORCE=1 : régénère aussi les secrets (instance à réinstaller).
# Sans terminal (entrée redirigée), une réponse vide ou absente prend la valeur par défaut.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MODELE="$ROOT/envs/.env.example"
PROFILS_DIR="$ROOT/config/profiles"

# shellcheck source=scripts/lib/tls.sh
source "$ROOT/scripts/lib/tls.sh"

# Clés des mots de passe générés (minuscules : pas de faux positif de check-secrets)
cles_mdp=(GITLAB_ROOT_PASSWORD SONARQUBE_DB_PASSWORD SONARQUBE_ADMIN_PASSWORD GRAFANA_ADMIN_PASSWORD
  PORTAINER_ADMIN_PASSWORD)
services=(gitlab sonarqube grafana portainer plantuml)
declare -A noms=([gitlab]=GitLab [sonarqube]=SonarQube [grafana]=Grafana [portainer]=Portainer [plantuml]=PlantUML)

erreur() { echo "Erreur : $*" >&2; exit 1; }

# --- Arguments ---------------------------------------------------------------

(($# == 1)) || erreur "usage : [FORCE=1] [NOUVEAUX_MDP=1] $0 <env>"
env_nom="$1"
# Même règle que la cible check-env du Makefile
[[ "$env_nom" =~ ^[a-z0-9][a-z0-9_-]*$ ]] \
  || erreur "nom d'instance invalide : $env_nom (attendu : minuscules, chiffres, - et _)"
FORCE="${FORCE:-}"
NOUVEAUX_MDP="${NOUVEAUX_MDP:-}"
[[ -f "$MODELE" ]] || erreur "modèle introuvable : $MODELE"

fichier="$ROOT/envs/$env_nom.env"
fichier_rel="envs/$env_nom.env"
existant=0
if [[ -e "$fichier" ]]; then
  [[ "$FORCE" == 1 ]] || erreur "$fichier_rel existe déjà : rien n'est modifié (FORCE=1 pour le régénérer)."
  [[ -f "$fichier" ]] || erreur "$fichier_rel n'est pas un fichier ordinaire."
  existant=1
fi
[[ -z "$NOUVEAUX_MDP" || "$NOUVEAUX_MDP" == 1 ]] || erreur "NOUVEAUX_MDP doit valoir 1 ou être absent."

# --- Valeurs existantes (FORCE=1) --------------------------------------------

# Dernière affectation de <clé> dans le fichier existant, guillemets englobants retirés
# (format env-file de Compose, lu sans source ni eval). Vide si absente.
valeur_existante() {
  ((existant)) || return 0
  local ligne valeur=""
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    ligne="${ligne%$'\r'}"
    if [[ "$ligne" =~ ^[[:space:]]*(export[[:space:]]+)?$1=(.*)$ ]]; then
      valeur="${BASH_REMATCH[2]}"
      if [[ "$valeur" =~ ^\"(.*)\"$ || "$valeur" =~ ^\'(.*)\'$ ]]; then
        valeur="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$fichier"
  printf '%s' "$valeur"
}

# --- Questions ---------------------------------------------------------------

# demander <variable> <question> <défaut> <fonction de validation>
# Réponse vide (ou fin de l'entrée) : défaut. Réponse invalide : nouvelle question en
# interactif, erreur sinon. La fonction de validation affiche elle-même le motif du refus.
demander() {
  local -n _resultat="$1"
  local reponse
  while true; do
    reponse=""
    read -r -p "$2 [$3] : " reponse || true
    reponse="${reponse:-$3}"
    if "$4" "$reponse"; then
      _resultat="$reponse"
      [[ -t 0 ]] || echo "$2 : $reponse"
      return 0
    fi
    [[ -t 0 ]] || exit 1
  done
}

valider_hostname() {
  local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
  if [[ ${#1} -le 253 && "$1" =~ ^${label}(\.${label})*$ ]]; then return 0; fi
  echo "  Nom invalide : $1 (minuscules, chiffres, - et ., ex. : gitlab.example.com)" >&2
  return 1
}

valider_tls_mode() {
  case "$1" in
    letsencrypt | custom | none) return 0 ;;
    *) echo "  TLS_MODE invalide : $1 (letsencrypt, custom ou none)" >&2; return 1 ;;
  esac
}

liste_profils=("$PROFILS_DIR"/*.env)
liste_profils=("${liste_profils[@]##*/}")
profils="${liste_profils[*]%.env}"
valider_profil() {
  if [[ "$1" =~ ^[a-z0-9_-]+$ && -f "$PROFILS_DIR/$1.env" ]]; then return 0; fi
  echo "  Profil inconnu : $1 (profils disponibles : $profils)" >&2
  return 1
}

# Réponses, renseignées par demander
domaine="" tls_mode="" profil=""

echo "Initialisation de $fichier_rel"
((existant)) && echo "(fichier existant : ses valeurs sont proposées par défaut)"
echo

# Domaine de base : déduit du hostname GitLab existant (gitlab.<domaine>), sinon localhost
gitlab_existant="$(valeur_existante GITLAB_HOSTNAME)"
domaine_existant="localhost"
[[ "$gitlab_existant" == gitlab.* ]] && domaine_existant="${gitlab_existant#gitlab.}"
demander domaine "Domaine de base de l'instance" "$domaine_existant" valider_hostname

declare -A hostnames
for s in "${services[@]}"; do
  cle="${s^^}_HOSTNAME"
  defaut="$s.$domaine"
  # Hostname existant proposé seulement si le domaine n'a pas changé
  if [[ "$domaine" == "$domaine_existant" ]]; then
    precedent="$(valeur_existante "$cle")"
    [[ -n "$precedent" ]] && defaut="$precedent"
  fi
  demander "hostnames[$s]" "Hostname de ${noms[$s]}" "$defaut" valider_hostname
done

tls_defaut="$(valeur_existante TLS_MODE)"
if ! [[ "$tls_defaut" =~ ^(letsencrypt|custom|none)$ ]]; then
  if est_hostname_local "$domaine"; then tls_defaut=none; else tls_defaut=letsencrypt; fi
fi
demander tls_mode "TLS_MODE (letsencrypt, custom, none)" "$tls_defaut" valider_tls_mode

profil_defaut="$(valeur_existante PLATFORM_PROFILE)"
valider_profil "${profil_defaut:-medium}" 2>/dev/null || profil_defaut=medium
demander profil "Profil de dimensionnement ($profils)" "${profil_defaut:-medium}" valider_profil

# --- Mots de passe -----------------------------------------------------------

# 24 caractères aléatoires, conformes aux règles SonarQube (≥ 12 caractères, majuscule, minuscule,
# chiffre, caractère spécial) et GitLab (≥ 8). Alphabet sans $ ' " \ # & + % ni espace : valeur sûre
# dans un env-file, l'interpolation Compose, la chaîne Ruby de GITLAB_OMNIBUS_CONFIG et un formulaire.
generer_mot_de_passe() {
  local alea mdp
  while true; do
    # head lit un bloc fini puis tr filtre : pas de SIGPIPE sous pipefail
    alea="$(head -c 2048 /dev/urandom | LC_ALL=C tr -dc 'A-Za-z0-9._,-')"
    mdp="${alea:0:24}"
    if [[ ${#mdp} -eq 24 && "$mdp" =~ ^[A-Za-z0-9] && "$mdp" =~ [A-Z] && "$mdp" =~ [a-z] \
          && "$mdp" =~ [0-9] && "$mdp" =~ [._,-] ]]; then
      printf '%s' "$mdp"
      return 0
    fi
  done
}

declare -A valeurs
nb_repris=0
# Secrets absents du fichier existant (variable ajoutée depuis sa génération) : générés, à signaler
absents=()
for cle in "${cles_mdp[@]}"; do
  precedent="$(valeur_existante "$cle")"
  if [[ "$NOUVEAUX_MDP" != 1 && -n "$precedent" && "$precedent" != change_me* ]]; then
    valeurs[$cle]="$precedent"
    nb_repris=$((nb_repris + 1))
  else
    valeurs[$cle]="$(generer_mot_de_passe)"
    ((existant)) && [[ "$NOUVEAUX_MDP" != 1 && -z "$precedent" ]] && absents+=("$cle")
  fi
done

# --- Valeurs dérivées --------------------------------------------------------

valeurs[TLS_MODE]="$tls_mode"
valeurs[PLATFORM_PROFILE]="$profil"
for s in "${services[@]}"; do
  valeurs[${s^^}_HOSTNAME]="${hostnames[$s]}"
done

# URLs publiques : hostname du service, servi par Traefik (contrôlé par scripts/check-env-urls.sh).
# GitLab : non renseignée, dérivée du hostname et du TLS_MODE (compose/gitlab.yml). SonarQube et
# Grafana : http:// quel que soit TLS_MODE tant que le TLS n'est pas livré (US 3-2 et 3-3).
url_gitlab="$(url_derivee "${hostnames[gitlab]}" "$tls_mode")"
valeurs[SONARQUBE_EXTERNAL_URL]="http://${hostnames[sonarqube]}"
valeurs[GRAFANA_EXTERNAL_URL]="http://${hostnames[grafana]}"

# --- Écriture ----------------------------------------------------------------

umask 077
# Suffixe .env : le fichier temporaire est couvert par le .gitignore (envs/*.env)
tmp="$(mktemp --suffix=.env "$ROOT/envs/.init-XXXXXX")"
trap 'rm -f "$tmp"' EXIT

# Valeurs transmises à awk par l'environnement (jamais sur la ligne de commande, visible de tous)
assignations=()
for cle in "${!valeurs[@]}"; do
  assignations+=("INIT_V_$cle=${valeurs[$cle]}")
done

{
  echo "# Généré par make init le $(date '+%Y-%m-%d %H:%M:%S') pour l'instance $env_nom (modèle : envs/.env.example)."
  echo "# Contient des secrets : ne jamais versionner ni partager ce fichier."
  echo
  # Chaque clé renseignée doit apparaître exactement une fois dans le modèle (« CLE= » ou « #CLE= »)
  # shellcheck disable=SC2016  # programme awk : les $ sont les champs awk, pas des variables shell
  env "${assignations[@]}" awk -v cles="${!valeurs[*]}" '
    BEGIN { n = split(cles, liste, " "); for (i = 1; i <= n; i++) vu[liste[i]] = 0 }
    match($0, /^#?[A-Z][A-Z0-9_]*=/) {
      cle = substr($0, 1, RLENGTH - 1); sub(/^#/, "", cle)
      if (cle in vu) { vu[cle]++; print cle "=" ENVIRON["INIT_V_" cle]; next }
    }
    { print }
    END {
      for (c in vu) if (vu[c] != 1) {
        print "Erreur : " c " présente " vu[c] " fois dans envs/.env.example (attendu : 1)" > "/dev/stderr"
        err = 1
      }
      exit err
    }' "$MODELE"
} > "$tmp"

if grep -nE '^[A-Z0-9_]+=change_me' "$tmp" >&2; then
  erreur "valeurs d'exemple restantes dans le fichier généré (voir ci-dessus)."
fi

if ((existant)); then
  # Sauvegarde jamais écrasée : suffixe -1, -2… si deux régénérations tombent dans la même seconde
  base="$fichier.bak.$(date +%Y%m%d-%H%M%S)"
  sauvegarde="$base"
  n=0
  while [[ -e "$sauvegarde" ]]; do n=$((n + 1)); sauvegarde="$base-$n"; done
  cp -p "$fichier" "$sauvegarde"
  chmod 600 "$sauvegarde"
fi
chmod 600 "$tmp"
mv -f "$tmp" "$fichier"

# --- Résumé (sans secret) ----------------------------------------------------

echo
echo "$fichier_rel généré (permissions 600)."
if ((existant)); then
  echo "  Sauvegarde de l'ancien fichier : ${sauvegarde#"$ROOT/"}"
  echo "  Ports, versions et autres réglages personnalisés repartent du modèle : les reprendre"
  echo "  depuis la sauvegarde si besoin."
fi
for s in "${services[@]}"; do
  printf '  %-23s %s\n' "${s^^}_HOSTNAME" "${hostnames[$s]}"
done
printf '  %-23s %s\n' TLS_MODE "$tls_mode" PLATFORM_PROFILE "$profil" \
  "GITLAB_EXTERNAL_URL" "$url_gitlab (dérivée)" \
  SONARQUBE_EXTERNAL_URL "${valeurs[SONARQUBE_EXTERNAL_URL]}" \
  GRAFANA_EXTERNAL_URL "${valeurs[GRAFANA_EXTERNAL_URL]}"
if ((nb_repris)); then
  echo "  Mots de passe : $nb_repris repris du fichier existant, $((${#cles_mdp[@]} - nb_repris)) générés."
else
  echo "  Mots de passe : ${#cles_mdp[@]} générés aléatoirement (à lire dans $fichier_rel)."
fi
if ((existant)) && [[ "$NOUVEAUX_MDP" == 1 ]]; then
  echo
  echo "Attention : nouveaux secrets. Sur une instance déjà déployée, le mot de passe PostgreSQL de"
  echo "SonarQube est déjà inscrit dans son volume et les mots de passe root GitLab et admin Portainer ne"
  echo "sont appliqués qu'au premier démarrage : les volumes doivent être recréés (ou les mots de passe"
  echo "changés dans les services)."
fi
if ((${#absents[@]})); then
  echo
  echo "Note : secret(s) absent(s) de l'ancien fichier, générés : ${absents[*]}."
  echo "Sur une instance déjà déployée, un mot de passe admin appliqué au premier démarrage seulement"
  echo "(Portainer) ne correspond pas au compte existant : y reporter le mot de passe réel si besoin."
fi
if [[ "$tls_mode" == none ]]; then
  # Même avertissement que make deploy (scripts/check-env-urls.sh)
  non_locaux=()
  for s in "${services[@]}"; do
    est_hostname_local "${hostnames[$s]}" || non_locaux+=("${hostnames[$s]}")
  done
  if ((${#non_locaux[@]})); then
    echo
    avertir_tls_none_non_local "${non_locaux[@]}"
  fi
else
  echo
  echo "Note : TLS_MODE=$tls_mode n'a pas encore d'effet (TLS : US 3-2 et 3-3) : les services sont"
  echo "servis en HTTP clair sur le port 80, identifiants compris. Ne pas exposer l'instance hors"
  echo "d'un réseau maîtrisé d'ici là."
fi
# *.localhost : résolu par les navigateurs et curl, pas toujours par le système (git, wget…)
non_resolus=()
for s in "${services[@]}"; do
  if est_hostname_local "${hostnames[$s]}" && ! getent hosts "${hostnames[$s]}" > /dev/null 2>&1; then
    non_resolus+=("${hostnames[$s]}")
  fi
done
if ((${#non_resolus[@]})); then
  echo
  echo "Note : ces hostnames ne sont pas résolus par le système (seuls les navigateurs et curl les"
  echo "résolvent d'eux-mêmes). Pour git et les autres outils, ajouter à /etc/hosts :"
  echo "  127.0.0.1 ${non_resolus[*]}"
fi
echo
echo "Étape suivante : make deploy ENV=$env_nom"
