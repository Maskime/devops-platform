#!/usr/bin/env bash
# Règles TLS partagées par scripts/check-env-urls.sh (make check-env, make deploy),
# scripts/init-env.sh (make init) et scripts/legacy/lib.sh (bootstrap). Fichier à sourcer : ne
# modifie pas les options du shell appelant.

# Hostname local : localhost ou *.localhost (RFC 6761, résolus vers la boucle locale). Une IP n'est pas
# un hostname valable : Traefik route par Host() et une IP ne peut pas désigner plusieurs services.
est_hostname_local() {
  local h="${1,,}"
  [[ "$h" == localhost || "$h" == *.localhost ]]
}

# Avertissement TLS_MODE=none avec des hostnames non locaux (passés en arguments), sur stderr
avertir_tls_none_non_local() {
  {
    echo "Attention : TLS_MODE=none avec des hostnames non locaux : $*"
    echo "  Les services sont servis en HTTP clair sur le port 80, identifiants compris. Réserver ce"
    echo "  mode au poste local ou à un réseau maîtrisé ; sinon TLS_MODE=letsencrypt ou custom."
  } >&2
}

# Schéma des URLs publiques selon TLS_MODE (<mode>, vide = none) : http en none, https sinon
schema_tls() {
  case "${1:-none}" in
    letsencrypt | custom) printf 'https' ;;
    *) printf 'http' ;;
  esac
}

# URL publique dérivée d'un hostname et du TLS_MODE : url_derivee <hostname> <mode>.
# Même règle que l'external_url de GitLab, calculée en Ruby dans compose/gitlab.yml : à garder
# identiques.
url_derivee() {
  printf '%s://%s' "$(schema_tls "${2:-}")" "$1"
}
