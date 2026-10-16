# Serveurs MCP (agents IA)

Chaque instance expose deux serveurs [MCP](https://modelcontextprotocol.io) (Model Context Protocol),
pour brancher un agent IA (Claude Code, etc.) sur GitLab et SonarQube sans configuration propre à
l'instance sur le poste :

| Serveur | URL | Authentification | Fourni par |
|---|---|---|---|
| GitLab | `https://<GITLAB_HOSTNAME>/api/v4/mcp` | OAuth 2.0 (compte GitLab de l'utilisateur, dans le navigateur) | GitLab lui-même : rien à déployer |
| SonarQube | `https://<SONARQUBE_MCP_HOSTNAME>/mcp` | Jeton utilisateur SonarQube (`Authorization: Bearer`) | Service `sonarqube-mcp` (image officielle `sonarsource/sonarqube-mcp`) |

`make status`, `make deploy`, la page d'accueil et le fichier de sortie (`GITLAB_MCP_URL`,
`SONARQUBE_MCP_URL` dans `outputs/<env>.env`) affichent les URLs de l'instance.

Chaque utilisateur s'authentifie avec son propre compte : les droits GitLab et SonarQube s'appliquent
tels quels, aucun jeton n'est stocké côté serveur.

## Disponibilité selon le `TLS_MODE`

| `TLS_MODE` | GitLab | SonarQube |
|---|---|---|
| `letsencrypt` | utilisable | actif |
| `custom` | utilisable (CA privée à déclarer sur le poste, voir plus bas) | actif |
| `none` | **inutilisable** : les clients MCP refusent d'envoyer un jeton OAuth à une URL `http://` autre que `localhost`, `127.0.0.1` ou `::1` | **désactivé** par défaut (jetons en clair) |

## SonarQube

### Activation

| Variable | Rôle | Défaut |
|---|---|---|
| `SONARQUBE_MCP_ENABLED` | `true` ou `false` | `true`, sauf en `TLS_MODE=none` |
| `SONARQUBE_MCP_HOSTNAME` | Hostname routé par Traefik | `sonarqube-mcp.<domaine>` (`make init`), `sonarqube-mcp.localhost` sinon |
| `SONARQUBE_MCP_VERSION` | Tag de l'image | voir `envs/.env.example` |

Le service appartient au profil Compose `sonarqube-mcp`, que `make deploy` active selon ces règles.
Désactivé, son conteneur est supprimé au déploiement suivant et son hostname n'est plus contrôlé
(certificat, Let's Encrypt). Forcé à `true` en `TLS_MODE=none`, `make deploy` le signale : les jetons
circulent en clair, à réserver au poste local.

Le serveur joint SonarQube par le réseau interne de la plateforme (`http://sonarqube:9000`) : aucune CA
n'est à lui fournir, quel que soit le `TLS_MODE`. Télémétrie désactivée.

### Jeton

Le serveur exige un **jeton utilisateur** (*My Account > Security > Generate Tokens*, type
*User Token*) : les jetons de projet et les jetons globaux d'analyse sont refusés. Le serveur n'accède
qu'à ce que le compte voit dans SonarQube.

### Branchement de Claude Code

```bash
claude mcp add --transport http sonarqube https://sonarqube-mcp.mondomaine.fr/mcp \
  --header "Authorization: Bearer <jeton utilisateur SonarQube>"
```

Le jeton est alors enregistré dans la configuration de Claude Code du poste (`~/.claude.json`, ou
`.mcp.json` avec `-s project` : à ne pas versionner avec le jeton).

### Licence

L'image `sonarsource/sonarqube-mcp` est publiée sous la *SONAR Source-Available License v1.0* (SSAL),
pas sous une licence libre : sa clause (c) du « Non-competitive Purpose » restreint les usages permis
(texte de la licence dans le [dépôt du serveur](https://github.com/SonarSource/sonarqube-mcp-server), à
lire avant de déployer). Ce dépôt reste sous licence MIT et ne fait que référencer l'image : la décision
de l'utiliser revient à chaque opérateur, au regard de son usage (sinon `SONARQUBE_MCP_ENABLED=false`).

## GitLab

### Activation

Le serveur MCP est intégré à GitLab (bêta jusqu'à 19.4, disponible en édition gratuite). `make bootstrap`
autorise son accès pour l'instance (réglage *Admin > Settings > General > Visibility and access controls >
MCP*, `mcp_server_enabled`), de façon idempotente. Il signale aussi :

- l'enregistrement dynamique des clients OAuth désactivé (réglage `dynamic_client_registration_enabled`,
  laissé à l'administrateur) : les clients ne s'enregistrent plus d'eux-mêmes, une application OAuth
  (scope `mcp`, non confidentielle) est alors à créer dans GitLab et à déclarer dans le client ;
- une URL GitLab en `http://` (`TLS_MODE=none`) : serveur inutilisable par les clients.

### Branchement de Claude Code

```bash
claude mcp add --transport http gitlab https://gitlab.mondomaine.fr/api/v4/mcp
```

Puis, dans Claude Code, `/mcp`, sélectionner `gitlab` et valider l'autorisation dans le navigateur.
Le client s'enregistre comme application OAuth (scope `mcp`) au nom de l'utilisateur.

Les jetons d'accès personnels classiques (`api`) sont refusés ; seuls OAuth (scope `mcp`) et les jetons
d'accès personnels à granularité fine (ressource *MCP tool*) sont acceptés. Les outils disponibles
dépendent de la version de GitLab ; ceux de GitLab Duo sont absents de l'édition communautaire.

## CA privée (`TLS_MODE=custom`)

Le client doit faire confiance à la CA qui a émis le certificat de l'instance (`config/certs/ca/ca.pem`,
docs/certificats.md). Claude Code est un client Node.js :

```bash
export NODE_EXTRA_CA_CERTS=/chemin/vers/ca.pem
claude
```

Sans cela, la connexion échoue sur une erreur de certificat (`unable to get local issuer certificate`).

## Vérification

`make smoke` interroge les deux serveurs avec des jetons éphémères, supprimés en fin d'étape :

- SonarQube (s'il est actif) : `initialize`, puis l'outil `search_my_sonarqube_projects` doit lister le
  projet de test, avec un jeton utilisateur temporaire du compte admin ;
- GitLab : `initialize`, puis l'outil `get_project` doit lire le projet de test, avec un jeton OAuth
  (scope `mcp`) de root créé par `gitlab-rails`, comme après une autorisation dans le navigateur.

Les deux appels partent de l'intérieur de la plateforme : ils valident les serveurs, pas le DNS, le
certificat ni le poste de l'utilisateur. Depuis un poste :

```bash
curl -sf https://sonarqube-mcp.mondomaine.fr/info        # {"version":"…"}, sans authentification
```

Côté GitLab, le diagnostic intégré vérifie la configuration (réglage, découverte OAuth, droits d'un
utilisateur) :

```bash
scripts/instance.sh compose <env> exec gitlab gitlab-rake "gitlab:mcp:verify_setup[<utilisateur>]"
```
