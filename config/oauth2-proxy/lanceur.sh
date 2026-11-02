#!/bin/sh
# Lanceur de la passerelle d'authentification (service oauth2-proxy, compose/proxy.yml) : sonde l'application
# OAuth GitLab, puis démarre oauth2-proxy en mode actif ou en mode refus. Mécanisme : docs/sso.md.
#
# Sonde : POST http://gitlab/oauth/token (réseau de la plateforme, sans TLS) avec les identifiants de
# l'application et un code d'autorisation factice. GitLab authentifie le client avant le code :
#   400 (invalid_grant)  → application présente, identifiants acceptés : mode actif ;
#   401 (invalid_client) → application absente ou secret différent : mode refus « non initialisée »
#                          (make bootstrap ENV=<env>) ;
#   autre / injoignable  → mode refus « GitLab indisponible ».
# Mode refus : oauth2-proxy sert une page explicite sans lien de connexion (réponse 403) pendant
# DUREE_REFUS secondes, puis le conteneur s'arrête ; Docker le relance (restart) et la sonde est rejouée.
# make bootstrap redémarre la passerelle dès l'application créée.
#
# Exécuté par le sh (busybox) de l'image oauth2-proxy -alpine. Les secrets sont lus dans les fichiers des
# secrets Compose et ne passent jamais en argument de processus (corps de la sonde sur l'entrée standard
# de wget, options *-file d'oauth2-proxy).
set -eu

readonly FICHIER_CLIENT=/run/secrets/sso_client_secret
readonly FICHIER_COOKIE=/run/secrets/sso_cookie_secret
readonly REPERTOIRE=/etc/devops-platform/oauth2-proxy
# CA privée de TLS_MODE=custom (overlay compose/tls/custom.yml), facultative
readonly CA=/etc/devops-platform/ca/ca.pem
readonly DUREE_REFUS=120

erreur() { echo "Erreur : $*" >&2; exit 1; }

[ -n "${SSO_CLIENT_ID:-}" ] || erreur "SSO_GITLAB_CLIENT_ID absent : make init ENV=<env> COMPLETER=1 (docs/sso.md)"
for f in "$FICHIER_CLIENT" "$FICHIER_COOKIE"; do
  [ -s "$f" ] || erreur "secret $f absent ou vide : SSO_GITLAB_CLIENT_SECRET et SSO_COOKIE_SECRET (make init ENV=<env> COMPLETER=1)"
done

# URL publique de GitLab : même règle que l'external_url de GitLab (compose/gitlab.yml, url_derivee de
# scripts/lib/tls.sh) ; cookies Secure dès que l'instance est en HTTPS
case "${SSO_TLS_MODE:-none}" in
  letsencrypt | custom) schema=https securise=true ;;
  *) schema=http securise=false ;;
esac
url="${SSO_GITLAB_URL:-}"
[ -n "$url" ] || url="$schema://${SSO_GITLAB_HOSTNAME:?SSO_GITLAB_HOSTNAME absent}"
url="${url%/}"

# --- Sonde ---------------------------------------------------------------------------------------

sonde() {
  # Identifiants au format contrôlé par make check-env (sans caractère à encoder). redirect_uri exigé :
  # sans lui, GitLab répond 400 (invalid_request) avant d'authentifier le client
  sortie="$({ printf 'grant_type=authorization_code&code=sonde-devops-platform&redirect_uri=%s&client_id=%s&client_secret=' \
    'http%3A%2F%2Fsonde.invalid%2F' "$SSO_CLIENT_ID"
    cat "$FICHIER_CLIENT"; } | wget -S -q -T 10 -O /dev/null --post-file=/dev/stdin \
    --header 'Content-Type: application/x-www-form-urlencoded' http://gitlab/oauth/token 2>&1)" || true
  printf '%s\n' "$sortie" | sed -n 's#.*HTTP/[0-9.]* \([0-9][0-9][0-9]\).*#\1#p' | head -n1
}
code="$(sonde)"
case "$code" in
  400) mode=actif ;;
  401) mode=refus motif=non-initialisee ;;
  *) mode=refus motif=gitlab-indisponible ;;
esac

# --- Options communes ----------------------------------------------------------------------------

# Hostnames protégés (liste séparée par des espaces) : seules destinations de retour admises
set --
for h in ${SSO_HOSTNAMES:?SSO_HOSTNAMES absent}; do set -- "$@" "--whitelist-domain=$h"; done
# Restriction facultative à un groupe GitLab (chemin complet, sous-groupes compris)
[ -z "${SSO_GITLAB_GROUPE:-}" ] || set -- "$@" "--gitlab-group=$SSO_GITLAB_GROUPE"
if [ -s "$CA" ]; then set -- "$@" "--provider-ca-file=$CA" --use-system-trust-store=true; fi

# Forward auth « upstream statique » : Traefik interroge / ; sans session, redirection vers GitLab, sinon
# 202 et identité dans les en-têtes X-Auth-Request-*. Découverte OIDC désactivée : URLs du fournisseur
# dérivées de l'URL publique, aucun appel à GitLab au démarrage. Session dans un cookie par hostname
# (sans domaine), sans jeton (minimal), valable 8 h sans rafraîchissement : un compte bloqué ou retiré
# du groupe est refusé à la reconnexion suivante.
set -- "$@" \
  --http-address=0.0.0.0:4180 \
  --reverse-proxy=true \
  --provider=gitlab \
  --provider-display-name=GitLab \
  --client-id="$SSO_CLIENT_ID" \
  --client-secret-file="$FICHIER_CLIENT" \
  --cookie-secret-file="$FICHIER_COOKIE" \
  --cookie-name=_devops_platform_sso \
  --cookie-secure="$securise" \
  --cookie-samesite=lax \
  --cookie-expire=8h \
  --cookie-refresh=0 \
  --session-cookie-minimal=true \
  --skip-oidc-discovery=true \
  --oidc-issuer-url="$url" \
  --login-url="$url/oauth/authorize" \
  --redeem-url="$url/oauth/token" \
  --oidc-jwks-url="$url/oauth/discovery/keys" \
  --scope="openid profile email" \
  --code-challenge-method=S256 \
  --email-domain='*' \
  --upstream=static://202 \
  --set-xauthrequest=true \
  --silence-ping-logging=true \
  --request-logging=false

if [ "$mode" = actif ]; then
  echo "Passerelle active : application OAuth reconnue par GitLab ($url)."
  exec oauth2-proxy "$@" --skip-provider-button=true
fi

if [ "$motif" = non-initialisee ]; then
  echo "Passerelle en mode refus : application OAuth inconnue de GitLab (HTTP $code), make bootstrap ENV=<env>." >&2
else
  echo "Passerelle en mode refus : GitLab injoignable ou indisponible (${code:-pas de réponse}) sur http://gitlab." >&2
fi
echo "Nouvelle sonde dans $DUREE_REFUS s (redémarrage du conteneur)." >&2
# Page de connexion remplacée par une page explicite, sans lien vers /oauth2/start (réponse 403)
exec timeout "$DUREE_REFUS" oauth2-proxy "$@" --skip-provider-button=false \
  --custom-templates-dir="$REPERTOIRE/refus-$motif"
