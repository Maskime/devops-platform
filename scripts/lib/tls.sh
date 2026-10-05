#!/usr/bin/env bash
# Règles TLS partagées par scripts/check-env-urls.sh (make check-env, make deploy) et
# scripts/init-env.sh (make init). Fichier à sourcer : ne modifie pas les options du shell appelant.

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
