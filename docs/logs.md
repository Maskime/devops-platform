# Rétention des logs (Loki)

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
- **Prise en compte** : `make deploy ENV=<env>` après modification de `envs/<env>.env` (le conteneur
  `loki` est recréé) ; `docker compose --env-file envs/<env>.env restart loki` après modification de
  `config/loki/loki-config.yaml`. Les logs déjà hors délai sont purgés dans les heures qui suivent.
- **Validation** : `make check-env` (préalable de `make deploy`) et `make verify` refusent une durée mal
  formée ou inférieure à 24h — Loki l'accepterait sans erreur — et passent la configuration résolue à
  `loki -verify-config` (`scripts/check-loki-config.sh`).

L'API de suppression à la demande (`/loki/api/v1/delete`) est désactivée (`deletion_mode: disabled`) :
Loki n'a pas d'authentification sur le réseau de la plateforme.
