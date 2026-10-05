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

# Contrôle de la paire fournie pour TLS_MODE=custom (docs/certificats.md) : <répertoire> <hostname>...
# Erreurs (retour 1) : cert.pem ou key.pem absent, vide ou illisible ; openssl absent (une paire
# invalide serait remplacée sans bruit par le certificat par défaut de Traefik) ; PEM illisible ; clé
# chiffrée ; clé ne correspondant pas au certificat ; certificat expiré ; extension SAN absente ;
# hostname non couvert. Avertissements : expiration sous 30 jours, clé lisible par d'autres.
# Messages sur stderr ; lecture seule.
verifier_certificats_custom() {
  local dir="$1" cert="$1/cert.pem" cle="$1/key.pem" f h sortie erreurs=0 non_couverts=()
  shift
  for f in "$cert" "$cle"; do
    if [[ ! -f "$f" || ! -s "$f" || ! -r "$f" ]]; then
      echo "Certificat attendu absent, vide ou illisible : $f (TLS_MODE=custom)." >&2
      erreurs=1
    fi
  done
  if ((erreurs)); then
    echo "  Déposer dans $dir/ la chaîne complète (cert.pem) et la clé privée non chiffrée (key.pem) :" >&2
    echo "  voir docs/certificats.md." >&2
    return 1
  fi
  if ! command -v openssl > /dev/null; then
    echo "openssl introuvable : requis en TLS_MODE=custom pour contrôler $cert et $cle." >&2
    return 1
  fi
  if ! openssl x509 -in "$cert" -noout 2> /dev/null; then
    echo "$cert n'est pas un certificat PEM lisible." >&2
    return 1
  fi
  if grep -q ENCRYPTED "$cle"; then
    echo "$cle est chiffrée : Traefik exige une clé non chiffrée (docs/certificats.md)." >&2
    return 1
  fi
  # -passin pass: : échoue au lieu de demander une phrase de passe
  if ! openssl pkey -in "$cle" -passin pass: -noout 2> /dev/null; then
    echo "$cle n'est pas une clé privée PEM lisible." >&2
    return 1
  fi
  if [[ "$(openssl x509 -in "$cert" -noout -pubkey)" != "$(openssl pkey -in "$cle" -passin pass: -pubout)" ]]; then
    echo "$cle ne correspond pas au certificat $cert." >&2
    return 1
  fi
  if ! openssl x509 -in "$cert" -noout -checkend 0 > /dev/null; then
    echo "$cert est expiré ($(openssl x509 -in "$cert" -noout -enddate))." >&2
    erreurs=1
  elif ! openssl x509 -in "$cert" -noout -checkend $((30 * 24 * 3600)) > /dev/null; then
    echo "Attention : $cert expire dans moins de 30 jours ($(openssl x509 -in "$cert" -noout -enddate)) :" >&2
    echo "  le renouveler (docs/certificats.md)." >&2
  fi
  if [[ "$(openssl x509 -in "$cert" -noout -ext subjectAltName 2> /dev/null)" != *DNS:* ]]; then
    echo "$cert n'a pas d'extension subjectAltName (DNS) : les navigateurs ignorent le CN et exigent un SAN." >&2
    erreurs=1
  else
    for h in "$@"; do
      # Code retour de -checkhost non fiable selon les versions d'OpenSSL : sortie analysée
      sortie="$(openssl x509 -in "$cert" -noout -checkhost "$h" 2> /dev/null || true)"
      [[ "$sortie" == *" does match certificate"* ]] || non_couverts+=("$h")
    done
    if ((${#non_couverts[@]})); then
      echo "$cert ne couvre pas : ${non_couverts[*]} (SAN ou joker attendu pour chaque *_HOSTNAME)." >&2
      erreurs=1
    fi
  fi
  if (((8#$(stat -c %a "$cle")) & 8#077)); then
    echo "Attention : $cle est lisible par d'autres utilisateurs (chmod 600 $cle)." >&2
  fi
  return "$erreurs"
}
