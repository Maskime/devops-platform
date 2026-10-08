#!/usr/bin/env bash
# Valide la configuration Loki d'une instance : scripts/check-loki-config.sh envs/<env>.env
# Appelé par `make verify` (chaque environnement) et `make check-env` (avant tout déploiement).
#   - Loki lancé avec -config.expand-env=true (sinon LOKI_RETENTION_PERIOD n'est pas substituée) ;
#   - LOKI_RETENTION_PERIOD vide (défaut), 0 (rétention illimitée) ou d'au moins 24h : Loki accepte
#     une durée plus courte sans erreur, ni à -verify-config ni au démarrage ;
#   - -verify-config avec l'image et la valeur résolues par compose (variable du shell prioritaire),
#     sur un moteur Docker LOCAL, quels que soient le contexte courant et DOCKER_HOST : contexte courant
#     s'il est local (unix://, npipe:// : Docker Desktop, Colima…) et joignable, sinon `default`. Sans
#     moteur local joignable, contrôles statiques seuls et avertissement (docs/deploiement.md#prérequis).
# Lecture seule : télécharge au besoin l'image Loki, ne crée ni conteneur durable, ni réseau, ni volume.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"

env_file="${1:?Usage : $0 envs/<env>.env}"
[[ -f "$env_file" ]] || { echo "Fichier introuvable : $env_file" >&2; exit 1; }

# Durée au format Loki (744h, 31d, 1w2d, 0s…) convertie en secondes ; échoue si le format est invalide
duree_en_secondes() {
  local reste="$1" total=0 n u
  [[ "$reste" == 0 ]] && { echo 0; return 0; }
  [[ "$reste" =~ ^([0-9]+(y|w|d|h|ms|m|s))+$ ]] || return 1
  while [[ "$reste" =~ ^([0-9]+)(y|w|d|h|ms|m|s)(.*)$ ]]; do
    n=$((10#${BASH_REMATCH[1]})) u="${BASH_REMATCH[2]}" reste="${BASH_REMATCH[3]}"
    case "$u" in
      y) total=$((total + n * 31536000)) ;;
      w) total=$((total + n * 604800)) ;;
      d) total=$((total + n * 86400)) ;;
      h) total=$((total + n * 3600)) ;;
      m) total=$((total + n * 60)) ;;
      s) total=$((total + n)) ;;
      ms) total=$((total + n / 1000)) ;;
    esac
  done
  echo "$total"
}

# Service loki tel que compose le résout pour cette instance (JSON : chaînes toujours entre guillemets)
if ! json="$(docker compose --env-file "$env_file" -f compose.yml config --format json loki 2>&1)"; then
  echo "$json" >&2
  echo "$env_file : configuration compose invalide" >&2; exit 1
fi
image="$(sed -nE 's/^ *"image": *"([^"]*)".*/\1/p' <<<"$json" | head -n1)"
retention="$(sed -nE 's/^ *"LOKI_RETENTION_PERIOD": *"([^"]*)".*/\1/p' <<<"$json" | head -n1)"
[[ -n "$image" ]] || { echo "$env_file : image du service loki introuvable" >&2; exit 1; }

if ! grep -qE '^ *"-config\.expand-env=true",?$' <<<"$json"; then
  echo "$env_file : loki doit être lancé avec -config.expand-env=true (compose/observability.yml)" >&2; exit 1
fi

if [[ -n "$retention" ]]; then
  if ! secondes="$(duree_en_secondes "$retention")"; then
    echo "$env_file : LOKI_RETENTION_PERIOD invalide ($retention) : durée attendue, ex. 744h, 31d, 0s" >&2; exit 1
  fi
  if ((secondes > 0 && secondes < 86400)); then
    echo "$env_file : LOKI_RETENTION_PERIOD trop courte ($retention) : minimum 24h, ou 0s pour une rétention illimitée" >&2
    exit 1
  fi
fi

# Moteur local : le contexte `default` est construit à partir de DOCKER_HOST (et des variables TLS
# associées), qui primeraient aussi sur tout contexte : elles sont retirées pour ce contrôle.
unset DOCKER_HOST DOCKER_TLS_VERIFY DOCKER_CERT_PATH
# Candidats : contexte courant s'il est local, puis `default` ; premier moteur joignable retenu.
candidats=(default)
courant="$(docker context show 2>/dev/null || true)"
if [[ -n "$courant" && "$courant" != default ]] \
  && [[ "$(docker context inspect -f '{{.Endpoints.docker.Host}}' "$courant" 2>/dev/null || true)" =~ ^(unix|npipe):// ]]; then
  candidats=("$courant" default)
fi
contexte=""
for c in "${candidats[@]}"; do
  if docker --context "$c" version --format '{{.Server.Version}}' >/dev/null 2>&1; then contexte="$c"; break; fi
done
if [[ -z "$contexte" ]]; then
  echo "Attention : $env_file : aucun moteur Docker local joignable (contextes ${candidats[*]}) ; -verify-config" >&2
  echo "  de Loki non exécuté, contrôles statiques seuls (docs/deploiement.md#prérequis)." >&2
  echo "$env_file : configuration Loki contrôlée statiquement ($image, rétention ${retention:-par défaut de loki-config.yaml})"
  exit 0
fi

if ! sortie="$(docker --context "$contexte" run --rm -e LOKI_RETENTION_PERIOD="$retention" -v "$ROOT/config/loki:/etc/loki:ro" \
    "$image" -config.file=/etc/loki/loki-config.yaml -config.expand-env=true -verify-config 2>&1)"; then
  echo "$sortie" >&2
  echo "$env_file : configuration Loki refusée par $image (-verify-config)" >&2; exit 1
fi
echo "$env_file : configuration Loki valide ($image sur le moteur local $contexte, rétention ${retention:-par défaut de loki-config.yaml})"
