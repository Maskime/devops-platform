#!/usr/bin/env bash
# Retrouve l'issue GitHub d'une user story à partir de son code (ex : 1-2 → « [US 1-2] … »).
# Affiche : numéro, état, titre, milestone, puis le corps de l'issue.
set -euo pipefail

code="${1:?Usage : find-us.sh <épopée>-<us> (ex : 1-2)}"
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

"$DIR/gh-api.sh" GET "/issues?labels=user-story&state=all&per_page=100" | CODE="$code" python3 -c '
import json, os, sys
prefix = "[US " + os.environ["CODE"] + "]"
match = [i for i in json.load(sys.stdin) if i["title"].startswith(prefix + " ")]
if not match:
    sys.exit("Aucune issue ne commence par " + prefix)
i = match[0]
milestone = (i.get("milestone") or {}).get("title", "-")
print("#{} [{}] {}".format(i["number"], i["state"], i["title"]))
print("Milestone : " + milestone)
print()
print(i["body"])
'
