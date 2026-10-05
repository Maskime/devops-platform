#!/usr/bin/env bash
# Vérifications statiques du repo (`make verify`, étape 5 du workflow d'implémentation).
# Les linters tournent dans des conteneurs : rien à installer sur l'hôte hormis Docker.
# Code de sortie non nul si au moins une vérification échoue.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
failed=0

# Images des linters : tag versionné ou digest (contrôlé par la section « images épinglées »).
# yamllint : aucun tag versionné publié, le tag 1 est figé par son digest.
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.11.0"
YAMLLINT_IMAGE="cytopia/yamllint:1@sha256:596fb19eb71e55ba5b2fa56d8c18a615ec82adc8d3bf2d73918cb78c8f3240fb"

section() { echo; echo "==> $*"; }
ko() { echo "    ✖ $*"; failed=1; }
ok() { echo "    ✔ $*"; }

# 1. shellcheck sur tous les scripts versionnés ou nouveaux
section "shellcheck"
mapfile -t sh_files < <(git ls-files --cached --others --exclude-standard '*.sh')
if ((${#sh_files[@]})); then
  if docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x "${sh_files[@]}"; then
    ok "${#sh_files[@]} script(s)"
  else
    ko "shellcheck"
  fi
else
  ok "aucun script"
fi

# 2. yamllint (config relaxed : on vise les erreurs de syntaxe, pas le style)
section "yamllint"
mapfile -t yml_files < <(git ls-files --cached --others --exclude-standard '*.yml' '*.yaml')
if ((${#yml_files[@]})); then
  if docker run --rm -v "$ROOT:/data:ro" -w /data "$YAMLLINT_IMAGE" \
      -d "{extends: relaxed, rules: {line-length: disable}}" "${yml_files[@]}"; then
    ok "${#yml_files[@]} fichier(s)"
  else
    ko "yamllint"
  fi
else
  ok "aucun fichier YAML"
fi

# 3. docker compose config pour chaque environnement (dont l'exemple)
section "docker compose config"
if [[ -f compose.yml ]]; then
  shopt -s nullglob dotglob
  env_files=(envs/*.env envs/.env.example)
  shopt -u dotglob
  ((${#env_files[@]})) || ko "aucun fichier dans envs/"
  for f in "${env_files[@]}"; do
    if docker compose --env-file "$f" -f compose.yml config -q; then ok "$f"; else ko "$f"; fi
  done
else
  ok "pas encore de compose.yml"
fi

# 4. Chaque variable interpolée par compose est documentée dans envs/.env.example
#    ($${…} = échappement compose, ignoré ; minuscules = variables shell des healthchecks)
section "variables documentées"
if [[ -f compose.yml && -f envs/.env.example ]]; then
  mapfile -t compose_vars < <(grep -ohE '(^|[^$])\$\{[A-Z][A-Z0-9_]*' compose.yml compose/*.yml \
    | sed -E 's/.*\$\{//' | sort -u)
  missing=0
  for v in "${compose_vars[@]}"; do
    grep -qE "^#?${v}=" envs/.env.example || { ko "$v absente de envs/.env.example"; missing=1; }
  done
  ((missing)) || ok "${#compose_vars[@]} variable(s)"
else
  ok "pas encore de compose.yml"
fi

# 5. Images épinglées : deux instances installées à des dates différentes doivent être identiques
#    (procédure de montée de version : docs/montee-de-version.md)
section "images épinglées"
# Tag versionné : contient une version majeure.mineure (refuse latest, 1, 17, lts, alpine…) ou un digest
tag_versionne() { [[ "$1" =~ [0-9]+\.[0-9]+ || "$1" == *@sha256:* ]]; }
# Référence d'image complète (<dépôt>:<tag> ou <dépôt>[:<tag>]@sha256:…)
image_versionnee() {
  local nom="${1##*/}"
  [[ "$nom" == *@sha256:* ]] || { [[ "$nom" == *:* ]] && tag_versionne "${nom#*:}"; }
}
images_ko=0
nb_images=0
if [[ -f compose.yml ]]; then
  # Chaque image compose : <dépôt>:${<NOM>_VERSION:-<tag>}, défaut identique à envs/.env.example
  motif_image='^[[:space:]]*image:[[:space:]]*[^[:space:]$]+:\$\{([A-Z][A-Z0-9_]*_VERSION):-([^}]*)\}[[:space:]]*$'
  while IFS=: read -r fichier num ligne; do
    nb_images=$((nb_images + 1))
    if [[ ! "$ligne" =~ $motif_image ]]; then
      ko "$fichier:$num : image non paramétrée (attendu : <dépôt>:\${<NOM>_VERSION:-<tag>})"
      images_ko=1; continue
    fi
    var="${BASH_REMATCH[1]}" defaut="${BASH_REMATCH[2]}"
    if ! tag_versionne "$defaut"; then
      ko "$fichier:$num : défaut de $var non versionné ($defaut)"; images_ko=1
    fi
    doc="$(sed -nE "s/^#?${var}=[\"']?([^\"']*)[\"']?[[:space:]]*\$/\1/p" envs/.env.example | head -n1)"
    if [[ "$doc" != "$defaut" ]]; then
      ko "$var : défaut compose ($defaut) ≠ envs/.env.example (${doc:-absent})"; images_ko=1
    fi
  done < <(grep -nE '^[[:space:]]*image:' compose.yml compose/*.yml)
fi
# Images lancées par les scripts : variables *_IMAGE à tag versionné ou digest
while IFS=: read -r fichier num ligne; do
  nb_images=$((nb_images + 1))
  valeur="${ligne#*=}" valeur="${valeur//[\"\']/}"
  image_versionnee "$valeur" || { ko "$fichier:$num : image non versionnée ($valeur)"; images_ko=1; }
done < <(git ls-files --cached --others --exclude-standard '*.sh' \
  | xargs -r grep -nE '^[[:space:]]*(readonly[[:space:]]+)?[A-Z][A-Z0-9_]*_IMAGE=' /dev/null)
# Aucun tag latest explicite (motif sans le littéral, pour ne pas détecter ce script)
if git ls-files --cached --others --exclude-standard compose.yml compose scripts Makefile \
    | xargs -r grep -nE '[:]latest([^A-Za-z0-9_.-]|$)' /dev/null; then
  ko "tag latest explicite (voir ci-dessus)"; images_ko=1
fi
# Instances locales : même règle que la cible check-env du Makefile (à garder synchronisées)
shopt -s nullglob
for f in envs/*.env; do
  if grep -nHE '^[A-Z0-9_]+_VERSION=["'"'"']?(latest)?["'"'"']?[[:space:]]*$' "$f"; then
    ko "$f : version vide ou latest (voir ci-dessus)"; images_ko=1
  fi
done
shopt -u nullglob
((images_ko)) || ok "$nb_images image(s)"

# 6. Secrets : délégué au garde-fou du repo (fichiers suivis et non suivis non ignorés)
section "secrets"
if scripts/check-secrets.sh; then ok "rien à signaler"; else ko "secrets (voir ci-dessus)"; fi

echo
if ((failed)); then echo "Vérification : ÉCHEC"; exit 1; fi
echo "Vérification : OK"
