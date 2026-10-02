#!/usr/bin/env bash
# Appel de l'API REST GitHub sur le repo courant, sans le CLI `gh`.
# Usage : gh-api.sh <METHOD> <chemin relatif au repo | URL absolue> [corps JSON]
#   gh-api.sh GET  /issues/12
#   gh-api.sh POST /issues '{"title":"…"}'
# Le token est lu depuis $GITHUB_TOKEN_FILE (défaut : ~/.config/github/token).
set -euo pipefail

REPO="${GITHUB_REPO:-Maskime/devops-platform}"
TOKEN_FILE="${GITHUB_TOKEN_FILE:-$HOME/.config/github/token}"
[[ -r "$TOKEN_FILE" ]] || { echo "Token introuvable : $TOKEN_FILE" >&2; exit 1; }

method="$1" path="$2" body="${3:-}"
[[ "$path" == http* ]] && url="$path" || url="https://api.github.com/repos/$REPO$path"

args=(-sS --fail-with-body -X "$method"
  -H "Authorization: Bearer $(cat "$TOKEN_FILE")"
  -H "Accept: application/vnd.github+json"
  -H "X-GitHub-Api-Version: 2022-11-28")
[[ -n "$body" ]] && args+=(-H "Content-Type: application/json" --data "$body")

curl "${args[@]}" "$url"
