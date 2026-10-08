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
  `trusted_proxies` de Rails), crue **seulement depuis le sous-réseau du réseau
  `devops-platform_gitlab-proxy`**, qui ne relie que Traefik et GitLab (réseau interne, sous-réseau fixé
  par `GITLAB_PROXY_SUBNET`, défaut `172.31.254.0/28`). Traefik joint GitLab par ce réseau (label
  `traefik.docker.network`). Une requête directe depuis le réseau de la plateforme garde son IP source :
  l'en-tête y est ignoré.

### Sous-réseau du lien Traefik → GitLab

`GITLAB_PROXY_SUBNET` est un CIDR IPv4 de `/16` à `/29` (`make check-env`). Le changer si le défaut
chevauche un réseau existant de l'hôte (autre réseau Docker, VPN) : la création du réseau échoue alors
avec « Pool overlaps ». Docker ne modifie pas le sous-réseau d'un réseau existant : après un changement,

```bash
make down ENV=<env>
docker network rm devops-platform_gitlab-proxy   # contexte Docker de l'instance en distant
make deploy ENV=<env>
```

Sans cette recréation, GitLab ferait confiance au nouveau sous-réseau alors que Traefik garde une
adresse de l'ancien : toutes les requêtes sembleraient venir de Traefik (limitation de débit commune,
journaux faussés). Contrôle automatique au déploiement : #146.

## SSH

`GITLAB_SSH_PORT` (défaut `2222`) est le seul port publié par GitLab, et celui affiché dans les URLs de
clone SSH :

```
ssh://git@<GITLAB_HOSTNAME>:<GITLAB_SSH_PORT>/<groupe>/<projet>.git
```

`make check-env` exige un entier de 1 à 65535 sans zéro en tête (Compose et GitLab le liraient
différemment), hors 80 et 443 (Traefik), et signale `22`, généralement pris par le sshd de l'hôte.

## Runner et jobs CI

Traefik porte les `*_HOSTNAME` de l'instance en **alias réseau** (`compose/proxy.yml`). Dans ces
réseaux, l'URL publique de GitLab mène donc à Traefik, par le même chemin et le même certificat que pour
un client externe, sans dépendre du DNS ni du hairpin NAT de l'hôte. Le runner s'enregistre sur cette
URL ; il dépend donc de Traefik pour joindre GitLab. En `TLS_MODE=custom` avec un certificat d'une CA
interne, le runner et les jobs vérifient ce certificat avec la [CA privée](certificats.md#ca-privée)
fournie.

### Réseau des jobs

Les conteneurs de jobs (et leurs `services:`) tournent sur un **réseau dédié**,
`GITLAB_RUNNER_NETWORK` (défaut `devops-platform_ci`), créé par `make deploy` et enregistré par
`make bootstrap` (`network_mode` du runner). **Traefik est son seul autre membre** : un job ne joint ni
`sonarqube-db`, ni `loki`, ni le nginx de GitLab (`gitlab:80`), ni aucun autre service ; leurs noms n'y
sont pas résolus et Docker bloque le trafic entre réseaux. Les jobs joignent GitLab et SonarQube
uniquement par Traefik :

| Cas | GitLab (clone) | SonarQube (`SONAR_HOST_URL`) |
|---|---|---|
| Cas général | URL publique | URL publique |
| Hostname `*.localhost` | `http://gitlab.devops-platform.internal:8000` | `http://sonarqube.devops-platform.internal:8000` |
| `TLS_MODE=custom` avec CA privée | URL publique (`CI_SERVER_TLS_CA_FILE`) | `http://sonarqube.devops-platform.internal:8000` |

Les noms `*.devops-platform.internal` sont des alias de Traefik sur le réseau des jobs seulement, servis
par son entrypoint `interne` (port 8000, HTTP, non publié, sans redirection HTTPS quel que soit le
`TLS_MODE`), qui ne route que ces deux noms. Ils servent quand l'URL publique est inutilisable depuis un
job : libcurl (donc git) résout tout `*.localhost` vers `127.0.0.1` sans consulter le DNS ni
`/etc/hosts`, et la JVM du scanner SonarQube n'utilise pas la CA fournie aux jobs (#144).

`make check-env` et `make bootstrap` refusent un `GITLAB_RUNNER_NETWORK` égal à un réseau de la
plateforme (`PLATFORM_NETWORK`, `devops-platform_socket-proxy*`, `devops-platform_gitlab-proxy`). Le
smoke test vérifie l'isolation depuis un job ([smoke test](smoke-test.md)).

Après un changement de hostname, de `TLS_MODE` ou de `GITLAB_RUNNER_NETWORK`, `make bootstrap`
ré-enregistre le runner et supprime l'ancien ([bootstrap](bootstrap.md)). Le runner lui-même reste sur
le réseau de la plateforme.

Limites :

- **Hostname `*.localhost`** : `CI_SERVER_URL` et `CI_API_V4_URL` (`http://gitlab.localhost`) restent
  injoignables par curl depuis un job : utiliser un hostname hors `*.localhost` pour tester des appels
  API depuis la CI.
- **Entre jobs** : tous les jobs, et leurs `services:`, partagent le réseau des jobs et se joignent
  entre eux (un service PostgreSQL d'un job est visible d'un autre job). Le trafic de l'entrypoint
  `interne` y circule en HTTP clair.
- **Passerelle de Traefik** : Traefik est sur deux réseaux non internes (plateforme et jobs) ; avant
  Docker Engine 28, sa route par défaut (accès sortant, ACME) suit l'ordre alphabétique de leurs noms
  (#145). Avec les noms par défaut, c'est le réseau de la plateforme.
- **Mise à jour** : entre le `make deploy` qui crée le réseau des jobs et le `make bootstrap` qui y
  ré-enregistre le runner, les jobs tournent encore sur le réseau de la plateforme : enchaîner les deux
  commandes.
