# Bootstrap d'une instance (`make bootstrap`)

`make bootstrap ENV=<env>` configure une instance déjà démarrée (`make deploy`) pour la rendre prête à
l'emploi. Il vise la même cible que `make deploy` : moteur Docker local, ou serveur distant si
`DEPLOY_SSH` est défini ([déploiement](deploiement.md)). Il ne crée **aucune donnée de test** (ni
projet, ni utilisateur, ni pipeline) et peut être relancé à volonté : une relance sur une instance à
jour ne change que le jeton d'administration.

Rien n'est installé sur le poste : les appels à l'API GitLab partent du conteneur `gitlab`
(`http://localhost`), indépendamment du DNS et du TLS du poste.

## Étapes

1. **Attente de GitLab** : services `gitlab` et `gitlab-runner` démarrés, puis GitLab prêt
   (`/-/readiness`, 15 minutes au plus), puis URL publique joignable depuis le runner, par Traefik
   (5 minutes au plus ; un certificat refusé ou un routage absent s'y signale).
2. **Jeton d'accès personnel d'administration** : voir ci-dessous.
3. **Runner d'instance** : voir ci-dessous. Le bootstrap attend enfin que le runner soit en ligne.

Le récapitulatif final affiche l'id du runner, son réseau, l'URL et l'expiration du jeton.

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

Le runner est enregistré avec l'exécuteur `docker`, l'image par défaut `alpine` (version épinglée
dans `scripts/bootstrap/gitlab.sh`), l'URL publique de GitLab et l'URL de clone décrite dans
[GitLab derrière le proxy](gitlab-proxy.md#runner-et-jobs-ci). Il porte la note de maintenance
« Géré par devops-platform (make bootstrap) » : c'est elle, et non la description, qui identifie les
runners du bootstrap.

La plateforme considère `config.toml` du conteneur `gitlab-runner` comme le sien. À chaque passage :

1. Le runner courant est celui de `config.toml` dont la configuration (description, URL, URL de clone,
   exécuteur, image, réseau) est celle attendue et qui existe dans GitLab.
2. Sont supprimés de GitLab : les autres runners de `config.toml` (ancienne description, ancienne
   URL, runner de `make bootstrap-legacy`…) et les runners d'instance portant la note de maintenance
   (orphelins, par exemple après perte du volume du runner).
3. `gitlab-runner verify --delete` retire de `config.toml` les runners supprimés ; un bloc que
   `verify` ne peut pas vérifier (URL qui ne résout plus) est retiré directement.
4. Sans runner courant, un runner d'instance est créé (`POST /user/runners`) puis enregistré
   (`gitlab-runner register`).

Changer la description, le réseau, le hostname ou le `TLS_MODE` conduit donc à un ré-enregistrement,
sans runner orphelin. Les runners enregistrés à la main (hors `config.toml` de la plateforme, sans la
note de maintenance) ne sont pas touchés.

## Limites

- **Réseau des jobs** : les jobs clonent par Traefik (ou par le service `gitlab` en `*.localhost`),
  joignables seulement sur le réseau de la plateforme. Un `GITLAB_RUNNER_NETWORK` différent doit le
  permettre ; le bootstrap avertit mais ne le vérifie pas.
- **`--docker-extra-hosts host.docker.internal:host-gateway`** de l'ancien bootstrap n'est plus posé :
  les jobs n'ont pas d'accès dédié à l'hôte.
- **Exécutions simultanées** : deux `make bootstrap` en parallèle sur la même instance peuvent
  enregistrer deux runners (aucun verrou, #101). Relancer `make bootstrap` seul remet l'instance en ordre.
- **`TLS_MODE=custom` avec une CA privée** : le runner ne fait pas confiance à cette CA (#79), l'attente
  de l'URL publique échoue.
