#!/usr/bin/env bash
# Affiche les labels de priorité (high, moderate, low) avec leur description GitHub, puis chaque issue
# ouverte dont le seul label est `backlog` : numéro, titre, URL et corps.
# N'affiche aucune issue s'il n'y a rien à catégoriser.
set -euo pipefail

DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
API="$DIR/../../github/scripts/gh-api.sh"

echo "## Labels de priorité"
for label in high moderate low; do
  "$API" GET "/labels/$label" | python3 -c '
import json, sys
l = json.load(sys.stdin)
print("- {} : {}".format(l["name"], l.get("description") or "(sans description)"))
'
done

echo
echo "## Issues à catégoriser"
page=1
while :; do
  json="$("$API" GET "/issues?labels=backlog&state=open&per_page=100&page=$page")"
  count="$(python3 -c 'import json, sys; print(len(json.load(sys.stdin)))' <<<"$json")"
  [[ "$count" -gt 0 ]] || break
  python3 -c '
import json, sys
for i in json.load(sys.stdin):
    if "pull_request" in i or [l["name"] for l in i["labels"]] != ["backlog"]:
        continue
    print("\n### #{} {}\n{}\n\n{}".format(i["number"], i["title"], i["html_url"], (i["body"] or "").strip()))
' <<<"$json"
  page=$((page + 1))
done
