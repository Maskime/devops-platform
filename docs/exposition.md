# Exposition (reverse proxy Traefik)

Traefik (`compose/proxy.yml`) est le seul point d'entrée web : il publie le port 80 (et 443 en HTTPS)
et route chaque requête vers le service dont le hostname correspond (`*_HOSTNAME`). Ce qui dépend du
mode TLS vit dans un overlay, `compose/tls/<mode>.yml`, fusionné avec `compose/proxy.yml` par
`compose.yml`. Aucun autre service web ne publie de
port ; seul reste publié le SSH de GitLab (`GITLAB_SSH_PORT`).

| Service | URL locale par défaut | Variable |
|---|---|---|
| GitLab | http://gitlab.localhost (SSH : port 2222) | `GITLAB_HOSTNAME`, `GITLAB_SSH_PORT` |
| SonarQube | http://sonarqube.localhost | `SONARQUBE_HOSTNAME` |
| Grafana | http://grafana.localhost | `GRAFANA_HOSTNAME` |
| Portainer | http://portainer.localhost | `PORTAINER_HOSTNAME` |
| PlantUML | http://plantuml.localhost | `PLANTUML_HOSTNAME` |

- **Résolution des noms.** Sur un serveur, chaque hostname doit pointer vers lui (DNS). En local,
  `*.localhost` est résolu vers `127.0.0.1` par les navigateurs et curl, mais pas toujours par le
  système (git, wget…) : `make init` le détecte et indique la ligne à ajouter à `/etc/hosts`
  (`127.0.0.1 gitlab.localhost sonarqube.localhost grafana.localhost portainer.localhost plantuml.localhost`).
- **URLs publiques.** L'hôte de `GITLAB_EXTERNAL_URL` (optionnelle, dérivée par défaut),
  `SONARQUBE_EXTERNAL_URL` et `GRAFANA_EXTERNAL_URL` doit être le hostname du service,
  sans port : `make deploy` (cible `check-env`) refuse une URL incohérente et indique la ligne à
  corriger.
- **Mode TLS (`TLS_MODE`).**
  - `none` (défaut, usage local) : HTTP simple sur le port 80, sans certificat (Portainer n'est plus
    servi en HTTPS auto-signé sur 9443). `make deploy` (cible `check-env`) exige des `*_EXTERNAL_URL`
    en `http://` et **avertit**, sans bloquer, si un hostname n'est pas local (`localhost`,
    `*.localhost`) : le trafic, identifiants compris, circule en clair. Un TLS terminé en amont
    (load balancer) n'est pas géré.
  - `custom` : HTTPS sur le port 443 avec les certificats fournis dans `config/certs/` (`cert.pem`,
    chaîne complète, et `key.pem`, non versionnés) ; le port 80 redirige vers HTTPS. `make deploy`
    exige des `*_EXTERNAL_URL` en `https://` et refuse un certificat absent, invalide, expiré, non
    apparié à sa clé ou ne couvrant pas chaque hostname. Renouvellement : `make reload-certs ENV=<env>`.
    Détails : [certificats fournis](certificats.md).
  - `letsencrypt` : HTTPS sur le port 443 avec des certificats Let's Encrypt obtenus et renouvelés
    automatiquement par Traefik, stockés sur le volume `devops-platform_traefik_acme` ; le port 80
    redirige vers HTTPS. Prérequis : hostnames publics résolus vers le serveur, port 80 (challenge
    `ACME_CHALLENGE=http`, défaut) ou 443 (`tls`) joignable depuis Internet. `make deploy` exige
    `ACME_EMAIL`, des `*_EXTERNAL_URL` en `https://` et refuse les hostnames locaux ou IP.
    Détails : [certificats Let's Encrypt](letsencrypt.md).
  - Toute autre valeur est refusée par `make deploy`.

## GitLab derrière le proxy

L'URL publique de GitLab est dérivée de `GITLAB_HOSTNAME` et du `TLS_MODE` (`GITLAB_EXTERNAL_URL`,
optionnelle, ne sert qu'à la forcer). Son nginx interne n'écoute qu'en HTTP derrière Traefik, et le
SSH passe par `GITLAB_SSH_PORT`. Le runner s'enregistre et clone par l'URL publique, via Traefik.
Détails et limites : [GitLab derrière le proxy](gitlab-proxy.md).

## Surface d'exposition

Sur l'hôte, seuls sont publiés **80** (Traefik), **443** (Traefik, en `TLS_MODE` `custom` ou `letsencrypt`) et le
**SSH de GitLab** (`GITLAB_SSH_PORT`, défaut 2222). `make verify` contrôle, pour chaque
`envs/*.env` et pour chaque mode TLS, chaque couple port publié → port du conteneur contre cette liste blanche, et refuse tout
`network_mode` `host`, `service:…` ou `container:…` (qui la contournerait).

- **Bases de données et services internes.** `sonarqube-db` (PostgreSQL) et Loki ne publient aucun
  port : ils ne sont joignables que depuis le réseau Docker de la plateforme. Le PostgreSQL et le Redis
  embarqués de GitLab écoutent sur des sockets Unix internes au conteneur. Les jobs CI
  tournent sur un réseau dédié où seul Traefik est joignable
  ([réseau des jobs](gitlab-proxy.md#réseau-des-jobs)).
- **API Docker.** Traefik et Promtail ne montent pas le socket Docker : ils lisent l'API, en lecture
  seule et sur une liste blanche d'endpoints, via le proxy filtrant `socket-proxy`, joignable
  uniquement sur un réseau interne dédié. Détails et limites : [accès à l'API Docker](acces-docker.md).
- **Portainer.** Le compte `admin` est créé dès le premier démarrage avec `PORTAINER_ADMIN_PASSWORD`
  (secret Compose, absent de `docker compose config` et de `docker inspect`) : aucun visiteur ne peut
  s'approprier l'instance avant l'opérateur. Ce mot de passe n'est appliqué qu'au premier démarrage
  (le changer ensuite dans l'interface) ; `make check-env` exige 12 caractères au moins. Le tunnel des
  agents Edge (port 8000) n'est pas proposé. ⚠️ Portainer monte le socket Docker : un administrateur
  Portainer est de fait `root` sur l'hôte.
- **Grafana.** Authentification obligatoire : accès anonyme, inscription et création d'organisation
  désactivés, ainsi que les dashboards partagés publiquement et les snapshots (consultables sans compte).
  Le compte admin est créé au premier démarrage avec `GRAFANA_ADMIN_PASSWORD`, transmis par un secret
  Compose (`GF_SECURITY_ADMIN_PASSWORD__FILE`) : absent de `docker compose config` et de
  `docker inspect`. Le script de démarrage de l'image le recopie toutefois dans l'environnement du
  processus Grafana, lisible depuis le conteneur (`docker exec`). Un secret vide ou absent fait
  refuser le démarrage (`make check-env`, puis l'entrypoint du conteneur), faute de quoi Grafana
  créerait le compte avec le mot de passe par défaut `admin`. Ne pas définir aussi
  `GF_SECURITY_ADMIN_PASSWORD` par une surcharge locale : Grafana refuse alors de démarrer.
