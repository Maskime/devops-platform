#!/usr/bin/env bash
# Retrouve l'issue GitHub d'une user story à partir de son code (ex : 1-2 → « [US 1-2] … »),
# ou toutes les user stories d'une épopée à partir de son numéro (ex : 1 → « [Épopée 1] … »).
# Affiche pour chaque US : numéro, état GitHub, titre, statut dans le cycle de vie, branche et PR
# éventuelles, épopée parente, puis le corps de l'issue.
#
# Statut (du plus avancé au moins avancé) :
#   terminée  — issue fermée
#   en revue  — PR ouverte depuis une branche us/<code>-*, ou label « en-revue »
#   en cours  — branche us/<code>-* sur le remote, ou label « en-cours »
#   nouvelle  — aucun des signaux ci-dessus
set -euo pipefail

code="${1:?Usage : find-us.sh <épopée>-<us> | <épopée> (ex : 1-2 ou 1)}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

"$DIR/gh-api.sh" GET "/issues?labels=user-story&state=all&per_page=100" >"$tmp/issues.json"
if [[ "$code" != *-* ]]; then
  "$DIR/gh-api.sh" GET "/issues?labels=epic&state=all&per_page=100" >"$tmp/epics.json"
fi
"$DIR/gh-api.sh" GET "/branches?per_page=100" >"$tmp/branches.json"
"$DIR/gh-api.sh" GET "/pulls?state=open&per_page=100" >"$tmp/pulls.json"

US_CODE="$code" TMP="$tmp" python3 - <<'EOF'
import json, os, sys

code, tmp = os.environ["US_CODE"], os.environ["TMP"]
load = lambda name: json.load(open(os.path.join(tmp, name)))

def show(i):
    branch_prefix = "us/" + i["title"][4:].split("]")[0] + "-"
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

issues = load("issues.json")
if "-" in code:
    prefix = "[US " + code + "]"
    match = [i for i in issues if i["title"].startswith(prefix + " ")]
    if not match:
        sys.exit("Aucune issue ne commence par " + prefix)
    show(match[0])
else:
    prefix = "[Épopée " + code + "]"
    match = [e for e in load("epics.json") if e["title"].startswith(prefix + " ")]
    if not match:
        sys.exit("Aucune épopée ne commence par " + prefix)
    e = match[0]
    s = e.get("sub_issues_summary") or {}
    print("#{} [{}] {} — {}/{} US terminées".format(
        e["number"], e["state"], e["title"], s.get("completed", 0), s.get("total", 0)))
    members = [i for i in issues if (i.get("parent_issue_url") or "").endswith("/issues/" + str(e["number"]))]
    members.sort(key=lambda i: [int(x) for x in i["title"][4:].split("]")[0].split("-")])
    for i in members:
        print("\n" + "=" * 80)
        show(i)
EOF
