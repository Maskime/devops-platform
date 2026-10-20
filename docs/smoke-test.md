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

## Déroulement

| Ordre | Vérification | Échec typique |
|---|---|---|
| 1 | Services `gitlab`, `gitlab-runner` et `sonarqube` présents et démarrés, verrou de l'instance pris, GitLab prêt, SonarQube `UP`, mot de passe admin SonarQube accepté | instance non déployée ou non bootstrapée |
| 2 | Jeton d'accès personnel root éphémère créé | — |
| 3 | Variables CI d'instance `SONAR_HOST_URL` et `SONAR_TOKEN` présentes, `SONAR_TOKEN` accepté par SonarQube, au moins un runner d'instance en ligne | `make bootstrap` non lancé, token révoqué |
| 4 | Projet GitLab `root/devops-platform-smoke` et projet SonarQube `devops-platform-smoke` créés, ou réutilisés | — |
| 5 | Isolation des projets co-localisés : Traefik seul membre de la plateforme sur le réseau des consommateurs ; deux [sentinelles](#sentinelles), l'une sur ce réseau, l'autre sur le réseau des jobs, joignent Traefik mais pas l'autre ; la première ne joint aucun service interne | instance déployée avant ce réseau (`make deploy`), service rattaché par erreur |
| 6 | Fichiers de `scripts/smoke/projet/` et liste des cibles d'isolation poussés sur `main` (un commit) | — |
| 7 | Pipeline du commit au vert | runner, clone, image du scanner, SonarQube injoignable depuis les jobs, service de la plateforme ou sentinelle joignable depuis un job |
| 8 | Analyse SonarQube de la branche `main` portant la révision du commit | token refusé, intégration en échec |
| 9 | Serveurs MCP : SonarQube (s'il est actif) liste le projet de test (`search_my_sonarqube_projects`), GitLab le lit (`get_project`) ; jetons éphémères ([serveurs MCP](mcp.md#vérification)) | `sonarqube-mcp` arrêté, accès au MCP GitLab non autorisé (`make bootstrap`) |
| 10 | Avec `NETTOYER=1` : projets GitLab et SonarQube supprimés | — |

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
| Conteneurs [sentinelles](#sentinelles) | label `devops-platform.smoke=<env>` | supprimés après le pipeline, succès ou échec |

- **Relance** : les projets sont réutilisés. Seuls les fichiers absents ou modifiés sont poussés ; s'ils
  sont tous à jour, un nouveau pipeline est lancé sur `main`. Un projet GitLab en attente de suppression
  est restauré.
- **Nettoyage** : `NETTOYER=1` supprime les deux projets **après un succès**. En échec, ils sont
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
- **Réseau** : le pipeline télécharge l'image du scanner (Docker Hub) et, sauf
  `GITLAB_RUNNER_HELPER_IMAGE`, l'image auxiliaire du runner (`registry.gitlab.com`) : un serveur sans
  accès à ces registres échoue au job ([image auxiliaire](bootstrap.md#image-auxiliaire-des-jobs)).
