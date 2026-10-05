#!/usr/bin/env bash
# Méta-bootstrap repris de Software Factory : enchaîne les scripts de scripts/legacy/ dans l'ordre
# des dépendances. GitLab passe en dernier : c'est le conteneur le plus lent à devenir healthy.
# À lancer après `make deploy ENV=<env>`.
# Usage : ENV=<env> scripts/legacy/setup-all.sh [--from <N>]  (ou make bootstrap-legacy ENV=<env>)
#   --from <N>  reprend à l'étape N (1-3) ; les étapes précédentes sont ignorées
#
# TEMPORAIRE — crée des données de test ; remplacé par l'épopée 5.
# Adaptations par rapport à la source :
#   - étapes Temporal et réseau inter-services retirées (hors périmètre de la plateforme) ;
#   - étape `docker compose up` retirée (assurée par `make deploy`) ;
#   - plus d'exécution parallèle (elle ne servait qu'à SonarQube + Temporal) ;
#   - messages en français.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ─── Couleurs ─────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; RESET='\033[0m'

banner() { echo -e "\n${CYAN}${BOLD}━━━  $*  ━━━${RESET}"; }
ok()     { echo -e "${GREEN}✔  $*${RESET}"; }
fail()   { echo -e "${RED}✖  $*${RESET}" >&2; }

# Lance un script, affiche sa sortie, s'arrête en cas d'échec.
run() {
  local label="$1" script="$SCRIPT_DIR/$2" rc=0
  echo -e "\n${YELLOW}▶ $label${RESET}"
  bash "$script" || rc=$?
  if ((rc == 0)); then
    ok "$label — terminé"
  else
    fail "$label — ÉCHEC (code $rc)"
    exit 1
  fi
}

# ─── Arguments ────────────────────────────────────────────────────────────────
FROM_STEP=1
args=("$@")
for ((i = 0; i < ${#args[@]}; i++)); do
  case "${args[$i]}" in
    --from)
      i=$((i + 1))
      FROM_STEP="${args[$i]:-}"
      if ! [[ "$FROM_STEP" =~ ^[1-3]$ ]]; then
        echo -e "${RED}--from attend un numéro d'étape entre 1 et 3${RESET}" >&2
        exit 1
      fi
      ;;
    *)
      echo -e "${RED}Argument inconnu : ${args[$i]}${RESET}" >&2
      exit 1
      ;;
  esac
done

# skip_before <N> : vrai si l'étape N doit être ignorée.
skip_before() { [[ "$FROM_STEP" -gt "$1" ]]; }

# ─── Étape 1 : SonarQube ──────────────────────────────────────────────────────
if skip_before 1; then
  echo -e "${YELLOW}  ⏭  Étape 1/3 — SonarQube (ignorée)${RESET}"
else
  banner "Étape 1/3 — SonarQube"
  run "SonarQube" setup-sonarqube.sh
fi

# ─── Étape 2 : analyse SonarQube (requiert l'étape 1) ─────────────────────────
if skip_before 2; then
  echo -e "${YELLOW}  ⏭  Étape 2/3 — Analyse SonarQube (ignorée)${RESET}"
else
  banner "Étape 2/3 — Analyse SonarQube"
  run "Analyse SonarQube" setup-sonarqube-analysis.sh
fi

# ─── Étape 3 : GitLab (conteneur le plus lent : en dernier) ───────────────────
if skip_before 3; then
  echo -e "${YELLOW}  ⏭  Étape 3/3 — GitLab (ignorée)${RESET}"
else
  banner "Étape 3/3 — GitLab"
  run "GitLab" setup-gitlab.sh
fi

echo -e "\n${GREEN}${BOLD}Bootstrap terminé.${RESET}\n"
