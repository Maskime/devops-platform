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
| Compte d'analyse | Compte technique `devops-platform-analyse`, permissions globales *Execute Analysis* et *Create Projects* seulement | rien à faire si déjà en place |
| Token d'analyse | Token `devops-platform-analyse` du compte d'analyse, stocké sur l'instance, copié dans `outputs/<env>.sonarqube-token` | conservé tant qu'il reste valide, depuis tout poste |

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

## Compte d'analyse

Le token exposé aux jobs CI appartient à un compte technique dédié, `devops-platform-analyse`, et non
au compte `admin`.

- **Création.** Compte local créé par `api/users/create` s'il n'existe pas (un compte désactivé du même
  login est réactivé). Son mot de passe est aléatoire et n'est conservé nulle part : personne ne s'y
  connecte.
- **Permissions.** Permissions globales directes ramenées à *Execute Analysis* (`scan`) et *Create
  Projects* (`provisioning`) : celles qui manquent sont ajoutées, toute autre est retirée. Les
  permissions globales des groupes `sonar-users` (dont le compte est membre, comme tout compte) et
  `Anyone` sont contrôlées : une permission autre que ces deux-là est signalée, pas modifiée.
- **Génération du token.** SonarQube refuse de générer un token d'analyse globale pour un autre compte :
  le bootstrap pose un mot de passe aléatoire sur le compte, fait générer le token par le compte
  lui-même, puis remplace aussitôt ce mot de passe par un autre aléa. Mots de passe et token ne passent
  que par l'entrée standard de `curl`.

## Token d'analyse

Token de type `GLOBAL_ANALYSIS_TOKEN` du compte d'analyse : il permet d'analyser n'importe quel projet,
et rien d'autre (ni administration, ni lecture par l'API). Sans date d'expiration.

SonarQube ne restitue jamais un token : le bootstrap le conserve à deux endroits.

| Emplacement | Rôle | Permissions |
|---|---|---|
| `/opt/sonarqube/data/devops-platform/analyse-token`, conteneur `sonarqube` (volume `sonarqube_data`, sur l'hôte de l'instance) | Référence, lisible depuis tout poste qui pilote l'instance ; `analyse-token.compte` à côté enregistre le compte propriétaire | répertoire `700`, fichiers `600` (utilisateur `sonarqube`) |
| `outputs/<env>.sonarqube-token` sur le poste | Copie locale, rafraîchie à chaque passage | `outputs/` en `700`, fichier `600`, non versionné |

- **Accès.** Lecture et écriture par `docker compose exec -T sonarqube`, avec la cible de `make
  bootstrap` : même mécanisme pour une instance locale et distante (`DEPLOY_SSH`). Le token passe par
  l'entrée standard, jamais en argument ni dans les journaux.
- **Relance.** Le token du stockage de l'instance est conservé s'il est encore valide et toujours
  présent pour le compte d'analyse ; la copie locale est alors mise à jour si elle diffère. Depuis un autre poste,
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

### Migration d'une instance existante

Une instance bootstrappée avant le compte d'analyse a un token `devops-platform-analyse` du compte
`admin`. Le premier `make bootstrap ENV=<env>` qui suit :

1. crée le compte d'analyse et lui génère un nouveau token (étape SonarQube) ; tant que l'ancien token
   `admin` existe, seul un token dont le stockage enregistre le compte propriétaire est conservé ;
2. pose ce token dans `SONAR_TOKEN`, puis révoque l'ancien token du compte `admin` (étape GitLab).
   L'étape GitLab ne révoque que si `SONAR_TOKEN` porte bien le token du stockage de l'instance, de
   propriétaire le compte d'analyse ; sinon elle le signale.

Les projets consommateurs qui utilisaient l'ancien token (`outputs/<env>.env` d'une version antérieure)
sont à reconfigurer. Avec `make bootstrap-sonarqube` seul, l'ancien token reste actif, et `SONAR_TOKEN`
inchangée, jusqu'au prochain `make bootstrap` ou `make bootstrap-gitlab`.

### Limites

- **Secret dans le volume.** `sonarqube_data` contient désormais le token : une sauvegarde de ce volume
  le contient aussi, et quiconque accède au moteur Docker de l'hôte peut le lire (accès équivalent à
  root, comme pour la base). Ne jamais supprimer ce volume pour reconstruire les index
  ([montée de version](montee-de-version.md)) : le token serait remplacé au bootstrap suivant.
- **Validation.** `api/authentication/validate` accepte tout token valide : un autre token déposé à la
  main dans le stockage serait conservé. Un token d'analyse globale ne permet de vérifier ni son nom ni
  son propriétaire : le fichier `analyse-token.compte` est déclaratif.
- **Projets créés par analyse.** Le modèle de permissions par défaut de SonarQube donne au créateur
  d'un projet (*Project Creators*) l'administration de ce projet : le compte d'analyse administre les
  projets que crée leur première analyse. Le token, d'analyse seulement, ne permet pas d'en user.
- **Groupes.** Les permissions héritées des groupes `sonar-users` et `Anyone` sont signalées, pas
  retirées : elles relèvent de la configuration de l'opérateur.
- **Exécutions simultanées.** L'étape est verrouillée dans le conteneur `sonarqube`
  (`/opt/sonarqube/data/devops-platform/.bootstrap.lock`) une fois SonarQube prêt : une seconde
  exécution s'arrête sans rien modifier ([exécutions simultanées](bootstrap.md#exécutions-simultanées)).
- **Trace.** `bash -x scripts/bootstrap/sonarqube.sh` afficherait le token et les mots de passe : ne
  pas tracer ce script (ni `scripts/bootstrap/gitlab.sh`).

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
