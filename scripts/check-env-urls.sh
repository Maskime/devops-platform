#!/usr/bin/env bash
# Vérifie la cohérence de l'exposition d'une instance. Appelé par `make check-env` (donc `make deploy`).
#   - TLS_MODE ∈ {letsencrypt, custom, none} (vide ou absent : none) ;
#   - chaque URL publique (*_EXTERNAL_URL) désigne le hostname routé par Traefik pour ce service
#     (*_HOSTNAME), sans port, en http:// en mode none (Traefik n'y sert que le port 80) et
#     obligatoirement en https:// en modes custom et letsencrypt (HTTP redirigé vers HTTPS) : sinon
#     liens, redirections et appels des scripts aboutissent à un 404 du proxy, à un port non publié ou
#     à une redirection. GITLAB_EXTERNAL_URL peut être absente (dérivée du hostname et du TLS_MODE) ;
#   - TLS_MODE=none avec un hostname non local : avertissement (HTTP clair), non bloquant ;
#   - TLS_MODE=custom : certificats fournis dans config/certs/ présents, cohérents et couvrant chaque
#     hostname (verifier_certificats_custom, scripts/lib/tls.sh) ;
#   - TLS_MODE=letsencrypt : hostnames publics (ni local, ni IP), ACME_EMAIL valide, ACME_CHALLENGE
#     connu (verifier_letsencrypt, scripts/lib/tls.sh).
#   - GITLAB_SSH_PORT : entier de 1 à 65535, hors 80 et 443 (ports de Traefik) ; 22 signalé.
#
# Usage : scripts/check-env-urls.sh <fichier env>
# Valeur effective, comme Compose : variable du shell prioritaire, sinon dernière affectation du
# fichier (guillemets englobants retirés). Lecture seule.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/tls.sh
source "$ROOT/scripts/lib/tls.sh"

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
  hote="$(valeur_effective "$cle_hote")"
  hote="${hote:-$service.localhost}"
  # Mode none : HTTP seul (port 80) ; custom et letsencrypt : HTTPS seul (port 443)
  schema="http"
  [[ "$tls_mode" != none ]] && schema="https"
  # URL absente : GitLab la dérive du hostname et du TLS_MODE (compose/gitlab.yml, url_derivee) ;
  # SonarQube et Grafana ont un défaut compose en http:// (#78), refusé en HTTPS.
  if [[ -z "$url" ]]; then
    if [[ "$service" != gitlab && "$schema" == https ]]; then
      echo "$cle_url absente : son défaut (http://$hote) est incorrect en TLS_MODE=$tls_mode." >&2
      echo "  Ajouter dans $fichier : $cle_url=$schema://$hote" >&2
      erreurs=1
    fi
    continue
  fi
  attendu="$schema://$hote"
  if [[ "$url" =~ ^(https?)://([^/:]+)(:[0-9]*)?(/.*)?$ ]]; then
    schema_url="${BASH_REMATCH[1]}" hote_url="${BASH_REMATCH[2]}" port_url="${BASH_REMATCH[3]}"
    [[ "$schema_url" == "$schema" && "${hote_url,,}" == "${hote,,}" && -z "$port_url" ]] && continue
  fi
  case "$tls_mode" in
    none) echo "$cle_url=$url ne correspond pas à $cle_hote=$hote en TLS_MODE=none (Traefik route le port 80, en HTTP, par hostname)." >&2 ;;
    *) echo "$cle_url=$url ne correspond pas à $cle_hote=$hote en TLS_MODE=$tls_mode (Traefik sert HTTPS sur le port 443, par hostname)." >&2 ;;
  esac
  echo "  Corriger dans $fichier : $cle_url=$attendu" >&2
  erreurs=1
done

# Port SSH de GitLab : publié par Compose et lu en base 10 par GitLab (URLs de clone) ; un zéro en tête
# ou une valeur non numérique les ferait diverger, 80 et 443 sont pris par Traefik
port_ssh="$(valeur_effective GITLAB_SSH_PORT)"
port_ssh="${port_ssh:-2222}"
if [[ ! "$port_ssh" =~ ^[1-9][0-9]{0,4}$ ]] || ((port_ssh > 65535)) || ((port_ssh == 80 || port_ssh == 443)); then
  echo "GITLAB_SSH_PORT invalide : $port_ssh (entier de 1 à 65535, sans zéro en tête, hors 80 et 443)." >&2
  echo "  Corriger dans $fichier : GITLAB_SSH_PORT=2222" >&2
  erreurs=1
elif ((port_ssh == 22)); then
  echo "Attention : GITLAB_SSH_PORT=22 entre en conflit avec le sshd de l'hôte s'il écoute sur ce port." >&2
fi

if ((erreurs)); then
  echo "Exposition incohérente dans $fichier (voir ci-dessus)." >&2
  exit 1
fi

# Hostnames effectifs des services exposés par Traefik
hotes=()
for service in gitlab sonarqube grafana portainer plantuml; do
  hote="$(valeur_effective "${service^^}_HOSTNAME")"
  hotes+=("${hote:-$service.localhost}")
done

# Une branche par mode
case "$tls_mode" in
  none)
    non_locaux=()
    for hote in "${hotes[@]}"; do
      est_hostname_local "$hote" || non_locaux+=("$hote")
    done
    if ((${#non_locaux[@]})); then avertir_tls_none_non_local "${non_locaux[@]}"; fi
    ;;
  custom)
    verifier_certificats_custom "$ROOT/config/certs" "${hotes[@]}" || {
      echo "Certificats de TLS_MODE=custom invalides (voir ci-dessus)." >&2
      exit 1
    }
    ;;
  letsencrypt)
    verifier_letsencrypt "$(valeur_effective ACME_EMAIL)" "$(valeur_effective ACME_CHALLENGE)" "${hotes[@]}" || {
      echo "Configuration de TLS_MODE=letsencrypt invalide dans $fichier (voir ci-dessus)." >&2
      exit 1
    }
    ;;
esac
