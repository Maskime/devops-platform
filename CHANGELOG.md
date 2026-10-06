# Journal des modifications

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/spec/v2.0.0.html).

## [Non publié]

### Migration

- Les montages de configuration de Loki, Promtail et Grafana passent en syntaxe longue
  (`create_host_path: false`, source `${PLATFORM_CONFIG_DIR:-../config}`) : ces trois services sont
  recréés au prochain `make deploy` (volumes conservés).
- Traefik et Promtail passent par le proxy de socket `socket-proxy` : au prochain `make deploy`, ils
  sont recréés (coupure HTTP de quelques secondes ; Promtail reprend la collecte à ses positions) et
  l'image `wollomatic/socket-proxy` est téléchargée. Une surcharge locale qui remonterait le socket
  dans `traefik` ou `promtail` est refusée par `make verify` : la retirer.
- `GITLAB_EXTERNAL_URL` devient optionnelle : commenter la ligne de chaque `envs/<env>.env` existant
  pour adopter l'URL dérivée (`https://<GITLAB_HOSTNAME>` en `letsencrypt` et `custom`,
  `http://<GITLAB_HOSTNAME>` en `none`). Une valeur explicite reste contrôlée (même hôte, schéma du mode).
- Runner enregistré par `make bootstrap-legacy` (`factory-runner`) : le premier `make bootstrap` le
  supprime et enregistre à sa place le runner d'instance `devops-platform-runner`.
- Runner déjà enregistré par `make bootstrap-legacy` : la relance réaligne son `url` et son
  `clone_url` (`config.toml`) sur l'URL publique.
- Traefik est désormais configuré par variables `TRAEFIK_*` (`environment`) et non plus par `command`,
  et ce qui dépend du mode TLS vit dans `compose/tls/<mode>.yml` (fusionné avec `compose/proxy.yml`).
  Les labels `traefik.http.routers.<service>.entrypoints` ont disparu : les routeurs suivent les
  entrypoints par défaut. Une surcharge locale de `command` ou de ces labels est à reporter.
- Ajouter `PORTAINER_ADMIN_PASSWORD` (12 caractères minimum) à chaque `envs/<env>.env` existant, sinon
  `make deploy` et `make check-env` refusent de démarrer. Sur une instance déjà initialisée, Portainer
  ignore cette valeur : y reporter le mot de passe admin réel pour garder le fichier à jour.
- Supprimer `PORTAINER_EDGE_PORT`, devenue sans effet.
- `TLS_MODE=custom` : `gitlab-runner` monte `config/certs/ca/` et est recréé au prochain
  `make deploy` (jobs en cours interrompus). En déploiement distant, la copie de configuration change
  d'empreinte une fois. Rien ne change en `none` et `letsencrypt`.
- Token d'analyse SonarQube stocké sur l'instance : lancer d'abord `make bootstrap-sonarqube ENV=<env>`
  depuis le poste qui détient `outputs/<env>.sonarqube-token`, qui le recopie dans le stockage de
  l'instance. Depuis un autre poste, le bootstrap refuse de révoquer un token dont il n'a aucune copie.
  Supprimer ce fichier ne provoque plus de rotation : utiliser `ROTATION=1`.

### Ajouté

- Variables CI d'instance SonarQube : l'étape GitLab de `make bootstrap` crée ou met à jour
  `SONAR_HOST_URL` (URL publique, ou `http://sonarqube:9000` en `*.localhost` et avec une CA privée) et
  `SONAR_TOKEN` (masquée, token d'analyse validé auprès de SonarQube avant écriture). Exemple de job
  `sonar-scanner` dans `docs/analyse-sonarqube.md`.
- Fichier de sortie `outputs/<env>.env` pour les projets consommateurs : URLs publiques de GitLab,
  SonarQube et Grafana, URL de l'API et URL SSH de GitLab, token d'analyse SonarQube (`SONAR_HOST_URL`,
  `SONAR_TOKEN`). Régénéré après chaque étape réussie de `make bootstrap`, permissions `600`, non
  versionné. Voir `docs/sortie-instance.md`.
- Bootstrap commun : `make bootstrap ENV=<env>` enchaîne SonarQube puis GitLab sur une cible Docker
  préparée une seule fois (contexte SSH, garde-fou d'instance en lecture seule) ; une étape dont le
  service est absent de l'instance est ignorée. `make bootstrap-sonarqube` et `make bootstrap-gitlab`
  lancent une seule étape. Voir `docs/bootstrap.md`.
- CA privée en `TLS_MODE=custom` : `config/certs/ca/ca.pem`, facultatif, est monté en lecture seule
  dans `gitlab-runner` (`compose/tls/gitlab/custom.yml`) ; `make bootstrap` vérifie l'URL publique
  avec cette CA et enregistre le runner avec `--tls-ca-file` (enregistrement, jobs, clone du helper,
  `CI_SERVER_TLS_CA_FILE`) ; `make check-env` contrôle la CA. Voir `docs/certificats.md`.
- Bootstrap GitLab : `make bootstrap ENV=<env>` (instance locale ou distante) attend GitLab, renouvelle
  le jeton d'administration root `devops-platform-bootstrap` (révocation des précédents, expiration
  au lendemain) et enregistre un runner d'instance ; `gitlab-runner verify --delete` avant tout
  ré-enregistrement, aucun runner orphelin, aucune donnée de test, idempotent. Variables optionnelles
  `GITLAB_RUNNER_DESCRIPTION` et `GITLAB_RUNNER_NETWORK`. Voir `docs/bootstrap.md`.
- Verrou du bootstrap : une seule étape GitLab de `make bootstrap` à la fois par instance (`flock` sur
  `/etc/gitlab-runner/.bootstrap.lock`, dans le volume du runner, valable quel que soit le poste) ; une
  seconde exécution s'arrête sans modifier GitLab en indiquant le détenteur. Libéré en fin de script,
  y compris en échec ou sur interruption. L'étape SonarQube n'est pas couverte.
- Image auxiliaire du runner : `GITLAB_RUNNER_HELPER_IMAGE` (dépôt sans tag, vide par défaut) remplace
  `registry.gitlab.com` pour le helper des jobs, qui démarrent alors sans accès à gitlab.com (par
  exemple `gitlab/gitlab-runner-helper` sur Docker Hub). Tag `v${CI_RUNNER_VERSION}` développé par le
  runner : multi-arch, aligné sur la version du runner. Voir `docs/bootstrap.md`.
- Bootstrap SonarQube : étape de `make bootstrap` (`scripts/bootstrap/sonarqube.sh`),
  instance locale ou distante. Vérifie `vm.max_map_count` sur l'hôte cible et la présence du plugin
  community branch, remplace le mot de passe par défaut du compte `admin` par
  `SONARQUBE_ADMIN_PASSWORD` et génère un token d'analyse (`GLOBAL_ANALYSIS_TOKEN`) dans
  `outputs/<env>.sonarqube-token` (600), conservé tant qu'il reste valide. Idempotent, aucune donnée
  créée. Documentation : `docs/bootstrap-sonarqube.md`.
- Nettoyage Docker planifié : `scripts/host-prereqs.sh` installe `/usr/local/sbin/devops-platform-prune`
  et le timer systemd `devops-platform-prune.timer` (chaque nuit vers 03:30). Supprime les conteneurs
  de jobs CI arrêtés, les volumes de cache du runner orphelins (reporté pendant un job), les images
  inutilisées (sauté si la plateforme est arrêtée par `down`) et le cache de build inutilisé ; volumes
  et conteneurs de la plateforme jamais touchés. Désactivable par `systemctl mask`, respecté par
  `host-prereqs.sh`. Le script, embarqué dans `host-prereqs.sh`, est contrôlé par shellcheck dans
  `make verify`. Détails : `docs/serveur.md`.
- Déploiement distant : `DEPLOY_SSH=ssh://[utilisateur@]hôte[:port]` dans `envs/<env>.env` fait
  piloter l'instance par le contexte Docker SSH `devops-platform-<env>` (créé ou mis à jour par
  `make`). Les fichiers de config montés sont copiés sur le serveur dans
  `${DEPLOY_DIR}/config-<empreinte>` (`DEPLOY_DIR`, défaut `/opt/devops-platform`), par un conteneur
  `busybox:1.38.0` ; un marqueur refuse une seconde instance sur le même serveur (`FORCER=1`).
  Nouvelles cibles `make down` (volumes conservés) et `make status` ; `make deploy` et `make status`
  affichent le récapitulatif des URLs. Commandes manuelles : `scripts/instance.sh compose <env> …`.
  Détails : `docs/deploiement.md`.
- Accès restreint à l'API Docker : Traefik (provider Docker) et Promtail (`docker_sd_configs`) ne
  montent plus le socket Docker et passent par un proxy filtrant (`compose/socket-proxy.yml`,
  `wollomatic/socket-proxy:1.13.1`, variable `SOCKET_PROXY_VERSION`) : lecture seule sur une liste
  blanche d'endpoints (ping, version, conteneurs, logs, réseaux, événements), clients limités à
  `traefik` et `promtail`, réseau dédié interne non partagé avec les jobs CI. `make verify` contrôle
  les montages du socket et l'isolement de ce réseau ; le contrôle de réseau renommé de
  `make deploy` admet un conteneur placé sur ce seul réseau. Détails : `docs/acces-docker.md`.
- Préparation d'un serveur : `scripts/host-prereqs.sh`, idempotent, exécuté en root sur le serveur.
  Installe Docker Engine et le plugin Compose depuis le dépôt officiel (Debian, Ubuntu ; ailleurs,
  contrôle des versions minimales Engine 25.0 / Compose 2.24.0), applique et persiste
  `vm.max_map_count` ≥ 524288, pose un `/etc/docker/daemon.json` borné (logs `json-file` 10m × 3, cache
  de build ≤ 10 Go, autres clés conservées) sans redémarrer Docker quand des conteneurs tournent
  (`--redemarrer-docker`), et autorise 80, 443 (sauf `--sans-https`) et le port SSH de GitLab
  (`--port-ssh-gitlab`) dans ufw ou firewalld s'ils sont actifs. Procédure : `docs/serveur.md`.
- `TLS_MODE=letsencrypt` : HTTPS sur le port 443 avec des certificats Let's Encrypt obtenus et
  renouvelés automatiquement par Traefik (resolver ACME, `compose/tls/letsencrypt.yml`), port 80
  redirigé vers HTTPS. Nouvelles variables `ACME_EMAIL` (obligatoire dans ce mode), `ACME_CHALLENGE`
  (`http`, HTTP-01, par défaut ; ou `tls`, TLS-ALPN-01) et `ACME_CA_SERVER` (staging). Compte et
  certificats conservés sur le volume `devops-platform_traefik_acme`. `make check-env` (donc `deploy`)
  exige un email valide, des `*_EXTERNAL_URL` renseignées en `https://` et refuse les hostnames
  locaux ou IP ; `make init` demande l'email et génère des URLs en `https://`. Procédure :
  `docs/letsencrypt.md`.
- `TLS_MODE=custom` : HTTPS sur le port 443 avec les certificats fournis dans `config/certs/`
  (`cert.pem`, chaîne complète ; `key.pem`, non chiffrée), port 80 redirigé vers HTTPS (302).
  `make check-env` (donc `deploy`) refuse un certificat absent, illisible, chiffré, expiré, sans SAN,
  non apparié à sa clé ou ne couvrant pas chaque `*_HOSTNAME` (`openssl` requis sur l'hôte), ainsi que
  des `*_EXTERNAL_URL` absentes ou hors `https://` ; avertissement à 30 jours de l'expiration. Nouvelle
  cible `make reload-certs ENV=<env>` après renouvellement ; procédure : `docs/certificats.md`.
  `make init` génère des URLs en `https://` en mode `custom`.
- GitLab derrière le proxy : `external_url` dérivée de `GITLAB_HOSTNAME` et du `TLS_MODE`
  (`GITLAB_EXTERNAL_URL` optionnelle) ; nginx interne en HTTP seul (ni HTTPS, ni redirection, ni
  Let's Encrypt d'Omnibus : pas de double TLS), schéma public transmis (`X-Forwarded-Proto`), IP réelle
  des clients (`X-Forwarded-For`). `make check-env` valide `GITLAB_SSH_PORT` (affiché dans les URLs de
  clone SSH). **Le conteneur `gitlab` est recréé au prochain `make deploy`** (configuration Omnibus
  modifiée : quelques minutes d'indisponibilité). Détails : `docs/gitlab-proxy.md`.
- Traefik porte les `*_HOSTNAME` en alias réseau : le runner (bootstrap legacy) s'enregistre et clone
  par l'URL publique de GitLab, via Traefik ; clone par `http://gitlab` pour un hostname `*.localhost`
  (libcurl le résout toujours vers `127.0.0.1`).

- `TLS_MODE=none` (HTTP simple, usage local) : services servis en HTTP par Traefik sur le port 80.
  `make check-env` (donc `deploy`) valide `TLS_MODE` (vide ou absent : `none`), exige des
  `*_EXTERNAL_URL` en `http://` en mode `none` et avertit, sans bloquer, si un hostname n'est pas local
  (`localhost`, `*.localhost`) ; `make init` affiche le même avertissement (`scripts/lib/tls.sh`).
  **Changement de comportement** : un `TLS_MODE` invalide, ou une URL `https://` en mode `none`, fait
  désormais échouer `make deploy`.
- Reverse proxy Traefik (`compose/proxy.yml`, `traefik:v3.7.13`, variable `TRAEFIK_VERSION`) : seul
  point d'entrée web, sur le port 80, routant GitLab, SonarQube, Grafana, Portainer et PlantUML selon
  leur `*_HOSTNAME`. Provider Docker limité aux conteneurs du projet, API et dashboard désactivés,
  logs d'accès collectés par promtail. HTTP seul : TLS à venir (US 3-2 à 3-4).
- `make check-env` (donc `deploy` et `bootstrap-legacy`) refuse une `*_EXTERNAL_URL` dont l'hôte
  diffère du `*_HOSTNAME` du service ou qui porte un port (`scripts/check-env-urls.sh`).
- `make verify` contrôle les ports publiés : seuls Traefik (80, et 443 pour le TLS à venir) et le SSH
  GitLab sont autorisés, en comparant port publié et port du conteneur ; tout `network_mode` `host`,
  `service:` ou `container:` est refusé.
- Portainer : compte `admin` créé au premier démarrage avec la nouvelle variable **obligatoire**
  `PORTAINER_ADMIN_PASSWORD` (secret Compose ; ≥ 12 caractères, contrôlé par `make check-env` ;
  générée par `make init`). Plus aucune fenêtre où un visiteur pourrait créer l'administrateur.
- Grafana : inscription, création d'organisation, dashboards partagés publiquement et snapshots
  désactivés explicitement (accès anonyme déjà désactivé).
- `make init` signale les hostnames `*.localhost` non résolus par le système et la ligne
  `/etc/hosts` à ajouter.
- Garde-fou contre les lancements en double : un module `compose/<module>.yml` lancé seul ou la
  plateforme lancée sous un autre nom de projet (`-p`) est refusé par Compose dès le chargement, avant
  tout conteneur (`PLATFORM_GARDE_FOU`, `compose/projet-autorise/`). `make deploy` refuse en outre de
  démarrer si des conteneurs d'un autre projet utilisent les volumes ou le réseau de l'instance
  (`scripts/check-doublons.sh`) ; `make verify` contrôle le garde-fou.
- `make init ENV=<env>` (`scripts/init-env.sh`) génère `envs/<env>.env` depuis le modèle : questions
  (domaine, hostnames, `TLS_MODE`, profil) avec valeurs par défaut, mots de passe aléatoires conformes
  aux règles SonarQube, fichier en permissions 600 ; refuse d'écraser un fichier existant sans
  `FORCE=1` (sauvegarde horodatée, secrets repris sauf `NOUVEAUX_MDP=1`).
- `envs/.env.example` : `TLS_MODE` et hostnames des services (`*_HOSTNAME`), consommés à partir de
  l'épopée 3.
- `check-secrets.sh` et `.gitignore` couvrent les sauvegardes `envs/<env>.env.*`.
- Configuration d'une instance entièrement portée par `envs/<env>.env` : ports publiés
  (`GITLAB_HTTP_PORT`, `GITLAB_SSH_PORT`, `SONARQUBE_PORT`, `PORTAINER_PORT`, `PORTAINER_EDGE_PORT`,
  `GRAFANA_PORT`, `PLANTUML_PORT`), URLs publiques (`SONARQUBE_EXTERNAL_URL`, `GRAFANA_EXTERNAL_URL`),
  réseau (`PLATFORM_NETWORK`), socket Docker (`DOCKER_SOCKET`) et tags d'images (`*_VERSION`),
  avec valeurs par défaut.
- `envs/.env.example` documente chaque variable : rôle, valeur par défaut, obligatoire ou non.
- `make check-env` (préalable des cibles d'instance) : exige `ENV=<env>` sur la ligne de commande,
  valide son format, refuse les versions vides ou `latest` et signale les variables obligatoires
  manquantes.
- `verify.sh` vérifie que chaque variable des fichiers compose est documentée dans `envs/.env.example`.
- Procédure de montée de version des images (`docs/montee-de-version.md`) : chemin de mise à jour
  GitLab, migration de schéma SonarQube et renouvellement du volume des plugins, version majeure de
  PostgreSQL, sauvegarde et retour arrière.
- `verify.sh` contrôle l'épinglage des images : variable `*_VERSION` pour chaque image compose, défaut
  versionné (`majeure.mineure`) et identique à `envs/.env.example`, images des scripts versionnées,
  aucun tag `latest`, aucune version vide ou `latest` dans `envs/*.env`.
- GitLab : port SSH affiché dans les URLs de clone (`gitlab_shell_ssh_port`).
- SonarQube : URL publique (`sonar.core.serverBaseURL`) issue de `SONARQUBE_EXTERNAL_URL` ;
  Grafana : `root_url` issue de `GRAFANA_EXTERNAL_URL`.
- Garde-fou contre les fuites de secrets `scripts/check-secrets.sh` (repris de Software Factory dans
  sa partie générique), exécuté par `make check-secrets`, `make verify` et la CI GitHub Actions
  sur chaque push et pull request ; mode `--history` pour l'historique de la branche.
- Hook pre-commit optionnel (`.githooks/pre-commit`), activé par `make install-hooks`.
- Profils de dimensionnement `PLATFORM_PROFILE` (`small`, `medium`, `large` ; défaut `medium`) :
  `config/profiles/<profil>.env` règle Puma, Sidekiq et le PostgreSQL embarqué de GitLab, ainsi que
  les heaps JVM de SonarQube. `make check-env` valide le profil, `make verify` contrôle les profils.
- Rétention des logs Loki : le compacteur purge les logs au-delà de `LOKI_RETENTION_PERIOD`
  (défaut 744h, soit 31 jours ; `0s` = illimitée), purge effective de l'ordre de 4h après l'échéance.
  `scripts/check-loki-config.sh`, appelé par `make check-env` et `make verify`, refuse une durée mal
  formée ou inférieure à 24h et valide la configuration résolue avec `loki -verify-config`
  (`make verify` télécharge désormais l'image Loki).

### Modifié

- **Token d'analyse SonarQube récupérable depuis tout poste** : référence dans le volume `sonarqube_data`
  de l'instance (`600`), `outputs/<env>.sonarqube-token` devient une copie locale rafraîchie à chaque
  bootstrap. Relancé depuis un autre poste, le bootstrap réutilise le token au lieu de le révoquer
  (variable CI `SONAR_TOKEN` et `outputs/<env>.env` restent valides). Rotation explicite par
  `make bootstrap ENV=<env> ROTATION=1`.
- README raccourci (présentation, démarrage rapide, configuration, commandes) : la documentation
  d'exploitation passe dans `docs/` (`initialisation.md`, `exposition.md`, `dimensionnement.md`,
  `logs.md`, `garde-fous.md`), à côté des pages existantes.
- **Services web derrière Traefik** : GitLab, SonarQube, Grafana, Portainer et PlantUML ne publient
  plus de port sur l'hôte ; ils sont servis sur `http://<hostname>` (défaut `<service>.localhost`).
  Portainer est servi en HTTP (port interne 9000) au lieu de HTTPS auto-signé sur 9443.
  URLs publiques par défaut (modèle, `make init`, scripts legacy) : `http://<hostname>`.
  **Migration d'une instance existante** : corriger dans `envs/<env>.env` les URLs générées avant
  le proxy (`GITLAB_EXTERNAL_URL=http://localhost`, `SONARQUBE_EXTERNAL_URL=http://localhost:9000`,
  `GRAFANA_EXTERNAL_URL=http://localhost:3100`) en `http://<hostname du service>` — `make deploy`
  l'exige et indique les lignes —, ajouter si besoin les hostnames `*.localhost` à `/etc/hosts`,
  puis `make deploy` (services web recréés, volumes conservés).
- Outillage Claude Code migré en skills (`.claude/skills/`) : `implement-us`, `plan-epic`,
  `launch-wave` et `github`, qui embarque les scripts d'accès à GitHub et de suivi des US.
  `.claude/commands/`, `.claude/scripts/` et `.claude/workflows/` disparaissent.
- `verify.sh` : image `cytopia/yamllint` figée par son digest (aucun tag versionné publié).
- `verify.sh` déplacé dans `scripts/` (toujours lancé par `make verify`).
- `/launch-wave` ouvre les sessions des US dans [herdr](https://herdr.dev) au lieu de tmux
  (`us-worktree.sh` supprimé) ; herdr devient un prérequis pour lancer une vague.
- Réseau Docker renommé `factory-network` → `devops-platform` (paramétrable via `PLATFORM_NETWORK`).
  Au prochain `make deploy`, les conteneurs d'une instance existante sont recréés sur le nouveau
  réseau (quelques minutes d'indisponibilité de GitLab, volumes conservés) : `make deploy` détecte
  le changement de réseau et force la recréation, faute de quoi Compose se contente de reconnecter
  les conteneurs, qui ne redémarrent plus (`network factory-network not found`). Le réseau des jobs CI du
  runner déjà enregistré est réaligné par `make bootstrap-legacy`, ou à la main (`network_mode` dans
  `/etc/gitlab-runner/config.toml`). L'ancien réseau peut ensuite être supprimé :
  `docker network rm factory-network`.
- Conteneurs nommés par Compose (`devops-platform-<service>-1`) : plus de `container_name` fixe,
  donc plus de collision avec d'autres stacks de l'hôte. Les commandes ciblent un service
  (`docker compose exec <service>`) et non plus un nom (`docker exec <nom>`) ; `make verify` le contrôle.
  Au prochain `make deploy`, les conteneurs d'une instance existante sont recréés : GitLab indisponible
  quelques minutes, jobs CI en cours interrompus. Le label `container` des logs Loki prend les nouveaux
  noms (le dashboard, fondé sur le label `service`, n'est pas affecté).
- Volumes nommés explicitement (`devops-platform_<volume>`), sous le nom que leur donnait déjà
  Compose : données conservées, aucune migration. Conséquence : ne jamais lancer `up` sur un module
  seul ni sous un autre nom de projet (`-p`), les conteneurs créés partageraient les volumes de l'instance.
- Loki lancé avec `-config.expand-env=true` ; API de suppression `/loki/api/v1/delete` désactivée.
  Au prochain `make deploy`, une instance existante purge ses logs de plus de 31 jours (défaut) :
  fixer `LOKI_RETENTION_PERIOD` avant pour les conserver. La première compaction d'un gros volume
  `loki_data` peut générer un pic d'entrées/sorties disque.
- `GITLAB_EXTERNAL_URL`, `GITLAB_ROOT_PASSWORD`, `SONARQUBE_DB_PASSWORD` et `GRAFANA_ADMIN_PASSWORD`
  sont obligatoires : `docker compose` refuse de démarrer sans elles.

### Supprimé

- Publication du port du tunnel des agents Edge Portainer (`PORTAINER_EDGE_PORT`, 8000) : les agents
  Edge déjà enrôlés ne peuvent plus joindre l'instance.
- Variables de port web `GITLAB_HTTP_PORT`, `SONARQUBE_PORT`, `GRAFANA_PORT`, `PORTAINER_PORT` et
  `PLANTUML_PORT` (ignorées si encore présentes dans un `envs/<env>.env`).

### Corrigé

- `scripts/instance.sh` : en distant (`DEPLOY_SSH`), le pré-test SSH consommait l'entrée standard
  destinée à `scripts/instance.sh compose <env> exec -T …` (`ssh -n`).
- GitLab : la concurrence Sidekiq était réglée par `sidekiq['max_concurrency']`, supprimé en GitLab
  17.0 et ignoré (Sidekiq tournait à 20). Elle passe par `sidekiq['concurrency']` : 10 avec le
  profil `medium`. Le profil `medium` porte aussi `max_connections` du PostgreSQL embarqué de 100 à 150.
  Au prochain `make deploy`, `gitlab` et `sonarqube` sont recréés (volumes conservés).

## [0.1.0] - 2026-10-05

Base de référence : extraction à l'identique de l'infrastructure de Software Factory (épopée 1).

### Ajouté

- README présentant la plateforme et sa cible de déploiement.
- Licence MIT.
- `.gitignore` excluant les fichiers d'environnement (`envs/*.env`, sauf `envs/.env.example`),
  les sorties du bootstrap (`outputs/`) et les certificats fournis (`config/certs/`).
- Arborescence `compose/`, `config/`, `envs/`, `scripts/`.
- Makefile auto-documenté : `make help` (cible par défaut) et `make verify`.
- Ce journal des modifications.
- Configuration Loki (`config/loki/`) et Promtail (`config/promtail/`) reprises de Software Factory.
  La collecte Promtail est limitée aux conteneurs du projet compose `devops-platform`.
- Provisioning Grafana (`config/grafana/provisioning/`) : datasource Loki par défaut et dashboard
  « Container Logs » (dossier *Plateforme*) avec des panneaux GitLab et SonarQube. Le dashboard
  `pipeline-runs` et les panneaux propres à Software Factory ne sont pas repris.
- `make deploy ENV=<env>` : démarre l'instance en local et attend que tous les services soient
  healthy ; refuse un fichier d'environnement absent ou contenant encore des valeurs `change_me`.
- Healthchecks pour `gitlab-runner` (métriques internes), `promtail` (sonde aussi Loki, dont l'image
  distroless n'en permet aucun) et `portainer`.
- `make bootstrap-legacy ENV=local` (temporaire) : scripts de bootstrap repris de Software Factory
  dans `scripts/legacy/` (GitLab, SonarQube, analyse de test), créant des données de test.
- Variable `SONARQUBE_ADMIN_PASSWORD` dans `envs/.env.example`.

### Modifié

- Portainer passe à la variante `2.45.1-alpine` (même version) pour permettre un healthcheck.

[Non publié]: https://github.com/Maskime/devops-platform/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/Maskime/devops-platform/releases/tag/v0.1.0
