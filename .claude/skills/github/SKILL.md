---
name: github
description: Accès à GitHub sans le CLI gh (API REST, push authentifié) et suivi des épopées et user stories du repo. À utiliser pour toute lecture ou écriture GitHub (issues, labels, PR, commentaires) et pour pousser une branche.
user-invocable: false
---

Le CLI `gh` n'est pas utilisé dans ce repo. Le token est lu dans `~/.config/github/token` (ou
`$GITHUB_TOKEN_FILE`) par les scripts ci-dessous : ne l'affiche jamais, ne le passe jamais en argument
ni dans une URL, ne le copie dans aucun fichier.

Les scripts sont dans `.claude/skills/github/scripts/` et se lancent depuis la racine du repo (ou d'un
de ses worktrees).

## API REST et push

| Script | Usage |
|---|---|
| `gh-api.sh <METHOD> <chemin\|URL> [corps JSON]` | Appel de l'API REST sur `Maskime/devops-platform` (`$GITHUB_REPO` pour un autre repo). Chemin relatif au repo (`/issues/12`) ou URL absolue (`https://api.github.com/user`). |
| `git-push.sh [args git push]` | Pousse la branche courante vers `origin` (avec `-u`), token injecté par en-tête HTTP. |

Pour un corps JSON contenant du texte libre (corps d'issue, de PR, commentaire), construis-le avec
`python3 -c 'import json…'` pour un échappement correct. Pour modifier un corps d'issue : lis-le
(`GET /issues/<num>`), modifie-le, puis `PATCH /issues/<num> '{"body":"…"}'`.

## Suivi des épopées et user stories

GitHub est la source de vérité : épopées (label `epic`, `[Épopée N] …`), user stories (sub-issues,
label `user-story`, `[US N-X] …`), dette (label `backlog`).

| Script | Usage |
|---|---|
| `find-us.sh <N>-<X>` | Une US : numéro, statut (nouvelle, en cours, en revue, terminée), branche, PR, épopée, puis le corps de l'issue. |
| `find-us.sh <N>` | L'épopée N puis chacune de ses US, dans l'ordre. |
| `us-status.sh <num> <en-cours\|en-revue\|aucun>` | Positionne les labels de statut d'une US (idempotent ; `en-cours` assigne aussi l'issue). |
| `check-epics.sh` | Liste les épopées ouvertes dont toutes les US sont terminées (à clôturer par l'opérateur). |

Statut calculé par `find-us.sh` : **terminée** si l'issue est fermée ; **en revue** si une PR est
ouverte depuis `us/<N>-<X>-*` ou label `en-revue` ; **en cours** si la branche existe sur le remote ou
label `en-cours` ; **nouvelle** sinon.
