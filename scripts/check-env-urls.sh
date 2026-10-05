#!/usr/bin/env bash
# Vérifie la cohérence de l'exposition d'une instance. Appelé par `make check-env` (donc `make deploy`).
#   - TLS_MODE ∈ {letsencrypt, custom, none} (vide ou absent : none) ;
#   - chaque URL publique (*_EXTERNAL_URL) désigne le hostname routé par Traefik pour ce service
#     (*_HOSTNAME), sans port, en http:// en mode none (Traefik n'y sert que le port 80) : sinon liens,
#     redirections et appels des scripts aboutissent à un 404 du proxy ou à un port non publié ;
#   - TLS_MODE=none avec un hostname non local : avertissement (HTTP clair), non bloquant.
#
# Usage : scripts/check-env-urls.sh <fichier env>
# Valeur effective, comme Compose : variable du shell prioritaire, sinon dernière affectation du
# fichier (guillemets englobants retirés). Lecture seule.
set -euo pipefail

# shellcheck source=scripts/lib/tls.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/tls.sh"

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

tls_mode="$(valeur_effective TLS_MODE)"
tls_mode="${tls_mode:-none}"
case "$tls_mode" in
  letsencrypt | custom | none) ;;
  *)
    echo "TLS_MODE invalide : $tls_mode (valeurs admises : letsencrypt, custom, none)." >&2
    echo "  Corriger dans $fichier : TLS_MODE=none (local) ou letsencrypt, custom" >&2
    exit 1
    ;;
esac
if [[ -n "${TLS_MODE+x}" ]]; then
  echo "Attention : TLS_MODE=$tls_mode vient du shell et remplace la valeur de $fichier." >&2
fi

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
  # Mode none : HTTP seul (port 80) ; autres modes : schéma de l'URL conservé
  schema="http"
  [[ "$tls_mode" != none && "$url" == https://* ]] && schema="https"
  attendu="$schema://$hote"
  if [[ "$url" =~ ^(https?)://([^/:]+)(:[0-9]*)?(/.*)?$ ]]; then
    schema_url="${BASH_REMATCH[1]}" hote_url="${BASH_REMATCH[2]}" port_url="${BASH_REMATCH[3]}"
    [[ "$schema_url" == "$schema" && "${hote_url,,}" == "${hote,,}" && -z "$port_url" ]] && continue
  fi
  if [[ "$tls_mode" == none ]]; then
    echo "$cle_url=$url ne correspond pas à $cle_hote=$hote en TLS_MODE=none (Traefik route le port 80, en HTTP, par hostname)." >&2
  else
    echo "$cle_url=$url ne correspond pas à $cle_hote=$hote (Traefik route le port 80 par hostname)." >&2
  fi
  echo "  Corriger dans $fichier : $cle_url=$attendu" >&2
  erreurs=1
done

if ((erreurs)); then
  echo "URL(s) publique(s) incohérente(s) avec les hostnames de $fichier (voir ci-dessus)." >&2
  exit 1
fi

# Une branche par mode : HTTPS (letsencrypt, custom) livré par les US 3-2 et 3-3
case "$tls_mode" in
  none)
    non_locaux=()
    for service in gitlab sonarqube grafana portainer plantuml; do
      hote="$(valeur_effective "${service^^}_HOSTNAME")"
      hote="${hote:-$service.localhost}"
      est_hostname_local "$hote" || non_locaux+=("$hote")
    done
    if ((${#non_locaux[@]})); then avertir_tls_none_non_local "${non_locaux[@]}"; fi
    ;;
  letsencrypt | custom)
    echo "Note : TLS_MODE=$tls_mode n'a pas encore d'effet (US 3-2 et 3-3) : HTTP clair sur le port 80." >&2
    ;;
esac
