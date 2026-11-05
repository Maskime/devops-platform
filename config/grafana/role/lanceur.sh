#!/bin/sh
# Lanceur du service grafana-role (compose/observability.yml) : second forward auth de Traefik devant
# Grafana, après la passerelle d'authentification (docs/sso.md, « Grafana »).
#
# Reçoit la requête avec les en-têtes d'identité posés par la passerelle et répond :
#   - 403 si le login (X-Auth-Request-User) est absent ou égal, casse ignorée, au compte admin local de
#     Grafana (GRAFANA_ADMIN_USER) : auth.proxy relierait sinon cet utilisateur GitLab au compte local ;
#   - 200 avec X-Auth-Request-Role: Admin si X-Auth-Request-Groups contient le groupe SSO_GROUPE_ADMIN
#     (chemin complet, casse ignorée), Viewer sinon (toujours Viewer si la variable est vide).
# Les groupes arrivent sur une ligne par groupe, fusionnées par nginx avec « , » : le motif tolère les
# espaces autour de chaque élément.
#
# Exécuté par le sh (busybox) de l'image nginx -alpine. Les valeurs sont revalidées ici : un lancement
# sans make (docker compose up) contourne make check-env.
set -eu

readonly CONF=/tmp/grafana-role.conf

erreur() { echo "Erreur : $*" >&2; exit 1; }

groupe="${SSO_GROUPE_ADMIN:-}"
admin="${GRAFANA_ADMIN_USER:-admin}"

# Mêmes motifs que scripts/check-env-sso.sh
segment='[A-Za-z0-9_][A-Za-z0-9_.-]*'
if [ -n "$groupe" ] && ! printf '%s\n' "$groupe" | grep -Eq "^${segment}(/${segment})*\$"; then
  erreur "SSO_GROUPE_ADMIN invalide : $groupe (chemin complet d'un groupe GitLab attendu, ex. : equipe/admins)"
fi
printf '%s\n' "$admin" | grep -Eq '^[A-Za-z0-9_][A-Za-z0-9_.@+-]*$' \
  || erreur "GRAFANA_ADMIN_USER invalide : $admin (lettres sans accent, chiffres, . _ @ + -)"

# Échappement des caractères spéciaux d'une expression régulière (. et + seulement possibles ici)
regex() { printf '%s' "$1" | sed 's/[.+]/\\&/g'; }

if [ -n "$groupe" ]; then
  ligne_admin="\"~*(^|,)\\s*$(regex "$groupe")\\s*(,|\$)\" Admin;"
else
  ligne_admin="# SSO_GROUPE_ADMIN vide : aucun administrateur par les groupes GitLab"
fi

cat > "$CONF" <<EOF
worker_processes 1;
pid /tmp/nginx.pid;
error_log /dev/stderr warn;

events {
  worker_connections 256;
}

http {
  access_log off;
  server_tokens off;
  client_body_temp_path /tmp/client_body;
  proxy_temp_path /tmp/proxy;
  fastcgi_temp_path /tmp/fastcgi;
  uwsgi_temp_path /tmp/uwsgi;
  scgi_temp_path /tmp/scgi;

  # Login absent ou homonyme du compte admin local de Grafana : refus
  map \$http_x_auth_request_user \$refus {
    default 0;
    "" 1;
    "~*^$(regex "$admin")\$" 1;
  }

  map \$http_x_auth_request_groups \$role {
    default Viewer;
    $ligne_admin
  }

  server {
    listen 8080;

    location = /sante {
      return 204;
    }

    location / {
      if (\$refus) {
        return 403;
      }
      add_header X-Auth-Request-Role \$role always;
      return 200;
    }
  }
}
EOF

nginx -t -q -c "$CONF" || erreur "configuration nginx générée invalide ($CONF)"
if [ -n "$groupe" ]; then
  echo "Rôles Grafana : Admin pour les membres du groupe GitLab $groupe, Viewer pour les autres."
else
  echo "Rôles Grafana : Viewer pour tous (SSO_GROUPE_ADMIN vide)."
fi
exec nginx -c "$CONF" -g 'daemon off;'
