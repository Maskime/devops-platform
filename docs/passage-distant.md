# Passage d'une instance locale en mode distant

Une instance installée **en local** a été déployée par `make deploy` lancé sur le serveur lui-même,
sans `DEPLOY_SSH`. Ses services montent alors `config/` directement depuis le checkout du dépôt.

Le **mode distant** la pilote par le contexte Docker SSH ([Déploiement](deploiement.md)). C'est le mode
qu'exige le [déploiement depuis GitHub Actions](deploiement-github.md). Le passage conserve les
données. Il change la source des fichiers de configuration montés et recrée les services concernés.

## Ce qui change, ce qui reste

| | Mode local | Mode distant |
|---|---|---|
| Cible Docker | moteur courant du poste | contexte `devops-platform-<env>` (`DEPLOY_SSH`) |
| Fichiers de `config/` montés | checkout du dépôt | copie `${DEPLOY_DIR}/config-<empreinte>` sur le serveur |
| Garde-fou d'instance, version | aucun | `${DEPLOY_DIR}/instance`, `${DEPLOY_DIR}/version` |

Le reste ne change pas :

- le moteur Docker est le même, et le nom de projet Compose (`devops-platform`) aussi. Conteneurs,
  réseaux et **volumes** (données GitLab, SonarQube, Grafana…) sont donc conservés ;
- le fichier d'instance garde ses secrets et ses réglages. Seule la ligne `DEPLOY_SSH` s'ajoute.

## Procédure

### 1. Sauvegarde

Le premier déploiement en mode distant recrée plusieurs services. C'est l'étape la plus risquée du
passage. Sauvegarder d'abord ([Sauvegarde et restauration](sauvegarde.md)) :

```bash
make backup ENV=prod DESTINATION=<répertoire hors du serveur, de préférence>
```

Cette sauvegarde est à froid : l'instance reste arrêtée le temps de l'archivage. Sans sauvegarde, une
erreur à cette étape peut être irréparable.

### 2. Accès SSH au moteur Docker

Depuis le poste qui pilotera l'instance (qui peut être le serveur lui-même), il faut :

- `ssh utilisateur@serveur` sans mot de passe ni question : clé SSH, et hôte déjà dans `known_hosts` ;
- un utilisateur distant membre du groupe `docker`.

Prérequis détaillés : [Déploiement](deploiement.md#prérequis).

```bash
ssh -o BatchMode=yes ssh://utilisateur@serveur:22 docker version --format '{{.Server.Version}}'
```

### 3. `DEPLOY_SSH` dans le fichier d'instance

```bash
# envs/prod.env
DEPLOY_SSH=ssh://utilisateur@serveur:22
#DEPLOY_DIR=/opt/devops-platform     # défaut
```

`DEPLOY_SSH` doit viser **le serveur qui porte déjà l'instance**. Un autre serveur démarrerait une
instance vide, avec des volumes neufs.

### 4. Premier déploiement en mode distant, depuis le poste

Placer le checkout sur la version installée ou sur une version plus récente
(`git switch --detach vX.Y.Z`), puis :

```bash
make deploy ENV=prod
```

Au premier passage :

- le marqueur `${DEPLOY_DIR}/instance` est écrit ;
- la configuration est copiée dans `${DEPLOY_DIR}/config-<empreinte>`, et la CA privée éventuelle dans
  `${DEPLOY_DIR}/ca-<empreinte>` ;
- la source de leurs montages change, donc Compose **recrée les services qui montent la
  configuration**, et eux seuls : Loki, Promtail, Grafana et `grafana-role`, page d'accueil, passerelle
  d'authentification, relais SonarQube, et Traefik en `TLS_MODE=custom` (le runner et SonarQube aussi,
  s'ils montent la CA). La recréation coupe brièvement ces services. GitLab, PostgreSQL, SonarQube (hors
  `TLS_MODE=custom`) et leurs volumes ne sont pas touchés ;
- la version est inscrite dans `${DEPLOY_DIR}/version`.

Vérifier ensuite :

```bash
make status ENV=prod      # cible ssh://…, version déployée, services healthy
make smoke ENV=prod       # facultatif : validation de bout en bout
```

### 5. Plus de `make deploy` local

Désormais, toutes les commandes passent par `DEPLOY_SSH`, depuis le poste ou depuis GitHub Actions.
Un `make deploy` lancé avec un fichier sans `DEPLOY_SSH`, par exemple depuis l'ancien checkout du
serveur, remonterait `config/` depuis le dépôt et contournerait le contrôle de version. Aucun
garde-fou ne l'empêche encore.

L'ancien checkout et son `envs/<env>.env` contiennent les secrets de l'instance. Ils peuvent être
supprimés une fois la sauvegarde vérifiée. S'ils sont conservés, leur fichier d'instance doit recevoir
le même `DEPLOY_SSH`, pour que toute commande lancée depuis ce checkout passe par le contexte SSH.

### 6. Déploiement depuis GitHub Actions (facultatif)

Suivre [Déploiement depuis GitHub Actions](deploiement-github.md), « Mise en place ». Le secret
`INSTANCE_ENV` reçoit le fichier d'instance **avec** `DEPLOY_SSH`, qui doit être joignable depuis
Internet. Ajouter l'instance à `INSTANCES_TAG`. La version suivante est alors déployée par le push de
son tag.

## Retour au mode local

Retirer `DEPLOY_SSH` du fichier, puis lancer `make deploy` depuis un checkout sur le serveur. Les
services qui montent la configuration sont recréés sur `config/` du checkout.

Les copies de `${DEPLOY_DIR}` ne sont plus utilisées. Supprimer le répertoire, marqueur et version
compris. Sinon, ils seraient de nouveau pris en compte au prochain passage en mode distant.
