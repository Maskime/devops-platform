#!/usr/bin/env bash
# Vérifications statiques du repo (`make verify`, étape 5 du workflow d'implémentation).
# Les linters tournent dans des conteneurs : rien à installer sur l'hôte hormis Docker.
# Code de sortie non nul si au moins une vérification échoue.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
failed=0

section() { echo; echo "==> $*"; }
ko() { echo "    ✖ $*"; failed=1; }
ok() { echo "    ✔ $*"; }

# 1. shellcheck sur tous les scripts versionnés ou nouveaux
section "shellcheck"
mapfile -t sh_files < <(git ls-files --cached --others --exclude-standard '*.sh')
if ((${#sh_files[@]})); then
  if docker run --rm -v "$ROOT:/mnt:ro" -w /mnt koalaman/shellcheck:v0.11.0 -x "${sh_files[@]}"; then
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
  if docker run --rm -v "$ROOT:/data:ro" -w /data cytopia/yamllint:1 \
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

# 5. Noms de conteneurs : Compose les attribue, les scripts ciblent les services
#    (`docker compose exec <service>`). Commentaires ignorés ; `docker run` et `docker inspect <id>` admis.
section "noms de conteneurs"
if [[ -f compose.yml ]] && grep -nE '^[[:space:]]*container_name:' compose.yml compose/*.yml; then
  ko "nom de conteneur fixé dans un fichier compose (voir ci-dessus)"
else
  ok "aucun nom fixé dans les fichiers compose"
fi
mapfile -t cible_files < <(git ls-files --cached --others --exclude-standard 'scripts/*.sh' Makefile)
if ((${#cible_files[@]})) && grep -nE '^[^#]*\bdocker (container )?(exec|logs|cp|restart|stop|start|kill|rm)\b' \
    "${cible_files[@]}"; then
  ko "conteneur ciblé par son nom (voir ci-dessus) : passer par docker compose <commande> <service>"
else
  ok "${#cible_files[@]} fichier(s) (scripts, Makefile) : services ciblés par compose"
fi

# 6. Secrets : délégué au garde-fou du repo (fichiers suivis et non suivis non ignorés)
section "secrets"
if scripts/check-secrets.sh; then ok "rien à signaler"; else ko "secrets (voir ci-dessus)"; fi

echo
if ((failed)); then echo "Vérification : ÉCHEC"; exit 1; fi
echo "Vérification : OK"
