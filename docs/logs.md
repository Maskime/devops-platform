# Logs (Loki)

Promtail collecte les logs des conteneurs par l'API Docker filtrée ([accès à l'API Docker](acces-docker.md))
et les envoie à Loki, consulté dans Grafana (*Explore*, source Loki) :

- **les conteneurs de la plateforme** (projet Compose `devops-platform`), toujours ;
- **les conteneurs de l'hôte hors plateforme** (projets co-localisés, services voisins) qui le
  demandent par un label ([ci-dessous](#conteneurs-hors-plateforme)). Les autres ne sont pas collectés.

## Labels des flux

| Label | Plateforme | Hors plateforme |
|---|---|---|
| `job` | `containers` | `host-containers` |
| `project` | `devops-platform` | projet Compose, sinon `hors-compose` |
| `service` | service Compose | `devops-platform.logs.service` s'il est posé, sinon service Compose, sinon `hors-compose` |
| `stream` | `stdout` ou `stderr` | `stdout` ou `stderr` |
| `container` | nom du conteneur (`devops-platform-<service>-1`, fixé par Compose) | absent |

Aucun identifiant ni nom de conteneur hors plateforme : un label à forte cardinalité (conteneurs
recréés, noms aléatoires de `docker run`) multiplierait les flux. Exemples de requêtes :

```logql
{job="containers", service="gitlab"}              # un service de la plateforme
{job="host-containers", project="monprojet"}      # tous les conteneurs d'un projet co-localisé
{job="host-containers"} |= "ERROR"                # tous les projets co-localisés
```

## Conteneurs hors plateforme

### Adhésion

Un conteneur est collecté s'il porte le label `devops-platform.logs=true` (et tourne). Exemple pour un
projet Compose ([branchement d'un projet](branchement-projet.md#logs-dans-grafana)) :

```yaml
services:
  app:
    labels:
      devops-platform.logs: "true"
```

Hors Compose : `docker run --label devops-platform.logs=true --label devops-platform.logs.service=<nom> …`
(sans `devops-platform.logs.service`, tous les conteneurs hors Compose partagent `service="hors-compose"`).

- **Recréation requise.** Les labels d'un conteneur sont fixés à sa création : `docker compose up -d`
  recrée le service après l'ajout du label ; retirer le label (et recréer) arrête la collecte.
- **Historique relu.** À l'adhésion, Promtail lit tout l'historique du conteneur conservé par Docker
  (`json-file`), dans la limite des débits ci-dessous ; Loki refuse les lignes de plus de 7 jours
  (`reject_old_samples_max_age`).
- **Prise en compte** : immédiate (découverte toutes les 5 s), sans redéploiement de la plateforme.
- **Noms stables.** Chaque combinaison projet × service × `stream` est un flux Loki ; le nombre de flux
  actifs est partagé avec la plateforme (`max_global_streams_per_user`, ci-dessous). Ne pas faire adhérer
  des projets Compose aux noms générés (`-p $CI_PIPELINE_ID`, par exemple).

### Visibilité

**Tout utilisateur autorisé de Grafana voit ces logs**, comme ceux de la plateforme : il n'y a pas de
cloisonnement par projet. Un projet qui adhère ne doit **journaliser ni secret** (jeton, mot de passe,
en-tête `Authorization`…) **ni donnée personnelle en clair** ; une ligne envoyée reste dans Loki jusqu'à
la purge par la rétention (l'API de suppression est désactivée).

### Limites

Rétention et limites d'ingestion de Loki sont les mêmes pour tous les flux (un seul locataire, aucune
surcharge par flux). Pour qu'un projet bavard ne fasse pas perdre les logs de la plateforme, Promtail
limite en plus le seul job `host-containers` (`config/promtail/promtail-config.yaml`) :

| Limite | Valeur | Portée | Au-delà |
|---|---|---|---|
| Débit par projet (Promtail) | 100 lignes/s, rafale 500 | chaque valeur de `project` (tous les conteneurs hors Compose partagent `hors-compose`) | lignes jetées |
| Débit global hors plateforme (Promtail) | 300 lignes/s, rafale 1000 | tous les projets ensemble | lignes jetées |
| Débit du locataire (Loki) | 16 Mo/s, rafale 32 Mo (`ingestion_rate_mb`, `ingestion_burst_size_mb`) | tous les flux | envoi refusé, réessayé par Promtail |
| Débit par flux (Loki) | 3 Mo/s, rafale 15 Mo (`per_stream_rate_limit`, `…_burst`) | chaque flux | ce flux seul refusé |
| Flux actifs (Loki) | 5000 (`max_global_streams_per_user`) | tous les flux | nouveaux flux refusés |
| Taille de ligne (Loki) | 256 Ko (`max_line_size`) | chaque ligne | ligne refusée |

Au pire, les projets envoient 300 lignes de 16 Ko (taille maximale d'une ligne Docker) par seconde,
soit environ 4,8 Mo/s (rafale environ 16 Mo) : le débit du locataire reste disponible pour la
plateforme. Les lignes jetées par Promtail sont comptées par sa métrique
`logentry_dropped_lines_total{reason="ratelimit_drop_stage"}`. Elles sont lues avant d'être jetées :
un conteneur très bavard coûte toujours du processeur à Promtail et au proxy de socket.

Le nombre de flux actifs n'est pas limité par projet : un projet qui crée des flux sans borne peut
empêcher l'apparition de nouveaux flux de la plateforme ([#255](https://github.com/Maskime/devops-platform/issues/255)).

## Rétention

Loki purge les logs plus anciens que `LOKI_RETENTION_PERIOD` (dans `envs/<env>.env`), **744h (31 jours)
par défaut**. Sans rétention, le volume `loki_data` croîtrait sans limite.

- **Format** : durée en `h`, `d` ou `w` (`168h`, `31d`, `4w`). Minimum **24h**, multiple de 24h recommandé
  (période de l'index). `0s` désactive la purge (conservation illimitée).
- **Au moins 168h recommandé** : Loki accepte à l'ingestion les logs vieux de moins de 7 jours
  (`reject_old_samples_max_age`, qui ne purge rien). Avec une rétention plus courte, des logs renvoyés en
  retard (positions de Promtail perdues, par exemple) sont stockés puis aussitôt purgés.
- **Délai de purge effectif** : de l'ordre de **4h au-delà de l'échéance**. Un chunk (jusqu'à 2h de logs)
  n'expire qu'avec sa dernière entrée ; le compacteur le marque à sa passe suivante (toutes les 10 min)
  et ne le supprime du disque qu'après `retention_delete_delay` (2h). L'espace des index est libéré par
  table journalière.
- **Prise en compte** : `make deploy ENV=<env>` après modification de `envs/<env>.env` ou de
  `config/loki/loki-config.yaml` : le conteneur `loki` est recréé ou redémarré ; pour une instance
  distante, la configuration est d'abord copiée sur le serveur. Les logs déjà hors délai sont purgés dans les heures qui suivent.
- **Validation** : `make check-env` (préalable de `make deploy`) et `make verify` refusent une durée mal
  formée ou inférieure à 24h — Loki l'accepterait sans erreur — et passent la configuration résolue à
  `loki -verify-config` (`scripts/check-loki-config.sh`).

L'API de suppression à la demande (`/loki/api/v1/delete`) est désactivée (`deletion_mode: disabled`) :
Loki n'a pas d'authentification sur le réseau de la plateforme (injoignable depuis les jobs CI, qui ont
leur propre réseau).
