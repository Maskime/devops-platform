# Branchement d'un projet

Comment un projet utilise GitLab, le runner et SonarQube d'une instance. Trois situations :

| Situation | Exemple | Ce qu'il faut |
|---|---|---|
| **Projet hébergé** sur le GitLab de l'instance | dépôt poussé dans GitLab, pipelines sur le runner d'instance | rien côté SonarQube : variables CI d'instance |
| **Projet co-localisé** : conteneurs sur le même hôte Docker que l'instance | application, outil ou runner de projet lancé par `docker compose` sur le serveur de l'instance | rejoindre le réseau des jobs, URLs de `outputs/<env>.env` |
| **Projet distant** : ailleurs (autre serveur, poste, autre GitLab ou autre CI) | pipeline d'un autre GitLab qui analyse dans SonarQube | URLs publiques et token de `outputs/<env>.env` |

Un projet peut cumuler : hébergé sur l'instance et déployé à côté d'elle, par exemple.

## Le fichier `outputs/<env>.env`

`make bootstrap ENV=<env>` écrit sur le poste qui le lance un fichier `outputs/<env>.env` : URLs
publiques, URL de l'API GitLab, base des URLs SSH, token d'analyse SonarQube et réseau des jobs
([contenu détaillé](sortie-instance.md)).

| Variable | Projet hébergé | Co-localisé | Distant |
|---|---|---|---|
| `GITLAB_URL`, `GITLAB_SSH_URL` | remote git | remote git (HTTPS) | remote git |
| `GITLAB_API_URL` | appels API (jeton personnel) | appels API | appels API |
| `SONAR_HOST_URL`, `SONAR_TOKEN` | déjà dans les pipelines | analyse ou appels SonarQube | variables CI du projet |
| `DEVOPS_PLATFORM_CI_NETWORK` | — | réseau Docker à rejoindre | — |

Le fichier contient `SONAR_TOKEN` :

- le transmettre par un canal sûr (gestionnaire de secrets, variables CI masquées), jamais par le dépôt
  du projet ;
- en co-localisé, le copier sur le serveur, hors de tout dépôt, en `600`
  (`scp outputs/<env>.env serveur:… && ssh serveur chmod 600 …`) ;
- le recopier après chaque `make bootstrap` qui change une URL ou le token (rotation `ROTATION=1`).

Aucun jeton GitLab n'y figure : un appel à l'API GitLab utilise un jeton personnel, de groupe ou de
projet créé dans GitLab ([#115](https://github.com/Maskime/devops-platform/issues/115)).

## Projet hébergé sur l'instance

1. Créer le projet dans GitLab (interface, ou `POST ${GITLAB_API_URL}/projects` avec un jeton).
2. Le pousser :

   ```bash
   set -a; source outputs/<env>.env; set +a
   git remote add origin "${GITLAB_URL}/<groupe>/<projet>.git"        # HTTPS
   git remote add origin "${GITLAB_SSH_URL}/<groupe>/<projet>.git"    # ou SSH (clé dans le profil)
   git push -u origin main
   ```

3. Ajouter un `.gitlab-ci.yml` (ci-dessous). Les jobs tournent sur le runner d'instance, qui accepte les
   jobs sans tag ; `SONAR_HOST_URL` et `SONAR_TOKEN` sont des variables CI d'instance posées par
   `make bootstrap` ([analyse SonarQube depuis la CI](analyse-sonarqube.md)) : le projet ne déclare
   rien.

### Exemple de `.gitlab-ci.yml`

```yaml
stages:
  - test

# Pipelines de merge request et de branche, sans doublon quand une merge request est ouverte
workflow:
  rules:
    - if: $CI_PIPELINE_SOURCE == "merge_request_event"
    - if: $CI_COMMIT_BRANCH && $CI_OPEN_MERGE_REQUESTS
      when: never
    - if: $CI_COMMIT_BRANCH

tests:
  stage: test
  image: alpine:3.24.2
  script:
    - echo "Remplacer par les tests du projet"

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
    - sonar-scanner -Dsonar.qualitygate.wait=true
```

Avec un `sonar-project.properties` à la racine du projet, seul endroit où figure la clé :

```properties
sonar.projectKey=<groupe>_<projet>
sonar.projectName=<projet>
sonar.sources=src
```

Le premier passage crée le projet dans SonarQube ; les branches et merge requests y sont rattachées
sans paramètre. Détail des options, de la quality gate et des limites (token partagé entre projets) :
[exemple de job](analyse-sonarqube.md#exemple-de-job). Les images sont épinglées par le projet, comme
celles de la plateforme.

## Projet co-localisé

Les conteneurs du projet rejoignent le **réseau des jobs** de l'instance (`DEVOPS_PLATFORM_CI_NETWORK`,
valeur de `GITLAB_RUNNER_NETWORK`, défaut `devops-platform_ci`), déclaré comme réseau Docker externe.
Traefik en est le seul membre côté plateforme et y porte les hostnames publics en alias : les URLs de
`outputs/<env>.env` mènent à Traefik, avec le même certificat que pour un client externe, sans DNS ni
hairpin NAT ([réseau des jobs](gitlab-proxy.md#réseau-des-jobs)).

Ne **pas** rejoindre le réseau de la plateforme (`PLATFORM_NETWORK`, défaut `devops-platform`) : il
relie `sonarqube-db`, Loki et le nginx de GitLab sans passer par Traefik, et `make deploy` le refuse à
un autre projet Compose ([garde-fous](garde-fous.md)).

```yaml
# compose.yml du projet
services:
  app:
    image: <image du projet>:<version>
    environment:
      # Seulement les variables utiles, seulement dans le conteneur qui en a besoin
      SONAR_HOST_URL: ${SONAR_HOST_URL:?}
      SONAR_TOKEN: ${SONAR_TOKEN:?}
    networks:
      - default      # réseau propre au projet (base, services internes)
      - plateforme   # accès à GitLab et SonarQube par Traefik

  db:
    image: postgres:<version>
    networks:
      - default      # jamais sur le réseau des jobs

networks:
  plateforme:
    external: true
    name: ${DEVOPS_PLATFORM_CI_NETWORK:?outputs/<env>.env non chargé}
```

```bash
docker compose --env-file .env --env-file /chemin/sûr/outputs/<env>.env up -d
```

- `--env-file` sert à l'interpolation ; le répéter garde le `.env` du projet, qu'il remplace sinon. Le
  dernier fichier l'emporte.
- Éviter `env_file: outputs/<env>.env` : il injecterait `SONAR_TOKEN` dans chaque conteneur, lisible
  par `docker inspect` et Portainer.
- La plateforme doit tourner avant le projet : le réseau des jobs est créé par `make deploy`.

### URL à utiliser depuis un conteneur

| Cas | GitLab | SonarQube |
|---|---|---|
| Cas général | `GITLAB_URL` | `SONAR_HOST_URL` |
| Hostname `*.localhost` | `http://gitlab.devops-platform.internal:8000` | `http://sonarqube.devops-platform.internal:8000` |
| `TLS_MODE=custom` avec CA privée | `GITLAB_URL`, CA montée dans le conteneur | `http://sonarqube.devops-platform.internal:8000` pour un scanner (JVM) ; sinon `SONAR_HOST_URL`, CA montée |

Les noms `*.devops-platform.internal` (HTTP, port 8000, non publiés) n'existent que sur ce réseau :
libcurl, donc git et curl, résout tout `*.localhost` vers `127.0.0.1`, et la JVM du scanner ignore la
CA fournie au système. Les poser dans `environment:` en lieu et place de la valeur de
`outputs/<env>.env`. La CA privée est `config/certs/ca/ca.pem` ([CA privée](certificats.md#ca-privée)).

### Runner de projet sur le même hôte

Un runner de projet ou de groupe installé sur le serveur de l'instance (exécuteur Docker) rejoint le même
réseau : `network_mode = "<DEVOPS_PLATFORM_CI_NETWORK>"` dans `[runners.docker]` de son `config.toml`,
URL de GitLab selon le tableau ci-dessus. Il surcharge `SONAR_HOST_URL` en variable de projet ou de
groupe si l'URL de la variable d'instance ne lui convient pas.

### Limites

- **Exposition aux jobs CI** : le réseau des jobs est partagé par tous les jobs de tous les projets de
  l'instance. Un conteneur qui le rejoint est joignable par tout utilisateur qui peut lancer un pipeline,
  et joint les conteneurs des jobs en cours. N'y attacher que le conteneur client, garder la base et les
  services internes sur le réseau propre au projet
  ([#156](https://github.com/Maskime/devops-platform/issues/156)).
- **SSH GitLab** : le hostname de GitLab désigne Traefik, qui ne route pas SSH. Cloner en HTTPS, ou
  joindre le port SSH publié sur l'hôte (`extra_hosts: ["host.docker.internal:host-gateway"]`, puis
  `ssh://git@host.docker.internal:<GITLAB_SSH_PORT>/…`).
- **Exposition du projet** : le Traefik de la plateforme ignore les conteneurs hors de son projet
  Compose ; des labels `traefik.*` sur les conteneurs du projet sont sans effet, et les ports 80 et
  443 de l'hôte sont pris.
- **`make down` de la plateforme** : il laisse le réseau des jobs en place tant qu'un conteneur du
  projet y est attaché (« Resource is still in use », sans erreur) ; `make deploy` le réutilise.
- **Changement de `GITLAB_RUNNER_NETWORK`** : après `make deploy` et `make bootstrap`, recopier
  `outputs/<env>.env` et relancer le projet (`up -d`) pour qu'il rejoigne le nouveau réseau.

## Projet distant

Le projet joint la plateforme par ses **URLs publiques** (`GITLAB_URL`, `GITLAB_SSH_URL`,
`SONAR_HOST_URL` de `outputs/<env>.env`), servies par Traefik sur les ports 80 et 443 de l'hôte
([exposition](exposition.md)).

- **DNS** : les hostnames doivent être résolus par le poste ou le runner distant (DNS public ou
  interne). Une instance en `*.localhost` n'est pas joignable à distance.
- **TLS** : en `letsencrypt`, rien à fournir. En `custom` avec une CA privée, distribuer
  `config/certs/ca/ca.pem` aux clients (git : `http.sslCAInfo`, scanner : magasin de confiance de la
  JVM) ([CA privée](certificats.md#ca-privée)). En `none`, le trafic, token compris, circule en clair :
  à réserver à un réseau de confiance.
- **SSH** : le port `GITLAB_SSH_PORT` de l'hôte doit être ouvert au pare-feu
  ([préparation d'un serveur](serveur.md)).
- **Autre GitLab** : déclarer `SONAR_HOST_URL` et `SONAR_TOKEN` (masquée) en variables CI du projet ou
  du groupe, puis reprendre l'[exemple de `.gitlab-ci.yml`](#exemple-de-gitlab-ciyml). Une autre CI
  (GitHub Actions, Jenkins…) passe les deux mêmes variables au scanner.
- **Runner distant d'un projet hébergé** : un runner de projet ou de groupe installé ailleurs, mais
  enregistré sur l'instance, ne joint pas les noms internes : le projet ou le groupe surcharge
  `SONAR_HOST_URL` par l'URL publique (une variable de projet prime sur la variable d'instance).
