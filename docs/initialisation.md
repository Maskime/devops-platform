# Initialisation d'une instance (`make init`)

`make init ENV=<env>` génère `envs/<env>.env` à partir du modèle `envs/.env.example`, sans secret à
inventer ni à copier :

| Question | Défaut |
|---|---|
| Domaine de base | `localhost` |
| Hostname de chaque service (GitLab, SonarQube, Grafana, Portainer, PlantUML) | `<service>.<domaine>` |
| `TLS_MODE` (`letsencrypt`, `custom`, `none`) | `none` pour un domaine local (`localhost`, `*.localhost`), sinon `letsencrypt` |
| Profil de dimensionnement | `medium` |

- **Mots de passe** (root GitLab, base et admin SonarQube, admin Grafana, admin Portainer) : 24 caractères aléatoires
  avec majuscule, minuscule, chiffre et caractère spécial (règles SonarQube), sans caractère
  problématique pour Compose ou le shell. Ils ne sont jamais affichés : les lire dans le fichier.
- **Fichier** en permissions `600`, écrit de façon atomique.
- **URLs publiques** : `GITLAB_EXTERNAL_URL` n'est pas écrite (dérivée par GitLab du hostname et du
  `TLS_MODE`) ; `SONARQUBE_EXTERNAL_URL` et `GRAFANA_EXTERNAL_URL` valent `https://<hostname>` en
  `custom` et `letsencrypt`, `http://<hostname>` en `none`. Avec `TLS_MODE=none` et un hostname non local, `make init` affiche le même
  avertissement que `make deploy` ; en `custom`, il rappelle les certificats à déposer dans
  `config/certs/` ; en `letsencrypt`, il demande l'email du compte ACME (`ACME_EMAIL`) et rappelle les
  prérequis (DNS public, port 80).
- **Sans terminal** (`make init ENV=<env> < /dev/null`, ou réponses passées sur l'entrée standard),
  une réponse vide prend la valeur par défaut et une réponse invalide arrête la commande.

**Fichier existant.** `make init` refuse de l'écraser. `FORCE=1` le régénère : l'ancien fichier est
sauvegardé dans `envs/<env>.env.bak.<date>` (600, non versionné, jamais écrasé), ses réponses sont
proposées par défaut et **ses secrets sont repris**. Les autres réglages (ports SSH, versions, réseau…)
repartent du modèle : les reprendre depuis la sauvegarde si besoin.
`FORCE=1 NOUVEAUX_MDP=1` régénère aussi les secrets : à réserver à une instance jamais déployée ou à
réinstaller, car le mot de passe PostgreSQL de SonarQube est inscrit dans son volume et les mots de
passe root GitLab et admin Portainer ne sont appliqués qu'au premier démarrage. Un secret absent de
l'ancien fichier (variable ajoutée depuis) est généré et signalé. `FORCE` et `NOUVEAUX_MDP` ne sont acceptés
que sur la ligne de commande, jamais hérités du shell.
