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
profil de dimensionnement, versions et secrets. Une instance vierge se monte en quelques commandes :

```bash
make init        ENV=staging   # génère envs/staging.env (secrets aléatoires)
make host-prereqs ENV=staging  # prépare le serveur (Docker, sysctl, daemon.json)
make deploy      ENV=staging   # déploie à distance via docker context SSH
make bootstrap   ENV=staging   # configure GitLab, le runner et SonarQube
make smoke       ENV=staging   # vérifie l'instance de bout en bout
```

> 🚧 **En construction.** Les commandes ci-dessus décrivent la cible. L'avancement est suivi dans les
> [milestones](https://github.com/Maskime/devops-platform/milestones) et les
> [issues](https://github.com/Maskime/devops-platform/issues?q=is%3Aissue+label%3Aepic) du projet.
> `make help` liste les cibles réellement disponibles à ce stade.

## Arborescence

| Chemin | Contenu |
|---|---|
| `Makefile` | Point d'entrée opérateur ; `make help` liste les cibles disponibles |
| `compose/` | Fichiers Docker Compose de la plateforme |
| `config/` | Configuration des services (Traefik, Loki, Promtail, Grafana…) |
| `config/certs/` | Certificats fournis pour `TLS_MODE=custom` (non versionnés) |
| `envs/` | Un fichier `<env>.env` par instance (non versionné) ; seul `.env.example` est versionné |
| `.github/workflows/` | CI GitHub Actions (garde-fou secrets) |
| `.githooks/` | Hooks Git optionnels (`make install-hooks`) |
| `scripts/` | Scripts d'exploitation (initialisation, déploiement, bootstrap, smoke test) |
| `outputs/` | Informations de connexion générées par le bootstrap (non versionné) |
| `CHANGELOG.md` | Journal des modifications ([Keep a Changelog](https://keepachangelog.com/fr/1.1.0/)) |

## Démarrage local (état actuel)

En attendant les épopées 2 à 5, la plateforme se lance en local à l'identique de Software Factory :

```bash
cp envs/.env.example envs/local.env   # puis remplacer chaque valeur change_me_*
make deploy ENV=local                 # démarre tous les services et attend qu'ils soient healthy
make bootstrap-legacy ENV=local       # optionnel : bootstrap repris de Software Factory
```

Toute la configuration de l'instance (ports, URLs, réseau, versions, secrets) tient dans
`envs/<env>.env` : chaque variable est documentée dans [`envs/.env.example`](envs/.env.example).
Les URLs locales par défaut :

| Service | URL locale | Variable de port |
|---|---|---|
| GitLab | http://localhost (SSH : port 2222) | `GITLAB_HTTP_PORT`, `GITLAB_SSH_PORT` |
| SonarQube | http://localhost:9000 | `SONARQUBE_PORT` |
| Grafana | http://localhost:3100 | `GRAFANA_PORT` |
| Portainer | https://localhost:9443 | `PORTAINER_PORT` |
| PlantUML | http://localhost:8081 | `PLANTUML_PORT` |

> ⚠️ `make bootstrap-legacy` est **temporaire** : il reprend les scripts `setup-*.sh` de Software
> Factory (`scripts/legacy/`), qui créent des **données de test** (projet `factory-test`, pipeline,
> analyse SonarQube). Il est réservé à `ENV=local` (`FORCER=1` pour passer outre) et sera remplacé
> par `make bootstrap` (épopée 5), qui laissera l'instance vierge.
> Il requiert `curl` et `python3` sur l'hôte, et `vm.max_map_count` ≥ 524288 pour SonarQube.

## Garde-fou contre les fuites de secrets

Le repo étant public, `scripts/check-secrets.sh` vérifie qu'aucun secret n'y est publié :
fichiers sensibles versionnés (`envs/<env>.env`, `outputs/`, `config/certs/`, clés et keystores),
couverture du `.gitignore`, jetons reconnaissables (GitLab, GitHub, SonarQube, Anthropic, AWS, Slack),
clés privées et valeurs littérales affectées à des variables `*PASSWORD*`, `*TOKEN*`, `*SECRET*` ou
`*API_KEY*` (les références `${VAR}` et les valeurs d'exemple `change_me_*` sont admises).
Seuls le fichier, la ligne et le type de secret sont affichés, jamais la valeur.

| Contexte | Commande |
|---|---|
| CI GitHub Actions (chaque push et PR) | `.github/workflows/check-secrets.yml`, automatique |
| Manuel | `make check-secrets` (inclus dans `make verify`) |
| Historique de la branche courante | `scripts/check-secrets.sh --history` (jetons et clés uniquement) |

**Hook pre-commit (optionnel).** Pour bloquer un commit dont le contenu indexé contient un secret :

```bash
make install-hooks                    # git config core.hooksPath .githooks
git commit --no-verify …              # contournement ponctuel, à réserver aux faux positifs avérés
git config --unset core.hooksPath     # désactivation
```

`core.hooksPath` remplace `.git/hooks` : les hooks personnels qui s'y trouvent ne sont plus exécutés.

**Faux positif.** Ajouter le marqueur `check-secrets: ignore` dans un commentaire sur la ligne concernée.

**Fuite avérée.** Révoquer immédiatement le secret auprès du service concerné : une fois poussé sur un
repo public, il doit être considéré comme compromis. Purger ensuite l'historique (`git filter-repo`).

## Origine

Cette plateforme est extraite de l'infrastructure du projet *Software Factory*, afin d'être réutilisée
par d'autres projets.

## Licence

[MIT](LICENSE)
