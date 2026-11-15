#!/usr/bin/env bash
# Version de la plateforme : checkout du poste (ou du runner GitHub) et version inscrite sur l'hôte d'une
# instance distante (${DEPLOY_DIR}/version, scripts/instance.sh). Partagée par scripts/instance.sh et
# scripts/ci/controler-ref.sh. Documentation : docs/deploiement.md, « Version déployée ».
# Fichier à sourcer : ne modifie pas les options du shell appelant.

# Tag de version publiée : v<X>.<Y>.<Z>, sans zéro initial ni suffixe
# shellcheck disable=SC2034 # utilisé par les scripts qui sourcent ce fichier
SEMVER_REGEX='^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$'

# Version du checkout de <répertoire> : VERSION_DEPLOYEE si elle est fournie (tag déployé par le workflow,
# validé par scripts/ci/controler-ref.sh), sinon `git describe` (vX.Y.Z, vX.Y.Z-N-g<sha>, suffixe -dirty),
# sinon « inconnue » (hors dépôt git, aucun tag de version dans l'historique)
version_locale() { # <répertoire>
  local v
  if [[ -n "${VERSION_DEPLOYEE:-}" ]]; then
    printf '%s' "$VERSION_DEPLOYEE"
    return 0
  fi
  v="$(git -C "$1" describe --tags --match 'v*' --dirty 2>/dev/null || true)"
  if [[ -n "$v" ]] && version_base "$v" >/dev/null; then printf '%s' "$v"; else printf inconnue; fi
}

# « X Y Z » de la version publiée sur laquelle repose <version> (vX.Y.Z, vX.Y.Z-N-g<sha>, -dirty) ;
# code 1 si <version> n'a pas cette forme
version_base() { # <version>
  local v="${1%-dirty}"
  if [[ "$v" =~ ^(v[^-]+)-[0-9]+-g[0-9a-f]+$ ]]; then v="${BASH_REMATCH[1]}"; fi
  [[ "$v" =~ $SEMVER_REGEX ]] || return 1
  printf '%s %s %s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
}

# Compare les versions publiées de base de <a> et <b> (X.Y.Z seuls : le nombre de commits d'un
# `git describe` n'a de sens que sur une même lignée). Affiche -1, 0 ou 1 ; code 1 si l'une des deux
# n'est pas comparable (inconnue, absente, autre forme).
version_comparer() { # <a> <b>
  local a b i
  a="$(version_base "$1")" || return 1
  b="$(version_base "$2")" || return 1
  read -r -a a <<<"$a"
  read -r -a b <<<"$b"
  for i in 0 1 2; do
    if ((a[i] < b[i])); then echo -1; return 0; fi
    if ((a[i] > b[i])); then echo 1; return 0; fi
  done
  echo 0
}
