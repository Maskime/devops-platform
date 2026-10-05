# Journal des modifications

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/spec/v2.0.0.html).

## [Non publié]

### Ajouté

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
- GitLab : port SSH affiché dans les URLs de clone (`gitlab_shell_ssh_port`).
- SonarQube : URL publique (`sonar.core.serverBaseURL`) issue de `SONARQUBE_EXTERNAL_URL` ;
  Grafana : `root_url` issue de `GRAFANA_EXTERNAL_URL`.
- Garde-fou contre les fuites de secrets `scripts/check-secrets.sh` (repris de Software Factory dans
  sa partie générique), exécuté par `make check-secrets`, `make verify` et la CI GitHub Actions
  sur chaque push et pull request ; mode `--history` pour l'historique de la branche.
- Hook pre-commit optionnel (`.githooks/pre-commit`), activé par `make install-hooks`.

### Modifié

- Réseau Docker renommé `factory-network` → `devops-platform` (paramétrable via `PLATFORM_NETWORK`).
  Au prochain `make deploy`, les conteneurs d'une instance existante sont recréés sur le nouveau
  réseau (quelques minutes d'indisponibilité de GitLab, volumes conservés) : `make deploy` détecte
  le changement de réseau et force la recréation, faute de quoi Compose se contente de reconnecter
  les conteneurs, qui ne redémarrent plus (`network factory-network not found`). Le réseau des jobs CI du
  runner déjà enregistré est réaligné par `make bootstrap-legacy`, ou à la main (`network_mode` dans
  `/etc/gitlab-runner/config.toml`). L'ancien réseau peut ensuite être supprimé :
  `docker network rm factory-network`.
- `GITLAB_EXTERNAL_URL`, `GITLAB_ROOT_PASSWORD`, `SONARQUBE_DB_PASSWORD` et `GRAFANA_ADMIN_PASSWORD`
  sont obligatoires : `docker compose` refuse de démarrer sans elles.

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
