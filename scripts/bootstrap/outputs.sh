#!/usr/bin/env bash
# Fichier de sortie d'une instance pour les projets consommateurs : outputs/<env>.env (URLs publiques,
# URL de l'API GitLab, token d'analyse SonarQube). Lit uniquement des fichiers locaux (envs/<env>.env,
# outputs/<env>.sonarqube-token), aucun appel Docker : régénérer est toujours sans risque. Idempotent.
# Lancé par `make bootstrap ENV=<env>` (scripts/instance.sh bootstrap) après chaque étape réussie.
# Documentation : docs/sortie-instance.md.
#
# Usage : scripts/bootstrap/outputs.sh envs/<env>.env
# Variables positionnées par scripts/instance.sh (absentes : lancement manuel) :
#   SORTIE_SERVICES  services de l'instance (séparés par des espaces) ; absente : tous
#   SORTIE_ETAPES    étapes de bootstrap exécutées avec succès ; absente : aucune
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/tls.sh
source "$ROOT/scripts/lib/tls.sh"
# shellcheck source=scripts/lib/sonarqube.sh
source "$ROOT/scripts/lib/sonarqube.sh" # MOTIF_TOKEN_SONAR (définitions seules, aucun appel Docker)

# Valeurs écrites sans guillemets (lues à l'identique par Compose, `source`, `docker --env-file` et
# l'import de variables CI) : seuls des caractères sans signification pour ces lecteurs sont admis
readonly MOTIF_URL='^https?://[A-Za-z0-9.-]+(:[0-9]+)?(/[A-Za-z0-9._~/-]*)?$'
readonly CA_CUSTOM=config/certs/ca/ca.pem

erreur() { echo "Erreur : $*" >&2; exit 1; }

(($# == 1)) || { echo "Usage : $0 envs/<env>.env" >&2; exit 1; }
env_file="$1"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file"
env="$(basename "$env_file" .env)"
[[ "$env" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || erreur "nom d'instance invalide : $env"
sortie="outputs/$env.env"
token_fichier="outputs/$env.sonarqube-token"

if [[ -n "${SORTIE_SERVICES+x}" ]]; then
  services=" $SORTIE_SERVICES "
  origine="scripts/instance.sh bootstrap (étapes : ${SORTIE_ETAPES:-aucune})"
else
  services=" gitlab sonarqube grafana "
  origine="$0 (lancement manuel, services supposés présents)"
fi
etapes=" ${SORTIE_ETAPES:-} "

tls_mode="$(env_valeur "$env_file" TLS_MODE)"
tls_mode="${tls_mode:-none}"

# URL publique d'un service : *_EXTERNAL_URL si renseignée, sinon même repli que Compose (GitLab :
# url_derivee, comme compose/gitlab.yml ; SonarQube et Grafana : http://<hostname>, comme
# compose/sonarqube.yml et compose/observability.yml, repli que make check-env réserve au mode none)
url_publique() { # <service>
  local service="$1" url hote
  url="$(env_valeur "$env_file" "${service^^}_EXTERNAL_URL")"
  if [[ -z "$url" ]]; then
    hote="$(env_valeur "$env_file" "${service^^}_HOSTNAME")"
    hote="${hote:-$service.localhost}"
    if [[ "$service" == gitlab ]]; then url="$(url_derivee "$hote" "$tls_mode")"; else url="http://$hote"; fi
  fi
  url="${url%/}"
  [[ "$url" =~ $MOTIF_URL ]] \
    || erreur "URL publique de $service non exportable : $url (attendu : http(s)://hôte[:port][/chemin], sans caractère spécial)"
  printf '%s' "$url"
}

present() { [[ "$services" == *" $1 "* ]]; }

lignes=(
  "# Instance $env : généré par $origine le $(date -Iseconds)."
  "# Régénéré à chaque bootstrap : ne pas modifier. Contient un secret : ne pas versionner ni diffuser."
  "DEVOPS_PLATFORM_ENV=$env"
)

if present gitlab; then
  url="$(url_publique gitlab)"
  hote="$(env_valeur "$env_file" GITLAB_HOSTNAME)"
  hote="${hote:-gitlab.localhost}"
  port_ssh="$(env_valeur "$env_file" GITLAB_SSH_PORT)"
  port_ssh="${port_ssh:-2222}"
  [[ "$port_ssh" =~ ^[0-9]{1,5}$ ]] || erreur "GITLAB_SSH_PORT invalide : $port_ssh"
  lignes+=("GITLAB_URL=$url" "GITLAB_API_URL=$url/api/v4" "GITLAB_SSH_URL=ssh://git@$hote:$port_ssh")
else
  lignes+=("# GitLab : service absent de l'instance.")
fi

if present sonarqube; then
  url="$(url_publique sonarqube)"
  lignes+=("SONAR_HOST_URL=$url")
  token=""
  if [[ -s "$token_fichier" ]]; then
    IFS= read -r token <"$token_fichier" || true
  fi
  if [[ -z "$token" ]]; then
    # Ligne omise plutôt que vide : un `source` écraserait la variable du consommateur
    lignes+=("# Token d'analyse absent de ce poste ($token_fichier) ; make bootstrap-sonarqube ENV=$env le récupère.")
    echo "Attention : $token_fichier absent : SONAR_TOKEN non écrit dans $sortie." >&2
  else
    [[ "$token" =~ $MOTIF_TOKEN_SONAR ]] || erreur "contenu inattendu dans $token_fichier (token non exporté)"
    if [[ "$etapes" != *" sonarqube "* ]]; then
      lignes+=("# Token d'analyse non revérifié lors de ce bootstrap (make bootstrap-sonarqube ENV=$env le contrôle).")
    fi
    lignes+=("SONAR_TOKEN=$token")
  fi
else
  lignes+=("# SonarQube : service absent de l'instance.")
fi

if present grafana; then
  url="$(url_publique grafana)"
  lignes+=("GRAFANA_URL=$url")
else
  lignes+=("# Grafana : service absent de l'instance.")
fi

if [[ "$tls_mode" == custom && -f "$CA_CUSTOM" ]]; then
  lignes+=("# Certificats signés par une CA privée : fournir $CA_CUSTOM aux clients (git, curl, scanners).")
fi

# Écriture atomique, répertoire 700 et fichier 600
umask 077
mkdir -p outputs
chmod 700 outputs
tmp="$(mktemp "outputs/.$env.env.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
printf '%s\n' "${lignes[@]}" >"$tmp"
chmod 600 "$tmp"
mv -f "$tmp" "$sortie"
trap - EXIT
echo "Fichier de sortie : $sortie"
