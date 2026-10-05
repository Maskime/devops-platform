# Montée de version des images

Chaque image de la plateforme est épinglée sur une version précise. Deux instances installées à des dates
différentes exécutent donc les mêmes versions. Ce document décrit comment faire évoluer ces versions sans
perte de données.

## Principe

- **Défaut du repo.** Chaque image compose est paramétrée par une variable `*_VERSION` dont la valeur par
  défaut figure dans le fichier compose (`image: gitlab/gitlab-ce:${GITLAB_VERSION:-19.4.1-ce.0}`) et,
  à l'identique, dans `envs/.env.example`.
- **Surcharge par instance.** Une instance peut fixer sa propre version dans `envs/<env>.env`
  (`GITLAB_VERSION=19.4.1-ce.0`). Une instance surchargée **ne suit plus** les défauts du repo : à chaque
  montée de version du repo, il faut mettre à jour ou retirer sa surcharge.
- **Garde-fous.** `make verify` refuse une image compose non paramétrée, un défaut sans version
  `majeure.mineure` (`latest`, `17`, `lts`…), un défaut différent de celui de `envs/.env.example`, un tag
  `latest` explicite dans les scripts et une version vide ou `latest` dans `envs/*.env`. `make deploy`
  (cible `check-env`) refuse une version vide ou `latest` dans le fichier de l'instance.
- **Limite : les tags sont mutables.** Un éditeur peut republier un tag (`postgres:17.11` est reconstruit à
  chaque mise à jour de son image de base, `mc1arke/…` peut être republié). L'épinglage par tag garantit la
  **version applicative**, pas l'identité bit à bit. Pour cette dernière, épingler aussi le digest dans
  l'instance : `SONARQUBE_DB_VERSION=17.11@sha256:<digest>` (digest affiché par
  `docker buildx imagetools inspect postgres:17.11`).

## Inventaire

| Image | Variable | Contrainte de version | Releases |
|---|---|---|---|
| `gitlab/gitlab-ce` | `GITLAB_VERSION` | [chemin de mise à jour](#gitlab-ce) obligatoire | [GitLab releases](https://about.gitlab.com/releases/categories/releases/) |
| `gitlab/gitlab-runner` | `GITLAB_RUNNER_VERSION` | même `majeure.mineure` que GitLab | [gitlab-runner](https://gitlab.com/gitlab-org/gitlab-runner/-/releases) |
| `mc1arke/sonarqube-with-community-branch-plugin` | `SONARQUBE_VERSION` | tag publié par mc1arke (plugin compatible embarqué) | [plugin community branch](https://github.com/mc1arke/sonarqube-community-branch-plugin/releases) |
| `postgres` (base SonarQube) | `SONARQUBE_DB_VERSION` | majeure supportée par SonarQube | [Docker Hub](https://hub.docker.com/_/postgres) |
| `grafana/grafana` | `GRAFANA_VERSION` | — | [grafana](https://github.com/grafana/grafana/releases) |
| `grafana/loki` | `LOKI_VERSION` | configuration `config/loki/` | [loki](https://github.com/grafana/loki/releases) |
| `grafana/promtail` | `PROMTAIL_VERSION` | déprécié, 3.6.x = dernière (#35) | [loki](https://github.com/grafana/loki/releases) |
| `portainer/portainer-ce` | `PORTAINER_VERSION` | variante `-alpine` (healthcheck) | [portainer](https://github.com/portainer/portainer/releases) |
| `plantuml/plantuml-server` | `PLANTUML_VERSION` | variante `jetty-` | [plantuml-server](https://github.com/plantuml/plantuml-server/releases) |
| `traefik` | `TRAEFIK_VERSION` | ≥ 3.6.1 pour Docker Engine 29 ; préfixe `v` | [traefik](https://github.com/traefik/traefik/releases) |

Images d'outillage, épinglées en dur dans les scripts (variables `*_IMAGE`, contrôlées par `make verify`) :

| Image | Script | Usage |
|---|---|---|
| `koalaman/shellcheck` | `scripts/verify.sh` | lint des scripts |
| `cytopia/yamllint` | `scripts/verify.sh` | lint YAML (aucun tag versionné publié : figé par digest) |
| `alpine` | `scripts/legacy/setup-gitlab.sh` | image des jobs CI de test |
| `sonarsource/sonar-scanner-cli` | `scripts/legacy/setup-sonarqube-analysis.sh` | analyse de test |

## Procédure générale

Les exemples se lancent depuis la racine du repo, avec :

```bash
ENV=<env>
dc() { docker compose --env-file "envs/$ENV.env" "$@"; }
SONARQUBE_URL=http://sonarqube.localhost   # SONARQUBE_EXTERNAL_URL de l'instance
```

1. **Choisir la version.** Dernière version stable de l'éditeur (Docker Hub, releases GitHub), en lisant
   les notes de version de **chaque** version intermédiaire (ruptures, migrations, configuration).
   Respecter les contraintes de l'[inventaire](#inventaire) et les sections propres à chaque brique
   ci-dessous.
2. **Sauvegarder à froid.** Une archive prise pendant que le service écrit est incohérente : arrêter le
   service, archiver ses volumes, le redémarrer. Le nom d'un volume est `devops-platform_<volume>`.

   ```bash
   mkdir -p ~/sauvegardes/"$ENV"
   dc stop grafana
   docker run --rm -v devops-platform_grafana_data:/source:ro -v ~/sauvegardes/"$ENV":/dest \
     alpine:3.24.2 tar czf "/dest/grafana_data-$(date +%F).tgz" -C /source .
   dc start grafana
   ```

   GitLab et la base SonarQube ont en plus leur outil de sauvegarde dédié (voir plus bas).
3. **Changer la version.**
   - Une instance seulement : modifier la variable dans `envs/<env>.env`.
   - Défaut du repo : modifier le défaut dans `compose/<module>.yml` **et** dans `envs/.env.example`, noter
     la montée dans `CHANGELOG.md` (avec les étapes manuelles éventuelles), puis `make verify`.
4. **Déployer** : `make deploy ENV=<env>` (télécharge l'image, recrée le conteneur, attend `healthy`).
   Exceptions : GitLab (une étape du chemin à la fois) et SonarQube (migration de schéma avant
   `make deploy`).
5. **Contrôler** : `dc ps` (tous `healthy`), connexion à l'interface, logs (`dc logs --tail 200 <service>`).

**Retour arrière.** Une version qui a migré des données (schéma GitLab, SonarQube, `grafana.db`,
Portainer…) ne peut pas être redescendue en changeant simplement le tag. Le retour arrière consiste à
remettre l'**ancien** tag **et** à restaurer la sauvegarde :

```bash
dc stop grafana
docker run --rm -v devops-platform_grafana_data:/cible -v ~/sauvegardes/"$ENV":/source:ro \
  alpine:3.24.2 sh -c 'rm -rf /cible/* /cible/..?* /cible/.[!.]* ; tar xzf /source/grafana_data-<date>.tgz -C /cible'
make deploy ENV=<env>   # avec l'ancien tag remis dans envs/<env>.env ou le compose
```

## GitLab CE

GitLab impose un **chemin de mise à jour** : on ne saute pas de versions arbitrairement.

1. **Calculer le chemin** avec l'[Upgrade Path tool](https://gitlab-com.gitlab.io/support/toolbox/upgrade-path/)
   (édition CE, version actuelle → version cible). Il liste les **arrêts obligatoires** (*required stops*),
   décrits dans [Upgrade paths](https://docs.gitlab.com/update/upgrade_paths/). Lire les notes de version
   de chaque arrêt ([Upgrade notes](https://docs.gitlab.com/update/)).
2. **Vérifier qu'aucune migration en arrière-plan n'est en cours** (à refaire avant **chaque** étape) :

   ```bash
   dc exec gitlab gitlab-rails runner -e production 'puts Gitlab::BackgroundMigration.remaining'
   dc exec gitlab gitlab-rails runner -e production \
     'puts Gitlab::Database::BackgroundMigration::BatchedMigration.queued.count'
   ```

   Les deux commandes doivent afficher `0` (vue équivalente : *Admin → Monitoring → Background migrations*).
   Sinon, attendre ; ne jamais enchaîner une étape tant qu'il en reste.
3. **Sauvegarder.** Une sauvegarde GitLab ne se restaure que sur **exactement** la version qui l'a produite.

   ```bash
   dc exec gitlab gitlab-backup create
   # Les archives sont écrites dans le volume gitlab_data : les copier hors de celui-ci
   dc cp gitlab:/var/opt/gitlab/backups ~/sauvegardes/"$ENV"/gitlab-backups
   # Secrets (chiffrement des données en base) et configuration : non inclus dans gitlab-backup
   dc cp gitlab:/etc/gitlab/gitlab-secrets.json ~/sauvegardes/"$ENV"/
   dc cp gitlab:/etc/gitlab/gitlab.rb ~/sauvegardes/"$ENV"/
   ```

4. **Monter d'un arrêt** : `GITLAB_VERSION=<arrêt suivant>` puis `make deploy ENV=<env>`. Les migrations
   de schéma tournent au démarrage et peuvent être longues : suivre `dc logs -f gitlab`, **ne pas
   interrompre** le conteneur. Si `make deploy` expire (`--wait-timeout 900`) alors que les migrations
   avancent encore, attendre que `dc ps gitlab` passe `healthy` sans relancer.
5. **Reprendre au point 2** pour l'arrêt suivant, jusqu'à la version cible.
6. **PostgreSQL embarqué.** Si les notes de version d'un arrêt exigent une montée de la base embarquée,
   la lancer une fois l'arrêt atteint : `dc exec gitlab gitlab-ctl pg-upgrade` (sauvegarde préalable).
7. **Runner** : une fois GitLab à la version cible, aligner `GITLAB_RUNNER_VERSION` sur la même
   `majeure.mineure` (tag `v<version>`), puis `make deploy ENV=<env>`. L'enregistrement du runner est
   conservé dans le volume `gitlab_runner_config`.

**Retour arrière** : remettre la version de l'arrêt précédent, puis restaurer la sauvegarde prise à cette
version ([Restore GitLab](https://docs.gitlab.com/administration/backup_restore/restore_gitlab/)) avec
`gitlab-secrets.json`.

## SonarQube

- **Version cible.** Le plugin community branch borne la version de SonarQube : la contrainte réelle est
  l'existence d'un tag `mc1arke/sonarqube-with-community-branch-plugin:<version>-community`, qui embarque un
  plugin compatible. Ne jamais remplacer l'image par `sonarqube` officielle.
- **Chemin.** Depuis une version antérieure à la dernière LTA (*Long-Term Active*), passer d'abord par
  cette LTA (documentation [SonarQube Community Build](https://docs.sonarsource.com/sonarqube-community-build/),
section *Server upgrade and maintenance*).
- **Base PostgreSQL.** Vérifier que la version de PostgreSQL utilisée est supportée par la version cible
  (voir [PostgreSQL](#postgresql-base-sonarqube)).

1. **Sauvegarder la base** (SonarQube arrêté pour une copie cohérente) :

   ```bash
   dc stop sonarqube
   dc exec -T sonarqube-db pg_dump -U sonar -Fc sonar > ~/sauvegardes/"$ENV"/sonar-$(date +%F).dump
   ```

2. **Renouveler le volume `sonarqube_extensions`.** Le plugin (`extensions/plugins/sonarqube-community-branch-plugin.jar`,
   chargé en `-javaagent`) vit dans ce volume, qui n'est rempli depuis l'image **qu'à sa création** : sans
   cette étape, l'ancien plugin est conservé et SonarQube démarre avec un plugin incompatible. Le volume ne
   contient que les plugins de l'image (un plugin installé à la main via le Marketplace serait perdu) ;
   **ne pas** toucher à `sonarqube_data` ni `sonarqube_db`.

   ```bash
   dc rm -sf sonarqube
   docker volume rm devops-platform_sonarqube_extensions
   ```

   Suppression structurelle de ce volume : #56.
3. **Changer `SONARQUBE_VERSION`**, puis démarrer SonarQube **sans** `make deploy` : tant que le schéma
   n'est pas migré, SonarQube reste en `DB_MIGRATION_NEEDED`, le healthcheck échoue et `make deploy`
   tomberait en erreur.

   ```bash
   dc up -d sonarqube
   curl -s "$SONARQUBE_URL/api/system/status"     # attendre "status":"DB_MIGRATION_NEEDED" (ou "UP")
   ```

4. **Migrer le schéma** : ouvrir `<SONARQUBE_EXTERNAL_URL>/setup`, ou
   `curl -s -X POST "$SONARQUBE_URL/api/system/migrate_db"`. Suivre `api/system/status`
   (`DB_MIGRATION_RUNNING` → `UP`) et `dc logs -f sonarqube`.
5. **Finaliser** : `make deploy ENV=<env>` une fois le statut `UP`. Les index Elasticsearch sont reconstruits
   au démarrage (`sonarqube_data`), ce qui peut prendre du temps sur une grosse instance.

**Retour arrière** : ancien tag, renouvellement de `sonarqube_extensions`, puis restauration de la base :

```bash
dc rm -sf sonarqube
dc exec -T sonarqube-db sh -c 'dropdb -U sonar sonar && createdb -U sonar sonar'
dc exec -T sonarqube-db pg_restore -U sonar -d sonar < ~/sauvegardes/"$ENV"/sonar-<date>.dump
```

## PostgreSQL (base SonarQube)

- **Version mineure** (`17.11` → `17.12`) : changer `SONARQUBE_DB_VERSION`, `make deploy ENV=<env>`.
- **Version majeure** (`17` → `18`) : le répertoire de données n'est **pas** compatible entre majeures.
  Procédure : vérifier que la version de SonarQube la supporte (PostgreSQL 18 : SonarQube 26.8 et plus),
  `pg_dump` (voir SonarQube, point 1), arrêter la pile SonarQube, supprimer le volume `sonarqube_db`
  **après** contrôle du dump, changer la version, démarrer `sonarqube-db` seul, `pg_restore`, puis
  `make deploy ENV=<env>`.
- **PostgreSQL 18 et plus** : l'image stocke ses données sous `/var/lib/postgresql/<majeure>/docker` et
  déclare le volume sur `/var/lib/postgresql`. Le montage actuel (`sonarqube_db:/var/lib/postgresql/data`
  dans `compose/sonarqube.yml`) doit passer à `sonarqube_db:/var/lib/postgresql` lors de cette montée.

## Grafana, Loki, Promtail

- **Grafana** migre sa base (`grafana.db`, volume `grafana_data`) au démarrage, sans retour possible :
  sauvegarde à froid du volume obligatoire. Le provisioning (`config/grafana/`) est relu à chaque démarrage.
- **Loki** : les notes de version peuvent imposer des changements de `config/loki/loki-config.yaml`
  (`schema_config`, options retirées). Valider la configuration avec la nouvelle image avant de déployer :
  `LOKI_VERSION=<version> scripts/check-loki-config.sh envs/<env>.env` (image et rétention de
  l'instance), ou à la main :
  `docker run --rm -v "$PWD/config/loki:/etc/loki:ro" grafana/loki:<version> -config.file=/etc/loki/loki-config.yaml -config.expand-env=true -verify-config`
  (`-config.expand-env=true` obligatoire : le fichier lit `LOKI_RETENTION_PERIOD`).
- **Promtail** est déprécié par Grafana ; 3.6.x est la dernière version. Migration vers Alloy : #35.

## Portainer, PlantUML

- **Portainer** : garder la variante `-alpine` (le healthcheck exige `wget`). Sauvegarde à froid du volume
  `portainer_data` (migration de sa base au démarrage).
- **PlantUML** : sans état ; garder la variante `jetty-`. Changer le tag et `make deploy ENV=<env>`.
