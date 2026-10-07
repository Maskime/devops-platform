#!/usr/bin/env bash
# Règles TLS partagées par scripts/check-env-urls.sh (make check-env, make deploy),
# scripts/init-env.sh (make init), scripts/bootstrap/ (make bootstrap) et scripts/smoke.sh (make smoke).
# Fichier à sourcer : ne modifie pas les options du shell appelant.

# Hostname local : localhost ou *.localhost (RFC 6761, résolus vers la boucle locale). Une IP n'est pas
# un hostname valable : Traefik route par Host() et une IP ne peut pas désigner plusieurs services.
est_hostname_local() {
  local h="${1,,}"
  [[ "$h" == localhost || "$h" == *.localhost ]]
}

# Adresse IPv4 ou IPv6 (Let's Encrypt n'émet pas de certificat pour une IP via Traefik)
est_adresse_ip() {
  [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ || "$1" == *:* ]]
}

# Email du compte ACME : forme x@y.z, sans espace. Motif du refus sur stderr.
valider_email_acme() {
  if [[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]]; then return 0; fi
  echo "  ACME_EMAIL invalide : ${1:-(vide)} (attendu : adresse joignable, ex. : ops@mondomaine.fr)" >&2
  return 1
}

# Contrôles de TLS_MODE=letsencrypt : <email> <challenge> <hostname>...
# Erreurs (retour 1) : email absent ou invalide ; challenge autre que http, tls (vide : http) ; hostname
# local ou IP (Let's Encrypt ne peut pas les valider). Avertissement : email d'un domaine d'exemple,
# refusé par Let's Encrypt. Messages sur stderr ; lecture seule.
verifier_letsencrypt() {
  local email="$1" challenge="${2:-http}" h erreurs=0 refuses=()
  shift 2
  if [[ -z "$email" ]]; then
    echo "ACME_EMAIL absent : obligatoire en TLS_MODE=letsencrypt (compte Let's Encrypt, avis d'expiration)." >&2
    erreurs=1
  elif ! valider_email_acme "$email"; then
    erreurs=1
  elif [[ "${email##*@}" =~ ^example\.(com|org|net)$ ]]; then
    echo "Attention : ACME_EMAIL=$email : Let's Encrypt refuse les domaines d'exemple." >&2
  fi
  case "$challenge" in
    http | tls) ;;
    *) echo "ACME_CHALLENGE invalide : $challenge (valeurs admises : http, tls)." >&2; erreurs=1 ;;
  esac
  for h in "$@"; do
    if est_hostname_local "$h" || est_adresse_ip "$h"; then refuses+=("$h"); fi
  done
  if ((${#refuses[@]})); then
    echo "Hostname(s) local(aux) ou IP en TLS_MODE=letsencrypt : ${refuses[*]}." >&2
    echo "  Let's Encrypt ne valide que des noms publics résolus vers le serveur : définir chaque" >&2
    echo "  *_HOSTNAME (défaut : <service>.localhost), ou TLS_MODE=none en local." >&2
    erreurs=1
  fi
  return "$erreurs"
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

# Contrôle de la paire fournie pour TLS_MODE=custom (docs/certificats.md) : <répertoire> <hostname>...
# Erreurs (retour 1) : cert.pem ou key.pem absent, vide ou illisible ; openssl absent (une paire
# invalide serait remplacée sans bruit par le certificat par défaut de Traefik) ; PEM illisible ; clé
# chiffrée ; clé ne correspondant pas au certificat ; certificat expiré ; extension SAN absente ;
# hostname non couvert ; CA facultative invalide (verifier_ca_custom). Avertissements : expiration sous
# 30 jours, clé lisible par d'autres. Messages sur stderr ; lecture seule.
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
  verifier_ca_custom "$dir" || erreurs=1
  if (((8#$(stat -c %a "$cle")) & 8#077)); then
    echo "Attention : $cle est lisible par d'autres utilisateurs (chmod 600 $cle)." >&2
  fi
  return "$erreurs"
}

# Contrôle de la CA facultative de TLS_MODE=custom, <répertoire>/ca/ca.pem (docs/certificats.md), montée
# dans gitlab-runner. Erreurs (retour 1) : <répertoire>/ca/ contient autre chose que ca.pem et .gitkeep
# (une clé de CA serait copiée sur l'hôte cible, montée dans le runner) ; ca.pem vide, illisible, pas
# un certificat PEM ou contenant une clé privée ; <répertoire>/cert.pem non vérifiable avec cette CA
# (-partial_chain : une CA intermédiaire suffit, comme pour le runner et curl). Sans ca.pem : rien.
# Messages sur stderr ; lecture seule. Suppose <répertoire>/cert.pem lisible (verifier_certificats_custom).
verifier_ca_custom() {
  local dir="$1/ca" ca="$1/ca/ca.pem" cert="$1/cert.pem" f intrus=() sortie
  [[ -d "$dir" ]] || return 0
  for f in "$dir"/* "$dir"/.[!.]* "$dir"/..?*; do
    [[ -e "$f" || -L "$f" ]] || continue
    case "${f##*/}" in
      ca.pem | .gitkeep) ;;
      *) intrus+=("${f##*/}") ;;
    esac
  done
  if ((${#intrus[@]})); then
    echo "$dir/ ne doit contenir que ca.pem (certificat public de la CA) : retirer ${intrus[*]}." >&2
    echo "  Le répertoire est monté dans gitlab-runner et copié sur l'hôte cible : jamais de clé de CA." >&2
    return 1
  fi
  [[ -e "$ca" ]] || return 0
  if [[ ! -f "$ca" || ! -s "$ca" || ! -r "$ca" ]]; then
    echo "CA vide ou illisible : $ca (fichier facultatif : le retirer, ou y déposer le certificat de la CA)." >&2
    return 1
  fi
  if grep -q "PRIVATE KEY" "$ca"; then
    echo "$ca contient une clé privée : n'y déposer que le certificat de la CA (docs/certificats.md)." >&2
    return 1
  fi
  if ! openssl x509 -in "$ca" -noout 2> /dev/null; then
    echo "$ca n'est pas un certificat PEM lisible." >&2
    return 1
  fi
  if ! sortie="$(openssl verify -partial_chain -CAfile "$ca" -untrusted "$cert" "$cert" 2>&1)"; then
    echo "$cert n'est pas vérifiable avec la CA $ca :" >&2
    echo "  $(grep -m1 -i error <<<"$sortie" || tail -n1 <<<"$sortie")" >&2
    echo "  ca.pem doit contenir la CA (racine ou intermédiaire) qui a émis le certificat." >&2
    return 1
  fi
}
