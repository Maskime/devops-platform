#!/usr/bin/env bash
# Bootstrap SonarQube (analyse) repris de Software Factory : crée un projet de test, lance une
# analyse sonar-scanner sur du code exemple et vérifie que l'API renvoie des résultats. Idempotent.
# Prérequis : setup-sonarqube.sh (mot de passe admin positionné).
# Usage : ENV=<env> scripts/legacy/setup-sonarqube-analysis.sh  (ou make bootstrap-legacy ENV=<env>)
#
# TEMPORAIRE — crée des données de test ; remplacé par les US 5-2 et 5-5.
# Adaptations par rapport à la source (logique inchangée par ailleurs) :
#   - variables lues dans envs/$ENV.env (lib.sh) au lieu de infrastructure/.env ;
#   - sources montées en lecture seule et répertoire de travail du scanner dans le conteneur :
#     rien n'est écrit dans le repo ; clé de projet passée au scanner ;
#   - image sonar-scanner-cli épinglée, réseau issu de lib.sh ; messages en français.
set -euo pipefail

# shellcheck source=scripts/legacy/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
charger_env

TEST_SRC_DIR="$ROOT/scripts/legacy/sonarqube-test"
SCANNER_IMAGE="sonarsource/sonar-scanner-cli:12.2.0.4256_8.1.0"
SONARQUBE_URL="${SONARQUBE_EXTERNAL_URL:-http://localhost:${SONARQUBE_PORT:-9000}}"
ADMIN_PASSWORD="${SONARQUBE_ADMIN_PASSWORD:-}"
PROJECT_KEY="${SONARQUBE_TEST_PROJECT_KEY:-factory-test}"

if [[ -z "$ADMIN_PASSWORD" || "$ADMIN_PASSWORD" == "change_me"* ]]; then
  echo "Erreur : SONARQUBE_ADMIN_PASSWORD n'est pas défini ou garde sa valeur d'exemple." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 1. Attente de SonarQube (10 minutes au plus)
# ---------------------------------------------------------------------------
echo "==> Attente de SonarQube..."
for i in $(seq 1 60); do
  STATUS=$(curl -sf "$SONARQUBE_URL/api/system/status" \
    | python3 -c "import json,sys; print(json.load(sys.stdin).get('status',''))" 2>/dev/null || true)
  if [[ "$STATUS" == "UP" ]]; then
    echo "    SonarQube est prêt."; break
  fi
  [[ "$i" -eq 60 ]] && { echo "Délai dépassé : SonarQube n'a pas atteint le statut UP en 10 minutes." >&2; exit 1; }
  echo "    ($i/60) statut=${STATUS:-injoignable}, nouvel essai dans 10 s..."
  sleep 10
done

# ---------------------------------------------------------------------------
# 2. Création du projet de test (idempotent — HTTP 400 si déjà présent)
# ---------------------------------------------------------------------------
echo "==> Création du projet '$PROJECT_KEY'..."
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
  -u "admin:$ADMIN_PASSWORD" \
  -X POST "$SONARQUBE_URL/api/projects/create" \
  -d "project=$PROJECT_KEY&name=Factory+Test+Project&visibility=private")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "    Projet créé."
elif [[ "$HTTP_CODE" == "400" ]]; then
  echo "    Projet déjà présent — rien à faire."
else
  echo "Erreur : HTTP $HTTP_CODE inattendu lors de la création du projet." >&2
  exit 1
fi

# ---------------------------------------------------------------------------
# 3. Génération du jeton du scanner (le précédent est révoqué d'abord)
# ---------------------------------------------------------------------------
echo "==> Génération du jeton du scanner..."
curl -s -o /dev/null \
  -u "admin:$ADMIN_PASSWORD" \
  -X POST "$SONARQUBE_URL/api/user_tokens/revoke" \
  -d "name=factory-scanner" || true

TOKEN_JSON=$(curl -sf \
  -u "admin:$ADMIN_PASSWORD" \
  -X POST "$SONARQUBE_URL/api/user_tokens/generate" \
  -d "name=factory-scanner")

SCANNER_TOKEN=$(echo "$TOKEN_JSON" \
  | python3 -c "import json,sys; t=json.load(sys.stdin).get('token',''); print(t)")

if [[ -z "$SCANNER_TOKEN" ]]; then
  echo "Erreur : échec de la génération du jeton du scanner. Réponse : $TOKEN_JSON" >&2
  exit 1
fi
echo "    Jeton généré."

# ---------------------------------------------------------------------------
# 4. Analyse sonar-scanner via Docker
# ---------------------------------------------------------------------------
echo "==> Analyse de '$TEST_SRC_DIR'..."
docker run --rm \
  --network "$RESEAU" \
  -v "$TEST_SRC_DIR:/usr/src:ro" \
  -e SONAR_HOST_URL="http://sonarqube:9000" \
  -e SONAR_TOKEN="$SCANNER_TOKEN" \
  "$SCANNER_IMAGE" \
  -Dsonar.projectKey="$PROJECT_KEY" \
  -Dsonar.working.directory=/tmp/.scannerwork

# ---------------------------------------------------------------------------
# 5. Attente de la fin du traitement de l'analyse (5 minutes au plus)
# ---------------------------------------------------------------------------
echo "==> Attente de la fin de l'analyse..."
for i in $(seq 1 30); do
  TASK_STATUS=$(curl -sf \
    -u "admin:$ADMIN_PASSWORD" \
    "$SONARQUBE_URL/api/ce/activity?component=$PROJECT_KEY&ps=1" \
    | python3 -c "
import json, sys
data = json.load(sys.stdin)
tasks = data.get('tasks', [])
print(tasks[0].get('status', '') if tasks else '')
" 2>/dev/null || true)

  if [[ "$TASK_STATUS" == "SUCCESS" ]]; then
    echo "    Analyse terminée."; break
  elif [[ "$TASK_STATUS" == "FAILED" ]]; then
    echo "Erreur : la tâche d'analyse SonarQube a échoué." >&2
    exit 1
  fi
  [[ "$i" -eq 30 ]] && { echo "Délai dépassé : l'analyse ne s'est pas terminée en 5 minutes." >&2; exit 1; }
  echo "    ($i/30) statut de la tâche=${TASK_STATUS:-en attente}, nouvel essai dans 10 s..."
  sleep 10
done

# ---------------------------------------------------------------------------
# 6. Vérification de l'API : issues de la branche par défaut (main)
# ---------------------------------------------------------------------------
echo "==> Interrogation de l'API issues (branch=main)..."
ISSUES_JSON=$(curl -sf \
  -u "admin:$ADMIN_PASSWORD" \
  "$SONARQUBE_URL/api/issues/search?projectKeys=$PROJECT_KEY&branch=main")

ISSUE_TOTAL=$(echo "$ISSUES_JSON" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('total', 0))" 2>/dev/null || echo "parse_error")

if [[ "$ISSUE_TOTAL" == "parse_error" ]]; then
  echo "Erreur : réponse de l'API issues illisible." >&2
  exit 1
fi
echo "    Issues trouvées : $ISSUE_TOTAL"

# ---------------------------------------------------------------------------
# 7. Vérification du statut de la quality gate
# ---------------------------------------------------------------------------
echo "==> Interrogation du statut de la quality gate..."
QG_JSON=$(curl -sf \
  -u "admin:$ADMIN_PASSWORD" \
  "$SONARQUBE_URL/api/qualitygates/project_status?projectKey=$PROJECT_KEY")

QG_STATUS=$(echo "$QG_JSON" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
print(data.get('projectStatus', {}).get('status', 'UNKNOWN'))
" 2>/dev/null || echo "parse_error")

if [[ "$QG_STATUS" == "parse_error" ]]; then
  echo "Erreur : réponse de l'API quality gate illisible." >&2
  exit 1
fi
echo "    Statut de la quality gate : $QG_STATUS"

# ---------------------------------------------------------------------------
# 8. Récapitulatif
# ---------------------------------------------------------------------------
echo ""
echo "Configuration terminée."
echo "  UI SonarQube         : $SONARQUBE_URL/dashboard?id=$PROJECT_KEY"
echo "  Clé du projet        : $PROJECT_KEY"
echo "  Issues (branch=main) : $ISSUE_TOTAL"
echo "  Quality gate         : $QG_STATUS"
