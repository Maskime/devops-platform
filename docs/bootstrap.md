# Bootstrap d'une instance (`make bootstrap`)

`make bootstrap ENV=<env>` configure une instance déjà démarrée (`make deploy`) pour la rendre prête à
l'emploi. Il vise la même cible que `make deploy` : moteur Docker local, ou serveur distant si
`DEPLOY_SSH` est défini ([déploiement](deploiement.md)). Il ne crée **aucune donnée de test** (ni
projet, ni utilisateur, ni pipeline) et peut être relancé à volonté : une relance sur une instance à
jour ne change que le jeton d'administration GitLab. Une seule étape GitLab à la fois par instance
([exécutions simultanées](#exécutions-simultanées)).

Rien n'est installé sur le poste : les appels aux API partent des conteneurs `sonarqube` et `gitlab`,
indépendamment du DNS et du TLS du poste.

## Enchaînement

| Ordre | Étape | Script | Lancée seule par |
|---|---|---|---|
| 1 | SonarQube : `vm.max_map_count`, compte admin, plugin, token d'analyse ([détails](bootstrap-sonarqube.md)) | `scripts/bootstrap/sonarqube.sh` | `make bootstrap-sonarqube` |
| 2 | GitLab : jeton d'administration, variables CI SonarQube, runner d'instance (ci-dessous) | `scripts/bootstrap/gitlab.sh` | `make bootstrap-gitlab` |

SonarQube passe en premier : son token d'analyse est posé en variable CI d'instance par l'étape
GitLab. Une
étape en échec arrête le bootstrap ; après correction, relancer `make bootstrap`, ou l'étape restante
seule. Une étape dont le service est absent de l'instance (brique retirée de `compose.yml`) est
ignorée, avec un message.

La cible est préparée **une seule fois** par `scripts/instance.sh bootstrap` : contexte Docker SSH et
pré-test de connexion, garde-fou d'instance (en lecture seule : le bootstrap n'écrit rien dans
`DEPLOY_DIR`). Les scripts d'étape appellent ensuite `docker compose` directement. Aucune copie de la
configuration n'est faite : le bootstrap ne recrée aucun service, il n'utilise que `exec` et `ps`.
Lancé directement, un script d'étape refuse une instance distante.

## Étape GitLab

1. **Attente de GitLab** : services `gitlab` et `gitlab-runner` démarrés, verrou de l'instance pris,
   puis GitLab prêt
   (`/-/readiness`, 15 minutes au plus), puis URL publique joignable depuis le runner, par Traefik
   (5 minutes au plus ; un certificat refusé ou un routage absent s'y signale). En `TLS_MODE=custom`,
   le certificat y est vérifié avec la CA privée si elle est fournie
   ([CA privée](certificats.md#ca-privée)).
2. **Jeton d'accès personnel d'administration** : voir ci-dessous.
3. **Variables CI d'instance** `SONAR_HOST_URL` et `SONAR_TOKEN` (masquée), créées ou mises à jour,
   token validé auprès de SonarQube avant écriture : voir [Analyse SonarQube depuis la
   CI](analyse-sonarqube.md). Ignorée si le service `sonarqube` est absent de l'instance.
4. **Runner d'instance** : voir ci-dessous. Le bootstrap attend enfin que le runner soit en ligne.

Le récapitulatif final affiche l'id du runner, son réseau, l'URL, l'expiration du jeton et l'état des
variables CI.

## Jeton d'administration

| Propriété | Valeur |
|---|---|
| Compte | `root` |
| Nom | `devops-platform-bootstrap` |
| Scopes | `api`, `admin_mode` (requis si le mode admin de GitLab est activé) |
| Expiration | lendemain de la création |

À chaque passage, tous les jetons actifs de ce nom sont révoqués, puis un nouveau est créé
(`gitlab-rails runner`). Sa valeur n'est jamais affichée, écrite sur disque ni passée en argument de
processus : elle ne sert qu'à la durée du bootstrap.

## Runner d'instance

| Variable (`envs/<env>.env`) | Rôle | Défaut |
|---|---|---|
| `GITLAB_RUNNER_DESCRIPTION` | Description du runner (nom dans `config.toml`) | `devops-platform-runner` |
| `GITLAB_RUNNER_NETWORK` | Réseau Docker des conteneurs de jobs | `PLATFORM_NETWORK` |
| `GITLAB_RUNNER_HELPER_IMAGE` | Dépôt de l'image auxiliaire (helper) des jobs, sans tag | vide : image standard de GitLab |

Le runner est enregistré avec l'exécuteur `docker`, l'image par défaut `alpine` (version épinglée
dans `scripts/bootstrap/gitlab.sh`), l'URL publique de GitLab et l'URL de clone décrite dans
[GitLab derrière le proxy](gitlab-proxy.md#runner-et-jobs-ci). En `TLS_MODE=custom` avec une CA privée,
il est enregistré avec `--tls-ca-file` ([CA privée](certificats.md#ca-privée)). Il porte la note de maintenance
« Géré par devops-platform (make bootstrap) » : c'est elle, et non la description, qui identifie les
runners du bootstrap.

La plateforme considère `config.toml` du conteneur `gitlab-runner` comme le sien. À chaque passage :

1. Le runner courant est celui de `config.toml` dont la configuration (description, URL, URL de clone,
   exécuteur, image, réseau, CA, image auxiliaire) est celle attendue et qui existe dans GitLab.
2. Sont supprimés de GitLab : les autres runners de `config.toml` (ancienne description, ancienne
   URL, runner de `make bootstrap-legacy`…) et les runners d'instance portant la note de maintenance
   (orphelins, par exemple après perte du volume du runner).
3. `gitlab-runner verify --delete` retire de `config.toml` les runners supprimés ; un bloc que
   `verify` ne peut pas vérifier (URL qui ne résout plus) est retiré directement.
4. Sans runner courant, un runner d'instance est créé (`POST /user/runners`) puis enregistré
   (`gitlab-runner register`).

Changer la description, le réseau, l'image auxiliaire, le hostname, le `TLS_MODE`, ou ajouter ou
retirer la CA privée, conduit donc à un ré-enregistrement, sans runner orphelin. Les runners enregistrés
à la main (hors `config.toml` de la plateforme, sans la note de maintenance) ne sont pas touchés.

## Image auxiliaire des jobs

Chaque job démarre aussi un conteneur auxiliaire (helper : clone, cache, artefacts). Par défaut, le
runner le tire de `registry.gitlab.com`, dont l'authentification passe par `gitlab.com` : sur un serveur
qui ne joint pas gitlab.com, tous les jobs échouent (`runner_external_dependency_failure`).

`GITLAB_RUNNER_HELPER_IMAGE` désigne un autre **dépôt**, sans tag ni digest (refusés) :
`gitlab/gitlab-runner-helper` (Docker Hub), ou un miroir (`registre.example.com:5000/gitlab-runner-helper`).
Le runner est enregistré avec `--docker-helper-image <dépôt>:v${CI_RUNNER_VERSION}` : le runner remplace
la variable à chaque job par sa propre version, donc le helper suit `GITLAB_RUNNER_VERSION` après une
montée de version, sans relancer le bootstrap. Le tag `v<version>` est un index multi-architecture :
aucune architecture n'est figée. Un miroir doit donc publier ce tag (et pas seulement
`x86_64-v<version>`).

Avant tout ré-enregistrement, le bootstrap tire `<dépôt>:v<version du runner déployé>` sur la cible :
erreur si l'image est introuvable, simple avertissement si le runner est déjà conforme.

## Exécutions simultanées

Un verrou garantit qu'une seule étape GitLab de `make bootstrap` modifie une instance à la fois : sans
lui, deux exécutions concurrentes (deux opérateurs, ou une relance pendant une exécution) révoqueraient le jeton
l'une de l'autre et supprimeraient le runner l'une de l'autre, ou en laisseraient deux enregistrés.

| Propriété | Valeur |
|---|---|
| Fichier | `/etc/gitlab-runner/.bootstrap.lock` du conteneur `gitlab-runner` (volume du runner) |
| Mécanisme | `flock`, tenu par un `docker compose exec` qui dure toute l'étape GitLab |
| Portée | étape GitLab, de la vérification des services jusqu'à la fin : jeton d'administration, variables CI et runner (l'étape SonarQube, lancée avant, n'est pas couverte) |
| Second bootstrap | attend 5 s au plus, puis s'arrête sans modifier GitLab, avec le dernier détenteur connu (utilisateur@poste, pid, date) |

Le fichier vit sur l'hôte de l'instance : le verrou vaut pour tous les postes, que l'instance soit
locale ou distante (`DEPLOY_SSH`). Il est libéré dès que le bootstrap se termine, y compris en échec,
sur Ctrl-C ou si le poste est tué : la commande qui le tient perd son entrée standard et s'arrête, le
noyau libère le verrou. Il n'y a jamais de déverrouillage manuel à faire ; le fichier, qui reste dans
le volume, est sans effet hors d'un bootstrap.

Un redémarrage du conteneur `gitlab-runner` (`make deploy` concurrent) ou une coupure de la connexion
SSH pendant le bootstrap fait perdre le verrou : le bootstrap le détecte avant de modifier les runners
et en fin d'exécution, et s'arrête. Relancer `make bootstrap`.

## Limites

- **Réseau des jobs** : les jobs clonent par Traefik (ou par le service `gitlab` en `*.localhost`) et
  joignent SonarQube par `SONAR_HOST_URL`, joignables seulement sur le réseau de la plateforme. Un `GITLAB_RUNNER_NETWORK` différent doit le
  permettre ; le bootstrap avertit mais ne le vérifie pas.
- **`--docker-extra-hosts host.docker.internal:host-gateway`** de l'ancien bootstrap n'est plus posé :
  les jobs n'ont pas d'accès dédié à l'hôte.
- **Verrou contourné** : `make bootstrap-legacy` et un `gitlab-runner register` lancé à la main ne
  prennent pas le verrou (#107) ; lancés pendant un bootstrap, leur runner peut être supprimé.
- **Connexion SSH inactive** : en distant, la connexion qui tient le verrou reste sans trafic pendant
  l'attente de GitLab ; un pare-feu ou un NAT qui la coupe fait échouer le bootstrap, à relancer (#108).
- **Image auxiliaire** : le dépôt doit être lisible anonymement, le runner n'a pas d'identifiants de
  registre. Le pré-téléchargement du bootstrap utilise ceux du poste (contexte Docker) : il peut réussir
  là où le runner échouera. Le runner tire le helper à chaque job (`pull_policy` `always`) : avec Docker
  Hub, chaque job consomme le quota de téléchargements anonymes de l'adresse IP du serveur ; un miroir
  (ou cache de proxy) l'évite.
- **Étape SonarQube non verrouillée** : deux `make bootstrap` en parallèle sur la même instance
  peuvent régénérer deux fois le token d'analyse SonarQube, le verrou ne couvrant que l'étape
  GitLab. Relancer `make bootstrap` seul remet l'instance en ordre.
- **Plusieurs postes** : le token d'analyse SonarQube n'existe que sur le poste qui l'a généré ;
  depuis un autre poste, `make bootstrap` le révoque et le remplace
  ([token d'analyse](bootstrap-sonarqube.md#token-danalyse)).
