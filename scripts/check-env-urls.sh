#!/usr/bin/env bash
# Vérifie que chaque URL publique (*_EXTERNAL_URL) d'une instance désigne le hostname routé par
# Traefik pour ce service (*_HOSTNAME), sans port : sinon liens, redirections et appels des scripts
# aboutissent à un 404 du proxy ou à un port qui n'est plus publié. Appelé par `make check-env`.
#
# Usage : scripts/check-env-urls.sh <fichier env>
# Valeur effective, comme Compose : variable du shell prioritaire, sinon dernière affectation du
# fichier (guillemets englobants retirés). Lecture seule.
set -euo pipefail

(($# == 1)) || { echo "Erreur : usage : $0 <fichier env>" >&2; exit 1; }
fichier="$1"
[[ -f "$fichier" ]] || { echo "Erreur : fichier introuvable : $fichier" >&2; exit 1; }

# Dernière affectation de <clé> dans le fichier, guillemets englobants retirés (vide si absente)
valeur_fichier() {
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

valeur_effective() {
  if [[ -n "${!1+x}" ]]; then printf '%s' "${!1}"; else valeur_fichier "$1"; fi
}

erreurs=0
for service in gitlab sonarqube grafana; do
  cle_url="${service^^}_EXTERNAL_URL"
  cle_hote="${service^^}_HOSTNAME"
  url="$(valeur_effective "$cle_url")"
  # URL absente : défaut compose dérivé du hostname (GITLAB_EXTERNAL_URL, obligatoire, est
  # signalée par `docker compose config`)
  [[ -n "$url" ]] || continue
  hote="$(valeur_effective "$cle_hote")"
  hote="${hote:-$service.localhost}"
  schema="http"
  [[ "$url" == https://* ]] && schema="https"
  attendu="$schema://$hote"
  if [[ "$url" =~ ^https?://([^/:]+)(:[0-9]*)?(/.*)?$ ]]; then
    hote_url="${BASH_REMATCH[1]}" port_url="${BASH_REMATCH[2]}"
    [[ "${hote_url,,}" == "${hote,,}" && -z "$port_url" ]] && continue
  fi
  echo "$cle_url=$url ne correspond pas à $cle_hote=$hote (Traefik route le port 80 par hostname)." >&2
  echo "  Corriger dans $fichier : $cle_url=$attendu" >&2
  erreurs=1
done

if ((erreurs)); then
  echo "URL(s) publique(s) incohérente(s) avec les hostnames de $fichier (voir ci-dessus)." >&2
  exit 1
fi
