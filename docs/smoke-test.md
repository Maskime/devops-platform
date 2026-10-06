# Smoke test d'une instance (`make smoke`)

`make smoke ENV=<env>` vérifie de bout en bout une instance déployée et bootstrapée : forge, runner,
pipeline CI et analyse SonarQube. Il crée pour cela des **données de test**, que `NETTOYER=1` supprime
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
| 1 | Services `gitlab`, `gitlab-runner` et `sonarqube` présents et démarrés, GitLab prêt, SonarQube `UP`, mot de passe admin SonarQube accepté | instance non déployée ou non bootstrapée |
| 2 | Jeton d'accès personnel root éphémère créé | — |
| 3 | Variables CI d'instance `SONAR_HOST_URL` et `SONAR_TOKEN` présentes, au moins un runner d'instance en ligne | `make bootstrap` non lancé |
| 4 | Projet GitLab `root/devops-platform-smoke` et projet SonarQube `devops-platform-smoke` créés, ou réutilisés | — |
| 5 | Fichiers de `scripts/smoke/projet/` poussés sur `main` (un commit) | — |
| 6 | Pipeline du commit au vert | runner, clone, image du scanner, SonarQube injoignable depuis les jobs |
| 7 | Analyse SonarQube de la branche `main` portant la révision du commit | token refusé, intégration en échec |
| 8 | Avec `NETTOYER=1` : projets GitLab et SonarQube supprimés | — |

Le pipeline poussé (`scripts/smoke/projet/.gitlab-ci.yml`) compte deux jobs :

- **`simple`** : image par défaut du runner ; valide l'exécution d'un job et le clone du dépôt ;
- **`sonar-scanner`** : `sonarsource/sonar-scanner-cli` (version épinglée, celle de
  [l'exemple de job](analyse-sonarqube.md#exemple-de-job)), qui n'utilise que les variables CI
  d'instance : il valide `SONAR_HOST_URL` et `SONAR_TOKEN` tels que les reçoit tout projet hébergé.

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
affiche l'état de chaque job et la fin du journal des jobs en échec.

## Données de test

| Donnée | Nom | Visibilité |
|---|---|---|
| Projet GitLab | `root/devops-platform-smoke` | privé, Auto DevOps désactivé |
| Projet SonarQube | `devops-platform-smoke` | privé |

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

## Limites

- **Exécutions simultanées** : le smoke test ne prend pas le verrou du bootstrap
  ([#120](https://github.com/Maskime/devops-platform/issues/120)). Deux `make smoke` simultanés sur la
  même instance se révoquent leur jeton ; un `make bootstrap` concurrent peut ré-enregistrer le runner
  pendant le pipeline.
- **Token d'analyse** : `SONAR_TOKEN` est seulement vérifié présent ; un token révoqué se révèle dans
  le journal du job `sonar-scanner`
  ([#121](https://github.com/Maskime/devops-platform/issues/121)). Le corriger par `make bootstrap`.
- **Service SonarQube absent** de l'instance : le smoke test refuse de s'exécuter.
- **Réseau** : le pipeline télécharge l'image du scanner (Docker Hub) et, sauf
  `GITLAB_RUNNER_HELPER_IMAGE`, l'image auxiliaire du runner (`registry.gitlab.com`) : un serveur sans
  accès à ces registres échoue au job ([image auxiliaire](bootstrap.md#image-auxiliaire-des-jobs)).
