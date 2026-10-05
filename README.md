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
| `config/profiles/` | Profils de dimensionnement (`PLATFORM_PROFILE`), versionnés |
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

## Profils de dimensionnement

`PLATFORM_PROFILE` (dans `envs/<env>.env`) adapte la consommation mémoire de GitLab et SonarQube à la
taille du serveur : `small`, `medium` (défaut) ou `large`. Chaque profil est un fichier
`config/profiles/<profil>.env`, injecté dans les conteneurs `gitlab` et `sonarqube`.

**Ressources minimales de l'hôte**, pour la plateforme complète (GitLab, SonarQube, observabilité,
outils), hors jobs CI du runner — prévoir de la marge s'ils tournent sur le même hôte :

| Profil | RAM | vCPU | Disque | Usage visé |
|---|---|---|---|---|
| `small` | 8 Go | 4 | 50 Go | Poste de développement, petite équipe (≈ 10 utilisateurs) |
| `medium` | 16 Go | 8 | 100 Go | Équipe de taille moyenne (≈ 50 utilisateurs) |
| `large` | 32 Go | 16 | 250 Go | Plusieurs équipes, gros dépôts et analyses lourdes |

Quel que soit le profil, SonarQube exige `vm.max_map_count` ≥ 524288 sur l'hôte.

**Réglages :**

| Réglage | `small` | `medium` | `large` |
|---|---|---|---|
| GitLab — workers Puma | 0 (mode single) | 2 | 4 |
| GitLab — threads Puma (min / max) | 1 / 4 | 1 / 4 | 4 / 4 |
| GitLab — concurrence Sidekiq | 5 | 10 | 20 |
| GitLab — PostgreSQL `shared_buffers` | 128MB | 256MB | 1GB |
| GitLab — PostgreSQL `max_connections` | 100 | 150 | 300 |
| SonarQube — heap web (Xmx) | 512m | 512m | 1g |
| SonarQube — heap Compute Engine (Xmx) | 512m | 512m | 2g |
| SonarQube — heap Elasticsearch (Xms = Xmx) | 512m | 512m | 2g |

`medium` reprend le réglage historique de la plateforme (heaps SonarQube par défaut).
En `small`, Puma tourne en **mode single** (un seul processus, sans maître) : quelques centaines de Mo
économisés, au prix d'un débit réduit et sans redémarrage progressif ni surveillance mémoire des workers.

**Changer de profil** : modifier `PLATFORM_PROFILE` dans `envs/<env>.env`, puis `make deploy ENV=<env>`,
qui recrée `gitlab` et `sonarqube` (volumes conservés ; GitLab indisponible quelques minutes).
`make check-env` refuse un profil inconnu et signale un `PLATFORM_PROFILE` exporté dans le shell, qui
prime sur le fichier. Pour un réglage sur mesure, ajouter un fichier `config/profiles/<nom>.env`
définissant les mêmes clés (contrôlé par `make verify`).

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
