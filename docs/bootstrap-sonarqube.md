# Bootstrap SonarQube

Première étape de [`make bootstrap ENV=<env>`](bootstrap.md), avant GitLab ; `make bootstrap-sonarqube
ENV=<env>` la lance seule (rotation du token, relance rapide). Elle configure le SonarQube d'une
instance déployée (`make deploy`), locale ou distante (`DEPLOY_SSH`), ne crée aucune donnée (ni projet,
ni analyse) et peut être relancée à volonté : chaque contrôle ne modifie que ce qui n'est pas déjà en
place.

| Étape | Contrôle ou action | Relance |
|---|---|---|
| `vm.max_map_count` | Valeur du noyau de l'hôte cible ≥ 524288, sinon arrêt | — |
| Attente | `api/system/status` à `UP`, 10 minutes au plus | — |
| Compte admin | Mot de passe par défaut `admin` remplacé par `SONARQUBE_ADMIN_PASSWORD` | rien à faire si déjà positionné |
| Plugin | `communityBranchPlugin` installé, sinon arrêt | — |
| Token d'analyse | Token `devops-platform-analyse` stocké sur l'instance, copié dans `outputs/<env>.sonarqube-token` | conservé tant qu'il reste valide, depuis tout poste |

## Fonctionnement

- **Cible.** `scripts/bootstrap/sonarqube.sh` hérite de la cible préparée par `make bootstrap`
  (même hôte et même contexte Docker que `make deploy`, voir [Déploiement](deploiement.md)) et appelle
  `docker compose` directement ; lancé seul sur une instance distante, il refuse de s'exécuter. L'API est
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

SonarQube ne restitue jamais un token : le bootstrap le conserve à deux endroits.

| Emplacement | Rôle | Permissions |
|---|---|---|
| `/opt/sonarqube/data/devops-platform/analyse-token`, conteneur `sonarqube` (volume `sonarqube_data`, sur l'hôte de l'instance) | Référence, lisible depuis tout poste qui pilote l'instance | répertoire `700`, fichier `600` (utilisateur `sonarqube`) |
| `outputs/<env>.sonarqube-token` sur le poste | Copie locale, rafraîchie à chaque passage | `outputs/` en `700`, fichier `600`, non versionné |

- **Accès.** Lecture et écriture par `docker compose exec -T sonarqube`, avec la cible de `make
  bootstrap` : même mécanisme pour une instance locale et distante (`DEPLOY_SSH`). Le token passe par
  l'entrée standard, jamais en argument ni dans les journaux.
- **Relance.** Le token du stockage de l'instance est conservé s'il est encore valide et toujours
  présent dans SonarQube ; la copie locale est alors mise à jour si elle diffère. Depuis un autre poste,
  le bootstrap récupère donc le même token : variable CI et consommateurs restent valides.
- **Remplacement.** Token du stockage invalide (révoqué à la main, base restaurée) ou absent de
  SonarQube (instance réinstallée) : le token du même nom est révoqué et remplacé, écrit dans le
  stockage de l'instance puis dans la copie locale. Un échec d'écriture arrête l'étape ; la relance le
  répare.
- **Variable CI.** L'étape GitLab de `make bootstrap` pose ce token en variable CI d'instance
  `SONAR_TOKEN` ([Analyse SonarQube depuis la CI](analyse-sonarqube.md)). Le [fichier de
  sortie](sortie-instance.md) `outputs/<env>.env` en reprend une copie, régénérée à chaque passage.
- **Rotation.** `make bootstrap ENV=<env> ROTATION=1` révoque et remplace le token, met à jour la
  variable CI `SONAR_TOKEN` et régénère `outputs/<env>.env`. Avec `make bootstrap-sonarqube` seul, la
  variable CI garde l'ancien token jusqu'au prochain `make bootstrap-gitlab`. Tout autre utilisateur du
  token (projets consommateurs) est à mettre à jour ; les autres postes récupèrent le nouveau token à
  leur prochain bootstrap. Supprimer la copie locale ne provoque plus de rotation.
- **Garde-fou.** Token `devops-platform-analyse` présent dans SonarQube, mais ni dans le stockage de
  l'instance ni dans la copie locale : le bootstrap refuse de le révoquer (il a été généré depuis un
  autre poste, avant le stockage de l'instance). Voir la migration ci-dessous ; si la copie est
  perdue, `ROTATION=1`.

### Migration d'une instance existante

Une instance bootstrappée avant le stockage de l'instance n'a son token que dans
`outputs/<env>.sonarqube-token`, sur un seul poste. Lancer d'abord `make bootstrap-sonarqube ENV=<env>`
depuis ce poste : le token y est validé puis recopié dans le stockage de l'instance, sans rotation.
Depuis un autre poste, le garde-fou ci-dessus s'applique tant que cette migration n'est pas faite.

### Limites

- **Secret dans le volume.** `sonarqube_data` contient désormais le token : une sauvegarde de ce volume
  le contient aussi, et quiconque accède au moteur Docker de l'hôte peut le lire (accès équivalent à
  root, comme pour la base). Ne jamais supprimer ce volume pour reconstruire les index
  ([montée de version](montee-de-version.md)) : le token serait remplacé au bootstrap suivant.
- **Validation.** `api/authentication/validate` accepte tout token valide : un autre token déposé à la
  main dans le stockage serait conservé. Un token d'analyse globale ne permet pas de vérifier son nom.
- **Exécutions simultanées.** L'étape est verrouillée dans le conteneur `sonarqube`
  (`/opt/sonarqube/data/devops-platform/.bootstrap.lock`) une fois SonarQube prêt : une seconde
  exécution s'arrête sans rien modifier ([exécutions simultanées](bootstrap.md#exécutions-simultanées)).
- **Trace.** `bash -x scripts/bootstrap/sonarqube.sh` afficherait le token : ne pas tracer ce script.

## Mot de passe admin inconnu

Le bootstrap s'arrête si le compte `admin` refuse à la fois `SONARQUBE_ADMIN_PASSWORD` et `admin` :
un autre mot de passe a été positionné, par exemple par `make init FORCE=1 NOUVEAUX_MDP=1` sur une
instance déjà bootstrappée, ou à la main dans l'interface.

1. Si l'ancienne valeur est connue (sauvegarde `envs/<env>.env.bak.<date>`), la remettre dans
   `envs/<env>.env`.
2. Sinon, remettre le mot de passe par défaut `admin` en base (commande manuelle unique, par la
   passerelle `scripts/instance.sh compose`), puis relancer le bootstrap, qui le remplace aussitôt par
   `SONARQUBE_ADMIN_PASSWORD` :

   ```bash
   scripts/instance.sh compose <env> exec -T sonarqube-db psql -U sonar -d sonar -c \
     "update users set crypted_password='100000\$t2h8AtNs1AlCHuLobDjHQTn9XppwTIx88UjqUm4s8RsfTuXQHSd/fpFexAnewwPsO6jGFQUv/24DnO55hY6Xew==', salt='k9x9eN127/3e/hf38iNiKwVfaVk=', hash_method='PBKDF2', reset_password=true, user_local=true where login='admin';"
   make bootstrap-sonarqube ENV=<env>
   ```

   Entre ces deux commandes, le compte `admin` accepte le mot de passe `admin` : les enchaîner sans
   attendre.
