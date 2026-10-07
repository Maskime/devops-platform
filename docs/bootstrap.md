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

Pour valider l'instance de bout en bout (pipeline et analyse SonarQube), lancer ensuite le
[smoke test](smoke-test.md) : `make smoke ENV=<env>`.

Après chaque étape réussie, le [fichier de sortie](sortie-instance.md) `outputs/<env>.env` (URLs
publiques, API GitLab, token d'analyse) est régénéré pour les projets consommateurs.

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
   URL, runner `factory-runner` de l'ancien bootstrap…) et les runners d'instance portant la note de maintenance
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

Des verrous garantissent qu'une seule opération modifie une instance à la fois. Sans eux, deux
exécutions concurrentes (deux opérateurs, une relance pendant une exécution, un smoke test pendant un
bootstrap) révoqueraient le jeton ou le token d'analyse l'une de l'autre, supprimeraient le runner
l'une de l'autre, ou en laisseraient deux enregistrés.

| Verrou | Fichier | Pris par |
|---|---|---|
| Instance | `/etc/gitlab-runner/.bootstrap.lock` du conteneur `gitlab-runner` (volume du runner) | `make bootstrap` (toutes les étapes), `make bootstrap-sonarqube`, `make bootstrap-gitlab`, `make smoke` |
| Étape SonarQube | `/opt/sonarqube/data/devops-platform/.bootstrap.lock` du conteneur `sonarqube` (volume `sonarqube_data`) | étape SonarQube, de la fin de l'attente de SonarQube jusqu'à la fin (mot de passe admin, token d'analyse) |

| Propriété | Valeur |
|---|---|
| Mécanisme | `flock`, tenu par un `docker compose exec` qui dure toute l'opération (`scripts/lib/verrou.sh`) |
| Seconde opération | attend 5 s au plus, puis s'arrête sans rien modifier, avec le dernier détenteur connu (commande, utilisateur@poste, pid, date) |
| Battement | une ligne vide envoyée au détenteur toutes les 30 s : la connexion qui tient le verrou n'est jamais inactive |

Le verrou d'instance est pris par `make bootstrap` avant la première étape et tenu jusqu'à la fin : un
smoke test ne peut s'intercaler ni pendant une rotation du token d'analyse, ni entre cette rotation et
la mise à jour de `SONAR_TOKEN` par l'étape GitLab. Si `gitlab-runner` est arrêté, il n'est pas pris
(l'étape GitLab s'arrête alors d'elle-même) ; le verrou de l'étape SonarQube protège toujours le token.
Le nom `.bootstrap.lock` est conservé pour rester compatible avec un bootstrap d'une version antérieure.

Les fichiers vivent sur l'hôte de l'instance : les verrous valent pour tous les postes, que l'instance
soit locale ou distante (`DEPLOY_SSH`). Ils sont libérés dès que l'opération se termine, y compris en
échec, sur Ctrl-C ou si le poste est tué : la commande qui tient le verrou perd son entrée standard et
s'arrête, le noyau libère le verrou (au plus 5 s après un `kill -9`, le temps que le battement
s'arrête). Il n'y a jamais de déverrouillage manuel à faire ; les fichiers, qui restent dans les
volumes, sont sans effet hors d'une opération.

En distant, le battement fait passer du trafic sur la connexion SSH du contexte Docker pendant les
longues attentes (GitLab, pipeline du smoke test) : un pare-feu, un NAT ou le `ClientAliveInterval` de
sshd ne la coupent pas pour inactivité. `ServerAliveInterval` dans `~/.ssh/config` (lu par la
connexion du contexte) détecte en plus une connexion morte côté poste.

Un redémarrage du conteneur qui tient le verrou (`make deploy` concurrent) ou une coupure de la
connexion SSH pendant l'opération fait perdre le verrou : l'opération le détecte avant ses
modifications et en fin d'exécution, et s'arrête. La relancer.

## Limites

- **Réseau des jobs** : les jobs clonent par Traefik (ou par le service `gitlab` en `*.localhost`) et
  joignent SonarQube par `SONAR_HOST_URL`, joignables seulement sur le réseau de la plateforme. Un `GITLAB_RUNNER_NETWORK` différent doit le
  permettre ; le bootstrap avertit mais ne le vérifie pas.
- **`--docker-extra-hosts host.docker.internal:host-gateway`** de l'ancien bootstrap n'est plus posé :
  les jobs n'ont pas d'accès dédié à l'hôte.
- **Verrou contourné** : un `gitlab-runner register` lancé à la main ne prend pas le verrou (#107) ;
  lancé pendant un bootstrap, son runner peut être supprimé.
- **Ancienne version** : un `make bootstrap` d'une version antérieure, refusé parce qu'un smoke test
  tient le verrou, annonce à tort « un autre make bootstrap » ; le détenteur affiché est exact.
- **Image auxiliaire** : le dépôt doit être lisible anonymement, le runner n'a pas d'identifiants de
  registre. Le pré-téléchargement du bootstrap utilise ceux du poste (contexte Docker) : il peut réussir
  là où le runner échouera. Le runner tire le helper à chaque job (`pull_policy` `always`) : avec Docker
  Hub, chaque job consomme le quota de téléchargements anonymes de l'adresse IP du serveur ; un miroir
  (ou cache de proxy) l'évite.
- **Plusieurs postes** : le token d'analyse SonarQube est stocké sur l'instance et récupéré depuis tout
  poste ; le fichier de sortie `outputs/<env>.env` n'existe que sur le poste qui l'a généré
  ([token d'analyse](bootstrap-sonarqube.md#token-danalyse)).
