#!/usr/bin/env bash
# Liste les épopées ouvertes dont toutes les user stories (sub-issues) sont fermées,
# c'est-à-dire prêtes à être clôturées par l'opérateur. N'affiche rien s'il n'y en a aucune.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/gh-api.sh" GET "/issues?labels=epic&state=open&per_page=100" | python3 -c '
import json, sys
for e in json.load(sys.stdin):
    s = e.get("sub_issues_summary") or {}
    if s.get("total") and s["completed"] == s["total"]:
        print("#{} {} — {}/{} US terminées : à clôturer".format(e["number"], e["title"], s["completed"], s["total"]))
'
