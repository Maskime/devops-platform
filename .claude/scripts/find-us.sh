#!/usr/bin/env bash
# Retrouve l'issue GitHub d'une user story à partir de son code (ex : 1-2 → « [US 1-2] … »).
# Affiche : numéro, état GitHub, titre, statut dans le cycle de vie, branche et PR éventuelles,
# épopée parente, puis le corps de l'issue.
#
# Statut (du plus avancé au moins avancé) :
#   terminée  — issue fermée
#   en revue  — PR ouverte depuis une branche us/<code>-*, ou label « en-revue »
#   en cours  — branche us/<code>-* sur le remote, ou label « en-cours »
#   nouvelle  — aucun des signaux ci-dessus
set -euo pipefail

code="${1:?Usage : find-us.sh <épopée>-<us> (ex : 1-2)}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$DIR/gh-api.sh" GET "/issues?labels=user-story&state=all&per_page=100" >"$tmp/issues.json"
"$DIR/gh-api.sh" GET "/branches?per_page=100" >"$tmp/branches.json"
"$DIR/gh-api.sh" GET "/pulls?state=open&per_page=100" >"$tmp/pulls.json"

US_CODE="$code" TMP="$tmp" python3 - <<'EOF'
import json, os, sys

code, tmp = os.environ["US_CODE"], os.environ["TMP"]
load = lambda name: json.load(open(os.path.join(tmp, name)))

prefix = "[US " + code + "]"
match = [i for i in load("issues.json") if i["title"].startswith(prefix + " ")]
if not match:
    sys.exit("Aucune issue ne commence par " + prefix)
i = match[0]

branch_prefix = "us/" + code + "-"
branches = [b["name"] for b in load("branches.json") if b["name"].startswith(branch_prefix)]
pulls = [p for p in load("pulls.json") if p["head"]["ref"].startswith(branch_prefix)]
labels = {l["name"] for l in i["labels"]}

if i["state"] == "closed":
    status = "terminée"
elif pulls or "en-revue" in labels:
    status = "en revue"
elif branches or "en-cours" in labels:
    status = "en cours"
else:
    status = "nouvelle"

milestone = (i.get("milestone") or {}).get("title", "-")
assignees = ", ".join(a["login"] for a in i["assignees"]) or "-"
print("#{} [{}] {}".format(i["number"], i["state"], i["title"]))
print("Statut : " + status)
print("Assignée à : " + assignees)
print("Branche : " + (", ".join(branches) or "-"))
print("PR : " + (", ".join("#{} {}".format(p["number"], p["html_url"]) for p in pulls) or "-"))
print("Milestone : " + milestone)
parent = i.get("parent_issue_url")
print("Épopée : " + ("#" + parent.rsplit("/", 1)[1] if parent else "-"))
print()
print(i["body"])
EOF
