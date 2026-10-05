#!/usr/bin/env bash
# Valide la configuration Loki d'une instance : scripts/check-loki-config.sh envs/<env>.env
# Appelé par `make verify` (chaque environnement) et `make check-env` (avant tout déploiement).
#   - Loki lancé avec -config.expand-env=true (sinon LOKI_RETENTION_PERIOD n'est pas substituée) ;
#   - LOKI_RETENTION_PERIOD vide (défaut), 0 (rétention illimitée) ou d'au moins 24h : Loki accepte
#     une durée plus courte sans erreur, ni à -verify-config ni au démarrage ;
#   - -verify-config avec l'image et la valeur résolues par compose (variable du shell prioritaire).
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

if ! sortie="$(docker run --rm -e LOKI_RETENTION_PERIOD="$retention" -v "$ROOT/config/loki:/etc/loki:ro" \
    "$image" -config.file=/etc/loki/loki-config.yaml -config.expand-env=true -verify-config 2>&1)"; then
  echo "$sortie" >&2
  echo "$env_file : configuration Loki refusée par $image (-verify-config)" >&2; exit 1
fi
echo "$env_file : configuration Loki valide ($image, rétention ${retention:-par défaut de loki-config.yaml})"
