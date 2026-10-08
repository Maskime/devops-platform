# Garde-fous

Trois protections de la plateforme : contre le démarrage de conteneurs en double sur les volumes d'une
instance, contre la publication de secrets dans ce repo public et contre l'introduction d'une image
non épinglée.

## Lancements en double

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
  par un conteneur d'un autre projet Compose (ou hors Compose), ou si un réseau de l'instance porte un
  conteneur d'un autre projet Compose. Les conteneurs sans label Compose sur un réseau
  (`docker run --network`) sont légitimes et ignorés. Le réseau des jobs (`GITLAB_RUNNER_NETWORK`)
  n'est pas contrôlé : les [projets co-localisés](branchement-projet.md#projet-co-localisé) le
  rejoignent ; un doublon d'un service de la plateforme y est aussi sur un autre réseau de l'instance,
  ou monte ses volumes. Contrôle en lecture seule.
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

## Fuites de secrets

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

## Images épinglées

`scripts/check-images.sh` refuse toute image dont la version n'est pas figée : image compose non
paramétrée par `*_VERSION`, défaut sans version `majeure.mineure` ou différent de `envs/.env.example`,
variable `*_IMAGE` d'un script ou image d'un pipeline `*.gitlab-ci.yml` sans tag versionné ni digest,
tag `latest` explicite, version vide ou `latest` dans `envs/*.env`. Le script n'utilise que bash, git et
les outils POSIX (aucun Docker). Règles et procédure : [Montée de version](montee-de-version.md).

| Contexte | Commande |
|---|---|
| CI GitHub Actions (chaque push et PR) | `.github/workflows/check-images.yml`, automatique |
| Manuel | `make check-images` (inclus dans `make verify`) |

La CI ne voit que les fichiers versionnés : les fichiers d'instance `envs/<env>.env` restent contrôlés
par `make verify` et, avant tout démarrage, par `make check-env`.

Un job en échec ne bloque le merge d'une PR que si le check est déclaré obligatoire dans la protection
de la branche `main` (réglage GitHub du repo).
