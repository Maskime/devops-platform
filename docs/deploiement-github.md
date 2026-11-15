# Déploiement depuis GitHub Actions

Le workflow `deploy` (`.github/workflows/deploy.yml`) exécute `make deploy` ou `make status` sur une
instance **distante** depuis GitHub, sans dépendre du poste de l'opérateur. Le runner GitHub reconstitue
le poste à partir des secrets d'un **environnement GitHub** du même nom que l'instance. Il lance ensuite
les mêmes cibles `make` qu'en [déploiement depuis le poste](deploiement.md).

Chaque déploiement correspond à une **version publiée** (tag `vX.Y.Z`), jamais à la tête de `main`.

```text
git push origin vX.Y.Z                       → make deploy sur chaque instance de INSTANCES_TAG
Actions > deploy > Run workflow (main)       → make status
Actions > deploy > Run workflow (tag vX.Y.Z) → make deploy ou make status
  controle : ref (tag de version atteignable depuis main), noms d'instance, environnements protégés,
             ruleset des tags
  instance : approbation d'un relecteur → secrets → scripts/ci/preparer-poste.sh → make <action>
```

## Principes de sécurité

Le dépôt est **public** : n'importe qui lit le workflow et les logs des runs.

- **Déclencheurs** : push d'un tag `v*` et lancement manuel (`workflow_dispatch`). Jamais de push de
  branche, de `pull_request` ni de `pull_request_target`. Seul l'opérateur peut pousser un tag `v*`
  ([ruleset](#5-ruleset-des-tags-de-version)), et un relecteur valide chaque déploiement.
- **Ref contrôlée avant tout contact avec le serveur** (`scripts/ci/controler-ref.sh`, dans les deux
  jobs) :
  - `deploy` vise uniquement un tag de version `v<X>.<Y>.<Z>`, sans zéro initial ni suffixe, dont le
    commit est atteignable depuis `main` (`git merge-base --is-ancestor`) ;
  - `status` est aussi accepté depuis `main` ;
  - toute autre branche est refusée.
- **Les règles de l'environnement GitHub et le ruleset sont la seule vraie protection des secrets.**
  Une personne ayant le droit d'écriture pourrait lancer depuis une autre branche un workflow modifié,
  sans ces contrôles. De même, GitHub exécute le workflow **tel qu'il est au commit tagué** : un tag
  posé hors de `main` porterait le workflow de son choix. Seules les règles de l'environnement
  (« branche `main` et tags `v*` », « relecteur obligatoire ») et le ruleset des tags l'en empêchent.
  Le job `controle` refuse un environnement ou un dépôt qui ne les a pas.
- **Aucun secret de dépôt ou d'organisation** nommé `INSTANCE_ENV`, `SSH_PRIVATE_KEY`,
  `SSH_KNOWN_HOSTS` ou `TLS_*` : un job en hériterait si l'environnement n'avait pas le sien.
- **Secrets masqués** avant toute commande `make` (`::add-mask::`) : valeurs des clés sensibles du
  fichier d'instance (motif `MOTIF_CLE_SENSIBLE` de `scripts/lib/env.sh`, contrôlé par `make verify`
  sur `envs/.env.example`), clé SSH, clé TLS, et `DEPLOY_SSH` (utilisateur, hôte et port du serveur).
  Les secrets ne sont transmis qu'à l'étape de préparation : aucune variable du shell ne prime sur le
  fichier d'instance pendant `make`.
- **Aucune action destructive** : ni `stop`, ni `down`, ni `restore`, ni `FORCER=1`, ni retour arrière
  (`RETOUR_ARRIERE=1`, [version déployée](deploiement.md#version-déployée)). Les garde-fous du
  poste s'appliquent tels quels (`make check-env`, [une instance par serveur](deploiement.md#une-instance-par-serveur)).
- **Runners hébergés par GitHub** (`ubuntu-24.04`, éphémères). Pas de runner auto-hébergé sur le
  serveur : son accès à Docker équivaut à root, et GitHub le déconseille sur un dépôt public.

## Mise en place

Le serveur doit être prêt comme pour un déploiement depuis le poste : [Installation](installation.md),
étapes 1 à 4 (prérequis, `TLS_MODE`, `make init`, `host-prereqs.sh`).

### 1. Clé SSH dédiée

Sur le poste, une clé réservée au workflow, **sans phrase de passe** (le runner ne peut pas la saisir) :

```bash
ssh-keygen -t ed25519 -N '' -C devops-platform-github -f ~/.ssh/devops-platform-github
```

Sur le serveur, dans `~/.ssh/authorized_keys` de l'utilisateur de `DEPLOY_SSH` (membre du groupe
`docker`), la clé publique précédée de `restrict` : ni redirection de ports, d'agent ou X11, ni
terminal. Docker par SSH n'en a pas besoin.

```text
restrict ssh-ed25519 AAAA… devops-platform-github
```

Cette clé donne un accès équivalent à root sur le serveur (groupe `docker`) : la retirer de
`authorized_keys` révoque le workflow.

### 2. Clé d'hôte du serveur (`known_hosts`)

Le runner vérifie la clé d'hôte du serveur (`StrictHostKeyChecking yes`) : elle doit être relevée puis
**vérifiée**, jamais acceptée à l'aveugle.

```bash
# Sur le poste : clé présentée par le serveur, au nom et au port de DEPLOY_SSH
ssh-keyscan -p 2222 -t ed25519 serveur.mondomaine.fr > known_hosts_serveur
ssh-keygen -lf known_hosts_serveur
# Sur le serveur, par une session déjà sûre (console, SSH déjà connu) : même empreinte attendue
ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub
```

Le nom doit être celui de `DEPLOY_SSH`, sous la forme `[hôte]:port` si le port n'est pas 22
(`ssh-keyscan -p` l'écrit ainsi) : `scripts/ci/preparer-poste.sh` refuse un `known_hosts` sans entrée
pour cet hôte.

### 3. Fichier d'instance

`envs/<env>.env`, généré sur le poste par `make init ENV=<env>`, avec `DEPLOY_SSH` renseigné
(`ssh://utilisateur@hôte[:port]`). Le workflow refuse une instance locale (`DEPLOY_SSH` vide). Vérifier
le fichier depuis le poste avant de le confier à GitHub : `make check-env ENV=<env>`.

### 4. Environnement GitHub

*Settings > Environments > New environment*, nommé **exactement** comme l'instance (`prod` pour
`envs/prod.env`). Le créer **avant** le premier run : un job qui vise un environnement inexistant le
crée sans aucune protection (le job `controle` arrête alors le run avant).

**Règles** (vérifiées par le job `controle`) :

| Réglage | Valeur |
|---|---|
| *Required reviewers* | au moins un relecteur ; il approuve chaque run avant l'accès aux secrets |
| *Deployment branches and tags* | *Selected branches and tags*, exactement deux règles : branche `main` (pour `status`) et tag `v*` |

*Prevent self-review* est facultatif : sans lui, l'opérateur qui lance le run peut l'approuver.

**Secrets d'environnement** (*Environment secrets*) :

| Secret | Contenu |
|---|---|
| `INSTANCE_ENV` | contenu complet de `envs/<env>.env` |
| `SSH_PRIVATE_KEY` | clé privée de l'étape 1 (`~/.ssh/devops-platform-github`, fichier entier) |
| `SSH_KNOWN_HOSTS` | contenu vérifié de `known_hosts_serveur` (étape 2) |
| `TLS_CERT_PEM`, `TLS_KEY_PEM` | `TLS_MODE=custom` uniquement : `config/certs/cert.pem` et `key.pem` |
| `TLS_CA_PEM` | `TLS_MODE=custom`, facultatif : `config/certs/ca/ca.pem` ([CA privée](certificats.md#ca-privée)) |

Depuis le poste, avec le CLI GitHub, les fichiers sont envoyés sans passer par le presse-papier :

```bash
gh secret set INSTANCE_ENV --env prod < envs/prod.env
gh secret set SSH_PRIVATE_KEY --env prod < ~/.ssh/devops-platform-github
gh secret set SSH_KNOWN_HOSTS --env prod < known_hosts_serveur
```

**Durée maximale d'un run** : 120 minutes par défaut. `make deploy` peut attendre l'arrêt gracieux du
runner GitLab (`GITLAB_RUNNER_STOP_GRACE_PERIOD`, 1 h par défaut), puis la santé des services (15 min),
puis l'application d'une CA privée (15 min). Avec une période d'arrêt plus longue, définir la variable
de dépôt `DEPLOY_TIMEOUT_MINUTES` (*Settings > Secrets and variables > Actions > Variables*). Un run
coupé par le délai laisse le déploiement inachevé : le relancer.

### 5. Ruleset des tags de version

*Settings > Rules > Rulesets > New ruleset > New tag ruleset* :

| Réglage | Valeur |
|---|---|
| *Enforcement status* | *Active* |
| *Bypass list* | l'opérateur, ou le rôle *Repository admin* |
| *Target tags* | *Include by pattern* : `v*` (aucune exclusion) |
| *Rules* | *Restrict creations*, *Restrict updates*, *Restrict deletions* |

Seuls les membres de la *Bypass list* peuvent alors créer, déplacer ou supprimer un tag `v*`. Sans
personne dans cette liste, plus personne ne peut publier de version.

Le job `controle` vérifie qu'un ruleset de tags actif couvre `v*` avec ces trois règles. La *Bypass list*
n'est pas lisible avec le jeton du workflow : sa vérification revient à l'opérateur.

### 6. Instances déployées par un tag

Variable de dépôt `INSTANCES_TAG` (*Settings > Secrets and variables > Actions > Variables*) : noms des
instances que le push d'un tag déploie, séparés par des espaces ou des virgules (`prod`, ou
`prod, prod-2`). Chaque instance a son environnement GitHub, approuvé séparément.

Si la variable est vide ou absente, le push d'un tag ne déploie rien. Le run le signale (annotation et
résumé) et se termine sans erreur.

### 7. Accès SSH depuis les runners

Les runners GitHub ont des adresses variables, réparties sur de larges plages : le port SSH du serveur
doit être joignable **depuis Internet**. Pour un serveur derrière une box : redirection du port SSH vers
le serveur, et nom DNS public (DNS dynamique si l'adresse change).

Risques et précautions :

- le sshd du serveur est exposé aux balayages permanents d'Internet : authentification **par clé
  uniquement** (`PasswordAuthentication no`, `PermitRootLogin no` dans `sshd_config`), et de
  préférence un port externe autre que 22 ;
- limiter les tentatives (`fail2ban`, ou `MaxStartups` et `LoginGraceTime` de sshd), en gardant en tête
  que `make deploy` ouvre plusieurs connexions simultanées (multiplexées sur le runner :
  `ControlMaster`) ;
- l'adresse du serveur n'apparaît pas dans les logs (masquée), mais reste découvrable par balayage.

Un accès par réseau privé (Tailscale, WireGuard) éviterait cette exposition : il n'est pas proposé.

## Publier une version

1. **CHANGELOG** : par une PR mergée dans `main`, la section « Non publié » de `CHANGELOG.md` devient
   `## [X.Y.Z] - <date>`. Le numéro suit le [Semantic Versioning](https://semver.org/lang/fr/) et doit
   être supérieur à la version en place.
2. **Tag annoté**, sur le commit de `main` qui porte cette PR :

   ```bash
   git fetch origin
   git tag -a vX.Y.Z -m "Version X.Y.Z" origin/main
   ```

3. **Push du seul tag** :

   ```bash
   git push origin vX.Y.Z
   ```

   Ne pas utiliser `git push --tags` : au-delà de trois tags poussés ensemble, GitHub ne déclenche
   aucun workflow.
4. **Validation** : *Actions > deploy*, le run du tag attend l'approbation de chaque environnement de
   `INSTANCES_TAG`. Après relecture (*Review deployments*), `make deploy` met l'instance à jour et
   inscrit la version sur le serveur ([version déployée](deploiement.md#version-déployée)).

Le relecteur approuve chaque run. L'historique des runs de l'environnement sert de journal des
déploiements (*Deployments*).

Un run est refusé dans trois cas :

- tag hors format (`v1.2`, `v1.2.3-rc1`, `v01.2.3`) ;
- tag posé sur un commit absent de `main` ;
- version inférieure à celle en place.

Un tag posé sur un commit antérieur à l'ajout du déclenchement par tag ne déclenche rien. Un nouveau tag
sur le même commit (aucun changement d'image) redéploie à l'identique et inscrit la nouvelle version.

Le retour à une version antérieure ne passe pas par GitHub. C'est une opération explicite depuis le
poste ([retour arrière](deploiement.md#version-déployée)).

## Lancer un run manuel

*Actions > deploy > Run workflow*, puis :

| *Use workflow from* | Actions acceptées |
|---|---|
| branche `main` | `status` uniquement (`deploy` refusé : le déploiement ne vise que des tags) |
| tag `vX.Y.Z` | `status` ou `deploy` (redéploiement de cette version sur une instance) |

| Entrée | Valeur |
|---|---|
| `instance` | nom de l'instance (et de l'environnement GitHub) |
| `action` | `status` (défaut) : version déployée, état des services et URLs ; `deploy` : démarrage ou mise à jour, attente de santé |

Toute autre branche est refusée. Le relecteur approuve ensuite le run.

Un seul run par instance à la fois, jamais annulé en cours, qu'il vienne d'un tag ou d'un lancement
manuel. GitHub ne garde qu'un run en attente par instance : un troisième run annule celui qui
attendait.

## Modifier l'instance

`INSTANCE_ENV` devient la **référence** du fichier d'instance : après toute modification de
`envs/<env>.env` sur le poste (`make init … COMPLETER=1`, montée de version, nouveau hostname),
remettre le secret à jour, puis lancer `deploy`. Un fichier du poste différent du secret ferait
diverger les deux modes de déploiement.

Les fichiers de `config/` (configuration de Loki, Grafana, passerelle…) viennent du tag déployé : une
modification passe par une PR mergée, puis par une nouvelle version.

Une instance installée en local passe au déploiement depuis GitHub selon la procédure
[Passage d'une instance locale en mode distant](passage-distant.md).

## Limites

- `make bootstrap` et `make smoke` ne sont pas encore proposés : sur une instance vierge, les lancer
  depuis le poste après le premier `deploy` ([Installation](installation.md), étapes 6 et 7).
- `make backup` et `make restore` restent réservés au poste (archives contenant des secrets, action
  destructive).
- Le contrôle Loki de `make check-env` s'exécute sur le moteur Docker du runner, comme sur le poste.
- Le runner télécharge les images d'outillage (Loki, busybox) à chaque run, depuis Docker Hub.
