#!/usr/bin/env bash
# Garde-fou contre les fuites de secrets (repo public).
# Reprend la partie générique de check-secrets.sh de Software Factory.
#
# Usage : scripts/check-secrets.sh [--staged | --history]
#   (défaut)   fichiers suivis et fichiers non suivis non ignorés de l'arbre de travail
#   --staged   contenu indexé uniquement (hook pre-commit)
#   --history  lignes ajoutées dans l'historique de HEAD (jetons et clés privées uniquement)
#
# Une ligne portant le marqueur « check-secrets: ignore » est exclue des contrôles de contenu.
# Les valeurs détectées ne sont jamais affichées : seuls le chemin, la ligne et le motif le sont.
# Code de sortie : 0 si rien n'est détecté, 1 sinon, 2 en cas d'usage incorrect.
set -euo pipefail

usage() { sed -n '2,12s/^# \{0,1\}//p' "$0"; }

MODE=worktree
case "${1:-}" in
  "") ;;
  --staged) MODE=staged ;;
  --history) MODE=history ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT"

# Le script contient les motifs : il est exclu du scan de contenu
PATHSPEC=(-- . ':!scripts/check-secrets.sh')
IGNORE_MARKER='check-secrets: ignore'

# Jetons reconnaissables : « libellé|regex étendue »
TOKEN_PATTERNS=(
  'jeton GitLab|glpat-[A-Za-z0-9_-]{20,}'
  'jeton runner GitLab|glrt-[A-Za-z0-9_-]{20,}'
  'jeton GitHub|github_pat_[A-Za-z0-9_]{20,}'
  'jeton GitHub|gh[pousr]_[A-Za-z0-9]{30,}'
  'jeton SonarQube|sq[apu]_[a-f0-9]{30,}'
  'clé Anthropic|sk-ant-[A-Za-z0-9_-]{20,}'
  'clé AWS|AKIA[0-9A-Z]{16}'
  'jeton Slack|xox[abpr]-[A-Za-z0-9-]{10,}'
  'clé privée|-----BEGIN [A-Z ]*PRIVATE KEY-----'
)

# Affectation d'une valeur littérale à une variable sensible (sensible à la casse) ;
# les références ($VAR, ${VAR}, $(…)) et les valeurs d'exemple sont exclues ensuite.
ASSIGN_PATTERN='[A-Z0-9_]*(PASSWORD|PASSWD|TOKEN|SECRET|API_KEY)[A-Z0-9_]*[[:space:]]*(=|:[[:space:]])[[:space:]]*["'\'']?[^"'\''$[:space:]]'
PLACEHOLDER_PATTERN='(PASSWORD|PASSWD|TOKEN|SECRET|API_KEY)[A-Z0-9_]*[[:space:]]*(=|:[[:space:]])[[:space:]]*["'\'']?(change_me|changeme|<)'

# Fichiers qui ne doivent jamais être versionnés
SENSITIVE_FILES='^(envs/[^/]+\.env(\.[^/]+)?|(.*/)?\.env|outputs/.+|config/certs/.+|.*\.(pem|key|p12|pfx|jks|keystore)|(.*/)?id_(rsa|ecdsa|ed25519))$'
SENSITIVE_ALLOWED='^(envs/\.env\.example|config/certs/\.gitkeep)$'

findings=0
report() { echo "  ✖ $*" >&2; findings=$((findings + 1)); }

# Recherche dans le contenu selon le mode ; sortie « chemin:ligne:contenu »
content_grep() {
  local pattern="$1" scope=(--untracked)
  [[ "$MODE" == staged ]] && scope=(--cached)
  git grep -nI -E "${scope[@]}" -e "$pattern" "${PATHSPEC[@]}" || true
}

# N'affiche que « chemin:ligne », jamais le contenu
locations() { grep -vF "$IGNORE_MARKER" | cut -d: -f1,2; }

scan_files() {
  echo "[1/4] Fichiers sensibles versionnés"
  local list=(--cached --others --exclude-standard) path
  [[ "$MODE" == staged ]] && list=(--cached)
  while IFS= read -r path; do
    report "$path : fichier sensible suivi par git (à retirer : git rm --cached)"
  done < <(git ls-files "${list[@]}" | grep -E "$SENSITIVE_FILES" | grep -vE "$SENSITIVE_ALLOWED" || true)
}

scan_gitignore() {
  echo "[2/4] Couverture du .gitignore"
  local path
  for path in envs/instance.env envs/instance.env.bak.20260101-000000 outputs/fichier config/certs/cert.pem; do
    git check-ignore -q --no-index "$path" || report "$path n'est pas ignoré par .gitignore"
  done
  if git check-ignore -q --no-index envs/.env.example; then
    report "envs/.env.example est ignoré par .gitignore alors qu'il doit être versionné"
  fi
}

scan_tokens() {
  echo "[3/4] Jetons et clés privées"
  local entry loc
  for entry in "${TOKEN_PATTERNS[@]}"; do
    while IFS= read -r loc; do
      report "$loc : ${entry%%|*}"
    done < <(content_grep "${entry#*|}" | locations)
  done
}

scan_assignments() {
  echo "[4/4] Valeurs littérales affectées à des variables sensibles"
  local loc
  while IFS= read -r loc; do
    report "$loc : valeur littérale de mot de passe, jeton ou secret"
  done < <(content_grep "$ASSIGN_PATTERN" | grep -vE "$PLACEHOLDER_PATTERN" | locations)
}

# Historique : lignes ajoutées, au format « commit<TAB>chemin<TAB>contenu »
scan_history() {
  echo "[1/1] Jetons et clés privées dans l'historique de HEAD"
  if ! git rev-parse -q --verify HEAD >/dev/null; then
    echo "  dépôt sans commit : rien à analyser"
    return
  fi
  local added entry hit
  added="$(git log -p --no-ext-diff --no-textconv --no-color --format='commit %h' HEAD "${PATHSPEC[@]}" |
    awk '/^commit [0-9a-f]+$/ { c = $2; next }
         /^\+\+\+ / { f = substr($0, 7); next }
         /^\+/ { print c "\t" f "\t" substr($0, 2) }')"
  for entry in "${TOKEN_PATTERNS[@]}"; do
    while IFS= read -r hit; do
      report "commit ${hit%%$'\t'*}, ${hit#*$'\t'} : ${entry%%|*}"
    done < <(grep -E -e "${entry#*|}" <<<"$added" | grep -vF "$IGNORE_MARKER" | cut -f1,2 | sort -u || true)
  done
}

echo "check-secrets ($MODE) : $(basename "$ROOT")"
if [[ "$MODE" == history ]]; then
  scan_history
else
  scan_files
  scan_gitignore
  scan_tokens
  scan_assignments
fi

if ((findings)); then
  echo "ÉCHEC : $findings problème(s) détecté(s)." >&2
  if [[ "$MODE" == history ]]; then
    echo "Révoquer le secret, puis le purger de l'historique (git filter-repo)." >&2
  else
    echo "Retirer le secret (variable d'environnement, envs/<env>.env) ou, pour un faux positif," >&2
    echo "ajouter le marqueur « $IGNORE_MARKER » en commentaire sur la ligne." >&2
  fi
  exit 1
fi
echo "OK : aucun secret détecté."
