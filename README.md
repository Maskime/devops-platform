# devops-platform

Plateforme DevOps auto-hébergée, déployable à l'identique sur n'importe quel serveur :

| Brique | Outil |
|---|---|
| Forge, tickets, CI/CD | GitLab CE + GitLab Runner |
| Analyse statique | SonarQube Community Edition (+ plugin community branch) |
| Logs | Grafana + Loki + Promtail |
| Outils | Portainer, PlantUML |
| Exposition | Traefik (TLS Let's Encrypt, certificats fournis ou HTTP simple) |

Chaque instance est entièrement décrite par un fichier `envs/<env>.env` : hostnames, mode TLS,
profil de dimensionnement, versions et secrets.

## Démarrage rapide

```bash
make init ENV=local                   # génère envs/local.env (Entrée pour garder chaque défaut)
make deploy ENV=local                 # démarre tous les services et attend qu'ils soient healthy
make bootstrap ENV=local              # SonarQube (compte admin, compte et token d'analyse) puis GitLab (runner)
make smoke ENV=local                  # projet de test, pipeline et analyse SonarQube de bout en bout
```

| Service | URL locale par défaut |
|---|---|
| GitLab | http://gitlab.localhost (SSH : port 2222) |
| SonarQube | http://sonarqube.localhost |
| Grafana | http://grafana.localhost |
| Portainer | http://portainer.localhost |
| PlantUML | http://plantuml.localhost |

Les mots de passe générés par `make init` se lisent dans `envs/local.env`. Si git ou wget ne résolvent
pas `*.localhost`, `make init` indique la ligne à ajouter à `/etc/hosts`.

## Configuration d'une instance

Toute la configuration tient dans `envs/<env>.env`, généré par `make init` ; chaque variable est
documentée dans [`envs/.env.example`](envs/.env.example). Les principaux réglages :

- **`TLS_MODE`** : `none` (HTTP, usage local), `letsencrypt` (certificats obtenus et renouvelés
  automatiquement) ou `custom` (certificats fournis dans `config/certs/`).
- **`PLATFORM_PROFILE`** : `small`, `medium` (défaut) ou `large`, selon la taille du serveur.
- **`*_HOSTNAME`** : un hostname par service, routé par Traefik ; seuls 80, 443 et le SSH de GitLab
  sont publiés sur l'hôte.
- **`*_VERSION`** : chaque image est épinglée sur une version précise, jamais `latest`.
- **`DEPLOY_SSH`** : serveur cible (`ssh://utilisateur@hôte`) ; vide, l'instance tourne sur le
  moteur Docker local.

`make check-env`, préalable de `make deploy`, refuse une configuration incohérente et indique la ligne
à corriger.

## Commandes

| Commande | Rôle |
|---|---|
| `make init ENV=<env>` | Génère `envs/<env>.env` (questions, secrets aléatoires) ; `FORCE=1` pour régénérer |
| `make deploy ENV=<env>` | Démarre l'instance, locale ou distante, et attend que tous les services soient healthy |
| `make status ENV=<env>` | État des services et URLs de l'instance |
| `make down ENV=<env>` | Arrête l'instance (volumes conservés) |
| `make bootstrap ENV=<env>` | Configure SonarQube puis GitLab : compte admin, compte et token d'analyse, runner d'instance (idempotent) ; `ROTATION=1` remplace le token d'analyse |
| `make bootstrap-sonarqube ENV=<env>` / `bootstrap-gitlab` | Une seule étape de `make bootstrap` |
| `make smoke ENV=<env>` | Smoke test de bout en bout : projet de test, pipeline, analyse SonarQube ; `NETTOYER=1` le supprime |
| `make reload-certs ENV=<env>` | Recharge les certificats de `config/certs/` (`TLS_MODE=custom`) |
| `make verify` | Vérifications statiques : shellcheck, yamllint, compose, secrets (Docker requis) |
| `make check-secrets` | Recherche de secrets dans le dépôt |
| `make install-hooks` | Active le hook pre-commit optionnel de recherche de secrets |

`make help` fait foi pour la liste des cibles disponibles.

## Documentation

| Page | Sujet |
|---|---|
| [Préparation d'un serveur](docs/serveur.md) | `scripts/host-prereqs.sh` : Docker, `vm.max_map_count`, `daemon.json`, pare-feu, nettoyage Docker planifié |
| [Déploiement](docs/deploiement.md) | `make deploy` / `status` / `down`, serveur distant (`DEPLOY_SSH`), copie de la config |
| [Initialisation](docs/initialisation.md) | `make init` : questions, secrets générés, régénération (`FORCE=1`) |
| [Bootstrap](docs/bootstrap.md) | `make bootstrap` : enchaînement des étapes, GitLab (jeton d'administration, runner d'instance, image auxiliaire), idempotence |
| [Analyse SonarQube depuis la CI](docs/analyse-sonarqube.md) | Variables CI d'instance `SONAR_HOST_URL` et `SONAR_TOKEN`, exemple de job `sonar-scanner` |
| [Smoke test](docs/smoke-test.md) | `make smoke` : vérifications, données de test, nettoyage (`NETTOYER=1`), délais |
| [Branchement d'un projet](docs/branchement-projet.md) | Brancher un projet hébergé, co-localisé ou distant : `outputs/<env>.env`, `.gitlab-ci.yml` avec analyse SonarQube, réseau Docker externe |
| [Fichier de sortie](docs/sortie-instance.md) | `outputs/<env>.env` pour les projets consommateurs : URLs, API GitLab, token d'analyse |
| [Bootstrap SonarQube](docs/bootstrap-sonarqube.md) | Étape SonarQube : `vm.max_map_count`, compte admin, token d'analyse, mot de passe admin inconnu |
| [Exposition](docs/exposition.md) | Traefik, hostnames, URLs publiques, modes TLS, surface d'exposition |
| [Certificats fournis](docs/certificats.md) | `TLS_MODE=custom` : fichiers attendus, contrôles, renouvellement |
| [Let's Encrypt](docs/letsencrypt.md) | `TLS_MODE=letsencrypt` : prérequis, challenge, stockage, renouvellement |
| [GitLab derrière le proxy](docs/gitlab-proxy.md) | URL publique, nginx interne, SSH, runner |
| [Dimensionnement](docs/dimensionnement.md) | Profils `small` / `medium` / `large` : ressources minimales et réglages |
| [Rétention des logs](docs/logs.md) | Durée de rétention Loki, délai de purge |
| [Accès à l'API Docker](docs/acces-docker.md) | Proxy de socket filtrant pour Traefik et Promtail : endpoints autorisés, isolement, limites |
| [Garde-fous](docs/garde-fous.md) | Lancements compose en double, fuites de secrets (CI, hook pre-commit) |
| [Montée de version](docs/montee-de-version.md) | Procédure par image (chemin de mise à jour GitLab, migration SonarQube) |

## Avancement

Voir les [milestones](https://github.com/Maskime/devops-platform/milestones) et le
[`CHANGELOG.md`](CHANGELOG.md).

## Arborescence

| Chemin | Contenu |
|---|---|
| `Makefile` | Point d'entrée opérateur |
| `compose.yml`, `compose/` | Modules Docker Compose, assemblés par `compose.yml` (overlays TLS dans `compose/tls/`) |
| `config/` | Configuration des services, profils de dimensionnement, certificats fournis (non versionnés) |
| `envs/` | Un fichier `<env>.env` par instance (non versionné) ; seul `.env.example` est versionné |
| `scripts/` | Scripts d'exploitation et de vérification |
| `docs/` | Documentation d'exploitation |
| `outputs/` | Informations de connexion générées par le bootstrap, dont `<env>.env` (non versionné) |

## Origine

Cette plateforme est extraite de l'infrastructure du projet *Software Factory*, afin d'être réutilisée
par d'autres projets.

## Licence

[MIT](LICENSE)
