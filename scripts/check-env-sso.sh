#!/usr/bin/env bash
# Contrôle des variables de la passerelle d'authentification (docs/sso.md) d'un fichier d'instance,
# lancé par make check-env (donc make deploy, bootstrap…) avant `docker compose config`.
#
# Usage : scripts/check-env-sso.sh envs/<env>.env
#   - identifiant, secret client et secret de cookie (SSO_GITLAB_CLIENT_ID, SSO_GITLAB_CLIENT_SECRET et
#     SSO_COOKIE_SECRET) présents, sinon commande à lancer pour les ajouter sans régénérer les autres
#     secrets, et au format attendu ;
#   - SSO_GITLAB_GROUPE : vide ou chemin de groupe GitLab.
# Valeur effective comme Compose (variable du shell prioritaire). Les secrets ne sont jamais affichés.
# Code de sortie : 0 si tout est conforme, 1 sinon.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"

(($# == 1)) || { echo "Usage : $0 envs/<env>.env" >&2; exit 1; }
env_file="$1"
[[ -f "$env_file" ]] || { echo "Fichier introuvable : $env_file" >&2; exit 1; }
env="$(basename "$env_file" .env)"

# Clé → motif attendu et description du format (même règles que envs/.env.example et
# scripts/init-env.sh ; formats sans caractère à encoder dans une requête de formulaire, cf.
# config/oauth2-proxy/lanceur.sh)
declare -A motifs=(
  [SSO_GITLAB_CLIENT_ID]='^[0-9a-f]{64}$'
  [SSO_GITLAB_CLIENT_SECRET]='^[A-Za-z0-9._,-]{16,128}$'
  [SSO_COOKIE_SECRET]='^([A-Za-z0-9]{16}|[A-Za-z0-9]{24}|[A-Za-z0-9]{32})$'
)
declare -A formats=(
  [SSO_GITLAB_CLIENT_ID]="64 caractères hexadécimaux minuscules"
  [SSO_GITLAB_CLIENT_SECRET]="16 à 128 caractères parmi lettres sans accent, chiffres, . _ , -"
  [SSO_COOKIE_SECRET]="exactement 16, 24 ou 32 caractères alphanumériques"
)
cles=(SSO_GITLAB_CLIENT_ID SSO_GITLAB_CLIENT_SECRET SSO_COOKIE_SECRET)

erreurs=0
absentes=()
for cle in "${cles[@]}"; do
  valeur="$(env_valeur "$env_file" "$cle")"
  if [[ -z "$valeur" ]]; then
    absentes+=("$cle")
  elif [[ ! "$valeur" =~ ${motifs[$cle]} ]]; then
    echo "$cle invalide dans $env_file (valeur non affichée) : ${formats[$cle]}." >&2
    erreurs=1
  fi
done
if ((${#absentes[@]})); then
  {
    echo "Variable(s) de la passerelle d'authentification absente(s) ou vide(s) dans $env_file : ${absentes[*]}."
    echo "  Les ajouter, sans régénérer les autres secrets : make init ENV=$env COMPLETER=1"
    echo "  (une ligne vide existante est à supprimer avant). Voir docs/sso.md."
  } >&2
  erreurs=1
fi

groupe="$(env_valeur "$env_file" SSO_GITLAB_GROUPE)"
segment='[A-Za-z0-9_][A-Za-z0-9_.-]*'
if [[ -n "$groupe" && ! "$groupe" =~ ^${segment}(/${segment})*$ ]]; then
  echo "SSO_GITLAB_GROUPE invalide : $groupe (chemin complet d'un groupe GitLab attendu, ex. : equipe/devops ; vide : pas de restriction)." >&2
  erreurs=1
fi

exit "$erreurs"
