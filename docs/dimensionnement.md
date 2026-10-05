# Profils de dimensionnement

`PLATFORM_PROFILE` (dans `envs/<env>.env`) adapte la consommation mémoire de GitLab et SonarQube à la
taille du serveur : `small`, `medium` (défaut) ou `large`. Chaque profil est un fichier
`config/profiles/<profil>.env`, injecté dans les conteneurs `gitlab` et `sonarqube`.

**Ressources minimales de l'hôte**, pour la plateforme complète (GitLab, SonarQube, observabilité,
outils), hors jobs CI du runner — prévoir de la marge s'ils tournent sur le même hôte :

| Profil | RAM | vCPU | Disque | Usage visé |
|---|---|---|---|---|
| `small` | 8 Go | 4 | 50 Go | Poste de développement, petite équipe (≈ 10 utilisateurs) |
| `medium` | 16 Go | 8 | 100 Go | Équipe de taille moyenne (≈ 50 utilisateurs) |
| `large` | 32 Go | 16 | 250 Go | Plusieurs équipes, gros dépôts et analyses lourdes |

Quel que soit le profil, SonarQube exige `vm.max_map_count` ≥ 524288 sur l'hôte.

**Réglages :**

| Réglage | `small` | `medium` | `large` |
|---|---|---|---|
| GitLab — workers Puma | 0 (mode single) | 2 | 4 |
| GitLab — threads Puma (min / max) | 1 / 4 | 1 / 4 | 4 / 4 |
| GitLab — concurrence Sidekiq | 5 | 10 | 20 |
| GitLab — PostgreSQL `shared_buffers` | 128MB | 256MB | 1GB |
| GitLab — PostgreSQL `max_connections` | 100 | 150 | 300 |
| SonarQube — heap web (Xmx) | 512m | 512m | 1g |
| SonarQube — heap Compute Engine (Xmx) | 512m | 512m | 2g |
| SonarQube — heap Elasticsearch (Xms = Xmx) | 512m | 512m | 2g |

`medium` reprend le réglage historique de la plateforme (heaps SonarQube par défaut).
En `small`, Puma tourne en **mode single** (un seul processus, sans maître) : quelques centaines de Mo
économisés, au prix d'un débit réduit et sans redémarrage progressif ni surveillance mémoire des workers.

**Changer de profil** : modifier `PLATFORM_PROFILE` dans `envs/<env>.env`, puis `make deploy ENV=<env>`,
qui recrée `gitlab` et `sonarqube` (volumes conservés ; GitLab indisponible quelques minutes).
`make check-env` refuse un profil inconnu et signale un `PLATFORM_PROFILE` exporté dans le shell, qui
prime sur le fichier. Pour un réglage sur mesure, ajouter un fichier `config/profiles/<nom>.env`
définissant les mêmes clés (contrôlé par `make verify`).
