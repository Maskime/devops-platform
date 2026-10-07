# Analyse SonarQube depuis la CI

`make bootstrap` pose deux **variables CI d'instance** GitLab, disponibles dans les pipelines de tous
les projets : un projet hébergé lance `sonar-scanner` sans aucune configuration SonarQube.

| Variable | Valeur | Masquée | Protégée |
|---|---|---|---|
| `SONAR_HOST_URL` | URL de SonarQube joignable depuis les jobs (ci-dessous) | non | non |
| `SONAR_TOKEN` | Token d'analyse de l'instance ([token d'analyse](bootstrap-sonarqube.md#token-danalyse)) | oui | non |

Les deux variables sont de type « variable », non développées (`raw`) et décrites « Géré par
devops-platform (make bootstrap) ». Non protégées, elles sont aussi disponibles dans les pipelines des
branches non protégées et des merge requests. Visibles dans **Admin > Paramètres > CI/CD > Variables**.

## Valeur de `SONAR_HOST_URL`

| Cas | `SONAR_HOST_URL` | Raison |
|---|---|---|
| Cas général | URL publique : `SONARQUBE_EXTERNAL_URL`, sinon `http://<SONARQUBE_HOSTNAME>` | servie par Traefik, joint par son alias réseau ([GitLab derrière le proxy](gitlab-proxy.md#runner-et-jobs-ci)) |
| `SONARQUBE_HOSTNAME` en `*.localhost` | `http://sonarqube.devops-platform.internal:8000` | libcurl résout tout `*.localhost` vers `127.0.0.1` |
| `TLS_MODE=custom` avec [CA privée](certificats.md#ca-privée) | `http://sonarqube.devops-platform.internal:8000` | la JVM du scanner n'utilise pas la CA fournie aux jobs (`CI_SERVER_TLS_CA_FILE`, #144) |

`http://sonarqube.devops-platform.internal:8000` est un nom interne de Traefik, servi seulement sur le
réseau des jobs par un entrypoint HTTP non publié ([réseau des jobs](gitlab-proxy.md#réseau-des-jobs)) :
le trafic d'analyse passe alors par Traefik, mais sans TLS. Les liens affichés par SonarQube (décoration des merge requests,
notifications) restent sur `SONARQUBE_EXTERNAL_URL`.

## Mise à jour et rotation

L'étape GitLab de `make bootstrap` crée les variables absentes et met à jour celles qui diffèrent ; une
relance sur une instance à jour ne les modifie pas. Elle passe avant l'enregistrement du runner.

- **Token.** Lu dans la copie locale `outputs/<env>.sonarqube-token`, que l'étape SonarQube récupère
  du stockage de l'instance ; transmis à GitLab par l'entrée standard, jamais affiché. Avant écriture,
  il est validé auprès de SonarQube : un token absent, illisible ou refusé (copie périmée) laisse
  `SONAR_TOKEN` telle quelle, avec un avertissement, pour ne pas remplacer un token valide par un token
  révoqué.
- **Rotation.** `make bootstrap ENV=<env> ROTATION=1` : l'étape SonarQube révoque et remplace le token,
  l'étape GitLab met `SONAR_TOKEN` à jour. Avec
  `make bootstrap-sonarqube` seul, les pipelines utilisent l'ancien token, révoqué, jusqu'au prochain
  `make bootstrap-gitlab`.
- **Changement de hostname ou de `TLS_MODE`.** `make deploy` puis `make bootstrap` : `SONAR_HOST_URL`
  suit.
- **Brique SonarQube absente** (service `sonarqube` retiré de l'instance) : l'étape est ignorée, les
  variables existantes ne sont pas retirées (#117).

## Exemple de job

À placer dans le `.gitlab-ci.yml` d'un projet. Le premier passage crée le projet dans SonarQube.

```yaml
# Pipelines de merge request et de branche, sans doublon quand une merge request est ouverte
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH && $CI_OPEN_MERGE_REQUESTS
      when: never
    - if: $CI_COMMIT_BRANCH

sonarqube:
  stage: test
  image:
    name: sonarsource/sonar-scanner-cli:12.2.0.4256_8.1.0
    entrypoint: [""]
  variables:
    SONAR_USER_HOME: "${CI_PROJECT_DIR}/.sonar"
    GIT_DEPTH: "0" # historique complet : blame et détection du code nouveau
  cache:
    key: "${CI_JOB_NAME}"
    paths:
      - .sonar/cache
  script:
    - sonar-scanner -Dsonar.projectKey="${CI_PROJECT_PATH_SLUG}" -Dsonar.qualitygate.wait=true
```

- `sonar-scanner` lit `SONAR_HOST_URL` et `SONAR_TOKEN` dans l'environnement : rien d'autre à fournir.
- Le plugin community branch reconnaît les variables de GitLab CI : une analyse de branche ou de merge
  request est rattachée à sa branche, ou à sa merge request, sans paramètre `sonar.branch.*` ni
  `sonar.pullrequest.*`.
- `sonar.qualitygate.wait=true` fait échouer le job si la quality gate échoue ; le retirer pour une
  analyse informative.
- Les autres réglages (sources, exclusions, langages) vont dans un `sonar-project.properties` à la
  racine du projet.
- Image du scanner : dernière stable à la rédaction ; la version est épinglée par chaque projet.

## Limites

- **Token partagé.** `SONAR_TOKEN` est un token d'analyse globale du compte `admin`, disponible dans
  tous les projets de l'instance. Le masquage ne cache la valeur que des logs : tout projet peut la lire
  dans un job, puis analyser, donc créer ou écraser, n'importe quel projet SonarQube (#116).
- **Runners hors plateforme.** Un runner de projet ou de groupe installé ailleurs ne joint pas
  les noms internes ni les alias de Traefik : le projet ou le groupe y surcharge `SONAR_HOST_URL`
  (une variable de projet ou de groupe prime sur la variable d'instance).
- **Réseau des jobs.** `SONAR_HOST_URL` est joignable sur le réseau des jobs (`GITLAB_RUNNER_NETWORK`)
  et sur celui de la plateforme ; un conteneur lancé sur un autre réseau ne le joint pas.
- **Plusieurs postes.** Depuis un poste qui n'a jamais lancé l'étape SonarQube, `make bootstrap`
  récupère le token de l'instance et `SONAR_TOKEN` reste inchangée ; `make bootstrap-gitlab` seul,
  sans copie locale, laisse la variable telle quelle avec un avertissement
  ([token d'analyse](bootstrap-sonarqube.md#token-danalyse)).
