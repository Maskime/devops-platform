#!/usr/bin/env bash
# Bootstrap GitLab repris de Software Factory : crée un projet de test, enregistre un runner,
# pousse un .gitlab-ci.yml et attend la réussite du pipeline.
# À lancer après `make deploy ENV=<env>`. Nécessite GitLab CE 15.10+ (POST /api/v4/user/runners).
# Usage : ENV=<env> scripts/legacy/setup-gitlab.sh  (ou make bootstrap-legacy ENV=<env>)
#
# TEMPORAIRE — crée des données de test ; remplacé par l'US 5-1.
# Adaptations par rapport à la source (logique inchangée par ailleurs) :
#   - variables lues dans envs/$ENV.env (lib.sh) au lieu de infrastructure/.env ;
#   - `docker exec <conteneur>` remplacé par `docker compose exec -T <service>` ;
#   - runner existant recherché via /runners/all (l'endpoint /runners ne renvoie pas les runners
#     d'instance : le script en réenregistrait un à chaque passage) ;
#   - jeton d'accès vérifié (préfixe glpat-) et erreurs de gitlab-rails affichées ;
#   - images épinglées (alpine), réseau issu de lib.sh ; messages en français ;
#   - runner déjà en ligne : réseau des jobs réaligné sur PLATFORM_NETWORK s'il a changé.
set -euo pipefail

# shellcheck source=scripts/legacy/lib.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
charger_env

GITLAB_URL="${GITLAB_EXTERNAL_URL:-http://${GITLAB_HOSTNAME:-gitlab.localhost}}"
GITLAB_INTERNAL_URL="http://gitlab"   # URL inter-conteneurs (nom de service Docker)
TEST_PROJECT_NAME="${GITLAB_TEST_PROJECT_NAME:-factory-test}"
RUNNER_IMAGE="alpine:3.24.2"

api() {
  local method="$1" path="$2"; shift 2
  local response http_code body
  response=$(curl -s -w "\n%{http_code}" --request "$method" \
    --header "PRIVATE-TOKEN: $TOKEN" "$@" "$GITLAB_URL/api/v4$path")
  http_code=$(echo "$response" | tail -1)
  body=$(echo "$response" | head -1)
  echo "$http_code $body"
}

check() {
  local expected="$1" label="$2" result="$3"
  local code="${result%% *}" body="${result#* }"
  if [[ "$code" != "$expected" ]]; then
    echo "$label : échec (HTTP $code) : $body" >&2; exit 1
  fi
  echo "$body"
}

json() {
  python3 -c "import json,sys; print(json.load(sys.stdin)$1)"
}

# ---------------------------------------------------------------------------
# 1. Attente de GitLab (10 minutes au plus)
# ---------------------------------------------------------------------------
echo "==> Attente de GitLab..."
for i in $(seq 1 60); do
  # curl lancé dans le conteneur : /-/health n'est autorisé que depuis 127.0.0.1 par défaut
  if dc exec -T gitlab curl -sf http://localhost/-/health > /dev/null 2>&1; then
    echo "    GitLab est prêt."; break
  fi
  [[ "$i" -eq 60 ]] && { echo "Délai dépassé : GitLab n'a pas démarré en 10 minutes." >&2; exit 1; }
  echo "    ($i/60) pas encore prêt, nouvel essai dans 10 s..."
  sleep 10
done

# ---------------------------------------------------------------------------
# 2. Création (ou renouvellement) d'un jeton d'accès personnel root via gitlab-rails runner
# ---------------------------------------------------------------------------
echo "==> Création du jeton d'accès personnel root..."
RAILS_ERR="$(mktemp)"
trap 'rm -f "$RAILS_ERR"' EXIT
TOKEN=$(dc exec -T gitlab gitlab-rails runner "
  existing = PersonalAccessToken.find_by(name: 'setup-token', user: User.find_by_username('root'))
  existing.revoke! if existing && !existing.revoked?
  token = User.find_by_username('root').personal_access_tokens.create!(
    name: 'setup-token',
    scopes: ['api'],
    expires_at: Date.today + 365
  )
  puts token.token
" 2>"$RAILS_ERR" | tail -1 || true)

if [[ ! "$TOKEN" =~ ^glpat- ]]; then
  echo "Échec de la création du jeton d'accès personnel." >&2
  cat "$RAILS_ERR" >&2
  exit 1
fi
echo "    Jeton prêt."

# ---------------------------------------------------------------------------
# 3. Création du projet de test (idempotent)
# ---------------------------------------------------------------------------
echo "==> Création du projet '$TEST_PROJECT_NAME'..."
EXISTING_ID=$(curl -sf --header "PRIVATE-TOKEN: $TOKEN" \
  "$GITLAB_URL/api/v4/projects?search=$TEST_PROJECT_NAME" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = next((str(p['id']) for p in data if p['name'] == '$TEST_PROJECT_NAME'), '')
print(match)
")

if [[ -n "$EXISTING_ID" ]]; then
  PROJECT_ID="$EXISTING_ID"
  echo "    Projet déjà présent (id=$PROJECT_ID)."
else
  RESULT=$(api POST /projects \
    --data "name=$TEST_PROJECT_NAME&initialize_with_readme=true&visibility=private")
  BODY=$(check 201 "Création du projet" "$RESULT")
  PROJECT_ID=$(echo "$BODY" | json "['id']")
  echo "    Projet créé (id=$PROJECT_ID)."
fi

# ---------------------------------------------------------------------------
# 4. Enregistrement du runner (idempotent — réenregistré si le runner existant est hors ligne)
# ---------------------------------------------------------------------------
echo "==> Configuration du runner..."
EXISTING_RUNNER=$(curl -sf --header "PRIVATE-TOKEN: $TOKEN" \
  "$GITLAB_URL/api/v4/runners/all?type=instance_type" \
  | python3 -c "
import json, sys
data = json.load(sys.stdin)
match = next(((str(r['id']), r.get('status','')) for r in data if r.get('description') == 'factory-runner'), ('',''))
print(match[0] + ':' + match[1])
" 2>/dev/null || true)

EXISTING_RUNNER_ID="${EXISTING_RUNNER%%:*}"
EXISTING_RUNNER_STATUS="${EXISTING_RUNNER##*:}"

if [[ -n "$EXISTING_RUNNER_ID" && "$EXISTING_RUNNER_STATUS" == "online" ]]; then
  echo "    Runner déjà enregistré et en ligne (id=$EXISTING_RUNNER_ID)."
  # Le réseau des jobs est écrit dans config.toml à l'enregistrement : après un changement de
  # PLATFORM_NETWORK, il pointe encore vers l'ancien réseau. Le runner recharge config.toml à chaud.
  RESEAU_JOBS=$(dc exec -T gitlab-runner \
    sed -n 's/^ *network_mode = "\(.*\)"$/\1/p' /etc/gitlab-runner/config.toml | head -n1)
  if [[ -n "$RESEAU_JOBS" && "$RESEAU_JOBS" != "$RESEAU" ]]; then
    dc exec -T gitlab-runner \
      sed -i "s/^\( *network_mode = \)\".*\"\$/\1\"$RESEAU\"/" /etc/gitlab-runner/config.toml
    echo "    Réseau des jobs réaligné : $RESEAU_JOBS → $RESEAU."
  fi
else
  if [[ -n "$EXISTING_RUNNER_ID" ]]; then
    echo "    Runner id=$EXISTING_RUNNER_ID présent mais '$EXISTING_RUNNER_STATUS' — suppression et réenregistrement..."
    curl -sf --request DELETE --header "PRIVATE-TOKEN: $TOKEN" \
      "$GITLAB_URL/api/v4/runners/$EXISTING_RUNNER_ID" > /dev/null || true
  fi

  # Retire de config.toml les runners qui n'existent plus côté serveur (dont celui supprimé
  # ci-dessus). Sans cela, chaque réenregistrement empile un bloc [[runners]] et laisse
  # orphelins ses volumes runner-<id>-cache-*.
  dc exec -T gitlab-runner gitlab-runner verify --delete || true

  RESULT=$(api POST /user/runners \
    --data "runner_type=instance_type&description=factory-runner")
  RUNNER_BODY=$(check 201 "Création du jeton de runner" "$RESULT")
  RUNNER_TOKEN=$(echo "$RUNNER_BODY" | json "['token']")

  dc exec -T gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "$GITLAB_INTERNAL_URL" \
    --clone-url "$GITLAB_INTERNAL_URL" \
    --token "$RUNNER_TOKEN" \
    --executor docker \
    --docker-image "$RUNNER_IMAGE" \
    --docker-network-mode "$RESEAU" \
    --docker-extra-hosts "host.docker.internal:host-gateway" \
    --description "factory-runner"
  echo "    Runner enregistré."
fi

# ---------------------------------------------------------------------------
# 5. Envoi du .gitlab-ci.yml (idempotent)
# ---------------------------------------------------------------------------
echo "==> Envoi du .gitlab-ci.yml..."
FILE_STATUS=$(curl -s -o /dev/null -w "%{http_code}" \
  --header "PRIVATE-TOKEN: $TOKEN" \
  "$GITLAB_URL/api/v4/projects/$PROJECT_ID/repository/files/.gitlab-ci.yml?ref=main")

if [[ "$FILE_STATUS" == "200" ]]; then
  echo "    .gitlab-ci.yml déjà présent, rien à faire."
else
  CI_CONTENT=$(cat <<YAML
stages:
  - test

smoke-test:
  stage: test
  image: $RUNNER_IMAGE
  script:
    - echo "CI is operational"
YAML
)
  PAYLOAD=$(CI_CONTENT="$CI_CONTENT" python3 -c "
import json, os
print(json.dumps({
  'branch': 'main',
  'commit_message': 'chore: add CI pipeline',
  'content': os.environ['CI_CONTENT']
}))
")
  RESULT=$(api POST "/projects/$PROJECT_ID/repository/files/.gitlab-ci.yml" \
    --header "Content-Type: application/json" --data "$PAYLOAD")
  check 201 "Envoi du .gitlab-ci.yml" "$RESULT" > /dev/null
  echo "    .gitlab-ci.yml envoyé."
fi

# ---------------------------------------------------------------------------
# 6. Déclenchement d'un pipeline et attente de sa réussite
# ---------------------------------------------------------------------------
echo "==> Déclenchement du pipeline..."
PIPELINE_RESULT=$(api POST "/projects/$PROJECT_ID/pipeline" \
  --data "ref=main")
PIPELINE_BODY=$(check 201 "Déclenchement du pipeline" "$PIPELINE_RESULT")
PIPELINE_ID=$(echo "$PIPELINE_BODY" | json "['id']")
echo "    Pipeline #$PIPELINE_ID déclenché."

echo "==> Attente de la fin du pipeline..."

for i in $(seq 1 30); do
  STATUS=$(curl -sf --header "PRIVATE-TOKEN: $TOKEN" \
    "$GITLAB_URL/api/v4/projects/$PROJECT_ID/pipelines/$PIPELINE_ID" \
    | json "['status']")
  echo "    Pipeline #$PIPELINE_ID : $STATUS"
  [[ "$STATUS" == "success" ]] && break
  [[ "$STATUS" == "failed" || "$STATUS" == "canceled" ]] && {
    echo "Pipeline $STATUS. Voir : $GITLAB_URL/root/$TEST_PROJECT_NAME/-/pipelines/$PIPELINE_ID" >&2
    exit 1
  }
  [[ "$i" -eq 30 ]] && { echo "Délai dépassé : le pipeline ne s'est pas terminé en 5 minutes." >&2; exit 1; }
  sleep 10
done

echo ""
echo "Configuration terminée."
echo "  Projet    : $GITLAB_URL/root/$TEST_PROJECT_NAME"
echo "  Pipelines : $GITLAB_URL/root/$TEST_PROJECT_NAME/-/pipelines"
echo "  Runners   : $GITLAB_URL/admin/runners"
