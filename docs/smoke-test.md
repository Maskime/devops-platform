# Smoke test d'une instance (`make smoke`)

`make smoke ENV=<env>` vérifie de bout en bout une instance déployée et bootstrapée : forge, runner,
isolation réseau, pipeline CI, analyse SonarQube et serveurs MCP. Il crée pour cela des **données de test**, que `NETTOYER=1` supprime
à la fin ; `make bootstrap`, lui, n'en crée jamais.

```bash
make deploy ENV=<env>
make bootstrap ENV=<env>
make smoke ENV=<env>                # projets de test conservés, URLs affichées
make smoke ENV=<env> NETTOYER=1     # projets de test supprimés après un succès
```

Comme `make bootstrap`, il vise le moteur Docker local ou le serveur de `DEPLOY_SSH`
([déploiement](deploiement.md)) et n'installe rien sur le poste : les appels aux API partent des
conteneurs `gitlab` et `sonarqube`. Il échoue (code de sortie non nul) à la première vérification
non satisfaite, avec la cause et la commande à lancer.

Une instance en `EXPOSITION=frontal` exige un frontal en service : le smoke test joint alors les
services par le frontal ([instance derrière un frontal](#instance-derrière-un-frontal)).

## Déroulement

| Ordre | Vérification | Échec typique |
|---|---|---|
| 1 | Services `gitlab`, `gitlab-runner` et `sonarqube` présents et démarrés, verrou de l'instance pris, GitLab prêt, SonarQube `UP`, mot de passe admin SonarQube accepté | instance non déployée ou non bootstrapée |
| 1 bis | En `EXPOSITION=frontal` seulement : exposition derrière le frontal ([détails](#instance-derrière-un-frontal)) | frontal arrêté ou mal configuré, port web publié |
| 2 | Jeton d'accès personnel root éphémère créé | — |
| 3 | Variables CI d'instance `SONAR_HOST_URL` et `SONAR_TOKEN` présentes, `SONAR_TOKEN` accepté par SonarQube, au moins un runner d'instance en ligne | `make bootstrap` non lancé, token révoqué |
| 4 | Projet GitLab `root/devops-platform-smoke` et projet SonarQube `devops-platform-smoke` créés, ou réutilisés | — |
| 5 | Isolation des projets co-localisés : Traefik seul membre de la plateforme sur le réseau des consommateurs ; deux [sentinelles](#sentinelles), l'une sur ce réseau, l'autre sur le réseau des jobs, joignent Traefik mais pas l'autre ; la première ne joint aucun service interne | instance déployée avant ce réseau (`make deploy`), service rattaché par erreur |
| 6 | Fichiers de `scripts/smoke/projet/` et liste des cibles d'isolation poussés sur `main` (un commit) | — |
| 7 | Pipeline du commit au vert | runner, clone, image du scanner, SonarQube injoignable depuis les jobs, service de la plateforme ou sentinelle joignable depuis un job |
| 7 bis | Logs hors plateforme (si Promtail, Loki et Grafana tournent) : une [sentinelle](#sentinelles) portant `devops-platform.logs=true` est retrouvée dans Loki sous `job="host-containers"`, `project="hors-compose"`, `service="smoke-logs"`, sans label `container` ; une sentinelle sans ce label n'y est pas | job `host-containers` absent de la configuration de Promtail (`make deploy`), Promtail ne joignant pas son proxy de socket |
| 8 | Analyse SonarQube de la branche `main` portant la révision du commit | token refusé, intégration en échec |
| 9 | Serveurs MCP : SonarQube (s'il est actif) liste le projet de test (`search_my_sonarqube_projects`), aussi par son URL publique en frontal, GitLab le lit (`get_project`) ; jetons éphémères ([serveurs MCP](mcp.md#vérification)) | `sonarqube-mcp` arrêté, accès au MCP GitLab non autorisé (`make bootstrap`) |
| 10 | Passerelle d'authentification ([détails](sso.md)), par le frontal en `EXPOSITION=frontal` : passerelle active ; chaque service protégé, appelé sans session avec des en-têtes d'identité forgés, redirige vers l'autorisation GitLab avec une URI de retour sur son hostname ; session de root ouverte sur la page d'accueil (code d'autorisation créé par `gitlab-rails`, callback, cookie `Secure` en HTTPS seulement), accès authentifié et identité transmise ; session de root sur Grafana : connexion sans formulaire, compte `root` et rôle attendu (`Admin` si root est membre de `SSO_GROUPE_ADMIN`, `Viewer` sinon) malgré des en-têtes forgés (`X-Auth-Request-Role: Admin` compris) ; service `grafana-role` (groupes sur plusieurs en-têtes, groupe voisin, homonyme du compte admin local refusé) ; Grafana joint hors Traefik avec des en-têtes d'identité refusé ; session de root sur SonarQube ([connexion automatique](sso.md#sonarqube)) : `api/users/current` connecté sous `root` (compte non local, e-mail GitLab, `sonar-users`, `sonar-administrators` si et seulement si root est membre de `SSO_GROUPE_ADMIN`) malgré des en-têtes forgés (`admin`, `sonar-administrators`) ; en-têtes forgés sans effet sur l'API GitLab, sur l'API SonarQube exemptée (jeton invalide refusé) et sur le routeur interne de SonarQube (non connecté) ; compte `admin` local de SonarQube accepté par l'API publique | passerelle en mode refus (`make bootstrap`), routeur sans middleware, en-têtes d'identité acceptés, Grafana affichant son formulaire ou rôle inattendu, adresse source non restreinte, relais `sonarqube-sso` absent ou non *healthy*, groupes SonarQube non réécrits |
| 11 | Portainer ([détails](sso.md#portainer)) : connexion du compte `admin` local, réglages OAuth conformes (application, URIs, création automatique de compte désactivée), comptes limités aux membres de `SSO_GROUPE_ADMIN` ; utilisateur GitLab de test hors du groupe : Portainer échange son code d'autorisation (créé par `gitlab-rails`), lit son identité et refuse la connexion (403) ; si `SSO_GROUPE_ADMIN` est renseigné et `SSO_GITLAB_GROUPE` vide, sa session de passerelle est refusée sur le hostname de Portainer (403) | `make bootstrap` non lancé, groupe modifié depuis le dernier bootstrap, mot de passe admin Portainer différent |
| 12 | Avec `NETTOYER=1` : projets GitLab et SonarQube et utilisateur de test supprimés | — |

Le pipeline poussé (`scripts/smoke/projet/.gitlab-ci.yml`) compte trois jobs :

- **`simple`** : image par défaut du runner ; valide l'exécution d'un job et le clone du dépôt ;
- **`isolation-reseau`** : image par défaut ; vérifie d'abord qu'il joint Traefik par l'hôte de
  `CI_REPOSITORY_URL` (contrôle positif de l'outil, `nc -z`), puis que `gitlab:80`, `sonarqube-db:5432` et `loki:3100` sont
  **injoignables**, par nom et par leurs IP sur les réseaux de la plateforme
  ([réseau des jobs](gitlab-proxy.md#réseau-des-jobs)), de même que la sentinelle du réseau des
  consommateurs (`smoke-consommateur:8080`). Les IP sont relevées par `make smoke` et
  poussées dans le fichier `isolation-cibles.txt` du projet de test ; Loki, facultatif, n'est testé
  que par son nom s'il ne tourne pas ;
- **`sonar-scanner`** : `sonarsource/sonar-scanner-cli` (version épinglée, celle de
  [l'exemple de job](analyse-sonarqube.md#exemple-de-job)), qui n'utilise que les variables CI
  d'instance : il valide `SONAR_HOST_URL` et `SONAR_TOKEN` tels que les reçoit tout projet hébergé.

## Instance derrière un frontal

En `EXPOSITION=frontal` ([frontal d'hôte](frontal.md)), le smoke test l'annonce dès le départ : il
dépend d'un frontal en service. L'étape 1 bis s'exécute avant toute donnée de test. Ses messages
d'erreur indiquent qui doit corriger :

- **« Plateforme »** : la correction se fait sur l'instance, en général avec `make deploy` ;
- **« Frontal absent »** : aucun conteneur n'occupe `FRONTAL_IP`, il faut démarrer le frontal ;
- **« Frontal »** : le frontal tourne mais ne respecte pas son
  [contrat](frontal.md#contrat-attendu-du-frontal).

Une plateforme en panne n'est jamais imputée au frontal : elle est testée sans lui avant toute sonde
par le frontal.

| Vérification | Échec signalé |
|---|---|
| Traefik démarré, rattaché à `devops-platform_frontal` à `FRONTAL_IP_TRAEFIK` | Plateforme |
| Aucun port publié sur l'hôte par l'instance, hormis le SSH de GitLab (`GITLAB_SSH_PORT`) | Plateforme |
| Un conteneur à `FRONTAL_IP` sur `devops-platform_frontal` | Frontal absent |
| GitLab répond par l'alias de Traefik (sans frontal) | Plateforme en panne |
| Par le frontal : `/users/sign_in` de GitLab (200), `/api/v4/mcp` sans jeton (401), API de SonarQube avec le compte admin (`UP`), accueil, Grafana, Portainer et PlantUML redirigés vers l'autorisation GitLab (302), serveur MCP SonarQube sans jeton (401) | Frontal : rien n'écoute sur le 443, hostname non routé (SNI), certificat inattendu (TLS terminé par le frontal) |
| Chaque requête faite par le frontal figure dans les logs d'accès de Traefik, avec une autre adresse client que `FRONTAL_IP` | Frontal : requête non transmise, ou envoyée sans PROXY protocol |
| Une [sentinelle](#sentinelles) sur `devops-platform_frontal` : port 80 de Traefik fermé ; connexion directe sans PROXY protocol, et avec un en-tête PROXY forgé (`203.0.113.7`), journalisées à l'adresse de la sentinelle | Plateforme (en-tête PROXY honoré hors de `FRONTAL_IP`) |

Les requêtes par le frontal partent du conteneur `gitlab-runner`. Elles visent le port 443 de la
passerelle IPv4 du réseau de la plateforme (`PLATFORM_NETWORK`), c'est-à-dire de l'hôte. Le hostname
est imposé et le certificat validé (CA privée en `custom`), comme pour un navigateur. Chaque requête
porte un marqueur unique (`?devops-platform-smoke-frontal=…`) qui permet de la retrouver dans les logs
d'accès de Traefik.

Les appels MCP SonarQube de l'étape 9 et toute l'étape 10 (passerelle d'authentification) passent
aussi par le frontal. Les autres étapes ne changent pas : le runner, les jobs et les projets
co-localisés joignent Traefik par les alias réseau, sans frontal.

**PROXY protocol.** Traefik honore l'en-tête PROXY de la seule `FRONTAL_IP`, mais ne refuse aucune
connexion ([limites du frontal](frontal.md#limites)). Le smoke test vérifie donc deux choses :

- une connexion directe à Traefik sur le réseau du frontal est admise, mais journalisée à l'adresse
  réelle de l'appelant ;
- un en-tête forgé est ignoré : l'adresse d'un client n'est pas usurpable.

### Sentinelles

L'étape 5 lance deux conteneurs `busybox` (image épinglée de `scripts/lib/images.sh`), hors Compose
comme un job ou un conteneur d'un autre projet, à l'écoute sur le port 8080 :

| Sentinelle | Réseau | Alias |
|---|---|---|
| consommateur | `CONSUMER_NETWORK` ([réseau des projets co-localisés](gitlab-proxy.md#réseau-des-projets-co-localisés)) | `smoke-consommateur` |
| job | `GITLAB_RUNNER_NETWORK` ([réseau des jobs](gitlab-proxy.md#réseau-des-jobs)) | `smoke-job` |

Contrôles positifs (outil et rattachement valides) : chacune se joint par son alias ; le consommateur
joint Traefik par les hostnames de GitLab et de SonarQube (port 80) et par les noms
`*.devops-platform.internal` (port 8000) ; le job joint Traefik par le hostname de GitLab. Contrôles
négatifs : aucune ne joint l'autre, par alias ni par IP ; le consommateur ne joint ni `gitlab:80`, ni
`sonarqube-db:5432`, ni `loki:3100`. Les sentinelles portent le label `devops-platform.smoke=<env>` ;
elles sont supprimées après le pipeline, en échec comme en succès, et une exécution interrompue laisse
les siennes au smoke test suivant, qui les supprime.

L'étape 7 bis lance deux autres sentinelles `busybox` (même label `devops-platform.smoke=<env>`), sans
réseau, qui écrivent chacune un jeton unique chaque seconde ; l'une porte `devops-platform.logs=true`
et `devops-platform.logs.service=smoke-logs` ([logs hors plateforme](logs.md#conteneurs-hors-plateforme)).
Le smoke test interroge Loki depuis le conteneur `grafana` : le jeton de la première doit apparaître
dans les 90 s avec les labels attendus, puis, 15 s plus tard, celui de la seconde doit être absent de
tous les flux. Elles sont supprimées à la fin de l'étape. Leurs lignes restent dans Loki jusqu'à la
purge par la rétention.

En `EXPOSITION=frontal`, l'étape 1 bis lance une sentinelle sur `devops-platform_frontal` (même
label). Elle utilise l'image du conteneur `gitlab-runner` (curl, en-tête PROXY forgé par
`--haproxy-clientip`). Elle reçoit une adresse fixe libre du sous-réseau, jamais `FRONTAL_IP` : le
frontal peut redémarrer pendant le test. Elle est supprimée à la fin de l'étape et s'arrête d'elle-même
après 2 min.

Le job ne demande pas la quality gate (`sonar.qualitygate.wait`) : le résultat de l'analyse d'un code
d'exemple ne dit rien de l'instance. Seule compte la présence de l'analyse.

## Délais

| Attente | Délai maximal |
|---|---|
| GitLab prêt | 15 min |
| SonarQube `UP` | 10 min |
| Pipeline terminé | 15 min (le premier passage télécharge l'image du scanner) |
| Analyse intégrée par SonarQube | 5 min |
| Suppression du projet GitLab (`NETTOYER=1`) | 5 min |

Un pipeline en attente d'un runner depuis plus de 3 minutes le signale. En échec, le smoke test
affiche l'état de chaque job et la fin du journal des jobs en échec. Un job en échec
`runner_external_dependency_failure` (image non téléchargeable, typiquement l'image auxiliaire depuis un
hôte sans accès à `registry.gitlab.com`) renvoie à `GITLAB_RUNNER_HELPER_IMAGE`.

## Données de test

| Donnée | Nom | Visibilité |
|---|---|---|
| Projet GitLab | `root/devops-platform-smoke` | privé, Auto DevOps désactivé |
| Projet SonarQube | `devops-platform-smoke` | privé |
| Jeton utilisateur SonarQube (compte admin), application OAuth GitLab (scope `mcp`) | `devops-platform-smoke-mcp` | supprimés en fin d'étape 9, succès ou échec |
| Conteneurs [sentinelles](#sentinelles) | label `devops-platform.smoke=<env>` | supprimés après le pipeline (celle du réseau du frontal, en fin d'étape 1 bis), succès ou échec |
| Utilisateur GitLab hors de `SSO_GROUPE_ADMIN` (étape 11) | `devops-platform-smoke-portainer` | bloqué en fin d'étape, succès ou échec ; débloqué et réutilisé au smoke test suivant |
| Compte Grafana de root (rôle synchronisé, voir [Grafana](sso.md#grafana)) | `root` | conservé : le même compte que lors d'une visite de root |

- **Relance** : les projets sont réutilisés. Seuls les fichiers absents ou modifiés sont poussés ; s'ils
  sont tous à jour, un nouveau pipeline est lancé sur `main`. Un projet GitLab en attente de suppression
  est restauré.
- **Nettoyage** : `NETTOYER=1` supprime les deux projets et l'utilisateur de test **après un succès**. En échec, ils sont
  conservés pour le diagnostic et leurs URLs sont affichées : corriger, puis relancer avec
  `NETTOYER=1`. GitLab peut différer la suppression d'un projet (projet seulement marqué) : le smoke
  test demande alors la suppression définitive et attend qu'elle soit faite.
- `NETTOYER` n'est accepté que sur la ligne de commande : une variable exportée par le shell est
  refusée.

## Jeton d'administration

Le smoke test crée un jeton d'accès personnel `root` nommé `devops-platform-smoke` (scopes `api` et
`admin_mode`, expiration le lendemain), après révocation des jetons actifs du même nom. Il le révoque en
fin d'exécution, succès ou échec ; s'il n'y parvient pas, il l'indique (le jeton expire le lendemain).
Comme celui du bootstrap ([jeton d'administration](bootstrap.md#jeton-dadministration)), sa valeur
n'est jamais affichée, écrite sur disque ni passée en argument de processus. Son nom diffère : un smoke
test ne révoque pas le jeton d'un bootstrap en cours.

## Exécutions simultanées

Le smoke test prend le verrou d'instance de `make bootstrap`
([exécutions simultanées](bootstrap.md#exécutions-simultanées)) et le tient jusqu'à la fin, révocation
de son jeton comprise. Un second `make smoke`, ou un `make bootstrap`, lancé pendant ce temps sur la
même instance s'arrête après 5 s sans rien modifier, en affichant le détenteur ; un smoke test lancé
pendant un bootstrap fait de même.

`SONAR_TOKEN` est validé auprès de SonarQube (`api/authentication/validate`) avant le pipeline : un
token révoqué, par exemple par une rotation depuis un autre poste, est signalé tout de suite au lieu de
faire échouer le job `sonar-scanner`. La valeur est lue par l'API GitLab dans une variable, jamais
affichée ni passée en argument de processus. Une variable « masquée et cachée » (valeur illisible par
l'API) n'est pas validée : le smoke test l'indique et continue.

## Limites

- **Service SonarQube absent** de l'instance : le smoke test refuse de s'exécuter.
- **Frontal joint par la passerelle du réseau de la plateforme** : il doit publier son port 443 sur
  toutes les adresses de l'hôte. Le chemin repose sur la redirection de port de Docker entre réseaux.
  Une publication sur une seule adresse, ou un pare-feu d'hôte qui filtre ce trafic, donne « rien
  n'écoute sur le port 443 de l'hôte » alors que le frontal fonctionne.
- **Sentinelle sur le réseau du frontal** : le contrat réserve ce réseau au frontal. La sentinelle est
  une exception temporaire, propre au test.
- **Logs d'accès de Traefik** au format par défaut (adresse du client en premier champ), lus dans les
  5 000 dernières lignes.
- **Réseau** : le pipeline télécharge l'image du scanner (Docker Hub) et, sauf
  `GITLAB_RUNNER_HELPER_IMAGE`, l'image auxiliaire du runner (`registry.gitlab.com`) : un serveur sans
  accès à ces registres échoue au job ([image auxiliaire](bootstrap.md#image-auxiliaire-des-jobs)).
