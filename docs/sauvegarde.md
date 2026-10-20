# Sauvegarde et restauration

`make backup` sauvegarde les données d'une instance dans un répertoire du poste de l'opérateur ;
`make restore` les remet en place, puis redéploie. L'instance peut être locale ou distante
(`DEPLOY_SSH`) : dans les deux cas, les données transitent par le poste.

```bash
make backup ENV=prod                                  # instance arrêtée le temps de l'archivage
make restore ENV=prod SAUVEGARDE=<répertoire>         # refusé si les volumes de l'hôte ne sont pas vides
make restore ENV=prod SAUVEGARDE=<répertoire> FORCER=1  # remplace les données en place
```

| Variable | Cible | Effet |
|---|---|---|
| `DESTINATION=<répertoire>` | `backup` | Répertoire parent des sauvegardes (défaut ci-dessous) |
| `AVEC_LOKI=1` | `backup` | Sauvegarde aussi les logs (`loki_data`) |
| `SAUVEGARDE=<répertoire>` | `restore` | Sauvegarde à restaurer (obligatoire) |
| `FORCER=1` | `restore` | Autorise le remplacement de volumes non vides |

Comme `FORCER`, ces variables sont acceptées seulement sur la ligne de commande, pas depuis le shell.

## Contenu

Volumes sauvegardés, s'ils sont déclarés par la configuration de l'instance :

| Volume | Service | Contenu |
|---|---|---|
| `gitlab_config` | gitlab | `gitlab.rb`, `gitlab-secrets.json`, clés SSH d'hôte |
| `gitlab_data` | gitlab | dépôts, base PostgreSQL embarquée, fichiers téléversés |
| `gitlab_runner_config` | gitlab-runner | enregistrement du runner (`config.toml`) |
| `sonarqube_db` | sonarqube-db | base PostgreSQL de SonarQube |
| `sonarqube_data` | sonarqube | données SonarQube (index reconstruits au démarrage) |
| `grafana_data` | grafana | base de Grafana |
| `portainer_data` | portainer | base de Portainer |
| `traefik_acme` | traefik | certificats Let's Encrypt (`TLS_MODE=letsencrypt` seulement) |
| `loki_data` | loki | logs, avec `AVEC_LOKI=1` seulement |

**Non sauvegardés** :

- `sonarqube_extensions` : plugins, remplis depuis l'image de SonarQube ;
- `gitlab_logs`, `sonarqube_logs` : journaux ;
- `promtail_positions` : positions de lecture des logs, reconstituées.

**Ni la configuration de l'instance ni ses secrets** ne sont sauvegardés : `envs/<env>.env`,
`config/certs/` (`TLS_MODE=custom`) et `outputs/` sont à conserver par ailleurs. Une restauration
n'est possible qu'avec le fichier de l'instance qui correspond aux données, en particulier
`SONARQUBE_DB_PASSWORD`.

## Emplacement et droits

Par défaut, chaque sauvegarde est écrite dans
`${XDG_DATA_HOME:-$HOME/.local/share}/devops-platform/sauvegardes/<env>/<env>-<AAAAMMJJ>T<HHMMSS>Z/`.
`DESTINATION` remplace le répertoire parent (`…/sauvegardes/<env>`). L'emplacement par défaut est hors
du repo : un `git clean` ne l'efface pas et il ne peut pas être versionné.

Les archives contiennent des secrets (bases de données, `gitlab-secrets.json`, clés SSH d'hôte) :
répertoire en `700`, fichiers en `600`.

Une sauvegarde est d'abord écrite dans `<nom>.partiel/`, puis renommée une fois complète. Un répertoire
`.partiel` est donc une sauvegarde interrompue, inutilisable : il peut être supprimé.

Une sauvegarde contient :

| Fichier | Contenu |
|---|---|
| `<volume>.tar.gz` | archive du volume |
| `manifeste.txt` | instance, date (UTC), cible, architecture CPU de l'hôte, image de chaque service qui écrit un volume sauvegardé (référence et identifiant), volumes avec l'empreinte SHA-256 de leur archive |
| `SHA256SUMS` | empreintes, pour un contrôle manuel : `sha256sum -c SHA256SUMS` |

## Sauvegarde

`make backup ENV=<env>` :

1. **Contrôles, instance en service** :
   - chaque volume à sauvegarder existe sur l'hôte ;
   - chaque service qui écrit un volume tourne avec l'image configurée dans `envs/<env>.env`. Si un tag
     a été changé dans le fichier sans `make deploy`, la sauvegarde est refusée : le manifeste doit
     porter la version qui a produit les données ;
   - l'image utilitaire `busybox` est présente sur l'hôte (téléchargée au besoin).
2. **Arrêt** (`docker compose stop`) : conteneurs conservés. Le runner est arrêté en premier : il ne
   prend plus de job et attend la fin des jobs en cours, au plus `GITLAB_RUNNER_STOP_GRACE_PERIOD`
   (1 h par défaut). Le verrou de l'instance est pris auparavant : la sauvegarde ne démarre pas pendant
   un `make bootstrap` ou un `make smoke`.
3. **Archivage** : un conteneur `busybox` sans réseau lit chaque volume en lecture seule sur l'hôte et
   écrit l'archive sur sa sortie standard, recueillie par le poste. L'archive est relue (`tar -tz`)
   et son empreinte calculée sur le poste.
4. **Redémarrage** des services qui tournaient avant, tels quels (ni recréation ni configuration
   appliquée), avec attente de leur état healthy. Le redémarrage a lieu aussi en cas d'erreur ou
   d'interruption (Ctrl-C) de l'archivage.

La sauvegarde affiche son chemin, sa taille, la durée d'arrêt et la commande de restauration.

## Restauration

`make restore ENV=<env> SAUVEGARDE=<répertoire>` vérifie la sauvegarde **avant d'arrêter quoi que ce
soit**. Elle refuse, en laissant l'instance inchangée :

- une sauvegarde d'une autre instance (`instance` du manifeste différent de `<env>`), même avec
  `FORCER=1` : ses secrets ne correspondent pas à `envs/<env>.env` ;
- une archive manquante ou dont l'empreinte diffère du manifeste ;
- un volume de la sauvegarde absent de la configuration (`traefik_acme` alors que `TLS_MODE` n'est
  plus `letsencrypt`, brique désactivée) ;
- une version d'image différente de celle du manifeste, pour chaque service qui écrit un volume
  restauré : GitLab, PostgreSQL ou SonarQube ne relisent pas les données d'une autre version ;
- une architecture CPU de l'hôte différente (`x86_64`, `aarch64`…) ;
- des volumes non vides sur l'hôte, sans `FORCER=1`.

Un volume déclaré par la configuration mais absent de la sauvegarde (Loki sauvegardé sans
`AVEC_LOKI=1`) est laissé tel quel, avec un avertissement.

Ensuite :

1. **Arrêt** (`docker compose down`) : conteneurs supprimés, volumes conservés.
2. **`sonarqube_extensions` supprimé** : il est rempli depuis l'image de SonarQube à sa recréation,
   avec le plugin community branch de la version restaurée.
3. **Volumes restaurés** un par un : vidés, puis l'archive, envoyée depuis le poste, est extraite par un
   conteneur `busybox` (propriétaires et droits numériques conservés). Un volume absent est créé avec
   les labels de Compose.
4. **`make deploy`** : démarrage et attente que tous les services soient healthy.

Une restauration interrompue laisse l'instance arrêtée, avec des volumes partiellement restaurés : la
relancer avec `FORCER=1`.

Après une restauration, relancer `make bootstrap ENV=<env>` : il régénère `outputs/<env>.env` (token
d'analyse SonarQube de la sauvegarde) et contrôle l'enregistrement du runner.

**Serveur perdu** : préparer un nouveau serveur ([Préparation d'un serveur](serveur.md)), pointer
`DEPLOY_SSH` dessus si son adresse a changé, puis `make restore ENV=<env> SAUVEGARDE=<répertoire>` : les
volumes sont vides, `FORCER` est inutile. Sur un serveur qui héberge déjà une autre instance, le
garde-fou « une instance par hôte » s'applique ([Déploiement](deploiement.md)).

## Retour arrière d'une montée de version

1. Avant la montée de version : `make backup ENV=<env>`.
2. Montée de version ratée : remettre l'**ancienne** version dans `envs/<env>.env` (ou retirer la
   surcharge).
3. `make restore ENV=<env> SAUVEGARDE=<répertoire> FORCER=1` : les versions configurées correspondent
   de nouveau au manifeste ; la restauration remet les données d'avant la migration, puis redéploie.

Procédure par image : [Montée de version](montee-de-version.md).

## Limites

- **Interruption de service** : l'instance est arrêtée pendant tout l'archivage. La durée dépend du
  volume de données et du débit entre le poste et le serveur (pas de sauvegarde incrémentale).
  L'arrêt du runner peut à lui seul durer jusqu'à `GITLAB_RUNNER_STOP_GRACE_PERIOD` si des jobs
  tournent.
- **Pas de rétention** : chaque sauvegarde est complète et conservée ; la place disque du poste est à
  surveiller, les anciennes sauvegardes à supprimer à la main.
- **Archives `busybox tar`** : un fichier de plus de 8 Gio dans un volume fait échouer la sauvegarde ;
  les attributs étendus et ACL ne sont pas conservés (non utilisés par les services de la plateforme) ;
  les sockets laissées par GitLab sont ignorées (recréées au démarrage).
- **Même version, même architecture** : une sauvegarde ne se restaure qu'avec les versions d'image
  qu'elle a enregistrées. Pour passer à une autre version, restaurer, puis suivre la
  [montée de version](montee-de-version.md).
- **Tags mutables** : seule la référence d'image (tag) est comparée ; l'identifiant d'image enregistré
  dans le manifeste est informatif ([épinglage par digest](montee-de-version.md#principe)).
- **Secrets de l'instance** : une restauration avec un `envs/<env>.env` régénéré (`make init FORCE=1
  NOUVEAUX_MDP=1`) après la sauvegarde n'est pas détectée ; SonarQube ne démarre alors pas.
- **Transfert** : en distant, toutes les données passent par la connexion SSH du contexte Docker.
