# Bootstrap SonarQube (`make bootstrap-sonarqube`)

`make bootstrap-sonarqube ENV=<env>` configure le SonarQube d'une instance déployée (`make deploy`),
locale ou distante (`DEPLOY_SSH`). Il ne crée aucune donnée (ni projet, ni analyse) et peut être
relancé à volonté : chaque étape ne modifie que ce qui n'est pas déjà en place.

| Étape | Contrôle ou action | Relance |
|---|---|---|
| `vm.max_map_count` | Valeur du noyau de l'hôte cible ≥ 524288, sinon arrêt | — |
| Attente | `api/system/status` à `UP`, 10 minutes au plus | — |
| Compte admin | Mot de passe par défaut `admin` remplacé par `SONARQUBE_ADMIN_PASSWORD` | rien à faire si déjà positionné |
| Plugin | `communityBranchPlugin` installé, sinon arrêt | — |
| Token d'analyse | Token `devops-platform-analyse` écrit dans `outputs/<env>.sonarqube-token` | conservé tant qu'il reste valide |

## Fonctionnement

- **Cible.** Les commandes passent par `scripts/instance.sh compose` : même hôte, même contexte
  Docker et mêmes garde-fous que `make deploy` (voir [Déploiement](deploiement.md)). L'API est
  appelée depuis le conteneur `sonarqube` (`http://localhost:9000`) : ni DNS ni certificat public
  requis sur le poste, ni `python3`.
- **Secrets.** `SONARQUBE_ADMIN_PASSWORD` est lu dans `envs/<env>.env` uniquement : une variable du
  même nom exportée dans le shell est ignorée. Identifiants et paramètres sont transmis à `curl` sur
  son entrée standard, jamais en argument de commande. Le token n'est jamais affiché.
- **`vm.max_map_count`.** Lu dans le conteneur `sonarqube-db` (réglage du noyau, commun à tous les
  conteneurs de l'hôte), qui tourne même quand SonarQube échoue faute de ce réglage. Correctif :
  `scripts/host-prereqs.sh` sur l'hôte (voir [Préparation d'un serveur](serveur.md)).
- **Mot de passe.** Contrôle par `api/authentication/validate` avec la valeur du fichier, puis avec
  `admin` ; changement par `api/users/change_password`. SonarQube impose 12 caractères avec majuscule,
  minuscule, chiffre et caractère spécial, ce que respectent les mots de passe générés par `make init`
  (voir [Initialisation](initialisation.md)).
- **Statut `DB_MIGRATION_NEEDED`.** Après une montée de version, SonarQube attend la migration de sa
  base : le bootstrap s'arrête et renvoie à la [Montée de version](montee-de-version.md).

## Token d'analyse

Token de type `GLOBAL_ANALYSIS_TOKEN` du compte `admin` : il permet d'analyser n'importe quel projet,
sans aucun droit d'administration. Sans date d'expiration.

- **Fichier.** `outputs/<env>.sonarqube-token` (une ligne), permissions `600` dans `outputs/` en
  `700`, non versionné. SonarQube ne restitue jamais un token : ce fichier est la seule copie.
- **Relance.** Le token du fichier est conservé s'il est encore valide et toujours présent dans
  SonarQube. Sinon (fichier absent ou invalide, instance réinstallée), le token du même nom est
  révoqué et remplacé.
- **Rotation.** Supprimer le fichier puis relancer `make bootstrap-sonarqube` : l'ancien token est
  révoqué. Tout ce qui l'utilise (variables CI, projets consommateurs) est à mettre à jour.
- **Plusieurs postes.** Le fichier n'existe que sur le poste qui a lancé le bootstrap. Lancé depuis un
  autre poste, le bootstrap révoque et remplace le token, avec un avertissement.

## Mot de passe admin inconnu

Le bootstrap s'arrête si le compte `admin` refuse à la fois `SONARQUBE_ADMIN_PASSWORD` et `admin` :
un autre mot de passe a été positionné, par exemple par `make init FORCE=1 NOUVEAUX_MDP=1` sur une
instance déjà bootstrappée, ou à la main dans l'interface.

1. Si l'ancienne valeur est connue (sauvegarde `envs/<env>.env.bak.<date>`), la remettre dans
   `envs/<env>.env`.
2. Sinon, remettre le mot de passe par défaut `admin` en base, puis relancer le bootstrap, qui le
   remplace aussitôt par `SONARQUBE_ADMIN_PASSWORD` :

   ```bash
   scripts/instance.sh compose <env> exec -T sonarqube-db psql -U sonar -d sonar -c \
     "update users set crypted_password='100000\$t2h8AtNs1AlCHuLobDjHQTn9XppwTIx88UjqUm4s8RsfTuXQHSd/fpFexAnewwPsO6jGFQUv/24DnO55hY6Xew==', salt='k9x9eN127/3e/hf38iNiKwVfaVk=', hash_method='PBKDF2', reset_password=true, user_local=true where login='admin';"
   make bootstrap-sonarqube ENV=<env>
   ```

   Entre ces deux commandes, le compte `admin` accepte le mot de passe `admin` : les enchaîner sans
   attendre.
