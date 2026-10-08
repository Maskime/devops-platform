# Accès à l'API Docker

Traefik (provider Docker) et Promtail (`docker_sd_configs`) doivent lire l'API Docker : liste des
conteneurs, labels, réseaux, logs. Monter le socket Docker, même en `:ro`, ne restreint pas cette API :
quiconque y accède peut créer un conteneur privilégié et prendre la main sur l'hôte. Traefik étant
exposé sur Internet (80/443), sa compromission vaudrait un accès `root` à l'hôte.

Chacun passe donc par **son propre proxy de socket filtrant** : `socket-proxy-traefik` et
`socket-proxy-promtail` (`compose/socket-proxy.yml`, image `wollomatic/socket-proxy`, variable
`SOCKET_PROXY_VERSION`). Chaque proxy n'accepte que son client et n'autorise que les appels dont ce
client a besoin : Traefik ne lit pas les logs, Promtail ne suit pas les événements.

## Mécanisme

- **Seuls les proxys montent le socket** (`DOCKER_SOCKET`). Traefik interroge
  `tcp://socket-proxy-traefik:2375` (`TRAEFIK_PROVIDERS_DOCKER_ENDPOINT`), Promtail
  `tcp://socket-proxy-promtail:2375` (`config/promtail/promtail-config.yaml`).
- **Une liste blanche par client, par méthode et par chemin.** Tout le reste est refusé : `403` pour
  un chemin non listé, `405` pour une méthode non autorisée. Les motifs sont des expressions
  régulières ancrées automatiquement, comparées au chemin avec ou sans préfixe de version d'API
  (`/v1.NN/`).

  | Méthode | Chemin | Traefik | Promtail | Usage |
  |---|---|---|---|---|
  | `HEAD`, `GET` | `/_ping` | ✔ | ✔ | négociation de la version d'API (`HEAD`, `GET` en repli) |
  | `GET` | `/version` | ✔ | | version du démon |
  | `GET` | `/containers/json`, `/containers/<id>/json` | ✔ | ✔ | liste, labels, adresses |
  | `GET` | `/events` | ✔ | | apparition et disparition de conteneurs (flux continu) |
  | `GET` | `/containers/<id>/logs` | | ✔ | lecture des logs (flux continu) |
  | `GET` | `/networks` | | ✔ | labels de réseau de `docker_sd_configs` |

  Aucune méthode d'écriture (`POST`, `PUT`, `DELETE`…) n'est permise : ni création, ni `exec`, ni
  arrêt de conteneur. Sont aussi refusés en lecture `/containers/<id>/archive` et `/export` (fichiers
  des conteneurs), `/info`, `/images`, `/volumes`, `/secrets`…
- **Un seul client par proxy.** Chaque proxy (`-allowfrom`) n'accepte que les connexions venant du
  hostname de son client (`traefik` ou `promtail`), résolu sur son réseau dédié à chaque requête : un
  conteneur recréé, qui change d'IP, reste autorisé.
- **Un réseau dédié et interne par proxy.** `socket-proxy-traefik` n'est que sur le réseau
  `devops-platform_socket-proxy-traefik`, `socket-proxy-promtail` que sur
  `devops-platform_socket-proxy-promtail` (`internal: true` : aucun accès sortant, aucun port publié),
  chacun partagé avec son seul client. Traefik ne joint donc pas le proxy de Promtail (le nom n'y est
  même pas résolu), ni l'inverse : un client ne peut pas se faire passer pour l'autre. Les jobs CI,
  lancés sur leur propre réseau (`GITLAB_RUNNER_NETWORK`), ne voient aucun des deux proxys. Les
  réseaux internes n'ayant pas de passerelle, ports publiés et accès sortant de Traefik (ACME) et de
  Promtail passent toujours par le réseau de la plateforme.
- **Durcissement des conteneurs.** Système de fichiers en lecture seule, aucune capacité Linux,
  `no-new-privileges`. Il tourne en `root` (uid 0, sans capacité) : l'utilisateur de l'image (65534)
  ne peut pas lire le socket (`root:docker`, `0660`, avec un GID `docker` propre à chaque hôte) ; en
  Docker rootless, l'uid 0 du conteneur est l'utilisateur propriétaire du socket.
- **Watchdog.** Si le socket devient inaccessible (redémarrage du démon Docker), le proxy s'arrête et
  Docker le relance (`restart: unless-stopped`). Traefik et Promtail se reconnectent seuls.

`make verify` contrôle, pour chaque environnement et chaque mode TLS :
- que seuls les proxys, `gitlab-runner` et `portainer` montent un socket Docker ;
- que chaque proxy est seul avec son client sur son réseau, interne ;
- que chaque proxy n'accepte que son client (`-allowfrom`), sans option hors liste (aucune méthode
  d'écriture, aucune variable `SP_*`), et que seul celui de Promtail autorise la lecture des logs.

Les proxys sont requis par les briques proxy et observabilité : l'entrée d'`include` de
`compose/socket-proxy.yml` dans `compose.yml` ne se commente pas.

Mise à jour d'une instance qui utilisait l'ancien proxy commun (`socket-proxy`) : `make deploy`
supprime son conteneur avant de démarrer les nouveaux proxys, puis son réseau
`devops-platform_socket-proxy` une fois vide.

## Limites

- **Lecture encore large.** Un client compromis peut lire la configuration de tous les conteneurs de
  l'hôte (`/containers/<id>/json`, variables d'environnement comprises : mots de passe initiaux de
  GitLab et Grafana, par exemple) et leurs logs. C'est le minimum requis par la découverte des routes.
- **Proxy de Promtail sans observabilité.** Brique observabilité désactivée, `socket-proxy-promtail`
  reste démarré, socket monté, sans client
  ([#166](https://github.com/Maskime/devops-platform/issues/166)).
- **Hors périmètre.** `gitlab-runner` (crée les conteneurs des jobs) et Portainer (outil
  d'administration de Docker) montent toujours le socket : un accès à l'un d'eux reste un accès `root`
  à l'hôte.

## Diagnostic

- **Requête refusée.** Chaque proxy journalise ses refus (niveau `WARN`), visibles dans
  `docker compose --env-file envs/<env>.env logs socket-proxy-traefik` (ou `socket-proxy-promtail`) et
  dans Grafana (`{service=~"socket-proxy-.*"}`). Côté client : `403`/`405` dans les logs de Traefik ou
  de Promtail.
- **Lister les appels réels d'un client** (après une montée de version de Traefik ou de Promtail, par
  exemple) : ajouter temporairement `-loglevel=debug` à la `command` de son proxy, puis
  `make deploy ENV=<env>` ; chaque requête acceptée apparaît (`allowed request`). Retirer l'option
  ensuite.
- **Avertissement `error looking up allowed client hostname`.** Le client du proxy n'existe pas encore
  au moment d'une requête : normal pendant un redémarrage du client.
