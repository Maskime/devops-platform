# GitLab derrière le proxy

Traefik termine le TLS et route `GITLAB_HOSTNAME` vers le nginx interne de GitLab, en HTTP. Cette page
décrit l'URL publique de GitLab, la configuration de son nginx, le SSH et la façon dont le runner et
les jobs CI joignent GitLab.

## URL publique (`external_url`)

Dérivée du hostname et du mode TLS :

| `TLS_MODE` | `external_url` |
|---|---|
| `none` (ou vide) | `http://<GITLAB_HOSTNAME>` |
| `letsencrypt`, `custom` | `https://<GITLAB_HOSTNAME>` |

Elle fait les liens, les URLs de clone HTTP, les redirections et l'enregistrement du runner. Le calcul
a lieu dans `GITLAB_OMNIBUS_CONFIG` (`compose/gitlab.yml`) ; `url_derivee` (`scripts/lib/tls.sh`)
applique la même règle côté scripts.

`GITLAB_EXTERNAL_URL` est optionnelle et ne sert qu'à forcer une valeur. Son hôte doit alors être
`GITLAB_HOSTNAME`, sans port, en `http://` en `none` et en `https://` en `letsencrypt` et `custom` :
`make deploy` (cible `check-env`) refuse toute autre valeur et indique la ligne à corriger. Pour
revenir à l'URL dérivée, commenter la ligne dans `envs/<env>.env`.

## Nginx interne

- **Pas de double TLS** : nginx écoute en HTTP sur le port 80 seulement. HTTPS, redirection HTTP →
  HTTPS et Let's Encrypt d'omnibus sont désactivés (`listen_https`, `redirect_http_to_https`,
  `letsencrypt['enable']`), sans quoi omnibus les activerait dès que l'`external_url` est en `https`.
- **Schéma public** : `X-Forwarded-Proto` et `X-Forwarded-Ssl` suivent le schéma de l'`external_url`
  (liens, cookies `Secure`, redirections corrects).
- **IP réelle des clients** : lue dans `X-Forwarded-For` posé par Traefik (`real_ip_*` de nginx,
  `trusted_proxies` de Rails). Le sous-réseau Docker n'étant pas fixé, la confiance porte sur les plages
  privées RFC 1918 ; limite : un job CI, sur le même réseau, peut joindre `gitlab:80` directement et
  usurper cet en-tête (#76).

## SSH

`GITLAB_SSH_PORT` (défaut `2222`) est le seul port publié par GitLab, et celui affiché dans les URLs de
clone SSH :

```
ssh://git@<GITLAB_HOSTNAME>:<GITLAB_SSH_PORT>/<groupe>/<projet>.git
```

`make check-env` exige un entier de 1 à 65535 sans zéro en tête (Compose et GitLab le liraient
différemment), hors 80 et 443 (Traefik), et signale `22`, généralement pris par le sshd de l'hôte.

## Runner et jobs CI

Traefik porte les `*_HOSTNAME` de l'instance en **alias réseau** sur le réseau de la plateforme
(`compose/proxy.yml`). Dans ce réseau, l'URL publique de GitLab mène donc à Traefik, par le même chemin
et le même certificat que pour un client externe, sans dépendre du DNS ni du hairpin NAT de l'hôte. Le
runner s'enregistre sur cette URL et ses jobs clonent par elle ; il dépend donc de Traefik pour
joindre GitLab. En `TLS_MODE=custom` avec un certificat d'une CA interne, le runner et les jobs
vérifient ce certificat avec la [CA privée](certificats.md#ca-privée) fournie.

Après un changement de hostname ou de `TLS_MODE`, `make bootstrap` ré-enregistre le runner sur la
nouvelle URL et supprime l'ancien ([bootstrap](bootstrap.md)).

Limites :

- **Hostname `*.localhost`** : libcurl, donc git, résout tout `*.localhost` vers `127.0.0.1` sans
  consulter DNS ni `/etc/hosts`. Les jobs clonent alors par `http://gitlab` (nom de service Docker).
  `CI_SERVER_URL` et `CI_API_V4_URL` (`http://gitlab.localhost`) restent injoignables par curl depuis
  un job : utiliser un hostname hors `*.localhost` pour tester des appels API depuis la CI.
