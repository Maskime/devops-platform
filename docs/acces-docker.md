# Accès à l'API Docker

Traefik (provider Docker) et Promtail (`docker_sd_configs`) doivent lire l'API Docker : liste des
conteneurs, labels, réseaux, logs. Monter le socket Docker, même en `:ro`, ne restreint pas cette API :
quiconque y accède peut créer un conteneur privilégié et prendre la main sur l'hôte. Traefik étant
exposé sur Internet (80/443), sa compromission vaudrait un accès `root` à l'hôte.

Les deux services passent donc par un **proxy de socket filtrant**, `socket-proxy`
(`compose/socket-proxy.yml`, image `wollomatic/socket-proxy`, variable `SOCKET_PROXY_VERSION`).

## Mécanisme

- **Seul le proxy monte le socket** (`DOCKER_SOCKET`). Traefik l'interroge sur
  `tcp://socket-proxy:2375` (`TRAEFIK_PROVIDERS_DOCKER_ENDPOINT`), Promtail aussi
  (`config/promtail/promtail-config.yaml`).
- **Liste blanche par méthode et par chemin.** Tout le reste est refusé : `403` pour un chemin non
  listé, `405` pour une méthode non autorisée. Les motifs sont des expressions régulières ancrées
  automatiquement, comparées au chemin avec ou sans préfixe de version d'API (`/v1.NN/`).

  | Méthode | Chemin | Utilisé par |
  |---|---|---|
  | `HEAD`, `GET` | `/_ping` | négociation de la version d'API (Traefik ≥ 3.6.1 : `HEAD`) |
  | `GET` | `/version` | Traefik |
  | `GET` | `/containers/json`, `/containers/<id>/json` | Traefik, Promtail (liste, labels, adresses) |
  | `GET` | `/containers/<id>/logs` | Promtail (lecture des logs, flux continu) |
  | `GET` | `/networks` | Promtail (labels de réseau de `docker_sd_configs`) |
  | `GET` | `/events` | Traefik (apparition et disparition de conteneurs, flux continu) |

  Aucune méthode d'écriture (`POST`, `PUT`, `DELETE`…) n'est permise : ni création, ni `exec`, ni
  arrêt de conteneur. Sont aussi refusés en lecture `/containers/<id>/archive` et `/export` (fichiers
  des conteneurs), `/info`, `/images`, `/volumes`, `/secrets`…
- **Clients autorisés : `traefik` et `promtail`.** Le proxy (`-allowfrom`) n'accepte que les
  connexions venant de ces hostnames, résolus sur le réseau dédié à chaque requête : un conteneur
  recréé, qui change d'IP, reste autorisé.
- **Réseau dédié et interne.** Le proxy n'est que sur le réseau `devops-platform_socket-proxy`
  (`internal: true` : aucun accès sortant, aucun port publié), partagé avec ses seuls clients. Les jobs
  CI, lancés sur le réseau de la plateforme (`PLATFORM_NETWORK`), ne le voient pas : le nom
  `socket-proxy` n'y est même pas résolu. Le réseau interne n'ayant pas de passerelle, ports publiés et
  accès sortant de Traefik (ACME) et de Promtail passent toujours par le réseau de la plateforme.
- **Durcissement du conteneur.** Système de fichiers en lecture seule, aucune capacité Linux,
  `no-new-privileges`. Il tourne en `root` (uid 0, sans capacité) : l'utilisateur de l'image (65534)
  ne peut pas lire le socket (`root:docker`, `0660`, avec un GID `docker` propre à chaque hôte) ; en
  Docker rootless, l'uid 0 du conteneur est l'utilisateur propriétaire du socket.
- **Watchdog.** Si le socket devient inaccessible (redémarrage du démon Docker), le proxy s'arrête et
  Docker le relance (`restart: unless-stopped`). Traefik et Promtail se reconnectent seuls.

`make verify` contrôle, pour chaque environnement et chaque mode TLS, que seuls `socket-proxy`,
`gitlab-runner` et `portainer` montent un socket Docker, que le réseau `socket-proxy` est interne et
qu'il ne relie que le proxy, Traefik et Promtail.

Le proxy est requis par les briques proxy et observabilité : son entrée d'`include` dans `compose.yml`
ne se commente pas.

## Limites

- **Lecture encore large.** Un client compromis peut lire la configuration de tous les conteneurs de
  l'hôte (`/containers/<id>/json`, variables d'environnement comprises : mots de passe initiaux de
  GitLab et Grafana, par exemple) et leurs logs. C'est le minimum requis par la découverte des routes.
- **Liste commune aux deux clients.** Traefik a accès aux logs (`/containers/<id>/logs`) et Promtail
  aux événements, dont chacun n'a pas besoin ([#91](https://github.com/Maskime/devops-platform/issues/91)).
- **Hors périmètre.** `gitlab-runner` (crée les conteneurs des jobs) et Portainer (outil
  d'administration de Docker) montent toujours le socket : un accès à l'un d'eux reste un accès `root`
  à l'hôte.

## Diagnostic

- **Requête refusée.** Le proxy journalise chaque refus (niveau `WARN`), visible dans
  `docker compose --env-file envs/<env>.env logs socket-proxy` et dans Grafana
  (`{service="socket-proxy"}`). Côté client : `403`/`405` dans les logs de Traefik ou de Promtail.
- **Lister les appels réels d'un client** (après une montée de version de Traefik ou de Promtail, par
  exemple) : ajouter temporairement `-loglevel=debug` à la `command` du service `socket-proxy`, puis
  `make deploy ENV=<env>` ; chaque requête acceptée apparaît (`allowed request`). Retirer l'option
  ensuite.
- **Avertissement `error looking up allowed client hostname`.** Un client autorisé n'existe pas (encore) :
  normal pendant le démarrage, ou en permanence pour `promtail` si la brique observabilité est
  désactivée. Sans effet sur l'autre client.
