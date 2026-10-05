#!/usr/bin/env bash
# Positionne le statut d'une user story via ses labels (idempotent).
# Usage : us-status.sh <numéro d'issue> <en-cours|en-revue|aucun>
#   en-cours — pose « en-cours », retire « en-revue », assigne l'issue au propriétaire du token
#   en-revue — pose « en-revue », retire « en-cours »
#   aucun    — retire les deux labels
# L'état « terminée » correspond à la fermeture de l'issue (« Closes #<num> » au merge de la PR).
# Les labels sont créés sur le repo s'ils n'existent pas encore.
set -euo pipefail

USAGE="Usage : us-status.sh <numéro de l'issue> <en-cours|en-revue|aucun>"
(($# == 2)) || { echo "$USAGE" >&2; exit 1; }
num="$1" status="$2"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
api() { "$DIR/gh-api.sh" "$@" >/dev/null; }

declare -A COLORS=([en-cours]=fbca04 [en-revue]=0e8a16)
declare -A DESCRIPTIONS=([en-cours]="User story en cours d'implémentation" [en-revue]="User story en attente de merge de sa PR")

ensure_label() {
  api GET "/labels/$1" 2>/dev/null && return
  api POST /labels "{\"name\":\"$1\",\"color\":\"${COLORS[$1]}\",\"description\":\"${DESCRIPTIONS[$1]}\"}"
  echo "Label « $1 » créé."
}

add_label() {
  ensure_label "$1"
  api POST "/issues/$num/labels" "{\"labels\":[\"$1\"]}"
}

remove_label() {
  # 404 si le label n'est pas posé : rien à faire
  api DELETE "/issues/$num/labels/$1" 2>/dev/null || true
}

case "$status" in
  en-cours)
    add_label en-cours
    remove_label en-revue
    login="$("$DIR/gh-api.sh" GET https://api.github.com/user | python3 -c 'import json,sys; print(json.load(sys.stdin)["login"])')"
    api POST "/issues/$num/assignees" "{\"assignees\":[\"$login\"]}"
    ;;
  en-revue)
    add_label en-revue
    remove_label en-cours
    ;;
  aucun)
    remove_label en-cours
    remove_label en-revue
    ;;
  *)
    echo "Statut inconnu : $status (attendu : en-cours, en-revue ou aucun)" >&2
    exit 1
    ;;
esac

echo "Issue #$num : statut « $status »."
