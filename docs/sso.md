# Authentification unique (passerelle GitLab)

Les services web de la plateforme sont placés derrière une **passerelle d'authentification**
(oauth2-proxy, service `oauth2-proxy` de `compose/proxy.yml`) : un visiteur sans session est redirigé
vers la page de connexion de GitLab, puis ramené sur l'URL demandée. Seuls les utilisateurs GitLab
actifs (et, en option, les membres d'un groupe) accèdent aux services, y compris à ceux qui n'ont pas
d'authentification propre (page d'accueil, PlantUML).

Grafana et SonarQube affichent encore leur propre page de connexion derrière la passerelle : la
passerelle filtre l'accès, chaque application garde ses comptes. Portainer se connecte avec l'identité
GitLab, réservé aux membres de `SSO_GROUPE_ADMIN` (voir « Portainer »).

## Mécanisme

1. Traefik applique aux routeurs protégés le middleware `passerelle-auth` (*forward auth*) : avant
   chaque requête, il interroge la passerelle (`http://oauth2-proxy:4180/`).
2. Sans session valide, la passerelle répond par une redirection vers
   `<URL GitLab>/oauth/authorize`. L'application OAuth de la plateforme est marquée **de confiance** :
   un utilisateur déjà connecté à GitLab n'a ni formulaire ni écran de consentement, et revient aussitôt
   (redirection silencieuse).
3. GitLab renvoie le navigateur sur `/oauth2/callback` **du même hostname**, routé vers la passerelle
   (routeur `passerelle`, chemin `/oauth2/` de chaque hostname protégé). La passerelle échange le code
   (PKCE), vérifie l'identité et pose un cookie de session (`_devops_platform_sso`) **propre à ce
   hostname**, puis redirige vers l'URL demandée au départ.
4. Avec une session valide, la passerelle répond 202 avec l'identité de l'utilisateur ; Traefik transmet
   la requête au service avec les en-têtes :

   | En-tête | Contenu |
   |---|---|
   | `X-Auth-Request-User` | Identifiant GitLab (`sub`) |
   | `X-Auth-Request-Preferred-Username` | Login GitLab |
   | `X-Auth-Request-Email` | E-mail principal |
   | `X-Auth-Request-Groups` | Groupes GitLab (chemins complets, séparés par des virgules) |

   Traefik retire de la requête tout en-tête `X-Auth-Request-*` envoyé par le client avant d'y copier
   ceux de la passerelle : un en-tête forgé n'atteint jamais un service protégé.

Aucun domaine parent commun n'est exigé entre les `*_HOSTNAME` : chaque hostname a son cookie et sa
propre URI de redirection dans l'application GitLab. Une session ouverte sur un service ne vaut pas
pour les autres, mais l'ouverture d'un autre service ne redemande rien tant que la session GitLab est
ouverte (aller-retour invisible).

Mode TLS : cookie `Secure` en `letsencrypt` et `custom` ; sans `Secure` en `none` (HTTP, usage local
sur `*.localhost`). La passerelle joint GitLab par son URL publique (`GITLAB_EXTERNAL_URL` ou dérivée),
résolue vers Traefik dans le réseau de la plateforme ; en `TLS_MODE=custom`, la CA privée facultative
(`config/certs/ca/ca.pem`) y est montée et ajoutée au magasin système.

## Services couverts et exemptés

| Accès | Passerelle | Remarque |
|---|---|---|
| Accueil (`HOME_HOSTNAME`), PlantUML, Grafana | **Protégés** | Tout le hostname |
| Portainer (`PORTAINER_HOSTNAME`) | **Protégé**, groupe `SSO_GROUPE_ADMIN` | Tout le hostname ; voir « Portainer » |
| SonarQube (`SONARQUBE_HOSTNAME`) : interface web | **Protégé** | |
| SonarQube : `/api/…` et `/batch/…` avec `Authorization: Bearer` ou `Basic` | Exempté | Scanner de la CI (token) ; formulaire `/api/authentication/login` exclu, reste protégé |
| GitLab (`GITLAB_HOSTNAME`) : interface, API, git en HTTPS, runner | Exempté | Fournisseur d'identité ; voir « GitLab » |
| SSH de GitLab (`GITLAB_SSH_PORT`) | Exempté | Hors Traefik |
| Serveur MCP SonarQube (`SONARQUBE_MCP_HOSTNAME`), serveur MCP de GitLab | Exemptés | Jeton du client |
| Routeurs internes `*.devops-platform.internal` (jobs CI) | Exemptés | Entrypoint interne, non publié |

Chaque routeur exempté supprime les en-têtes d'identité reçus du client (middlewares
`<service>-sans-identite`) : une application qui leur ferait confiance ne peut pas être trompée par une
requête qui contourne la passerelle. Le smoke test vérifie qu'une requête aux en-têtes d'identité
forgés est redirigée vers GitLab sur chaque service protégé et reste sans effet sur les API exemptées.

Exemption SonarQube : n'importe qui peut envoyer un en-tête `Authorization` et atteindre l'API sans
passer par la passerelle ; SonarQube vérifie alors le jeton ou le mot de passe, comme avant cette
passerelle. Les comptes locaux de SonarQube restent donc la protection de son API.

## GitLab

GitLab n'est pas derrière la passerelle : il en est le fournisseur. `make bootstrap` y impose, à chaque
passage :

- l'**inscription libre désactivée** ;
- le niveau de visibilité **public restreint** : un visiteur anonyme arrive sur la page de connexion.
  Les projets et groupes déjà publics restent lisibles sans compte : les passer en interne ou privé.

## Application OAuth et ordre de mise en route

`make init` génère dans `envs/<env>.env` l'identifiant (`SSO_GITLAB_CLIENT_ID`) et le secret
(`SSO_GITLAB_CLIENT_SECRET`) de l'application OAuth, la clé des cookies de la passerelle
(`SSO_COOKIE_SECRET`) et les identifiants de l'application de Portainer (`SSO_PORTAINER_CLIENT_ID`,
`SSO_PORTAINER_CLIENT_SECRET`, voir « Portainer »). Pour un fichier d'instance généré avant la passerelle, `make check-env` (donc
`make deploy`) refuse de démarrer et indique la commande qui les ajoute sans toucher au reste :

```bash
make init ENV=<env> COMPLETER=1
```

`FORCE=1` ne convient pas : il régénère le fichier depuis le modèle et perd les réglages hors questions
(versions, ports, `SSO_GITLAB_GROUPE`…).

Ordre de mise en route : **`make deploy`, puis `make bootstrap`**. Le bootstrap crée ou met à jour
l'application `devops-platform-sso` de GitLab (Admin > Applications) : ces identifiants, une URI de
redirection par hostname protégé (`<schéma>://<hostname>/oauth2/callback`), scopes `openid`, `profile`,
`email` et `read_user`, confidentielle et de confiance. Il est idempotent et relance la passerelle
seulement si l'application a changé.

Avant le bootstrap, la passerelle est en **mode refus** : tout service protégé affiche « Passerelle
d'authentification non initialisée » (HTTP 403), sans lien de connexion. Elle sonde GitLab
(`http://gitlab`, réseau interne) au démarrage : application inconnue → page « non initialisée »,
GitLab injoignable (démarrage en cours) → page « GitLab indisponible ». En mode refus, le conteneur
redémarre toutes les deux minutes pour rejouer la sonde. Les services protégés peuvent alors répondre
404 quelques secondes. `make status` affiche le mode de la passerelle.

Après un changement d'identifiants ou de hostname : `make deploy` puis `make bootstrap`. Passerelle
arrêtée ou non *healthy* : Traefik retire le middleware et les routeurs protégés ne sont plus servis
(404) ; aucun accès ne passe sans authentification.

## Utilisateurs admis et restriction par groupe

- Tout utilisateur GitLab **actif** dont l'e-mail est confirmé. Un compte créé par un administrateur
  sans confirmation de l'e-mail est refusé par la passerelle (« email is not verified ») : confirmer
  l'e-mail dans Admin > Utilisateurs.
- `SSO_GITLAB_GROUPE` (vide par défaut) : chemin complet d'un groupe GitLab (`equipe`,
  `equipe/devops`) ; seuls ses membres, sous-groupes compris, passent. Après modification :
  `make deploy ENV=<env>`.

## Portainer

Portainer donne la main sur Docker, donc sur l'hôte : il est réservé aux membres du groupe GitLab
`SSO_GROUPE_ADMIN` (chemin complet, ex. `equipe/admins`), qui s'y connectent avec leur identité GitLab.

### Mécanisme

- **Seconde application OAuth** `devops-platform-portainer`, créée ou mise à jour par `make bootstrap`
  avec `SSO_PORTAINER_CLIENT_ID` et `SSO_PORTAINER_CLIENT_SECRET` (générés par `make init`, ou
  `make init ENV=<env> COMPLETER=1`) : URI de redirection `<schéma>://<PORTAINER_HOSTNAME>/`, scope
  `read_user` seul, confidentielle et de confiance (pas d'écran de consentement).
- **Réglages de Portainer** posés par son API à chaque `make bootstrap` (idempotent) : authentification
  OAuth (fournisseur personnalisé), autorisation par l'URL publique de GitLab (navigateur), échange du
  code et lecture de l'identité (`/api/v4/user`, champ `username`) par `http://gitlab`, réseau interne de
  la plateforme (indépendant du `TLS_MODE` et de la CA), **création automatique de compte désactivée**.
  Le bootstrap se connecte avec le compte `admin` local et `PORTAINER_ADMIN_PASSWORD`.
- **Connexion** : passerelle (session GitLab), puis page de connexion de Portainer, bouton « Login with
  OAuth » : retour immédiat, sans saisie, l'application étant de confiance.

### Restriction au groupe

Deux contrôles indépendants :

1. **Passerelle** : le routeur de Portainer interroge une seconde fois la passerelle
   (`/oauth2/auth?allowed_groups=<SSO_GROUPE_ADMIN>`, middleware `portainer-admins` de
   `compose/tools.yml`) : un utilisateur GitLab hors du groupe reçoit **403** avant d'atteindre
   Portainer. Les groupes sont ceux lus à l'ouverture de la session de la passerelle.
2. **Portainer** n'admet que les comptes qui existent déjà. `make bootstrap` les synchronise :
   - un compte **administrateur** pour chaque membre actif du groupe, membres hérités des groupes
     parents compris (invitations en attente et comptes de service exclus), nommé comme son login
     GitLab (sans tenir compte de la casse) ;
   - les comptes créés ainsi appartiennent à l'équipe Portainer `devops-platform-sso` ; celui d'une
     personne qui a quitté le groupe est supprimé ;
   - un compte existant homonyme d'un membre est pris en charge (rôle administrateur, équipe) ;
   - un compte Portainer **non géré** et hors du groupe arrête le bootstrap **sans rien modifier** :
     son homonyme GitLab y entrerait par OAuth. Le supprimer ou le renommer dans Portainer (ou ajouter
     la personne au groupe), puis relancer `make bootstrap`.

   Le compte `admin` local (identifiant 1) n'est jamais modifié. Un utilisateur GitLab sans compte
   Portainer est refusé par Portainer (« Account not created beforehand »), même s'il a passé la
   passerelle.

`SSO_GROUPE_ADMIN` vide : aucun filtre à la passerelle, aucun compte GitLab dans Portainer (tout
utilisateur GitLab est refusé), seul l'admin local se connecte ; le bootstrap le signale. Groupe
introuvable dans GitLab : le bootstrap s'arrête avant toute modification.

Portée : membres du groupe et des groupes parents. Un membre d'un **sous-groupe** seulement n'est pas
admis (contrairement à `SSO_GITLAB_GROUPE`, qui admet les sous-groupes). Si `SSO_GITLAB_GROUPE` est
renseigné, les administrateurs doivent aussi en être membres pour passer la passerelle.

### Ajout et retrait d'un administrateur

- **Ajout** au groupe : compte Portainer créé au `make bootstrap` suivant.
- **Retrait** : refusé par la passerelle à la prochaine ouverture de session (8 h au plus), compte
  supprimé au `make bootstrap` suivant. Révocation immédiate : supprimer le compte dans Portainer
  (Administration > Users, ses sessions Portainer sont aussitôt invalidées), ou `make bootstrap`.

### Compte admin local

Le compte `admin` (`PORTAINER_ADMIN_PASSWORD`) reste utilisable par le formulaire de connexion de
Portainer, derrière la passerelle ou par l'[accès de secours](#accès-de-secours-sans-gitlab). Il sert
aussi au bootstrap et au smoke test : un mot de passe changé dans l'interface doit être reporté dans
`envs/<env>.env`, sinon `make bootstrap` s'arrête à l'étape Portainer (une seule tentative de
connexion, Portainer limitant les échecs).

### Limites

- **Pas de redirection automatique** vers GitLab : Portainer Community Edition (version épinglée
  `PORTAINER_VERSION`) n'a pas l'option de masquer le formulaire interne (réservée à l'édition
  Business) ; un clic sur « Login with OAuth » reste nécessaire.
- Comptes synchronisés au `make bootstrap` seulement (voir « Ajout et retrait d'un administrateur »).
- La déconnexion de Portainer ne ferme ni la session GitLab ni celle de la passerelle (voir
  « Déconnexion »).
- Tous les membres du groupe sont administrateurs de Portainer : aucun rôle plus restreint.

## Durée de session

La session de la passerelle dure **8 heures**, sans rafraîchissement. Un compte bloqué, supprimé ou
retiré du groupe garde l'accès aux services jusqu'à l'expiration de sa session (8 h au plus), puis est
refusé à la reconnexion. Pour couper tout de suite tous les accès : changer `SSO_COOKIE_SECRET`
(toutes les sessions deviennent invalides), puis `make deploy`.

À l'expiration, une requête en arrière-plan d'une interface déjà ouverte (Grafana, SonarQube) reçoit une
erreur au lieu de la redirection : recharger la page.

## Déconnexion

`/oauth2/sign_out` sur un hostname supprime le cookie de ce hostname seulement : les autres services
gardent leur session, et la session GitLab reste ouverte (une nouvelle visite reconnecte aussitôt).
Pour une déconnexion complète : se déconnecter de GitLab, puis fermer le navigateur, ou attendre
l'expiration des sessions de la passerelle.

## Accès de secours sans GitLab

GitLab indisponible, plus aucun service protégé n'est accessible par son hostname. Accès direct, sans
passerelle, par un tunnel SSH vers le service (réseau de la plateforme), avec les comptes admin locaux
(`GRAFANA_ADMIN_PASSWORD`, `PORTAINER_ADMIN_PASSWORD`, `SONARQUBE_ADMIN_PASSWORD` de
`envs/<env>.env`). Sur le serveur :

```bash
docker inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}} {{end}}' devops-platform-grafana-1
```

Puis, depuis le poste, tunnel vers cette adresse et le port interne du service (Grafana 3000,
SonarQube 9000, Portainer 9000, PlantUML 8080, accueil 80) :

```bash
ssh -N -L 3000:<IP du conteneur>:3000 <utilisateur>@<serveur>
```

et ouvrir `http://localhost:3000`. Les liens et redirections de l'application pointent toujours vers son
URL publique : naviguer par les chemins relatifs. Portainer : se connecter avec le compte `admin` local
par le formulaire (« Login with OAuth » renvoie vers GitLab).

## Limites

- Session par hostname : la déconnexion ne couvre qu'un service (voir « Déconnexion »).
- Portainer : clic sur « Login with OAuth », comptes synchronisés par `make bootstrap` (voir
  « Portainer », « Limites »).
- Exemption SonarQube par en-tête `Authorization` : l'API reste joignable sans passer par la passerelle
  (voir « Services couverts et exemptés »).
- Image : `quay.io/oauth2-proxy/oauth2-proxy` (variante `-alpine`, `OAUTH2_PROXY_VERSION`), montée de
  version : [montée de version](montee-de-version.md).
