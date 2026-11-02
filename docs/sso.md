# Authentification unique (passerelle GitLab)

Les services web de la plateforme sont placés derrière une **passerelle d'authentification**
(oauth2-proxy, service `oauth2-proxy` de `compose/proxy.yml`) : un visiteur sans session est redirigé
vers la page de connexion de GitLab, puis ramené sur l'URL demandée. Seuls les utilisateurs GitLab
actifs (et, en option, les membres d'un groupe) accèdent aux services, y compris à ceux qui n'ont pas
d'authentification propre (page d'accueil, PlantUML).

Grafana ouvre directement la session de l'utilisateur GitLab (voir « Grafana »). SonarQube et Portainer
affichent encore leur propre page de connexion derrière la passerelle : la passerelle filtre l'accès,
ces applications gardent leurs comptes.

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
   | `X-Auth-Request-User` | Login GitLab |
   | `X-Auth-Request-Preferred-Username` | Login GitLab |
   | `X-Auth-Request-Email` | E-mail principal |
   | `X-Auth-Request-Groups` | Groupes GitLab (chemins complets, groupes hérités compris), un en-tête par groupe |

   Le nom complet de l'utilisateur n'est pas transmis.

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
| Accueil (`HOME_HOSTNAME`), PlantUML, Grafana, Portainer | **Protégés** | Tout le hostname |
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
(`SSO_GITLAB_CLIENT_SECRET`) de l'application OAuth, ainsi que la clé des cookies de la passerelle
(`SSO_COOKIE_SECRET`). Pour un fichier d'instance généré avant la passerelle, `make check-env` (donc
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

## Grafana

Un utilisateur qui a passé la passerelle arrive dans Grafana **déjà connecté**, sans formulaire. Son
compte Grafana est créé à la première visite : login et e-mail GitLab (nom affiché : le login, la
passerelle ne transmettant pas le nom complet).

### Mécanisme : `auth.proxy`

Grafana lit l'identité dans les en-têtes de la passerelle (`auth.proxy` de Grafana) plutôt que de mener
sa propre connexion OAuth avec GitLab : la passerelle a déjà authentifié l'utilisateur, et ce choix
n'impose ni seconde application OAuth, ni secret supplémentaire, ni nouvelle redirection. Chaîne d'une
requête vers `GRAFANA_HOSTNAME` :

1. `passerelle-auth` (forward auth vers la passerelle) : session vérifiée, en-têtes
   `X-Auth-Request-*` du client supprimés puis remplacés par ceux de la passerelle ;
2. `grafana-role` (second forward auth, service `grafana-role` de `compose/observability.yml`) :
   calcule le rôle à partir des groupes et le transmet dans `X-Auth-Request-Role` (valeur du client
   supprimée par l'étape 1, puis remplacée) ;
3. Grafana : login `X-Auth-Request-User`, e-mail `X-Auth-Request-Email`, rôle `X-Auth-Request-Role`.

Grafana n'accepte ces en-têtes que d'**une seule adresse source** : celle de Traefik sur le réseau
interne `devops-platform_grafana-proxy`, qui ne relie que Traefik et Grafana (sous-réseau
`GRAFANA_PROXY_SUBNET`, défaut `172.31.254.16/28`, adresse fixe de Traefik `GRAFANA_PROXY_IP_TRAEFIK`,
défaut `172.31.254.30`). Une requête portant ces en-têtes depuis une autre source (autre conteneur de la
plateforme, hôte, tunnel SSH) est refusée. Grafana n'a pas d'autre routeur que celui protégé par la
passerelle. Les deux sous-réseaux `*_PROXY_SUBNET` doivent être disjoints (`make check-env`) ; changer
le sous-réseau d'une instance existante impose de supprimer le réseau `devops-platform_grafana-proxy`
(`make down`, puis `make deploy`).

Si `grafana-role` est arrêté, Traefik répond par une erreur sur Grafana : aucun accès sans rôle calculé.

### Rôles

| Utilisateur GitLab | Rôle Grafana (organisation principale) |
|---|---|
| Membre du groupe `SSO_GROUPE_ADMIN`, directement ou par un groupe parent | `Admin` |
| Autres | `Viewer` |
| Login identique à `GRAFANA_ADMIN_USER` (casse ignorée) | Refusé (403) |

- `SSO_GROUPE_ADMIN` (`envs/<env>.env`, vide par défaut) : chemin complet d'un groupe GitLab
  (`equipe/admins`), comparé sans tenir compte de la casse. Vide : tout le monde est `Viewer`
  (administration par le compte local). Après modification : `make deploy ENV=<env>`.
- Il s'agit du rôle d'**organisation** `Admin` (dashboards, sources de données, utilisateurs de
  l'organisation), pas de *Grafana Server Admin*, réservé au compte local.
- Le rôle est recalculé à **chaque connexion**, c'est-à-dire à chaque nouvelle session de la passerelle :
  les groupes sont lus dans GitLab à l'ouverture de la session et figés pour sa durée (8 h au plus, voir
  « Durée de session »). Grafana applique le nouveau rôle dès la requête suivante. Pour qu'un
  changement d'appartenance prenne effet tout de suite : `/oauth2/sign_out` sur `GRAFANA_HOSTNAME` (ou
  le bouton de déconnexion de Grafana, qui y renvoie), puis nouvelle visite.
- **Homonymie avec le compte admin local** : Grafana relie un utilisateur de la passerelle à un compte
  existant de même login. Un utilisateur GitLab nommé comme `GRAFANA_ADMIN_USER` obtiendrait le compte
  admin local (et lui imposerait son rôle) : `grafana-role` le refuse. `make check-env` refuse
  `GRAFANA_ADMIN_USER=root`, compte GitLab toujours présent. Grafana relie aussi par e-mail : ne pas
  donner à un compte GitLab l'e-mail du compte admin local (`admin@localhost` par défaut).

### Compte admin local et inscription

Le compte `GRAFANA_ADMIN_USER` (mot de passe `GRAFANA_ADMIN_PASSWORD`) reste utilisable par le
formulaire de connexion, joint par l'accès de secours ci-dessous : sans en-tête d'identité, Grafana
affiche son formulaire habituel. L'inscription libre, l'accès anonyme, les dashboards publics et les
snapshots restent désactivés ; seuls les utilisateurs passés par la passerelle obtiennent un compte.
La source de données Loki provisionnée n'est pas concernée.

## Accès de secours sans GitLab

GitLab indisponible, plus aucun service protégé n'est accessible par son hostname. Accès direct, sans
passerelle, par un tunnel SSH vers le service (réseau de la plateforme), avec les comptes admin locaux
(`GRAFANA_ADMIN_PASSWORD`, `PORTAINER_ADMIN_PASSWORD`, `SONARQUBE_ADMIN_PASSWORD` de
`envs/<env>.env`). Sur le serveur :

```bash
docker inspect -f '{{(index .NetworkSettings.Networks "devops-platform").IPAddress}}' devops-platform-grafana-1
```

(adresse sur le réseau de la plateforme, `PLATFORM_NETWORK` ; Grafana est aussi sur
`devops-platform_grafana-proxy`, réservé à Traefik).

Puis, depuis le poste, tunnel vers cette adresse et le port interne du service (Grafana 3000,
SonarQube 9000, Portainer 9000, PlantUML 8080, accueil 80) :

```bash
ssh -N -L 3000:<IP du conteneur>:3000 <utilisateur>@<serveur>
```

et ouvrir `http://localhost:3000`. Les liens et redirections de l'application pointent toujours vers son
URL publique : naviguer par les chemins relatifs.

## Limites

- Session par hostname : la déconnexion ne couvre qu'un service (voir « Déconnexion »).
- Grafana : nom complet GitLab non transmis (nom affiché = login) ; rôle figé pour la durée de la
  session de la passerelle (voir « Grafana »).
- Exemption SonarQube par en-tête `Authorization` : l'API reste joignable sans passer par la passerelle
  (voir « Services couverts et exemptés »).
- Image : `quay.io/oauth2-proxy/oauth2-proxy` (variante `-alpine`, `OAUTH2_PROXY_VERSION`), montée de
  version : [montée de version](montee-de-version.md).
