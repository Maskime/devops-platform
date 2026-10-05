#!/usr/bin/env bash
# Bootstrap SonarQube repris de Software Factory : attend que SonarQube soit prêt et sécurise le
# compte admin en remplaçant le mot de passe par défaut « admin ». Idempotent.
# À lancer après `make deploy ENV=<env>`.
# Usage : ENV=<env> scripts/legacy/setup-sonarqube.sh  (ou make bootstrap-legacy ENV=<env>)
#
# TEMPORAIRE — remplacé par l'US 5-2.
# Adaptations par rapport à la source (logique inchangée par ailleurs) :
#   - variables lues dans envs/$ENV.env (lib.sh) au lieu de infrastructure/.env ;
#   - paramètres du changement de mot de passe encodés (--data-urlencode) : un mot de passe
#     contenant + & % était enregistré altéré, et le compte admin devenait inaccessible au script ;
#   - lecture indirecte des variables (${!nom}) au lieu de eval ;
#   - messages en français.
set -euo pipefail

# shellcheck source=scripts/legacy/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
charger_env

SONARQUBE_URL="${SONARQUBE_EXTERNAL_URL:-http://${SONARQUBE_HOSTNAME:-sonarqube.localhost}}"
ADMIN_PASSWORD="${SONARQUBE_ADMIN_PASSWORD:-}"
# shellcheck disable=SC2034  # lue indirectement par la boucle ci-dessous
DB_PASSWORD="${SONARQUBE_DB_PASSWORD:-}"

for var_name in ADMIN_PASSWORD DB_PASSWORD; do
  val="${!var_name}"
  if [[ -z "$val" || "$val" == "change_me"* ]]; then
    echo "Erreur : ${var_name} n'est pas défini ou garde sa valeur d'exemple dans $ENV_FILE." >&2
    exit 1
  fi
done

# ---------------------------------------------------------------------------
# 1. Vérification de vm.max_map_count (requis par l'Elasticsearch embarqué)
# ---------------------------------------------------------------------------
echo "==> Vérification de vm.max_map_count..."
CURRENT_MAP_COUNT=$(cat /proc/sys/vm/max_map_count 2>/dev/null || echo 0)
if [[ "$CURRENT_MAP_COUNT" -lt 524288 ]]; then
  echo "" >&2
  echo "Erreur : vm.max_map_count vaut $CURRENT_MAP_COUNT (minimum requis : 524288)." >&2
  echo "L'Elasticsearch embarqué de SonarQube ne démarrera pas avec cette valeur." >&2
  echo "" >&2
  echo "Correctif (session courante) :" >&2
  echo "  sudo sysctl -w vm.max_map_count=524288" >&2
  echo "" >&2
  echo "Correctif (persistant) :" >&2
  echo "  echo 'vm.max_map_count=524288' | sudo tee /etc/sysctl.d/sonarqube.conf" >&2
  echo "  sudo sysctl --system" >&2
  echo "" >&2
  exit 1
fi
echo "    vm.max_map_count=$CURRENT_MAP_COUNT — OK."

# ---------------------------------------------------------------------------
# 2. Attente de SonarQube (10 minutes au plus)
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
# 3. Vérification du plugin community branch
# ---------------------------------------------------------------------------
echo "==> Vérification du plugin sonarqube-community-branch-plugin..."
PLUGIN_JSON=$(curl -sf -u "admin:$ADMIN_PASSWORD" "$SONARQUBE_URL/api/plugins/installed" 2>/dev/null \
  || curl -sf -u "admin:admin" "$SONARQUBE_URL/api/plugins/installed" 2>/dev/null \
  || echo "{}")
PLUGIN_PRESENT=$(echo "$PLUGIN_JSON" | python3 -c "
import json, sys
plugins = json.load(sys.stdin).get('plugins', [])
keys = [p.get('key', '') for p in plugins]
print('true' if any('communityBranch' in k or 'branch' in k.lower() for k in keys) else 'false')
" 2>/dev/null || echo "false")

if [[ "$PLUGIN_PRESENT" == "true" ]]; then
  echo "    Plugin communityBranchPlugin — OK."
else
  echo "Avertissement : plugin communityBranchPlugin non détecté. Vérifier que l'image utilisée est" >&2
  echo "                mc1arke/sonarqube-with-community-branch-plugin (voir compose/sonarqube.yml)." >&2
fi

# ---------------------------------------------------------------------------
# 4. Changement du mot de passe admin par défaut (idempotent)
# ---------------------------------------------------------------------------
echo "==> Sécurisation du compte admin..."

# /api/authentication/validate répond toujours HTTP 200 : on teste le champ « valid ».
VALID=$(curl -sf -u "admin:$ADMIN_PASSWORD" "$SONARQUBE_URL/api/authentication/validate" \
  | python3 -c "import json,sys; print(json.load(sys.stdin).get('valid', False))" 2>/dev/null || echo "false")

if [[ "$VALID" == "True" ]]; then
  echo "    Mot de passe admin déjà positionné à la valeur configurée — rien à faire."
else
  # Le mot de passe configuré ne fonctionne pas : changement depuis le mot de passe par défaut « admin ».
  CHANGE_BODY=$(curl -s -w "\n%{http_code}" \
    -u "admin:admin" \
    -X POST "$SONARQUBE_URL/api/users/change_password" \
    --data-urlencode "login=admin" \
    --data-urlencode "previousPassword=admin" \
    --data-urlencode "password=$ADMIN_PASSWORD")
  CHANGE_CODE=$(echo "$CHANGE_BODY" | tail -1)
  CHANGE_MSG=$(echo "$CHANGE_BODY" | head -n -1)

  if [[ "$CHANGE_CODE" == "204" ]]; then
    echo "    Mot de passe admin modifié."
  elif [[ "$CHANGE_CODE" == "401" ]]; then
    echo "Erreur : authentification admin impossible, ni avec le mot de passe par défaut ('admin')" >&2
    echo "ni avec SONARQUBE_ADMIN_PASSWORD. Un autre mot de passe est peut-être déjà positionné." >&2
    echo "Intervention manuelle requise : se connecter à $SONARQUBE_URL et réinitialiser le mot de passe admin." >&2
    exit 1
  elif [[ "$CHANGE_CODE" == "400" ]]; then
    echo "Erreur : SonarQube a refusé le nouveau mot de passe (HTTP 400)." >&2
    echo "Réponse : $CHANGE_MSG" >&2
    echo "" >&2
    echo "Règles SonarQube : 12 caractères minimum, avec majuscule, minuscule, chiffre et caractère" >&2
    echo "spécial. Vérifier SONARQUBE_ADMIN_PASSWORD dans $ENV_FILE." >&2
    exit 1
  else
    echo "Erreur : HTTP $CHANGE_CODE inattendu lors du changement de mot de passe admin." >&2
    echo "Réponse : $CHANGE_MSG" >&2
    exit 1
  fi
fi

# ---------------------------------------------------------------------------
# 5. Récapitulatif
# ---------------------------------------------------------------------------
echo ""
echo "Configuration terminée."
echo "  UI SonarQube : $SONARQUBE_URL"
echo "  Identifiants : admin / <SONARQUBE_ADMIN_PASSWORD configuré>"
