#!/usr/bin/env bash
# Contrôle de la ref d'un run du workflow deploy (.github/workflows/deploy.yml, docs/deploiement-github.md),
# avant tout contact avec le serveur :
#   - refs/heads/main : action status uniquement (le deploy ne vise que des tags) ;
#   - refs/tags/<tag> : tag de version v<X>.<Y>.<Z> pointant sur <sha>, commit atteignable depuis main
#     (origin/main : checkout avec tout l'historique, fetch-depth: 0) ; action deploy ou status ;
#   - toute autre ref (autre branche, tag hors format) : refusée.
# Erreurs émises en annotations GitHub (::error::). Lecture seule : aucun effet sur le dépôt.
#
# Usage : scripts/ci/controler-ref.sh <ref> <action : deploy|status> <sha du commit du run>
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/version.sh
source "$ROOT/scripts/lib/version.sh"

refus() { echo "::error::$*"; exit 1; }

(($# == 3)) || refus "usage : $0 <ref> <deploy|status> <sha>"
ref="$1" action="$2" sha="$3"
case "$action" in
  deploy | status) ;;
  *) refus "Action non autorisée : $action (attendu : deploy ou status)." ;;
esac
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || refus "SHA de commit invalide : $sha"

case "$ref" in
  refs/heads/main)
    [[ "$action" == status ]] \
      || refus "deploy refusé depuis la branche main : le deploy ne vise que des tags de version (relancer le run depuis un tag vX.Y.Z, ou pousser un tag)."
    echo "Ref : branche main, action status."
    ;;
  refs/heads/*)
    refus "Run lancé depuis la branche ${ref#refs/heads/} : seuls main (status) et les tags de version vX.Y.Z sont acceptés."
    ;;
  refs/tags/*)
    tag="${ref#refs/tags/}"
    [[ "$tag" =~ $SEMVER_REGEX ]] \
      || refus "Tag « $tag » refusé : tag de version v<X>.<Y>.<Z> attendu (sans zéro initial ni suffixe)."
    cible="$(git rev-parse -q --verify "refs/tags/$tag^{commit}" 2>/dev/null)" \
      || refus "Tag $tag absent du checkout."
    [[ "$cible" == "$sha" ]] || refus "Tag $tag : commit $cible, différent du commit du run ($sha)."
    git rev-parse -q --verify refs/remotes/origin/main >/dev/null \
      || refus "origin/main absente du checkout (actions/checkout avec fetch-depth: 0 attendu)."
    git merge-base --is-ancestor "$sha" refs/remotes/origin/main \
      || refus "Tag $tag refusé : son commit ($sha) n'est pas atteignable depuis main (tag posé hors de main)."
    echo "Ref : tag $tag, commit atteignable depuis main, action $action."
    ;;
  *)
    refus "Ref non autorisée : $ref (attendu : refs/heads/main ou refs/tags/vX.Y.Z)."
    ;;
esac
