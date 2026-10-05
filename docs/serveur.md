# Préparation d'un serveur

`scripts/host-prereqs.sh` installe et règle sur un serveur neuf tout ce dont la plateforme a besoin :
Docker Engine et le plugin Compose, `vm.max_map_count` pour SonarQube, un `/etc/docker/daemon.json`
borné et l'ouverture des ports dans le pare-feu. Il est **idempotent** : chaque étape contrôle l'état
avant d'agir, une nouvelle exécution n'affiche que des `✔` et termine par « 0 modification(s) ».

## Exécution

Le script est autonome (aucun autre fichier du repo requis) et s'exécute **sur le serveur, en root** :

```bash
scp scripts/host-prereqs.sh <serveur>:/tmp/
ssh -t <serveur> sudo bash /tmp/host-prereqs.sh --port-ssh-gitlab 2222
```

| Option | Rôle |
|---|---|
| `--port-ssh-gitlab <port>` | Port SSH de GitLab publié sur l'hôte : reprendre `GITLAB_SSH_PORT` de `envs/<env>.env` (défaut : 2222) |
| `--sans-https` | N'ouvre pas 443 : instance en `TLS_MODE=none` |
| `--redemarrer-docker` | Autorise le redémarrage de Docker pour appliquer `daemon.json` même si des conteneurs tournent |
| `-h`, `--aide` | Aide |

Chaque ligne de sortie est `✔` (déjà conforme), `➜` (modifié) ou `⚠` (à traiter par l'opérateur,
rappelé dans le résumé final). Le script s'arrête sur une erreur explicite dès qu'une situation exige
une décision de l'opérateur ; il est alors relancé une fois celle-ci prise.

## Étapes

### Docker Engine et plugin Compose

- **Debian et Ubuntu** (`ID` de `/etc/os-release`) : installation depuis le dépôt officiel Docker
  (clé `/etc/apt/keyrings/docker.asc`, dont l'empreinte est vérifiée, et source
  `/etc/apt/sources.list.d/docker.sources`), paquets `docker-ce`, `docker-ce-cli`, `containerd.io`,
  `docker-buildx-plugin`, `docker-compose-plugin`, plus `ca-certificates`, `curl`, `gnupg` et `jq`.
  Une source `download.docker.com` déjà déclarée (ancienne procédure, `docker.list`) est réutilisée.
- **Autres distributions** (dérivés compris) : Docker Engine, le plugin Compose et `jq` doivent déjà
  être installés ; le script contrôle les versions et poursuit.
- **Versions minimales** : Engine 25.0, Compose 2.24.0. Une version plus ancienne arrête le script :
  la mise à jour de Docker redémarre les conteneurs, elle reste une décision de l'opérateur (voir plus
  bas).
- **Installations refusées** : Docker en **snap** (il ignore `/etc/docker/daemon.json`) et les paquets
  de la distribution **`docker.io`** ou **`podman-docker`** (en conflit avec `docker-ce`). Plateforme
  arrêtée, les désinstaller (`snap remove docker`, ou `apt-get remove docker.io podman-docker`, qui
  conserve images et volumes dans `/var/lib/docker`), puis relancer le script.
- Le service `docker` est activé au démarrage et démarré. Aucun utilisateur n'est ajouté au groupe
  `docker` (accès équivalent à root).

À la première installation, le script installe la dernière version du dépôt : deux serveurs préparés à
des dates différentes peuvent avoir des Engines différents (images de la plateforme, elles, épinglées).

### `/etc/docker/daemon.json`

| Clé | Valeur | Effet |
|---|---|---|
| `log-driver` | `json-file` | Pilote lu par Promtail via l'API Docker |
| `log-opts` | `max-size: 10m`, `max-file: 3` | 30 Mo de logs au plus par conteneur |
| `builder.gc` | `enabled: true`, `defaultMaxUsedSpace: 10GB` | Cache de build (jobs CI du runner) borné à 10 Go |

Avant l'Engine 28, la limite du cache s'écrit `defaultKeepStorage` (choisie selon la version installée).

- Les **autres clés** d'un fichier existant sont conservées. Une valeur différente sur une clé gérée est
  remplacée et signalée (`⚠`) ; `log-opts` est remplacé en bloc (les options d'un autre pilote
  empêcheraient Docker de démarrer). L'ancien fichier est sauvegardé (`daemon.json.<date>.bak`).
- Sur un serveur neuf, le fichier est posé **avant** l'installation : Docker démarre directement avec.
- Docker ne relit pas ces réglages à chaud. Si le fichier est plus récent que le démarrage de Docker :
  sans conteneur en cours, Docker est redémarré ; sinon le script **ne redémarre pas** (cela arrêterait
  la plateforme) et l'indique à chaque exécution (`⚠`) jusqu'à un `systemctl restart docker` dans une
  fenêtre de maintenance, ou une relance avec `--redemarrer-docker`.
- Les options de logs ne s'appliquent qu'aux conteneurs **créés** après le redémarrage :
  `docker compose … up -d --force-recreate` (volumes conservés) pour les étendre aux conteneurs
  existants.

### `vm.max_map_count`

Elasticsearch, embarqué dans SonarQube, exige `vm.max_map_count` ≥ 524288. Le script applique cette
valeur à chaud et la persiste dans `/etc/sysctl.d/99-zz-devops-platform.conf` ; une valeur plus élevée
déjà en place est conservée, jamais abaissée.

Les fichiers sysctl sont appliqués au démarrage par ordre alphabétique de nom (le dernier l'emporte),
puis `/etc/sysctl.conf`. Si un fichier lu après le nôtre fixe une valeur inférieure, la valeur
retomberait au redémarrage : le script s'arrête en citant ce fichier, sans le modifier.

### Pare-feu

Si **ufw** ou **firewalld** est actif, le script y autorise uniquement les ports de la plateforme :
`80/tcp`, `443/tcp` (sauf `--sans-https`) et le port SSH de GitLab (zone par défaut et configuration
permanente pour firewalld). Aucune règle n'est supprimée ; le SSH de l'hôte n'est pas touché.

Sans pare-feu actif, rien n'est fait : en activer un pourrait couper l'accès SSH au serveur.

> Les ports publiés par Docker **contournent** ufw et firewalld (règles iptables/nftables propres à
> Docker). La garantie « uniquement 80, 443 et SSH GitLab » vient des `ports:` des fichiers compose,
> contrôlés par `make verify` (voir [Exposition](exposition.md)). Un pare-feu en amont (fournisseur
> cloud, routeur) reste la protection de référence.

## Mise à jour de Docker

Le script n'installe que les paquets manquants et ne met jamais Docker à jour. La mise à jour
(`apt-get install --only-upgrade docker-ce docker-ce-cli containerd.io docker-buildx-plugin
docker-compose-plugin`) redémarre Docker, donc tous les conteneurs : à faire dans une fenêtre de
maintenance, puis vérifier l'état avec `docker compose … ps`.
