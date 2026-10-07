# Fichier de sortie d'une instance

`make bootstrap ENV=<env>` écrit `outputs/<env>.env` : ce qu'il faut pour brancher un projet sur
l'instance (URLs publiques, API GitLab, token d'analyse SonarQube), sans relire `envs/<env>.env`.
Le fichier est produit par `scripts/bootstrap/outputs.sh`.

## Contenu

| Variable | Valeur |
|---|---|
| `DEVOPS_PLATFORM_ENV` | Nom de l'instance |
| `GITLAB_URL` | URL publique de GitLab |
| `GITLAB_API_URL` | `${GITLAB_URL}/api/v4` |
| `GITLAB_SSH_URL` | `ssh://git@<GITLAB_HOSTNAME>:<GITLAB_SSH_PORT>` (base des URLs de clone SSH) |
| `SONAR_HOST_URL` | URL publique de SonarQube |
| `SONAR_TOKEN` | Token d'analyse SonarQube ([token d'analyse](bootstrap-sonarqube.md#token-danalyse)) |
| `GRAFANA_URL` | URL publique de Grafana |

`SONAR_HOST_URL` et `SONAR_TOKEN` portent les noms attendus par les scanners SonarQube.

Les URLs suivent les règles de l'instance : `*_EXTERNAL_URL` si elle est renseignée, sinon l'URL
dérivée du hostname et du `TLS_MODE` ([exposition](exposition.md)). Le fichier est régénéré à chaque
passage : il suit un changement de hostname, de `TLS_MODE` ou de token.

Des commentaires signalent les cas particuliers :

- **Service absent** de l'instance (brique retirée de `compose.yml`) : ses variables sont omises.
- **Token absent** du poste (copie locale `outputs/<env>.sonarqube-token`, voir [plusieurs postes](#limites)) :
  la ligne `SONAR_TOKEN` est **omise**, plutôt que laissée vide, pour ne pas écraser la variable d'un
  consommateur. Un avertissement s'affiche.
- **Token non revérifié** : `make bootstrap-gitlab` seul ne contrôle pas le token ; il est recopié tel
  quel. `make bootstrap-sonarqube` le contrôle.
- **CA privée** (`TLS_MODE=custom` avec `config/certs/ca/ca.pem`) : les clients du projet (git, curl,
  scanners) doivent la recevoir pour vérifier les certificats ([CA privée](certificats.md#ca-privée)).

Le jeton d'administration GitLab du bootstrap n'y figure **pas** : il est éphémère et porte les droits
`root` ([jeton d'administration](bootstrap.md#jeton-dadministration)). Un jeton GitLab dédié aux projets
consommateurs reste à fournir
([#115](https://github.com/Maskime/devops-platform/issues/115)).

## Régénération

Le fichier est réécrit **après chaque étape réussie** de `make bootstrap`, `make bootstrap-sonarqube`
et `make bootstrap-gitlab`. Il reflète l'état du poste après la dernière étape terminée : si l'étape
GitLab échoue après une rotation du token SonarQube, le fichier contient déjà le nouveau token.

Lancement manuel, sans toucher à l'instance (lecture de fichiers locaux seulement) :

```bash
scripts/bootstrap/outputs.sh envs/<env>.env
```

Il suppose alors tous les services présents. Une URL ou un token contenant un caractère inattendu
(espace, `$`, guillemet…) arrête la génération avec une erreur : les valeurs sont écrites sans
guillemets.

## Sécurité

- `outputs/` est ignoré par git et refusé par la [recherche de secrets](garde-fous.md).
- Fichier en `600`, répertoire `outputs/` en `700`, écriture atomique.
- Le fichier contient `SONAR_TOKEN` : ne le transmettre que par un canal sûr (variables CI masquées,
  gestionnaire de secrets).

## Utilisation

Le format (une affectation `VAR=valeur` par ligne, valeurs sans guillemets) se lit à l'identique par :

```bash
set -a; source outputs/<env>.env; set +a             # shell
docker compose --env-file outputs/<env>.env config   # interpolation Compose
docker run --env-file outputs/<env>.env …            # variables d'un conteneur
```

Un projet hébergé sur l'instance n'a rien à déclarer : `make bootstrap` pose `SONAR_HOST_URL` et
`SONAR_TOKEN` en variables CI d'instance ([Analyse SonarQube depuis la CI](analyse-sonarqube.md)). Pour
un projet hébergé sur un autre GitLab, les déclarer comme variables CI de ce projet (`SONAR_TOKEN`
masquée).

## Limites

- **Plusieurs postes** : le fichier n'existe que sur le poste qui a lancé le bootstrap. Depuis un autre
  poste, `make bootstrap` récupère le même token d'analyse ([token
  d'analyse](bootstrap-sonarqube.md#token-danalyse)) : les fichiers des deux postes restent valides.
  Après une rotation (`ROTATION=1`), celui des autres postes reste faux jusqu'à leur prochain bootstrap.
- **Instance distante** : le fichier est écrit sur le poste, pas sur le serveur.
