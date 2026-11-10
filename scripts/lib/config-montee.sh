#!/usr/bin/env bash
# shellcheck disable=SC2034 # variables utilisées par les scripts qui sourcent ce fichier
# Fichiers de config/ montés par les services, copiés sur l'hôte d'une instance distante
# (${DEPLOY_DIR}/config-<empreinte>, PLATFORM_CONFIG_DIR) par scripts/instance.sh. Fichier à sourcer,
# partagé avec scripts/verify.sh, qui contrôle que chaque montage ${PLATFORM_CONFIG_DIR}/… des fichiers
# compose y figure. Documentation : docs/deploiement.md.
#
# Les env_file, lus par Compose sur le poste, n'en font pas partie. TLS_MODE=custom : fichiers de
# compose/tls/custom.yml en plus (CONFIG_MONTEE_CUSTOM). La CA facultative, montée par gitlab-runner et
# sonarqube (compose/tls/gitlab/custom.yml, compose/tls/sonarqube/custom.yml), a sa propre copie et sa
# propre empreinte (PLATFORM_CA_DIR) : un autre changement de config ne recrée pas ces services, et
# seul ca.pem est copié (jamais une clé de CA déposée à côté).
readonly CONFIG_MONTEE=(loki/loki-config.yaml promtail/promtail-config.yaml grafana/provisioning
  grafana/role home oauth2-proxy sonarqube-sso)
# Service qui monte chaque élément de CONFIG_MONTEE et le lit à son démarrage : en local, le montage
# pointe directement sur config/ et `up` ne le recrée pas après une modification (appliquer_config de
# scripts/instance.sh)
declare -rA SERVICE_CONFIG=([loki/loki-config.yaml]=loki [promtail/promtail-config.yaml]=promtail
  [grafana/provisioning]=grafana [grafana/role]=grafana-role [home]=home [oauth2-proxy]=oauth2-proxy
  [sonarqube-sso]=sonarqube-sso)
# Montés par traefik en TLS_MODE=custom (rechargés par make reload-certs)
readonly CONFIG_MONTEE_CUSTOM=(traefik/tls-custom.yml certs/cert.pem certs/key.pem)
readonly CA_CUSTOM=config/certs/ca/ca.pem
