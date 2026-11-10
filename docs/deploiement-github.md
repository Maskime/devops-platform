# Déploiement depuis GitHub Actions

Le workflow `deploy` (`.github/workflows/deploy.yml`) exécute `make deploy` ou `make status` sur une
instance **distante** depuis l'onglet *Actions* de GitHub, sans dépendre du poste de l'opérateur. Le
runner GitHub reconstitue le poste à partir des secrets d'un **environnement GitHub** du même nom que
l'instance, puis lance les mêmes cibles `make` qu'en [déploiement depuis le poste](deploiement.md), qui
reste le mode nominal.

```text
Actions > deploy > Run workflow (instance, action)
  controle : branche main, nom d'instance, environnement GitHub protégé
  instance : approbation d'un relecteur → secrets → scripts/ci/preparer-poste.sh → make <action>
```

## Principes de sécurité

Le dépôt est **public** : n'importe qui lit le workflow et les logs des runs.

- **Déclenchement manuel uniquement** (`workflow_dispatch`), jamais sur `push`, `pull_request` ni
  `pull_request_target`.
- **Les règles de l'environnement GitHub sont la seule vraie protection des secrets.** Le workflow
  vérifie aussi la branche, mais une personne ayant le droit d'écriture pourrait lancer depuis une autre
  branche un workflow modifié sans ces contrôles. Seules les règles « branche `main` seule » et
  « relecteur obligatoire » de l'environnement l'en empêchent : le job `controle` refuse un
  environnement qui ne les a pas.
- **Aucun secret de dépôt ou d'organisation** nommé `INSTANCE_ENV`, `SSH_PRIVATE_KEY`,
  `SSH_KNOWN_HOSTS` ou `TLS_*` : un job en hériterait si l'environnement n'avait pas le sien.
- **Secrets masqués** avant toute commande `make` (`::add-mask::`) : valeurs des clés sensibles du
  fichier d'instance (motif `MOTIF_CLE_SENSIBLE` de `scripts/lib/env.sh`, contrôlé par `make verify`
  sur `envs/.env.example`), clé SSH, clé TLS, et `DEPLOY_SSH` (utilisateur, hôte et port du serveur).
  Les secrets ne sont transmis qu'à l'étape de préparation : aucune variable du shell ne prime sur le
  fichier d'instance pendant `make`.
- **Aucune action destructive** : ni `stop`, ni `down`, ni `restore`, ni `FORCER=1`. Les garde-fous du
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
| *Deployment branches and tags* | *Selected branches and tags*, une seule règle : branche `main` |

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

### 5. Accès SSH depuis les runners

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

## Lancer un run

*Actions > deploy > Run workflow*, branche `main`, puis :

| Entrée | Valeur |
|---|---|
| `instance` | nom de l'instance (et de l'environnement GitHub) |
| `action` | `status` (défaut) : état des services et URLs ; `deploy` : démarrage ou mise à jour, attente de santé |

Le relecteur approuve ensuite le run (*Review deployments*). L'historique des runs de l'environnement
sert de journal des déploiements (*Deployments*).

Un seul run par instance à la fois, jamais annulé en cours. GitHub ne garde qu'un run en attente par
instance : un troisième lancement annule le run qui attendait.

## Modifier l'instance

`INSTANCE_ENV` devient la **référence** du fichier d'instance : après toute modification de
`envs/<env>.env` sur le poste (`make init … COMPLETER=1`, montée de version, nouveau hostname),
remettre le secret à jour, puis lancer `deploy`. Un fichier du poste différent du secret ferait
diverger les deux modes de déploiement.

Les fichiers de `config/` (configuration de Loki, Grafana, passerelle…) viennent de la branche `main` :
une modification passe par une PR mergée avant le run.

## Limites

- `make bootstrap` et `make smoke` ne sont pas encore proposés : sur une instance vierge, les lancer
  depuis le poste après le premier `deploy` ([Installation](installation.md), étapes 6 et 7).
- `make backup` et `make restore` restent réservés au poste (archives contenant des secrets, action
  destructive).
- Le contrôle Loki de `make check-env` s'exécute sur le moteur Docker du runner, comme sur le poste.
- Le runner télécharge les images d'outillage (Loki, busybox) à chaque run, depuis Docker Hub.
