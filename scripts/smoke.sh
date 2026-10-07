#!/usr/bin/env bash
# Smoke test d'une instance bootstrapée (make bootstrap) : crée (ou réutilise) le projet de test
# root/devops-platform-smoke dans GitLab, y pousse scripts/smoke/projet/ (.gitlab-ci.yml avec un job
# simple et un job sonar-scanner), attend que le pipeline passe au vert et que l'analyse du commit
# apparaisse dans SonarQube. NETTOYER=1 : projets de test GitLab et SonarQube supprimés après un succès.
# Lancé par `make smoke ENV=<env>` (scripts/instance.sh smoke), qui positionne la cible Docker (contexte
# SSH d'une instance distante). Documentation : docs/smoke-test.md.
#
# Usage : [NETTOYER=1] scripts/smoke.sh envs/<env>.env
#
# Aucun outil requis sur le poste : appels à l'API GitLab depuis le conteneur gitlab
# (scripts/lib/gitlab.sh), à l'API SonarQube depuis le conteneur sonarqube (scripts/lib/sonarqube.sh).
# Jeton root éphémère (PAT_NOM), révoqué en fin de script ; aucun secret en argument de processus.
# Verrou de l'instance partagé avec make bootstrap (scripts/lib/verrou.sh) : ni deux smoke tests, ni un
# smoke test et un bootstrap en même temps sur une instance.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/tls.sh
source "$ROOT/scripts/lib/tls.sh"
# shellcheck source=scripts/lib/gitlab.sh
source "$ROOT/scripts/lib/gitlab.sh"
# shellcheck source=scripts/lib/sonarqube.sh
source "$ROOT/scripts/lib/sonarqube.sh"
# shellcheck source=scripts/lib/verrou.sh
source "$ROOT/scripts/lib/verrou.sh"

# Projet de test : chemin GitLab (espace de noms root) et clé SonarQube, la seconde reprise dans
# scripts/smoke/projet/.gitlab-ci.yml
readonly PROJET=devops-platform-smoke
readonly SONAR_CLE=devops-platform-smoke
readonly BRANCHE=main
readonly SOURCES=scripts/smoke/projet
# Nom du PAT root du smoke test, distinct de celui du bootstrap (qui révoque les jetons de son nom)
readonly PAT_NOM=devops-platform-smoke
# Verrou de make bootstrap (scripts/instance.sh, scripts/bootstrap/gitlab.sh) : volume du runner
readonly FICHIER_VERROU=/etc/gitlab-runner/.bootstrap.lock
# Premier pipeline : téléchargement de l'image du scanner compris
readonly ATTENTE_GITLAB=900 ATTENTE_SONAR=600 ATTENTE_PIPELINE=900 ATTENTE_ANALYSE=300
readonly ATTENTE_SUPPRESSION=300 ATTENTE_PENDING=180

erreur() { echo "Erreur : $*" >&2; exit 1; }
etape() { echo; echo "==> $*"; }

(($# == 1)) || { echo "Usage : [NETTOYER=1] $0 envs/<env>.env" >&2; exit 1; }
env_file="$1"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file"
env="$(basename "$env_file" .env)"

dc() { docker compose --env-file "$env_file" "$@"; }

# Garde-fou : lancé hors `make smoke`, une instance distante serait cherchée sur le moteur local
if [[ -n "$(env_valeur_fichier "$env_file" DEPLOY_SSH)" && "${DOCKER_CONTEXT:-}" != "devops-platform-$env" ]]; then
  erreur "instance distante (DEPLOY_SSH dans $env_file) : lancer make smoke ENV=$env"
fi

case "${NETTOYER:-}" in
  1) nettoyer=1 ;;
  "" | 0) nettoyer=0 ;;
  *) erreur "NETTOYER invalide : ${NETTOYER} (attendu : 1)" ;;
esac

# Lu dans le fichier uniquement, comme scripts/bootstrap/sonarqube.sh
admin_mdp="$(env_valeur_fichier "$env_file" SONARQUBE_ADMIN_PASSWORD)"
[[ -n "$admin_mdp" ]] || erreur "SONARQUBE_ADMIN_PASSWORD absent de $env_file"
admin="admin:$admin_mdp"

# URL publique de SonarQube, pour le récapitulatif (même règle que scripts/bootstrap/sonarqube.sh)
sonar_url="$(env_valeur "$env_file" SONARQUBE_EXTERNAL_URL)"
if [[ -z "$sonar_url" ]]; then
  hote="$(env_valeur "$env_file" SONARQUBE_HOSTNAME)"
  sonar_url="http://${hote:-sonarqube.localhost}"
fi
sonar_url="${sonar_url%/}"

# --- Fin du script --------------------------------------------------------------------------------

# Jeton root révoqué par lui-même (succès ou échec), puis verrou libéré ; projet de test conservé en
# cas d'échec
projet_id="" projet_url="" pipeline_url=""
# shellcheck disable=SC2016 # code Ruby
readonly CODE_REVOCATION='
code, _ = api("delete", "/personal_access_tokens/self")
abort("HTTP #{code}") unless code == 204
'
terminer() {
  local code=$?
  if [[ -n "$pat" ]]; then
    if gitlab_api "$CODE_REVOCATION" > /dev/null; then
      pat=""
    else
      echo "Attention : jeton $PAT_NOM non révoqué (il expire le $pat_expiration)." >&2
    fi
  fi
  if ((code != 0)) && [[ -n "$projet_id" ]]; then
    {
      echo
      echo "Smoke test en échec : projet de test conservé pour diagnostic."
      echo "  Projet    : $projet_url"
      if [[ -n "$pipeline_url" ]]; then echo "  Pipeline  : $pipeline_url"; fi
      echo "  SonarQube : $sonar_url/dashboard?id=$SONAR_CLE"
    } >&2
  fi
  verrou_liberer
  exit "$code"
}
trap terminer EXIT

# --- 1. Disponibilité -----------------------------------------------------------------------------

etape "Disponibilité de l'instance $env"
services=" $(dc config --services | paste -sd ' ' -) "
for service in gitlab gitlab-runner sonarqube; do
  [[ "$services" == *" $service "* ]] \
    || erreur "service $service absent de l'instance : smoke test impossible (il vérifie GitLab, le runner et SonarQube)"
  [[ -n "$(dc ps -q --status running "$service")" ]] \
    || erreur "service $service arrêté : démarrer l'instance (make deploy ENV=$env)"
done
verrou_prendre gitlab-runner "$FICHIER_VERROU" "make smoke ENV=$env"
echo "    Verrou de l'instance pris ($FICHIER_VERROU, conteneur gitlab-runner)."

gitlab_pret() { dc exec -T gitlab curl -sf -o /dev/null http://localhost/-/readiness 2> /dev/null; }
attendre "GitLab" "$ATTENTE_GITLAB" gitlab_pret \
  || erreur "GitLab n'est pas prêt après $((ATTENTE_GITLAB / 60)) min (docker compose logs gitlab)"
echo "    GitLab est prêt."

sonar_pret() { sonar_api GET /api/system/status '' && [[ "$CORPS" == *'"status":"UP"'* ]]; }
attendre "SonarQube" "$ATTENTE_SONAR" sonar_pret \
  || erreur "SonarQube n'a pas atteint le statut UP en $((ATTENTE_SONAR / 60)) min (docker compose logs sonarqube)"
identite_valide "$admin" \
  || erreur "SONARQUBE_ADMIN_PASSWORD refusé par SonarQube : instance non bootstrapée ? (make bootstrap ENV=$env)"
echo "    SonarQube est prêt."

# --- 2. Jeton d'accès personnel -------------------------------------------------------------------

etape "Jeton d'accès personnel root ($PAT_NOM)"
creer_pat_root "$PAT_NOM"
echo "    Jeton créé (expire le $pat_expiration, révoqué en fin de smoke test)."

# --- 3. Configuration posée par make bootstrap ----------------------------------------------------

etape "Configuration de l'instance (make bootstrap)"
# Seuls des marqueurs sont affichés : le corps d'une variable contient sa valeur
# shellcheck disable=SC2016 # code Ruby
code_bootstrap='
%w[SONAR_HOST_URL SONAR_TOKEN].each do |cle|
  code, _ = api("get", "/admin/ci/variables/#{cle}")
  if code == 200 then puts "PRESENTE=#{cle}"
  elsif code == 404 then puts "ABSENTE=#{cle}"
  else abort("Lecture de la variable d instance #{cle} : HTTP #{code}")
  end
end
liste = api!("get", "/runners/all?type=instance_type&status=online&paused=false&per_page=100", 200)
puts "RUNNERS=#{liste.size}"
'
sortie="$(gitlab_api "$code_bootstrap")" || erreur "lecture de la configuration de GitLab impossible (voir ci-dessus)"
absentes="$(sed -n 's/^ABSENTE=//p' <<<"$sortie" | paste -sd ' ' -)"
[[ -z "$absentes" ]] \
  || erreur "variable(s) CI d'instance absente(s) : $absentes (make bootstrap ENV=$env, docs/analyse-sonarqube.md)"
echo "    Variables CI d'instance SONAR_HOST_URL et SONAR_TOKEN présentes."
runners="$(sed -n 's/^RUNNERS=//p' <<<"$sortie")"
((${runners:-0} > 0)) || erreur "aucun runner d'instance en ligne (make bootstrap ENV=$env, docs/bootstrap.md)"
echo "    $runners runner(s) d'instance en ligne."

# SONAR_TOKEN validé auprès de SonarQube avant le pipeline : un token révoqué (rotation depuis un autre
# poste) ne se révélerait qu'après plusieurs minutes, dans le journal du job sonar-scanner. La valeur
# n'est jamais affichée : une seule ligne VALEUR=… (ou CACHEE : variable « masked and hidden », valeur
# illisible par l'API), lue dans une variable ; erreurs sans corps de réponse (api, jamais api!).
# shellcheck disable=SC2016 # code Ruby
code_sonar_token='
code, v = api("get", "/admin/ci/variables/SONAR_TOKEN")
abort("Lecture de la variable d instance (SONAR_TOKEN) : HTTP #{code}") unless code == 200 && v.is_a?(Hash)
puts(v["value"].nil? ? "CACHEE" : "VALEUR=#{v["value"]}")
'
ligne_token="$(gitlab_api "$code_sonar_token")" || erreur "lecture de la variable CI d'instance SONAR_TOKEN impossible (voir ci-dessus)"
if [[ "$ligne_token" == CACHEE ]]; then
  echo "Attention : SONAR_TOKEN cachée (masked and hidden) : valeur illisible, non validée avant le pipeline." >&2
elif [[ "$ligne_token" != VALEUR=* || ! "${ligne_token#VALEUR=}" =~ $MOTIF_TOKEN_SONAR ]]; then
  unset ligne_token
  erreur "SONAR_TOKEN ne contient pas un token SonarQube : make bootstrap ENV=$env la remet à jour (docs/analyse-sonarqube.md)"
elif ! identite_valide "${ligne_token#VALEUR=}:"; then
  unset ligne_token
  erreur "SONAR_TOKEN refusé par SonarQube (token révoqué : rotation depuis un autre poste ?) : make bootstrap ENV=$env la remet à jour (docs/analyse-sonarqube.md)"
else
  echo "    SONAR_TOKEN acceptée par SonarQube (valeur non affichée)."
fi
unset ligne_token

# --- 4. Projets de test ---------------------------------------------------------------------------

etape "Projet de test root/$PROJET (GitLab) et $SONAR_CLE (SonarQube)"
verrou_tenu
# Projet réutilisé d'une exécution à l'autre, réglages rétablis : sans Auto DevOps (un seul pipeline,
# le nôtre), runners d'instance autorisés, privé. Un projet en attente de suppression est restauré.
# shellcheck disable=SC2016 # code Ruby
code_projet='
chemin = ARGV[0]
reglages = { "auto_devops_enabled" => "false", "shared_runners_enabled" => "true", "visibility" => "private" }
code, p = api("get", "/projects/#{URI.encode_www_form_component("root/#{chemin}")}")
case code
when 404
  p = api!("post", "/projects", 201, reglages.merge("name" => chemin, "path" => chemin))
  puts "ETAT=créé"
when 200
  etat = "réutilisé"
  if p["marked_for_deletion_on"]
    api!("post", "/projects/#{p["id"]}/restore", [200, 201])
    etat = "restauré"
  end
  if reglages.any? { |k, v| p[k].to_s != v }
    p = api!("put", "/projects/#{p["id"]}", 200, reglages)
    etat += ", réglages rétablis"
  end
  puts "ETAT=#{etat}"
else
  abort("Lecture du projet root/#{chemin} : HTTP #{code}")
end
puts "ID=#{p["id"]}"
puts "URL=#{p["web_url"]}"
'
sortie="$(gitlab_api "$code_projet" "$PROJET")" || erreur "projet GitLab root/$PROJET : création impossible (voir ci-dessus)"
projet_id="$(sed -n 's/^ID=//p' <<<"$sortie")"
projet_url="$(sed -n 's/^URL=//p' <<<"$sortie")"
[[ "$projet_id" =~ ^[0-9]+$ ]] || erreur "réponse inattendue à la création du projet GitLab"
echo "    GitLab : projet $(sed -n 's/^ETAT=//p' <<<"$sortie") (id=$projet_id)."

# Provisionné privé avant la première analyse (sinon créé public par le scanner)
sonar_api GET /api/projects/search "$admin" "projects=$SONAR_CLE" || erreur "SonarQube injoignable"
[[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu sur api/projects/search : $CORPS"
if [[ "$CORPS" == *"\"key\":\"$SONAR_CLE\""* ]]; then
  echo "    SonarQube : projet réutilisé."
else
  sonar_api POST /api/projects/create "$admin" "project=$SONAR_CLE" "name=$SONAR_CLE" visibility=private \
    "mainBranch=$BRANCHE" || erreur "SonarQube injoignable"
  [[ "$CODE" == 200 ]] || erreur "HTTP $CODE inattendu à la création du projet SonarQube : $CORPS"
  echo "    SonarQube : projet créé (privé)."
fi

# --- 5. Envoi du .gitlab-ci.yml -------------------------------------------------------------------

etape "Envoi de $SOURCES/ sur la branche $BRANCHE"
# Fichiers « chemin=contenu en base64 » en arguments (contenu versionné, non secret). Commit des seuls
# fichiers absents ou différents ; tout identique : nouveau pipeline sur la branche.
fichiers=()
while IFS= read -r f; do
  fichiers+=("$f=$(base64 < "$SOURCES/$f" | tr -d '\n')")
done < <(cd "$SOURCES" && find . -type f | sed 's#^\./##' | LC_ALL=C sort)
((${#fichiers[@]})) || erreur "aucun fichier dans $SOURCES"
# shellcheck disable=SC2016 # code Ruby
code_envoi='
id, branche = ARGV[0], ARGV[1]
existe = api("get", "/projects/#{id}/repository/branches/#{branche}")[0] == 200
actions = ARGV[2..].filter_map do |a|
  chemin, b64 = a.split("=", 2)
  contenu = b64.unpack1("m")
  action = "create"
  if existe
    code, f = api("get", "/projects/#{id}/repository/files/#{URI.encode_www_form_component(chemin)}?ref=#{branche}")
    abort("Lecture de #{chemin} : HTTP #{code}") unless [200, 404].include?(code)
    if code == 200
      next if f["content"].unpack1("m") == contenu
      action = "update"
    end
  end
  { "action" => action, "file_path" => chemin, "content" => b64, "encoding" => "base64" }
end
if actions.empty?
  p = api!("post", "/projects/#{id}/pipeline", 201, { "ref" => branche })
  puts "PIPELINE=#{p["id"]}"
  puts "SHA=#{p["sha"]}"
else
  c = api!("post", "/projects/#{id}/repository/commits", 201,
    json: { "branch" => branche, "commit_message" => "test: smoke test de la plateforme (make smoke)", "actions" => actions })
  puts "COMMIT=#{actions.map { |a| "#{a["action"]} #{a["file_path"]}" }.join(", ")}"
  puts "SHA=#{c["id"]}"
end
'
sortie="$(gitlab_api "$code_envoi" "$projet_id" "$BRANCHE" "${fichiers[@]}")" \
  || erreur "envoi des fichiers du projet de test impossible (voir ci-dessus)"
sha="$(sed -n 's/^SHA=//p' <<<"$sortie")"
pipeline="$(sed -n 's/^PIPELINE=//p' <<<"$sortie")"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || erreur "réponse inattendue à l'envoi des fichiers"
if [[ -n "$pipeline" ]]; then
  echo "    Fichiers déjà à jour : pipeline $pipeline déclenché sur $BRANCHE (${sha:0:8})."
else
  echo "    Commit ${sha:0:8} : $(sed -n 's/^COMMIT=//p' <<<"$sortie")."
fi

# --- 6. Pipeline ----------------------------------------------------------------------------------

etape "Pipeline du commit ${sha:0:8}"
# shellcheck disable=SC2016 # code Ruby
code_pipeline='
require "time"
id, sha, pid = ARGV
if pid.to_s.empty?
  p = api!("get", "/projects/#{id}/pipelines?sha=#{sha}&order_by=id&sort=desc&per_page=1", 200).first
  exit 0 unless p
else
  p = api!("get", "/projects/#{id}/pipelines/#{pid}", 200)
end
puts "PIPELINE=#{p["id"]}"
puts "STATUT=#{p["status"]}"
puts "URL=#{p["web_url"]}"
puts "CREE=#{Time.parse(p["created_at"]).utc.strftime("%Y-%m-%dT%H:%M:%S+0000")}"
'
# Pipeline créé par le push : apparaît en quelques secondes
pipeline_trouve() {
  sortie="$(gitlab_api "$code_pipeline" "$projet_id" "$sha" "$pipeline")" || return 1
  [[ -n "$(sed -n 's/^PIPELINE=//p' <<<"$sortie")" ]]
}
attendre "Pipeline du commit" 120 pipeline_trouve \
  || erreur "aucun pipeline créé pour le commit ${sha:0:8} ($projet_url/-/pipelines)"
pipeline="$(sed -n 's/^PIPELINE=//p' <<<"$sortie")"
pipeline_url="$(sed -n 's/^URL=//p' <<<"$sortie")"
pipeline_cree="$(sed -n 's/^CREE=//p' <<<"$sortie")"
echo "    Pipeline $pipeline : $pipeline_url"

# Attente tant que le pipeline est en cours ; succès seulement sur « success »
debut=$SECONDS indice=0
while :; do
  sortie="$(gitlab_api "$code_pipeline" "$projet_id" "$sha" "$pipeline")" \
    || erreur "lecture du pipeline $pipeline impossible (voir ci-dessus)"
  statut="$(sed -n 's/^STATUT=//p' <<<"$sortie")"
  case "$statut" in
    success) echo "    Pipeline $pipeline : succès."; break ;;
    created | waiting_for_resource | preparing | pending | running) ;;
    *) statut_final="$statut"; break ;;
  esac
  if [[ "$statut" == pending ]] && ((SECONDS - debut > ATTENTE_PENDING && !indice)); then
    echo "    Pipeline toujours en attente d'un runner : runner d'instance en ligne et autorisé ? (make bootstrap ENV=$env)" >&2
    indice=1
  fi
  ((SECONDS - debut < ATTENTE_PIPELINE)) \
    || { statut_final="$statut (délai de $((ATTENTE_PIPELINE / 60)) min dépassé)"; break; }
  echo "    Pipeline $pipeline : $statut ($((SECONDS - debut)) s écoulées)..."
  sleep "$PAS"
done

if [[ -n "${statut_final:-}" ]]; then
  # État des jobs et fin du journal des jobs en échec
  # shellcheck disable=SC2016 # code Ruby
  code_jobs='
  id, pid = ARGV
  api!("get", "/projects/#{id}/pipelines/#{pid}/jobs?per_page=100", 200).each do |j|
    puts "    Job #{j["name"]} : #{j["status"]}#{j["failure_reason"] ? " (#{j["failure_reason"]})" : ""}"
    next unless j["status"] == "failed"
    _, trace = api("get", "/projects/#{id}/jobs/#{j["id"]}/trace")
    puts "    --- fin du journal de #{j["name"]} ---"
    puts trace.to_s.gsub(/\e\[[0-9;]*[A-Za-z]/, "").lines.last(25).map { |l| "    | #{l}" }.join
  end
  '
  rapport="$(gitlab_api "$code_jobs" "$projet_id" "$pipeline" || true)"
  echo "$rapport" >&2
  if [[ "$rapport" == *runner_external_dependency_failure* ]]; then
    {
      echo "Indice : image d'un job (auxiliaire du runner ou image du job) non téléchargeable depuis l'hôte."
      echo "  Sans accès à registry.gitlab.com : GITLAB_RUNNER_HELPER_IMAGE puis make bootstrap ENV=$env"
      echo "  (docs/bootstrap.md, « Image auxiliaire des jobs »)."
    } >&2
  fi
  erreur "pipeline $pipeline : $statut_final ($pipeline_url)"
fi

verrou_tenu

# --- 7. Analyse SonarQube -------------------------------------------------------------------------

etape "Analyse SonarQube du commit ${sha:0:8}"
# Analyse de la branche, postérieure à la création du pipeline, portant la révision du commit. Elle
# est intégrée par SonarQube (tâche de fond) après la fin du job sonar-scanner.
analyse_presente() {
  sonar_api GET /api/project_analyses/search "$admin" "project=$SONAR_CLE" "branch=$BRANCHE" \
    "from=$pipeline_cree" ps=100 || return 1
  [[ "$CODE" == 200 && "$CORPS" == *"\"revision\":\"$sha\""* ]] && return 0
  # Tâche d'intégration en échec : inutile d'attendre
  sonar_api GET /api/ce/activity "$admin" "component=$SONAR_CLE" status=FAILED,CANCELED \
    "minSubmittedAt=$pipeline_cree" || return 1
  if [[ "$CODE" == 200 && "$CORPS" == *'"status":"'* ]]; then
    erreur "intégration de l'analyse en échec dans SonarQube ($sonar_url/project/background_tasks?id=$SONAR_CLE)"
  fi
  return 1
}
attendre "Analyse" "$ATTENTE_ANALYSE" analyse_presente \
  || erreur "aucune analyse du commit ${sha:0:8} dans SonarQube après $((ATTENTE_ANALYSE / 60)) min ($sonar_url/dashboard?id=$SONAR_CLE)"
echo "    Analyse présente : $sonar_url/dashboard?id=$SONAR_CLE"

# --- 8. Nettoyage ---------------------------------------------------------------------------------

if ((nettoyer)); then
  etape "Nettoyage des projets de test (NETTOYER=1)"
  # GitLab peut différer la suppression (projet seulement marqué, renommé) : suppression définitive
  # demandée avec le chemin courant du projet, relu par son id
  # shellcheck disable=SC2016 # code Ruby
  code_suppression='
  id = ARGV[0]
  code, _ = api("delete", "/projects/#{id}")
  abort("Suppression du projet #{id} : HTTP #{code}") unless [202, 404].include?(code)
  code, p = api("get", "/projects/#{id}")
  if code == 200 && p["marked_for_deletion_on"]
    chemin = URI.encode_www_form_component(p["path_with_namespace"])
    c, corps = api("delete", "/projects/#{id}?permanently_remove=true&full_path=#{chemin}")
    abort("Suppression définitive du projet #{id} : HTTP #{c} : #{corps}") unless [202, 404].include?(c)
  end
  '
  gitlab_api "$code_suppression" "$projet_id" || erreur "suppression du projet GitLab impossible (voir ci-dessus)"
  # shellcheck disable=SC2016 # code Ruby
  code_absent='exit(api("get", "/projects/#{ARGV[0]}")[0] == 404 ? 0 : 1)'
  projet_absent() { gitlab_api "$code_absent" "$projet_id"; }
  attendre "Suppression du projet GitLab" "$ATTENTE_SUPPRESSION" projet_absent \
    || erreur "projet GitLab $projet_id toujours présent après $((ATTENTE_SUPPRESSION / 60)) min"
  echo "    GitLab : projet root/$PROJET supprimé."
  projet_id=""

  sonar_api POST /api/projects/delete "$admin" "project=$SONAR_CLE" || erreur "SonarQube injoignable"
  [[ "$CODE" == 204 || "$CODE" == 404 ]] || erreur "HTTP $CODE inattendu à la suppression du projet SonarQube : $CORPS"
  echo "    SonarQube : projet $SONAR_CLE supprimé."
fi

# --- Récapitulatif --------------------------------------------------------------------------------

echo
echo "Smoke test réussi ($env) : pipeline $pipeline au vert, analyse SonarQube du commit ${sha:0:8} présente."
if ((nettoyer)); then
  echo "  Projets de test supprimés (NETTOYER=1)."
else
  echo "  Projet    : $projet_url"
  echo "  Pipeline  : $pipeline_url"
  echo "  SonarQube : $sonar_url/dashboard?id=$SONAR_CLE"
  echo "  Supprimer les projets de test : make smoke ENV=$env NETTOYER=1"
fi
