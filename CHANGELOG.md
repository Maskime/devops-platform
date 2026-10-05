# Journal des modifications

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/spec/v2.0.0.html).

## [Non publié]

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

[Non publié]: https://github.com/Maskime/devops-platform/commits/main
