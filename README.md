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
| `docs/` | Documentation d'exploitation ([montée de version](docs/montee-de-version.md)) |
| `envs/` | Un fichier `<env>.env` par instance (non versionné) ; seul `.env.example` est versionné |
| `.github/workflows/` | CI GitHub Actions (garde-fou secrets) |
| `.githooks/` | Hooks Git optionnels (`make install-hooks`) |
| `scripts/` | Scripts d'exploitation (initialisation, déploiement, bootstrap, smoke test) |
| `outputs/` | Informations de connexion générées par le bootstrap (non versionné) |
| `CHANGELOG.md` | Journal des modifications ([Keep a Changelog](https://keepachangelog.com/fr/1.1.0/)) |

## Démarrage local (état actuel)

En attendant les épopées 2 à 5, la plateforme se lance en local à l'identique de Software Factory :

```bash
make init ENV=local                   # génère envs/local.env (Entrée pour garder chaque défaut)
make deploy ENV=local                 # démarre tous les services et attend qu'ils soient healthy
make bootstrap-legacy ENV=local       # optionnel : bootstrap repris de Software Factory
```

Toute la configuration de l'instance (hostnames, URLs, réseau, versions, secrets) tient dans
`envs/<env>.env` : chaque variable est documentée dans [`envs/.env.example`](envs/.env.example).
Chaque image est épinglée sur une version précise (variables `*_VERSION`, jamais `latest`) ; pour en
changer, suivre la [procédure de montée de version](docs/montee-de-version.md) (chemin de mise à jour
GitLab, migration SonarQube).

## Exposition (reverse proxy Traefik)

Traefik (`compose/proxy.yml`) est le seul point d'entrée web : il publie le port 80 et route chaque
requête vers le service dont le hostname correspond (`*_HOSTNAME`). Aucun autre service web ne publie de
port ; seuls restent publiés le SSH de GitLab (`GITLAB_SSH_PORT`) et le tunnel des agents Edge de
Portainer (`PORTAINER_EDGE_PORT`). `make verify` contrôle cette liste.

| Service | URL locale par défaut | Variable |
|---|---|---|
| GitLab | http://gitlab.localhost (SSH : port 2222) | `GITLAB_HOSTNAME`, `GITLAB_SSH_PORT` |
| SonarQube | http://sonarqube.localhost | `SONARQUBE_HOSTNAME` |
| Grafana | http://grafana.localhost | `GRAFANA_HOSTNAME` |
| Portainer | http://portainer.localhost | `PORTAINER_HOSTNAME` |
| PlantUML | http://plantuml.localhost | `PLANTUML_HOSTNAME` |

- **Résolution des noms.** Sur un serveur, chaque hostname doit pointer vers lui (DNS). En local,
  `*.localhost` est résolu vers `127.0.0.1` par les navigateurs et curl, mais pas toujours par le
  système (git, wget…) : `make init` le détecte et indique la ligne à ajouter à `/etc/hosts`
  (`127.0.0.1 gitlab.localhost sonarqube.localhost grafana.localhost portainer.localhost plantuml.localhost`).
- **URLs publiques.** L'hôte de `GITLAB_EXTERNAL_URL`, `SONARQUBE_EXTERNAL_URL` et
  `GRAFANA_EXTERNAL_URL` doit être le hostname du service, sans port : `make deploy` (cible
  `check-env`) refuse une URL incohérente et indique la ligne à corriger.
- **HTTP clair.** Tant que le TLS n'est pas livré (US 3-2 à 3-4), `TLS_MODE` est sans effet : tout le
  trafic, identifiants compris, circule en HTTP sur le port 80 (Portainer n'est plus servi en HTTPS
  auto-signé sur 9443). Ne pas exposer l'instance hors d'un réseau maîtrisé d'ici là.

> ⚠️ `make bootstrap-legacy` est **temporaire** : il reprend les scripts `setup-*.sh` de Software
> Factory (`scripts/legacy/`), qui créent des **données de test** (projet `factory-test`, pipeline,
> analyse SonarQube). Il est réservé à `ENV=local` (`FORCER=1` pour passer outre) et sera remplacé
> par `make bootstrap` (épopée 5), qui laissera l'instance vierge.
> Il requiert `curl` et `python3` sur l'hôte, et `vm.max_map_count` ≥ 524288 pour SonarQube.

## Initialisation d'une instance (`make init`)

`make init ENV=<env>` génère `envs/<env>.env` à partir du modèle `envs/.env.example`, sans secret à
inventer ni à copier :

| Question | Défaut |
|---|---|
| Domaine de base | `localhost` |
| Hostname de chaque service (GitLab, SonarQube, Grafana, Portainer, PlantUML) | `<service>.<domaine>` |
| `TLS_MODE` (`letsencrypt`, `custom`, `none`) | `none` pour un domaine local (`localhost`, `*.localhost`), sinon `letsencrypt` |
| Profil de dimensionnement | `medium` |

- **Mots de passe** (root GitLab, base et admin SonarQube, admin Grafana) : 24 caractères aléatoires
  avec majuscule, minuscule, chiffre et caractère spécial (règles SonarQube), sans caractère
  problématique pour Compose ou le shell. Ils ne sont jamais affichés : les lire dans le fichier.
- **Fichier** en permissions `600`, écrit de façon atomique.
- **URLs publiques** (`*_EXTERNAL_URL`) dérivées des hostnames : `http://<hostname>`, servies par
  Traefik sur le port 80. `TLS_MODE` n'a pas encore d'effet (TLS : US 3-2 à 3-4).
- **Sans terminal** (`make init ENV=<env> < /dev/null`, ou réponses passées sur l'entrée standard),
  une réponse vide prend la valeur par défaut et une réponse invalide arrête la commande.

**Fichier existant.** `make init` refuse de l'écraser. `FORCE=1` le régénère : l'ancien fichier est
sauvegardé dans `envs/<env>.env.bak.<date>` (600, non versionné, jamais écrasé), ses réponses sont
proposées par défaut et **ses secrets sont repris**. Les autres réglages (ports SSH, versions, réseau…)
repartent du modèle : les reprendre depuis la sauvegarde si besoin.
`FORCE=1 NOUVEAUX_MDP=1` régénère aussi les secrets : à réserver à une instance jamais déployée ou à
réinstaller, car le mot de passe PostgreSQL de SonarQube est inscrit dans son volume et le mot de
passe root GitLab n'est appliqué qu'au premier démarrage. `FORCE` et `NOUVEAUX_MDP` ne sont acceptés
que sur la ligne de commande, jamais hérités du shell.

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
