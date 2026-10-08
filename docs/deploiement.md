# Déploiement local ou distant

`make deploy`, `make down` et `make status` pilotent une instance depuis le poste de l'opérateur, sur
le moteur Docker local ou sur un serveur distant. La cible est définie dans `envs/<env>.env` :

```bash
# envs/prod.env
DEPLOY_SSH=ssh://deploy@devops.mondomaine.fr     # vide ou absente : moteur Docker local
#DEPLOY_DIR=/opt/devops-platform                 # répertoire de config sur le serveur (défaut)
```

| Commande | Effet |
|---|---|
| `make deploy ENV=<env>` | Contrôles (`make check-env`), démarrage ou mise à jour, attente que tous les services soient healthy (15 min au plus), récapitulatif des URLs |
| `make status ENV=<env>` | Cible, état de chaque service, récapitulatif des URLs |
| `make down ENV=<env>` | Arrête l'instance : conteneurs et réseaux supprimés, **volumes conservés**. Instance distante : [confirmation](#arrêt) |

`DEPLOY_SSH` et `DEPLOY_DIR` sont lues **dans le fichier uniquement** : contrairement aux autres
variables, une valeur exportée dans le shell est ignorée, pour que la cible d'une commande ne dépende
que du fichier de l'instance.

## Prérequis

**Serveur** :

- préparé par `scripts/host-prereqs.sh` ([Préparation d'un serveur](serveur.md)) : Docker Engine 25.0
  minimum. Seul l'Engine sert : Compose s'exécute sur le poste ;
- un utilisateur joignable en SSH **par clé**, avec accès à Docker (root, ou membre du groupe
  `docker`, ce qui équivaut à un accès root) ;
- accès aux registres d'images (Docker Hub), comme pour un déploiement local.

**Poste de l'opérateur** :

- Docker (CLI, plugin Compose 2.24 minimum) **et un moteur Docker local** : `make check-env` valide la
  configuration Loki dans un conteneur, même pour une instance distante (voir ci-dessous) ;
- client OpenSSH 7.7 minimum, bash 4 minimum (sur macOS : bash de Homebrew), `sha256sum` ou `shasum` ;
- connexion SSH non interactive : `ssh <DEPLOY_SSH> docker version` doit répondre sans question
  (clé chargée ou déclarée dans `~/.ssh/config`, hôte déjà présent dans `known_hosts`).

`make deploy` commence par ce test (`BatchMode`, 10 s maximum). En cas d'échec, il affiche l'erreur
SSH et les points à vérifier, au lieu de rester bloqué sur une question.

**Moteur local du contrôle Loki.** `make check-env` (préalable de `deploy`, `bootstrap`, `smoke`…) et
`make verify` lancent Loki avec `-verify-config` sur un moteur **du poste**, quels que soient le
contexte Docker courant (`docker context use`, `DOCKER_CONTEXT`) et `DOCKER_HOST` :

- `DOCKER_HOST` (et `DOCKER_TLS_VERIFY`, `DOCKER_CERT_PATH`) est ignoré pour ce contrôle ;
- le contexte courant est retenu s'il désigne un moteur local (`unix://`, `npipe://` : Docker Desktop,
  Colima, OrbStack…) et répond, sinon le contexte `default` (`/var/run/docker.sock`) ;
- si aucun ne répond, seuls les contrôles statiques sont faits (`-config.expand-env=true`, format et
  minimum de `LOKI_RETENTION_PERIOD`) et un avertissement l'indique : la configuration n'est alors
  validée par Loki qu'au démarrage, sur le serveur.

## Mécanisme

### Contexte Docker

Avec `DEPLOY_SSH`, `make` crée le contexte Docker `devops-platform-<env>`. Si `DEPLOY_SSH` a changé, il
le met à jour. Toutes les commandes Docker de l'instance passent ensuite par ce contexte.

- Le contexte courant de l'opérateur (`docker context use`) n'est pas modifié.
- Une variable `DOCKER_HOST` exportée est ignorée, avec un avertissement, car elle l'emporterait sur le
  contexte.
- Sans `DEPLOY_SSH`, `make` utilise le moteur courant du poste, comme avant.

Chaque requête simultanée de Compose ouvre sa propre connexion SSH. Avec la configuration par
défaut de sshd (`MaxStartups 10:30:100`), au-delà d'une dizaine de connexions en cours d'ouverture,
le serveur en coupe (« Connection closed by … », `dial-stdio` en échec). En déploiement distant,
`make` borne donc le parallélisme de Compose à 4 (`COMPOSE_PARALLEL_LIMIT`, une valeur exportée dans
le shell reste prioritaire). Pour accélérer les commandes, un multiplexage SSH côté poste fait passer
toutes ces connexions par une seule :

```text
# ~/.ssh/config
Host devops.mondomaine.fr
  ControlMaster auto
  ControlPath ~/.ssh/cm-%r@%h:%p
  ControlPersist 10m
```

### Fichiers de configuration sur le serveur

Compose lit sur le poste les fichiers compose, les `env_file` (profils, challenge ACME) et les secrets.
Les montages de fichiers, en revanche, sont résolus par le moteur Docker, sur le serveur. Ces fichiers
doivent donc y être présents.

**Fichiers copiés** (et eux seuls) :

- `config/loki/loki-config.yaml`
- `config/promtail/promtail-config.yaml`
- `config/grafana/provisioning/`
- en `TLS_MODE=custom` : `config/traefik/tls-custom.yml`, `config/certs/cert.pem` et
  `config/certs/key.pem`
- en `TLS_MODE=custom`, à part : `config/certs/ca/ca.pem` s'il existe (seul fichier copié de
  `config/certs/ca/` : [CA privée](certificats.md#ca-privée))

**Où** : dans `${DEPLOY_DIR}/config-<empreinte>` sur le serveur. L'empreinte est calculée sur les
chemins et le contenu de ces fichiers. Les montages pointent vers ce répertoire via la variable interne
`PLATFORM_CONFIG_DIR`, qui vaut par défaut `config/` du repo.

La CA privée a sa propre copie, `${DEPLOY_DIR}/ca-<empreinte de ca.pem>` (`ca-vide` sans CA, créé
quand même : il est monté). La variable interne `PLATFORM_CA_DIR` y pointe, et vaut par défaut
`config/certs/ca/` du repo. Seuls `gitlab-runner` et `sonarqube` la montent. Un changement d'une
autre partie de la configuration ne les recrée donc pas.

**Idempotence** : si un répertoire de même empreinte existe déjà, rien n'est envoyé.

**Prise en compte d'une modification** : un fichier modifié produit une nouvelle empreinte, donc un
nouveau répertoire. `make deploy` recrée alors les services qui montent la configuration (Loki,
Promtail, Grafana, et Traefik en `TLS_MODE=custom`), et eux seuls. Un changement de `ca.pem` recrée
`gitlab-runner` et `sonarqube`, et eux seuls, par `make deploy` ou `make reload-certs`.

**Méthode de copie** : le transfert passe par le contexte Docker. Un conteneur `busybox` (sans réseau)
extrait une archive tar envoyée depuis le poste. Il ne faut ni `rsync`, ni `scp`, ni `sudo`.

**Atomicité** : la copie est extraite dans `config-<empreinte>.tmp` (ou `ca-<empreinte>.tmp`), puis renommée. Une copie
interrompue est refaite au déploiement suivant.

**Droits sur le serveur** :

| Élément | Droits |
|---|---|
| `DEPLOY_DIR` | `700`, propriétaire `root` |
| Fichiers copiés | propriétaire `root`, lisibles par tous (Grafana et Loki ne tournent pas en root) |
| `certs/key.pem` | `600` (Traefik tourne en root) |

**Nettoyage** : après un déploiement réussi, les copies (`config-*`, `ca-*`) qu'aucun conteneur du
projet ne monte plus sont supprimées. Après un `make reload-certs`, seuls Traefik, et le runner et
SonarQube si la CA a changé, passent sur les nouvelles copies. Les anciennes restent tant que d'autres
services les montent.

Les montages sont déclarés avec `create_host_path: false`. Lancée sans `PLATFORM_CONFIG_DIR`, une
commande échoue donc (« bind source path does not exist ») au lieu de créer des répertoires vides sur
le serveur.

### Arrêt du runner

`gitlab-runner` s'arrête par `SIGQUIT` : il ne prend plus de job et attend la fin des jobs en cours.
Au-delà de `GITLAB_RUNNER_STOP_GRACE_PERIOD` (1 h par défaut, `envs/.env.example`), Docker le tue.
Cela vaut pour toute recréation ou tout arrêt du runner :

- `make deploy` (nouvelle version, configuration modifiée, CA privée changée) ;
- `make reload-certs` (CA privée changée) ;
- `make down`.

Ces commandes attendent donc la fin des jobs en cours. Pendant l'attente, aucun nouveau job ne
démarre ; les jobs en attente reprennent avec le nouveau runner.

- **Forcer l'arrêt** (jobs interrompus) : `scripts/instance.sh compose <env> stop -t 10 gitlab-runner`,
  puis la commande voulue.
- **Commande interrompue** (Ctrl-C, coupure SSH) pendant l'attente : Docker termine l'arrêt, mais le
  nouveau conteneur n'est pas créé. Relancer `make deploy ENV=<env>`.
- **Délai dépassé** : le runner est tué et les conteneurs de ses jobs restent en place. Les lister :
  `docker ps --filter label=com.gitlab.gitlab-runner.managed=true`. Les supprimer avec `docker rm -f`.
- **Redémarrage de Docker ou du serveur** : l'arrêt est borné par le délai d'arrêt du service
  `docker` (systemd), en général plus court. Les jobs en cours sont alors interrompus.

### Une instance par serveur

Le nom de projet Compose est fixe (`devops-platform`). Deux fichiers d'env qui viseraient le même
serveur piloteraient donc les mêmes conteneurs et les mêmes volumes, avec des secrets différents.

Pour l'éviter, le premier `make deploy` écrit le nom de l'instance dans `${DEPLOY_DIR}/instance`. Les
commandes suivantes refusent une autre instance sur ce serveur. Pour remplacer volontairement
l'instance du serveur, passer `FORCER=1` sur la ligne de commande (une valeur héritée du shell est
refusée).

## Commandes manuelles sur une instance distante

Une commande `docker compose` lancée à la main n'a ni le contexte ni `PLATFORM_CONFIG_DIR`. Pour une
instance distante, utiliser la passerelle, qui positionne les deux :

```bash
scripts/instance.sh compose <env> logs -f gitlab
scripts/instance.sh compose <env> exec gitlab gitlab-rake gitlab:check
```

`make bootstrap` (SonarQube puis GitLab) vise la même cible que `make deploy`, locale ou distante,
préparée une seule fois pour toutes ses étapes ([bootstrap](bootstrap.md)).

## Récapitulatif des URLs

`make deploy` et `make status` affichent l'URL de chaque service. Le schéma est `http` en
`TLS_MODE=none` et `https` sinon. L'hôte est le `*_HOSTNAME` effectif de chaque service, et l'URL SSH
de GitLab utilise `GITLAB_SSH_PORT`. `make check-env` garantit que les `*_EXTERNAL_URL` concordent avec
ces valeurs.

Les services dotés d'un healthcheck doivent être `healthy`. Loki n'a pas de healthcheck (image
distroless) : il doit être démarré, et sa santé est couverte par celui de Promtail
([Rétention des logs](logs.md)).

## Arrêt

`make down ENV=<env>` exécute `docker compose down`, **sans `-v`** :

- les conteneurs et les réseaux sont supprimés ;
- les volumes (données GitLab, SonarQube, Grafana…) sont conservés ;
- les copies de configuration restent sur le serveur.

`make deploy` relance l'instance à l'identique.

**Instance distante** (`DEPLOY_SSH` défini) : avant tout contact avec le serveur, `make down` affiche
l'instance et son hôte, puis demande de **retaper le nom de l'instance** ; toute autre réponse annule.
Hors terminal (script, CI), la confirmation passe par `CONFIRMER=1`, accepté seulement sur la ligne de
commande (une variable exportée dans le shell est refusée) :

```bash
make down ENV=prod                # question : taper « prod » pour confirmer
make down ENV=prod CONFIRMER=1    # sans question (obligatoire hors terminal)
```

Une instance locale s'arrête sans question. Les commandes manuelles
(`scripts/instance.sh compose <env> down`, `stop`…) ne demandent pas de confirmation.
