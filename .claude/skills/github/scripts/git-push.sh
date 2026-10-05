#!/usr/bin/env bash
# Pousse la branche courante vers origin en injectant le token GitHub dans un en-tête HTTP
# (jamais dans l'URL du remote ni dans la config git).
# Usage : git-push.sh [arguments supplémentaires de git push]
set -euo pipefail

TOKEN_FILE="${GITHUB_TOKEN_FILE:-$HOME/.config/github/token}"
[[ -r "$TOKEN_FILE" ]] || { echo "Token introuvable : $TOKEN_FILE" >&2; exit 1; }

auth=$(printf 'x-access-token:%s' "$(cat "$TOKEN_FILE")" | base64 -w0)
git -c http.extraHeader="Authorization: Basic $auth" push -u origin "$(git branch --show-current)" "$@"
