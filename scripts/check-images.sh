#!/usr/bin/env bash
# Contrôle d'épinglage des images : deux instances installées à des dates différentes doivent être
# identiques (procédure de montée de version : docs/montee-de-version.md).
#
# Usage : scripts/check-images.sh
#   - chaque image compose : <dépôt>:${<NOM>_VERSION:-<tag>}, défaut versionné et identique à envs/.env.example ;
#   - images lancées par les scripts : variables *_IMAGE à tag versionné ou digest ;
#   - images des pipelines GitLab versionnés (*.gitlab-ci.yml) : tag versionné ou digest ;
#   - aucun tag latest explicite (compose, scripts, Makefile, envs/.env.example, .github/) ;
#   - instances locales (envs/*.env, non versionnés) : aucune version vide ou latest.
#
# Bash, git et outils POSIX uniquement (aucun Docker) : lancé par `make verify`, `make check-images` et la
# CI GitHub Actions. En CI, seuls les fichiers versionnés existent : les instances restent couvertes par
# `make verify` et `make check-env`.
# Code de sortie : 0 si tout est épinglé, 1 sinon.
set -euo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

images_ko=0
nb_images=0
ko() { echo "    ✖ $*"; images_ko=1; }

# Fichiers versionnés ou nouveaux (non ignorés) correspondant aux chemins donnés
fichiers() { git ls-files --cached --others --exclude-standard -- "$@" | sort -u; }

# Tag versionné : contient une version majeure.mineure (refuse latest, 1, 17, lts, alpine…) ou un digest
tag_versionne() { [[ "$1" =~ [0-9]+\.[0-9]+ || "$1" == *@sha256:* ]]; }
# Référence d'image complète (<dépôt>:<tag> ou <dépôt>[:<tag>]@sha256:…)
image_versionnee() {
  local nom="${1##*/}"
  [[ "$nom" == *@sha256:* ]] || { [[ "$nom" == *:* ]] && tag_versionne "${nom#*:}"; }
}

# 1. Images compose : <dépôt>:${<NOM>_VERSION:-<tag>}, défaut identique à envs/.env.example
if [[ -f compose.yml ]]; then
  if [[ ! -f envs/.env.example ]]; then
    ko "envs/.env.example introuvable : défauts des images compose non vérifiables"
  else
    motif_image='^[[:space:]]*image:[[:space:]]*[^[:space:]$]+:\$\{([A-Z][A-Z0-9_]*_VERSION):-([^}]*)\}[[:space:]]*$'
    while IFS=: read -r fichier num ligne; do
      nb_images=$((nb_images + 1))
      if [[ ! "$ligne" =~ $motif_image ]]; then
        ko "$fichier:$num : image non paramétrée (attendu : <dépôt>:\${<NOM>_VERSION:-<tag>})"
        continue
      fi
      var="${BASH_REMATCH[1]}" defaut="${BASH_REMATCH[2]}"
      tag_versionne "$defaut" || ko "$fichier:$num : défaut de $var non versionné ($defaut)"
      doc="$(sed -nE "s/^#?${var}=[\"']?([^\"']*)[\"']?[[:space:]]*\$/\1/p" envs/.env.example | head -n1)"
      [[ "$doc" == "$defaut" ]] || ko "$var : défaut compose ($defaut) ≠ envs/.env.example (${doc:-absent})"
    done < <(fichiers compose.yml 'compose/*.yml' | xargs -r grep -snHE '^[[:space:]]*image:' || true)
    ((nb_images)) || ko "aucune image lue dans les fichiers compose (grep indisponible ?)"
  fi
fi

# 2. Images lancées par les scripts : variables *_IMAGE à tag versionné ou digest
while IFS=: read -r fichier num ligne; do
  nb_images=$((nb_images + 1))
  valeur="${ligne#*=}" valeur="${valeur//[\"\']/}"
  image_versionnee "$valeur" || ko "$fichier:$num : image non versionnée ($valeur)"
done < <(fichiers '*.sh' | xargs -r grep -snHE '^[[:space:]]*(readonly[[:space:]]+)?[A-Z][A-Z0-9_]*_IMAGE=' || true)

# 3. Pipelines GitLab versionnés : `image: <réf>` ou `image:` suivi de `name: <réf>`
#    (une référence contenant une variable n'est pas vérifiable : refusée)
# shellcheck disable=SC2016 # programme awk : $ littéraux
while IFS=: read -r fichier num ref; do
  nb_images=$((nb_images + 1))
  if [[ "$ref" == *'$'* ]] || ! image_versionnee "$ref"; then
    ko "$fichier:$num : image de pipeline non versionnée ($ref)"
  fi
done < <(fichiers '*.gitlab-ci.yml' | xargs -r awk '
  FNR == 1 { attente = 0 }
  /^[[:space:]]*#/ { next }
  { ligne = $0; sub(/[[:space:]]+#.*$/, "", ligne) }
  attente && match(ligne, /^[[:space:]]*name:[[:space:]]*/) {
    ref = substr(ligne, RLENGTH + 1); gsub(/["\047[:space:]]/, "", ref)
    print FILENAME ":" FNR ":" ref; attente = 0; next
  }
  match(ligne, /^[[:space:]]*(- )?image:[[:space:]]*/) {
    ref = substr(ligne, RLENGTH + 1); gsub(/["\047[:space:]]/, "", ref)
    if (ref == "") attente = 1; else print FILENAME ":" FNR ":" ref
  }
')

# 4. Aucun tag latest explicite (motif sans le littéral, pour ne pas détecter ce script). Décision sur la
#    sortie de grep, pas sur le code de xargs (123 dès qu'un lot ne correspond pas)
latest="$(fichiers compose.yml compose scripts Makefile envs/.env.example .github \
  | xargs -r grep -snHE '[:]latest([^A-Za-z0-9_.-]|$)' || true)"
if [[ -n "$latest" ]]; then
  echo "$latest"
  ko "tag latest explicite (voir ci-dessus)"
fi

# 5. Instances locales : même règle que la cible check-env du Makefile (à garder synchronisées)
shopt -s nullglob
for f in envs/*.env; do
  if grep -nHE '^[A-Z0-9_]+_VERSION=["'"'"']?(latest)?["'"'"']?[[:space:]]*$' "$f"; then
    ko "$f : version vide ou latest (voir ci-dessus)"
  fi
done
shopt -u nullglob

if ((images_ko)); then exit 1; fi
echo "    ✔ $nb_images image(s)"
