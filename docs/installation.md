# Installation d'une instance vierge

Ce guide mène, sans connaissance préalable du projet, d'un serveur nu à une instance prête à l'emploi
et validée de bout en bout. Il enchaîne les commandes dans l'ordre et renvoie, pour le détail de chaque
mécanisme, à la page de documentation correspondante.

```text
make init  →  host-prereqs.sh  →  make deploy  →  make bootstrap  →  make smoke
 (poste)        (serveur)          (poste)          (poste)           (poste)
```

Deux machines interviennent :

- le **poste de l'opérateur**, où le repo est cloné et d'où partent toutes les commandes `make` ;
- le **serveur**, qui héberge l'instance et que `make` pilote par SSH (`DEPLOY_SSH`).

Pour une instance **locale** (essai, développement), poste et serveur sont la même machine :
`DEPLOY_SSH` reste vide et les remarques « En local » de chaque étape s'appliquent.

## 1. Prérequis

### Serveur

- Linux 64 bits avec **systemd**, accès `root` (ou `sudo`).
- **Debian ou Ubuntu** pour que Docker soit installé automatiquement. Sur une autre distribution,
  installer au préalable Docker Engine 25.0 minimum, le plugin Compose 2.24 minimum et `jq`.
- Un utilisateur joignable en SSH **par clé**, qui aura accès à Docker (étape 4).
- Accès sortant aux registres d'images : Docker Hub, et `registry.gitlab.com` pour l'image auxiliaire
  des jobs CI (sinon, voir [Dépannage](#autres-problèmes-courants)).

Détails : [Préparation d'un serveur](serveur.md), [Déploiement](deploiement.md#prérequis).

### Ressources par profil

Le profil (`PLATFORM_PROFILE`) dimensionne GitLab et SonarQube. Ressources minimales de l'hôte pour la
plateforme complète, **hors jobs CI** (prévoir de la marge s'ils tournent sur le même hôte) :

<!-- Repris de docs/dimensionnement.md : garder les deux tableaux synchronisés. -->

| Profil | RAM | vCPU | Disque | Usage visé |
|---|---|---|---|---|
| `small` | 8 Go | 4 | 50 Go | Poste de développement, petite équipe (≈ 10 utilisateurs) |
| `medium` (défaut) | 16 Go | 8 | 100 Go | Équipe de taille moyenne (≈ 50 utilisateurs) |
| `large` | 32 Go | 16 | 250 Go | Plusieurs équipes, gros dépôts et analyses lourdes |

En local, choisir `small`. Sous WSL2, la mémoire disponible pour Docker est celle de la VM WSL
(paramètre `memory` de `.wslconfig`), pas celle du poste. Détails des réglages :
[Dimensionnement](dimensionnement.md).

### Poste de l'opérateur

- Docker (CLI, plugin Compose 2.24 minimum) **et un moteur Docker local** : `make` valide la
  configuration de Loki dans un conteneur local, même pour une instance distante, quel que soit le
  contexte Docker courant ou `DOCKER_HOST` ([détails](deploiement.md#prérequis)).
- GNU `make`, `git`, bash 4 minimum (sur macOS : celui de Homebrew), client OpenSSH 7.7 minimum,
  `sha256sum` ou `shasum`, `openssl` (contrôle des certificats en `TLS_MODE=custom`).

### DNS

Chaque service a son hostname, routé par Traefik : GitLab, SonarQube, Grafana, Portainer et PlantUML.
Par défaut, `<service>.<domaine>` (par exemple `gitlab.devops.mondomaine.fr`).

- **Serveur** : un enregistrement A (et/ou AAAA) par hostname, vers l'adresse du serveur, ou un
  enregistrement joker (`*.devops.mondomaine.fr`). En `TLS_MODE=letsencrypt`, ces noms doivent être
  résolus **depuis Internet**.
- **En local** : `*.localhost`, résolu vers `127.0.0.1` par les navigateurs et `curl`. Si git ou wget
  ne le résolvent pas, `make init` affiche la ligne à ajouter à `/etc/hosts`.

### Ports entrants

Seuls ces ports sont publiés sur l'hôte. Les ouvrir dans tout pare-feu **en amont** du serveur
(groupe de sécurité du fournisseur cloud, routeur, NAT) :

| Port | Quand | Rôle |
|---|---|---|
| 80/tcp | toujours | HTTP ; en HTTPS, redirection vers 443 et challenge Let's Encrypt HTTP-01 |
| 443/tcp | `TLS_MODE` `custom` ou `letsencrypt` | HTTPS (Traefik) |
| `GITLAB_SSH_PORT` (défaut 2222) | toujours | `git` en SSH ; pas 22, généralement pris par le sshd de l'hôte |
| SSH de l'hôte (22) | instance distante | pilotage par `make` depuis le poste (déjà ouvert en général) |

Sur le serveur, `host-prereqs.sh` ouvre ces ports dans ufw ou firewalld s'ils sont actifs. Les ports
publiés par Docker contournent de toute façon ces pare-feu : voir [Exposition](exposition.md#surface-dexposition).

## 2. Choisir le mode TLS et le profil

Ces choix sont posés par `make init` (étape 3). Les faire **avant** : changer `TLS_MODE` à la main
ensuite impose de corriger aussi `SONARQUBE_EXTERNAL_URL` et `GRAFANA_EXTERNAL_URL` (`http://` ou
`https://`), ce que `make deploy` signale.

| Situation | `TLS_MODE` | Ce qu'il faut fournir |
|---|---|---|
| Poste local, essai (`*.localhost`) | `none` | Rien. Tout circule en HTTP clair : `make deploy` avertit si un hostname n'est pas local |
| Serveur joignable depuis Internet, noms publics | `letsencrypt` | `ACME_EMAIL` (adresse réelle) ; port 80 ouvert depuis Internet, ou 443 avec `ACME_CHALLENGE=tls` |
| Réseau interne, PKI de l'organisation, serveur non joignable depuis Internet | `custom` | Un certificat couvrant **tous** les hostnames (*subjectAltName* explicites ou joker), déposé sur le poste |

- **`letsencrypt`** : certificats obtenus et renouvelés automatiquement par Traefik. Let's Encrypt
  refuse `localhost`, `*.localhost` et les adresses IP. Pour un premier essai sans consommer les
  quotas de production, utiliser l'environnement de staging (`ACME_CA_SERVER`, voir
  [Let's Encrypt](letsencrypt.md#mise-en-place)).
- **`custom`** : sur le poste, `config/certs/cert.pem` (chaîne complète, certificat du serveur en
  premier), `config/certs/key.pem` (clé non chiffrée, `chmod 600`) et, pour une CA interne,
  `config/certs/ca/ca.pem`. `make deploy` les copie sur le serveur. Renouvellement manuel par
  `make reload-certs`. Voir [Certificats fournis](certificats.md).
- Vue d'ensemble : [Exposition](exposition.md).

Le **profil** se choisit d'après le tableau des [ressources](#ressources-par-profil) ; il se change
plus tard sans perte de données ([Dimensionnement](dimensionnement.md)).

## 3. Générer la configuration (`make init`)

Sur le poste :

```bash
git clone https://github.com/Maskime/devops-platform.git
cd devops-platform
git checkout <version>                # facultatif : figer une version publiée (git tag -l)
make init ENV=prod                    # « prod » : nom de l'instance, fichier envs/prod.env
```

Une instance suit une version figée. La version 0.1.0 précède l'outillage décrit ici (`make init`,
`make bootstrap`…) : prendre une version ultérieure, ou `main` tant qu'aucune n'est publiée.

`make init` pose quatre questions (Entrée garde la valeur par défaut) : domaine de base, hostname de
chaque service, `TLS_MODE`, profil ; en `letsencrypt`, il demande aussi `ACME_EMAIL`. Il génère tous
les mots de passe et écrit `envs/<env>.env` en permissions `600`.

Compléter ensuite le fichier à la main :

- **Instance distante** : décommenter `DEPLOY_SSH` et l'écrire sous la forme
  `ssh://utilisateur@hôte[:port]` (toute autre forme est refusée) :

  ```bash
  DEPLOY_SSH=ssh://deploy@devops.mondomaine.fr
  ```

  `make init` termine par « Étape suivante : make deploy » : pour un serveur, passer d'abord par les
  étapes 4 et 5.
- **Port SSH de GitLab** : `GITLAB_SSH_PORT` si 2222 ne convient pas.
- **`TLS_MODE=custom`** : déposer les certificats dans `config/certs/` (voir étape 2).

> `envs/<env>.env` n'est pas versionné et contient tous les secrets de l'instance : le **sauvegarder**
> hors du repo (gestionnaire de secrets). `make init FORCE=1` régénère le fichier en reprenant
> réponses et secrets, mais remet tous les réglages faits à la main (`DEPLOY_SSH`, `GITLAB_SSH_PORT`…)
> aux valeurs du modèle : les reporter depuis la sauvegarde `envs/<env>.env.bak.<date>`.

Détails : [Initialisation](initialisation.md) ; chaque variable est commentée dans
[`envs/.env.example`](../envs/.env.example).

## 4. Préparer le serveur (`host-prereqs.sh`)

`scripts/host-prereqs.sh` installe Docker, règle `vm.max_map_count` pour SonarQube, borne les logs
Docker, ouvre les ports dans le pare-feu local et planifie un nettoyage Docker. Il s'exécute **sur le
serveur, en root**, et ne dépend d'aucun autre fichier du repo :

```bash
scp scripts/host-prereqs.sh deploy@devops.mondomaine.fr:/tmp/
ssh -t deploy@devops.mondomaine.fr sudo bash /tmp/host-prereqs.sh --port-ssh-gitlab 2222
```

- `--port-ssh-gitlab` : reprendre `GITLAB_SSH_PORT` de `envs/<env>.env` ;
- `--sans-https` : en `TLS_MODE=none`, n'ouvre pas 443 ;
- `bash /tmp/host-prereqs.sh --aide` liste les options.

**Résultat attendu** : des lignes `✔` (conforme) ou `➜` (modifié), un résumé final ; les `⚠` sont à
traiter (ils sont rappelés dans le résumé). Le script est idempotent : relancé, il termine par
« 0 modification(s) ».

Puis donner à l'utilisateur de déploiement l'accès à Docker (le script n'ajoute personne au groupe
`docker`) et vérifier, **depuis le poste**, que la connexion ne pose aucune question :

```bash
ssh -t deploy@devops.mondomaine.fr sudo usermod -aG docker deploy
ssh deploy@devops.mondomaine.fr docker version     # nouvelle connexion : le groupe est pris en compte
```

Être membre du groupe `docker` équivaut à un accès `root` sur le serveur. La clé SSH doit être chargée
(ou déclarée dans `~/.ssh/config`) et l'hôte présent dans `~/.ssh/known_hosts` : `make deploy` se
connecte sans interaction et échoue sinon.

**En local :**

- **Linux natif** (Debian ou Ubuntu, systemd) : `sudo bash scripts/host-prereqs.sh --sans-https`.
- **Docker Desktop** (WSL2, macOS) : **ne pas** lancer le script, qui installerait un second moteur
  Docker. Seul `vm.max_map_count` est nécessaire, à régler dans la VM de Docker Desktop par un
  conteneur privilégié, seulement si la valeur actuelle est inférieure à 524288 (ne pas abaisser une
  valeur plus élevée) :

  ```bash
  docker run --rm alpine:3.24.2 sysctl vm.max_map_count                          # valeur actuelle
  docker run --rm --privileged alpine:3.24.2 sysctl -w vm.max_map_count=524288   # si inférieure
  ```

  Ce réglage est perdu au redémarrage de Docker Desktop (ou de WSL, du poste) : le refaire avant
  `make deploy`.

Détails : [Préparation d'un serveur](serveur.md).

## 5. Démarrer l'instance (`make deploy`)

Sur le poste :

```bash
make deploy ENV=prod
```

1. Contrôles de cohérence (`make check-env`) : valeurs d'exemple, versions épinglées, profil, URLs,
   certificats ou email ACME selon le mode. Chaque refus indique la ligne à corriger.
2. En distant : contexte Docker `devops-platform-<env>` sur `DEPLOY_SSH`, copie des fichiers de
   configuration sur le serveur, garde-fou « une instance par serveur ».
3. Téléchargement des images et démarrage, puis attente que tous les services soient `healthy`
   (**15 minutes au plus**). Le premier démarrage de GitLab prend plusieurs minutes : c'est normal.
4. Récapitulatif : état de chaque service et URL de chaque interface.

`make status ENV=prod` réaffiche ce récapitulatif à tout moment. En `letsencrypt`, les certificats
sont demandés au premier accès de Traefik à chaque service : vérifier l'émetteur avec
`openssl s_client` ([Let's Encrypt](letsencrypt.md#mise-en-place)).

Détails : [Déploiement](deploiement.md).

## 6. Configurer l'instance (`make bootstrap`)

```bash
make bootstrap ENV=prod
```

Deux étapes, dans l'ordre, sans aucune donnée de test :

1. **SonarQube** : contrôle de `vm.max_map_count`, mot de passe admin, plugin, compte et token
   d'analyse ;
2. **GitLab** : variables CI d'instance `SONAR_HOST_URL` et `SONAR_TOKEN`, enregistrement du runner
   d'instance, attente qu'il soit en ligne.

Il écrit `outputs/<env>.env` (URLs, API GitLab, token d'analyse, réseau des jobs) pour les projets qui
consomment la plateforme ([Fichier de sortie](sortie-instance.md)). Il est idempotent : en cas d'échec, corriger
puis relancer.

Détails : [Bootstrap](bootstrap.md), [Bootstrap SonarQube](bootstrap-sonarqube.md).

## 7. Valider de bout en bout (`make smoke`)

```bash
make smoke ENV=prod NETTOYER=1
```

Le smoke test crée un projet GitLab et un projet SonarQube de test, pousse un commit, attend que le
pipeline passe au vert (job simple, isolation réseau des jobs, analyse `sonar-scanner`) et que
l'analyse apparaisse dans SonarQube. `NETTOYER=1` supprime ces projets après un succès, pour laisser
l'instance vierge ; sans lui, ils sont conservés et leurs URLs affichées. Le premier passage
télécharge l'image du scanner : compter jusqu'à une quinzaine de minutes.

Détails : [Smoke test](smoke-test.md).

## 8. Premières connexions

Les mots de passe ne sont jamais affichés : les lire dans `envs/<env>.env`.

| Interface | Utilisateur | Mot de passe |
|---|---|---|
| GitLab | `root` | `GITLAB_ROOT_PASSWORD` |
| SonarQube | `admin` | `SONARQUBE_ADMIN_PASSWORD` |
| Grafana | `GRAFANA_ADMIN_USER` (défaut `admin`) | `GRAFANA_ADMIN_PASSWORD` |
| Portainer | `admin` | `PORTAINER_ADMIN_PASSWORD` |
| PlantUML | — | — |

Les mots de passe de GitLab et Portainer ne sont appliqués qu'au **premier démarrage** : une fois
changés dans l'interface, le fichier ne fait plus foi pour eux.

L'instance est prête. Pour la suite : [Branchement d'un projet](branchement-projet.md),
[Analyse SonarQube depuis la CI](analyse-sonarqube.md),
[Montée de version](montee-de-version.md), [Rétention des logs](logs.md).

## Dépannage

Pour une instance distante, les commandes `docker compose` passent par la passerelle
`scripts/instance.sh compose <env> …`, qui vise le bon serveur (elle fonctionne aussi en local).

### GitLab lent au démarrage

**Symptôme** : `gitlab` reste `starting` plusieurs minutes, ou son URL répond 404 ou 502.

- Au premier démarrage, GitLab initialise sa base et se configure : **5 à 10 minutes** sont normales,
  davantage sur un petit serveur. Son healthcheck tolère environ 12 minutes avant de le déclarer
  `unhealthy`, et `make deploy` attend 15 minutes. Tant qu'il n'est pas `healthy`, Traefik ne le route
  pas.
- Suivre l'avancement : `scripts/instance.sh compose <env> logs -f gitlab`, et l'état de ses
  composants : `scripts/instance.sh compose <env> exec gitlab gitlab-ctl status`.
- `make deploy` a échoué sur le délai alors que les logs progressent : le relancer, il est idempotent
  et reprend l'attente.
- Redémarrages en boucle, `Killed` dans les logs, hôte qui swappe : **mémoire insuffisante**. Vérifier
  avec `docker stats` (ou `dmesg | grep -i oom` sur le serveur), puis passer au profil `small` ou
  augmenter la RAM ([Dimensionnement](dimensionnement.md)).
- `make bootstrap` ou `make smoke` attendent eux aussi GitLab (15 minutes au plus) : les lancer avant
  la fin du démarrage n'est pas une erreur.

### Elasticsearch (SonarQube)

SonarQube embarque Elasticsearch, qui a des exigences propres sur l'hôte.

**Symptôme** : `make deploy` échoue sur le délai avec `sonarqube` `unhealthy` ou qui redémarre en
boucle. Les logs (`scripts/instance.sh compose <env> logs sonarqube`) contiennent :

- **`max virtual memory areas vm.max_map_count [...] is too low`** : réglage du noyau de l'hôte
  absent. Lancer `host-prereqs.sh` sur le serveur, ou, avec Docker Desktop, la commande
  `sysctl` de l'étape 4, puis `make deploy`. Avec Docker Desktop, le réglage est perdu à chaque
  redémarrage. `make bootstrap` contrôle aussi cette valeur et s'arrête si elle est
  insuffisante.
- **`flood stage disk watermark`**, index en lecture seule : disque de l'hôte presque plein (95 %).
  Libérer de la place (`docker system df` ; le nettoyage planifié par `host-prereqs.sh` ne touche pas
  aux volumes de la plateforme), puis redémarrer `sonarqube` :
  `scripts/instance.sh compose <env> restart sonarqube`.
- **`OutOfMemoryError`**, ou processus Elasticsearch tué : mémoire insuffisante pour les heaps du
  profil ([Dimensionnement](dimensionnement.md)).

Sur une instance **vierge** qui ne démarre pas pour une autre raison, repartir de volumes vides est
légitime. Sur une instance qui a des données, ne jamais supprimer le volume `sonarqube_data`
([Montée de version](montee-de-version.md#sonarqube)).

### Certificats

- **`make deploy` refuse le certificat** (`TLS_MODE=custom`) : le message dit pourquoi (clé non
  appariée, hostname absent du *subjectAltName*, certificat expiré, clé chiffrée…). Corriger les
  fichiers de `config/certs/` et relancer ; liste des contrôles : [Certificats fournis](certificats.md#contrôles-au-déploiement).
- **Le navigateur reçoit `TRAEFIK DEFAULT CERT`** (`TLS_MODE=letsencrypt`) : Let's Encrypt n'a pas
  délivré le certificat. La cause est dans les logs de Traefik :
  `scripts/instance.sh compose <env> logs traefik | grep -i acme`. Le plus souvent : hostname non
  résolu vers le serveur depuis Internet, port 80 (ou 443 avec `ACME_CHALLENGE=tls`) fermé en amont,
  ou quota atteint après plusieurs essais (passer par le staging).
- **Passage du staging à la production** : retirer `ACME_CA_SERVER`, puis vider le stockage des
  certificats, sinon ceux du staging restent servis :

  ```bash
  scripts/instance.sh compose <env> rm -sf traefik
  docker --context devops-platform-<env> volume rm devops-platform_traefik_acme   # en local : sans --context
  make deploy ENV=<env>
  ```

- **`make bootstrap` signale un certificat refusé** en joignant GitLab depuis le runner
  (`TLS_MODE=custom`, CA interne) : déposer `config/certs/ca/ca.pem`, puis `make deploy` et
  `make bootstrap` ([CA privée](certificats.md#ca-privée)).
- **`git` ou `curl` refusent le certificat sur le poste** (CA interne) : ajouter la CA au magasin du
  poste ([CA privée](certificats.md#ca-privée)).

### Autres problèmes courants

- **`make deploy` : connexion impossible ou Docker inaccessible** : la connexion SSH doit aboutir sans
  question (`ssh <hôte> docker version`) ; voir l'étape 4 et [Déploiement](deploiement.md#prérequis).
- **`git clone` ne résout pas `gitlab.localhost`** : ajouter la ligne affichée par `make init` à
  `/etc/hosts` ([Exposition](exposition.md)).
- **Jobs CI en échec `runner_external_dependency_failure`** : le serveur ne joint pas
  `registry.gitlab.com` ; renseigner `GITLAB_RUNNER_HELPER_IMAGE`
  ([image auxiliaire](bootstrap.md#image-auxiliaire-des-jobs)).
- **`make bootstrap` : mot de passe admin SonarQube refusé** :
  [Mot de passe admin inconnu](bootstrap-sonarqube.md#mot-de-passe-admin-inconnu).
