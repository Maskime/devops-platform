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

Toute la configuration de l'instance (ports, URLs, réseau, versions, secrets) tient dans
`envs/<env>.env` : chaque variable est documentée dans [`envs/.env.example`](envs/.env.example).
Chaque image est épinglée sur une version précise (variables `*_VERSION`, jamais `latest`) ; pour en
changer, suivre la [procédure de montée de version](docs/montee-de-version.md) (chemin de mise à jour
GitLab, migration SonarQube).
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
- **URLs publiques** (`*_EXTERNAL_URL`) dérivées des hostnames, en `http://` sur les ports par défaut
  (`localhost` pour un domaine local). `TLS_MODE` et les hostnames n'ont pas encore d'effet : ils
  seront consommés par le reverse proxy (épopée 3).
- **Sans terminal** (`make init ENV=<env> < /dev/null`, ou réponses passées sur l'entrée standard),
  une réponse vide prend la valeur par défaut et une réponse invalide arrête la commande.

**Fichier existant.** `make init` refuse de l'écraser. `FORCE=1` le régénère : l'ancien fichier est
sauvegardé dans `envs/<env>.env.bak.<date>` (600, non versionné, jamais écrasé), ses réponses sont
proposées par défaut et **ses secrets sont repris**. Les autres réglages (ports, versions, réseau…)
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

## Rétention des logs (Loki)

Loki purge les logs plus anciens que `LOKI_RETENTION_PERIOD` (dans `envs/<env>.env`), **744h (31 jours)
par défaut**. Sans rétention, le volume `loki_data` croîtrait sans limite.

- **Format** : durée en `h`, `d` ou `w` (`168h`, `31d`, `4w`). Minimum **24h**, multiple de 24h recommandé
  (période de l'index). `0s` désactive la purge (conservation illimitée).
- **Au moins 168h recommandé** : Loki accepte à l'ingestion les logs vieux de moins de 7 jours
  (`reject_old_samples_max_age`, qui ne purge rien). Avec une rétention plus courte, des logs renvoyés en
  retard (positions de Promtail perdues, par exemple) sont stockés puis aussitôt purgés.
- **Délai de purge effectif** : de l'ordre de **4h au-delà de l'échéance**. Un chunk (jusqu'à 2h de logs)
  n'expire qu'avec sa dernière entrée ; le compacteur le marque à sa passe suivante (toutes les 10 min)
  et ne le supprime du disque qu'après `retention_delete_delay` (2h). L'espace des index est libéré par
  table journalière.
- **Prise en compte** : `make deploy ENV=<env>` après modification de `envs/<env>.env` (le conteneur
  `loki` est recréé) ; `docker compose --env-file envs/<env>.env restart loki` après modification de
  `config/loki/loki-config.yaml`. Les logs déjà hors délai sont purgés dans les heures qui suivent.
- **Validation** : `make check-env` (préalable de `make deploy`) et `make verify` refusent une durée mal
  formée ou inférieure à 24h — Loki l'accepterait sans erreur — et passent la configuration résolue à
  `loki -verify-config` (`scripts/check-loki-config.sh`).

L'API de suppression à la demande (`/loki/api/v1/delete`) est désactivée (`deletion_mode: disabled`) :
Loki n'a pas d'authentification sur le réseau de la plateforme.

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
