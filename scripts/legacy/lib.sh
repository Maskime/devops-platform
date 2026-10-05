#!/usr/bin/env bash
# Fonctions communes aux scripts de bootstrap repris de Software Factory (scripts/legacy/).
# Temporaire : ces scripts créent des données de test et seront remplacés par l'épopée 5.
# À sourcer, pas à exécuter. Fournit :
#   charger_env — exporte les variables de envs/$ENV.env (ENV obligatoire)
#   dc          — docker compose de l'instance, quel que soit le répertoire courant
#   ROOT        — racine du repo
#   RESEAU      — réseau Docker de la plateforme (positionné par charger_env)
#   les fonctions de scripts/lib/tls.sh (url_derivee, est_hostname_local…)

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Règles TLS partagées (schema_tls, url_derivee, est_hostname_local)
# shellcheck source=scripts/lib/tls.sh
source "$ROOT/scripts/lib/tls.sh"

# Lit le fichier d'environnement ligne à ligne (format env-file de Compose), sans `source` ni eval :
# les valeurs peuvent contenir des caractères spéciaux du shell ($ & ; ' "…) sans être interprétées.
charger_env() {
  [[ -n "${ENV:-}" ]] || { echo "Erreur : ENV non défini (ex. : ENV=local $0)." >&2; exit 1; }
  ENV_FILE="$ROOT/envs/$ENV.env"
  [[ -f "$ENV_FILE" ]] || { echo "Erreur : $ENV_FILE introuvable (copier envs/.env.example)." >&2; exit 1; }

  local ligne cle valeur
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    ligne="${ligne%$'\r'}"
    [[ "$ligne" =~ ^[[:space:]]*(#|$) ]] && continue
    if [[ ! "$ligne" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)=(.*)$ ]]; then
      echo "Avertissement : ligne ignorée dans $ENV_FILE : $ligne" >&2
      continue
    fi
    cle="${BASH_REMATCH[2]}" valeur="${BASH_REMATCH[3]}"
    # Guillemets englobants retirés, comme le fait Compose
    if [[ "$valeur" =~ ^\"(.*)\"$ || "$valeur" =~ ^\'(.*)\'$ ]]; then
      valeur="${BASH_REMATCH[1]}"
    fi
    export "$cle=$valeur"
  done < "$ENV_FILE"

  # Même défaut que `networks.platform.name` dans compose/*.yml
  # shellcheck disable=SC2034  # utilisée par les scripts qui sourcent ce fichier
  RESEAU="${PLATFORM_NETWORK:-devops-platform}"
}

dc() {
  docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml" --env-file "$ENV_FILE" "$@"
}
