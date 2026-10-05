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
| `compose/` | Modules Docker Compose de la plateforme, assemblés par `compose.yml` |
| `compose/projet-autorise/` | Garde-fou contre les lancements en double (nom de projet autorisé) |
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
port ; seul reste publié le SSH de GitLab (`GITLAB_SSH_PORT`).

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
- **URLs publiques.** L'hôte de `GITLAB_EXTERNAL_URL` (optionnelle, dérivée par défaut : voir
  ci-dessous), `SONARQUBE_EXTERNAL_URL` et `GRAFANA_EXTERNAL_URL` doit être le hostname du service,
  sans port : `make deploy` (cible `check-env`) refuse une URL incohérente et indique la ligne à
  corriger.
- **Mode TLS (`TLS_MODE`).**
  - `none` (défaut, usage local) : HTTP simple sur le port 80, sans certificat (Portainer n'est plus
    servi en HTTPS auto-signé sur 9443). `make deploy` (cible `check-env`) exige des `*_EXTERNAL_URL`
    en `http://` et **avertit**, sans bloquer, si un hostname n'est pas local (`localhost`,
    `*.localhost`) : le trafic, identifiants compris, circule en clair. Un TLS terminé en amont
    (load balancer) n'est pas géré.
  - `letsencrypt`, `custom` : HTTPS à venir (US 3-2 et 3-3) ; d'ici là, sans effet (HTTP clair sur le
    port 80, signalé par `make deploy`) : ne pas exposer l'instance hors d'un réseau maîtrisé.
  - Toute autre valeur est refusée par `make deploy`.

### GitLab derrière le proxy

- **URL publique (`external_url`)** dérivée du hostname et du mode TLS : `https://<GITLAB_HOSTNAME>`
  en `letsencrypt` et `custom`, `http://<GITLAB_HOSTNAME>` en `none`. Elle fait les liens, les URLs de
  clone HTTP et l'enregistrement du runner. `GITLAB_EXTERNAL_URL` ne sert plus qu'à forcer une valeur
  (même hôte, sans port) ; une valeur explicite en `http://` en `letsencrypt` ou `custom` est signalée
  par `make deploy`.
- **Nginx interne** : Traefik termine le TLS. Le nginx de GitLab écoute en HTTP sur 80 seulement, sans
  HTTPS, redirection ni Let's Encrypt propres (pas de double TLS), et transmet à GitLab le schéma public
  (`X-Forwarded-Proto`). L'IP réelle des clients est lue dans `X-Forwarded-For` ; limite : la confiance
  porte sur les plages privées, jobs CI compris (#76).
- **SSH** : `GITLAB_SSH_PORT` (défaut 2222) est le seul port publié par GitLab et celui des URLs de
  clone SSH (`ssh://git@<GITLAB_HOSTNAME>:<port>/<groupe>/<projet>.git`). `make check-env` exige un
  entier de 1 à 65535 sans zéro en tête, hors 80 et 443, et signale 22 (sshd de l'hôte).
- **Runner et jobs CI** : Traefik porte les `*_HOSTNAME` en alias sur le réseau de la plateforme. Dans
  ce réseau, l'URL publique mène donc à Traefik, par le même chemin et le même certificat que pour un
  client externe, sans DNS ni hairpin NAT. Le runner s'enregistre et clone par cette URL ; il dépend
  désormais de Traefik pour joindre GitLab.
  - **Exception `*.localhost`** : libcurl, donc git, résout tout `*.localhost` vers `127.0.0.1` sans
    consulter DNS ni `/etc/hosts`. Le clone des jobs passe alors par `http://gitlab` (nom de service).
    Dans un job, `CI_SERVER_URL` et `CI_API_V4_URL` (`http://gitlab.localhost`) restent injoignables
    par curl : utiliser un hostname hors `*.localhost` pour tester des appels API depuis la CI.
  - **`TLS_MODE=custom` avec une CA privée** : le runner, les jobs et le bootstrap ne font pas encore
    confiance à cette CA (#79).

### Surface d'exposition

Sur l'hôte, seuls sont publiés **80** (Traefik), **443** (Traefik, avec le TLS : US 3-2 à 3-4) et le
**SSH de GitLab** (`GITLAB_SSH_PORT`, défaut 2222). `make verify` contrôle, pour chaque
`envs/*.env`, chaque couple port publié → port du conteneur contre cette liste blanche, et refuse tout
`network_mode` `host`, `service:…` ou `container:…` (qui la contournerait).

- **Bases de données et services internes.** `sonarqube-db` (PostgreSQL) et Loki ne publient aucun
  port : ils ne sont joignables que depuis le réseau Docker de la plateforme. Le PostgreSQL et le Redis
  embarqués de GitLab écoutent sur des sockets Unix internes au conteneur. Limite connue : le réseau
  de la plateforme est partagé avec les jobs CI, qui peuvent donc les atteindre (#71).
- **Portainer.** Le compte `admin` est créé dès le premier démarrage avec `PORTAINER_ADMIN_PASSWORD`
  (secret Compose, absent de `docker compose config` et de `docker inspect`) : aucun visiteur ne peut
  s'approprier l'instance avant l'opérateur. Ce mot de passe n'est appliqué qu'au premier démarrage
  (le changer ensuite dans l'interface) ; `make check-env` exige 12 caractères au moins. Le tunnel des
  agents Edge (port 8000) n'est pas proposé. ⚠️ Portainer monte le socket Docker : un administrateur
  Portainer est de fait `root` sur l'hôte.
- **Grafana.** Authentification obligatoire : accès anonyme, inscription et création d'organisation
  désactivés, ainsi que les dashboards partagés publiquement et les snapshots (consultables sans compte).

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

- **Mots de passe** (root GitLab, base et admin SonarQube, admin Grafana, admin Portainer) : 24 caractères aléatoires
  avec majuscule, minuscule, chiffre et caractère spécial (règles SonarQube), sans caractère
  problématique pour Compose ou le shell. Ils ne sont jamais affichés : les lire dans le fichier.
- **Fichier** en permissions `600`, écrit de façon atomique.
- **URLs publiques** : `GITLAB_EXTERNAL_URL` n'est pas écrite (dérivée par GitLab du hostname et
  du `TLS_MODE`, voir « GitLab derrière le proxy ») ; `SONARQUBE_EXTERNAL_URL` et
  `GRAFANA_EXTERNAL_URL` valent `http://<hostname>`, servies par Traefik sur le port 80. Avec `TLS_MODE=none` et un hostname non local, `make init` affiche le même
  avertissement que `make deploy` ; `letsencrypt` et `custom` n'ont pas encore d'effet (US 3-2 et 3-3).
- **Sans terminal** (`make init ENV=<env> < /dev/null`, ou réponses passées sur l'entrée standard),
  une réponse vide prend la valeur par défaut et une réponse invalide arrête la commande.

**Fichier existant.** `make init` refuse de l'écraser. `FORCE=1` le régénère : l'ancien fichier est
sauvegardé dans `envs/<env>.env.bak.<date>` (600, non versionné, jamais écrasé), ses réponses sont
proposées par défaut et **ses secrets sont repris**. Les autres réglages (ports SSH, versions, réseau…)
repartent du modèle : les reprendre depuis la sauvegarde si besoin.
`FORCE=1 NOUVEAUX_MDP=1` régénère aussi les secrets : à réserver à une instance jamais déployée ou à
réinstaller, car le mot de passe PostgreSQL de SonarQube est inscrit dans son volume et les mots de
passe root GitLab et admin Portainer ne sont appliqués qu'au premier démarrage. Un secret absent de
l'ancien fichier (variable ajoutée depuis) est généré et signalé. `FORCE` et `NOUVEAUX_MDP` ne sont acceptés
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

## Garde-fou contre les lancements en double

Les volumes de l'instance portent des noms fixes (`devops-platform_*`) et les conteneurs sont nommés
par Compose. Lancer un module seul (`docker compose -f compose/<module>.yml up`) ou la plateforme sous
un autre nom de projet (`docker compose -p <autre> up`) créerait donc des conteneurs **en double sur
les mêmes volumes et le même réseau** : deux `sonarqube-db` sur les mêmes données (corruption), deux
`gitlab-runner` (jobs exécutés deux fois). Compose se contente d'un avertissement ; la plateforme les
refuse.

**Commande correcte :** `make deploy ENV=<env>`, ou `docker compose --env-file envs/<env>.env …`
depuis la racine du repo, **sans `-p` ni `-f`**. Pour valider un seul module :
`docker compose --env-file envs/<env>.env config <service>`.

| Lancement | Refusé par | Message |
|---|---|---|
| Module seul : `-f compose/<module>.yml` (ou en surcharge, `-f compose.yml -f compose/<module>.yml`) | Compose, au chargement | `required variable PLATFORM_GARDE_FOU is missing a value: compose/<module>.yml est un module de compose.yml et ne se lance pas seul … : make deploy ENV=<env> …` |
| Autre nom de projet : `-p <autre>`, ou `COMPOSE_PROJECT_NAME=<autre>` exporté (y compris pour `make`) | Compose, au chargement | `stat …/compose/projet-autorise/<autre>.env: no such file or directory` |
| Doublon déjà présent (créé en contournant le garde-fou, ou avant sa mise en place) | `make deploy`, avant `up` | Liste des conteneurs fautifs et commande de nettoyage |

**Mécanisme.**
- Chaque module exige la variable `PLATFORM_GARDE_FOU` (extension `x-garde-fou-<module>`, sans effet
  sur les services). Elle n'est définie que par l'`env_file` des `include` de `compose.yml` : un module
  chargé sans passer par `compose.yml` échoue avec un message qui donne la commande correcte.
- Cet `env_file` est `compose/projet-autorise/${COMPOSE_PROJECT_NAME}.env`. Seul
  `compose/projet-autorise/devops-platform.env` existe : sous tout autre nom de projet, Compose s'arrête
  faute de fichier. Ce message est celui de Compose et ne peut pas être personnalisé
  ([#65](https://github.com/Maskime/devops-platform/issues/65)).
- Les deux refus interviennent au chargement du modèle : **aucun conteneur n'est créé** par `up`,
  `create` ou `run`. Les commandes qui agissent sur des conteneurs existants d'un projet (`ps`, `stop`,
  `down`…) peuvent se passer du modèle et restent possibles : elles servent au nettoyage.
- `make deploy` lance en plus `scripts/check-doublons.sh` : refus si un volume de l'instance est monté
  par un conteneur d'un autre projet Compose (ou hors Compose), ou si le réseau de l'instance porte un
  conteneur d'un autre projet Compose. Les conteneurs sans label Compose sur le réseau (jobs CI du
  runner, `docker run --network`) sont légitimes et ignorés. Contrôle en lecture seule.
- `make verify` vérifie que le garde-fou refuse bien chaque module seul et un autre nom de projet.

**Limites** : ce qui reste possible en contournant les cibles `make`, délibérément.
- Exporter `PLATFORM_GARDE_FOU=1` avant de lancer un module seul, ou créer un fichier
  `compose/projet-autorise/<autre>.env` : le garde-fou de Compose est alors neutralisé (le contrôle de
  `make deploy` détectera les doublons ainsi créés au prochain déploiement).
- `docker run` avec un volume `devops-platform_*` : Compose n'intervient pas (détecté par
  `make deploy` seulement).
- Le garde-fou ne protège que contre les doublons **sur un même hôte Docker** : deux serveurs ont
  chacun leurs volumes.
- Renommer le projet (`name:` de `compose.yml`) impose de renommer
  `compose/projet-autorise/<projet>.env`, comme les préfixes des volumes.

**Nettoyer un doublon.** Supprimer les conteneurs signalés par leur identifiant (les volumes sont
conservés), puis relancer `make deploy ENV=<env>` :

```bash
docker rm -f <id> …                  # identifiants affichés par make deploy
docker compose -p <autre> down       # tout un projet doublon (module seul : projet « compose »)
```

**Ne jamais** utiliser `down -v` ni `docker volume rm` : si le doublon a créé un volume
`devops-platform_*` avant l'instance, ce volume porte son label de projet et serait supprimé avec les
données de l'instance.

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
