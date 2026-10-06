#!/usr/bin/env bash
# Bootstrap GitLab d'une instance déployée : attente de GitLab, jeton d'accès personnel (PAT)
# d'administration renouvelé, variables CI d'instance SonarQube (SONAR_HOST_URL, SONAR_TOKEN), runner
# d'instance enregistré. Aucune donnée de test créée ; idempotent.
# Lancé par `make bootstrap ENV=<env>` (scripts/instance.sh bootstrap), qui positionne la cible Docker
# (contexte SSH d'une instance distante). Documentation : docs/bootstrap.md.
#
# Usage : scripts/bootstrap/gitlab.sh envs/<env>.env
#
# Les appels à l'API GitLab partent du conteneur gitlab (http://localhost) : ils ne dépendent ni du
# DNS, ni du TLS, ni de l'emplacement du poste. Le JSON est traité par le Ruby embarqué de l'image
# GitLab : rien à installer sur le poste. Les jetons ne passent jamais en argument de processus.
# Seuls l'URL publique, l'enregistrement et les jobs passent par Traefik et son certificat : en
# TLS_MODE=custom, la CA privée facultative montée dans le runner les vérifie (docs/certificats.md).
# Un seul bootstrap à la fois par instance : verrou flock dans le volume du runner (voir « Verrou »).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/tls.sh
source "$ROOT/scripts/lib/tls.sh"

# Image par défaut des jobs CI (dernière stable, épinglée)
readonly RUNNER_IMAGE="alpine:3.24.2"
readonly DESCRIPTION_DEFAUT="devops-platform-runner"
# Nom du PAT root du bootstrap : tous les PAT actifs de ce nom sont révoqués avant d'en créer un
readonly PAT_NOM="devops-platform-bootstrap"
# Marqueur des runners créés par le bootstrap (maintenance_note) : indépendant de la description,
# il permet de retrouver et supprimer les anciens runners après un changement de description
readonly MARQUEUR="Géré par devops-platform (make bootstrap) : ne pas modifier."
readonly CONFIG_RUNNER=/etc/gitlab-runner/config.toml
# URL de SonarQube pour les jobs quand l'URL publique n'est pas utilisable : nom de service Docker sur
# le réseau de la plateforme (port interne de compose/sonarqube.yml)
readonly SONAR_URL_INTERNE="http://sonarqube:9000"
# CA privée de TLS_MODE=custom dans le conteneur gitlab-runner : montage de compose/tls/gitlab/custom.yml
# (config/certs/ca/ca.pem), à garder identiques
readonly CA_CONTENEUR=/etc/devops-platform/ca/ca.pem
# Verrou de l'instance : dans le volume du runner, donc sur l'hôte de l'instance quel que soit le poste
readonly FICHIER_VERROU=/etc/gitlab-runner/.bootstrap.lock
readonly RUBY=/opt/gitlab/embedded/bin/ruby
readonly ATTENTE_GITLAB=900 ATTENTE_URL=300 ATTENTE_EN_LIGNE=120 ATTENTE_VERROU=60 PAS=10

erreur() { echo "Erreur : $*" >&2; exit 1; }
etape() { echo; echo "==> $*"; }

(($# == 1)) || { echo "Usage : $0 envs/<env>.env" >&2; exit 1; }
env_file="$1"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file"
env="$(basename "$env_file" .env)"

dc() { docker compose --env-file "$env_file" "$@"; }

# Garde-fou : lancé hors `make bootstrap`, une instance distante serait cherchée sur le moteur local
# (même nom de projet compose) et une éventuelle instance locale reconfigurée à sa place
if [[ -n "$(env_valeur_fichier "$env_file" DEPLOY_SSH)" && "${DOCKER_CONTEXT:-}" != "devops-platform-$env" ]]; then
  erreur "instance distante (DEPLOY_SSH dans $env_file) : lancer make bootstrap ENV=$env"
fi

# --- Paramètres de l'instance --------------------------------------------------------------------

description="$(env_valeur "$env_file" GITLAB_RUNNER_DESCRIPTION)"
description="${description:-$DESCRIPTION_DEFAUT}"
motif_description='^[A-Za-z0-9 ._-]{1,100}$'
[[ "$description" =~ $motif_description ]] \
  || erreur "GITLAB_RUNNER_DESCRIPTION invalide : $description (1 à 100 caractères parmi lettres sans accent, chiffres, espace, . _ -)"

reseau_plateforme="$(env_valeur "$env_file" PLATFORM_NETWORK)"
reseau_plateforme="${reseau_plateforme:-devops-platform}"
reseau="$(env_valeur "$env_file" GITLAB_RUNNER_NETWORK)"
reseau="${reseau:-$reseau_plateforme}"
[[ "$reseau" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]] \
  || erreur "GITLAB_RUNNER_NETWORK invalide : $reseau (nom de réseau Docker attendu)"

# Image auxiliaire (helper) des jobs : dépôt sans tag. Le tag v${CI_RUNNER_VERSION} est enregistré tel
# quel et développé par le runner à chaque job : le helper suit la version du binaire, quelle que soit
# l'architecture (tag multi-arch), sans ré-enregistrement après une montée de version. Vide : image
# standard de GitLab (registry.gitlab.com). Voir docs/bootstrap.md.
helper_depot="$(env_valeur "$env_file" GITLAB_RUNNER_HELPER_IMAGE)"
helper_image=""
if [[ -n "$helper_depot" ]]; then
  composant='[a-z0-9]([a-z0-9._-]*[a-z0-9])?'
  motif_depot="^(${composant}(:[0-9]+)?/)?${composant}(/${composant})*\$"
  [[ "$helper_depot" =~ $motif_depot ]] \
    || erreur "GITLAB_RUNNER_HELPER_IMAGE invalide : $helper_depot (dépôt sans tag ni digest attendu, ex. gitlab/gitlab-runner-helper : le tag est calculé, voir docs/bootstrap.md)"
  helper_image="$helper_depot:v\${CI_RUNNER_VERSION}"
fi

# URL publique : même règle que l'external_url de GitLab (compose/gitlab.yml, url_derivee)
hostname="$(env_valeur "$env_file" GITLAB_HOSTNAME)"
hostname="${hostname:-gitlab.localhost}"
url="$(env_valeur "$env_file" GITLAB_EXTERNAL_URL)"
tls_mode="$(env_valeur "$env_file" TLS_MODE)"
tls_mode="${tls_mode:-none}"
url="${url:-$(url_derivee "$hostname" "$tls_mode")}"
url="${url%/}"
# Clone des jobs : URL publique (alias réseau de Traefik), sauf *.localhost, que libcurl (donc git)
# résout toujours vers 127.0.0.1 : nom de service Docker (docs/gitlab-proxy.md)
if est_hostname_local "$hostname"; then clone_url="http://gitlab"; else clone_url="$url"; fi

# SonarQube : URL publique, même règle que sonar.core.serverBaseURL (compose/sonarqube.yml), et token
# d'analyse écrit par l'étape SonarQube (scripts/bootstrap/sonarqube.sh)
sonar_hostname="$(env_valeur "$env_file" SONARQUBE_HOSTNAME)"
sonar_hostname="${sonar_hostname:-sonarqube.localhost}"
sonar_url="$(env_valeur "$env_file" SONARQUBE_EXTERNAL_URL)"
sonar_url="${sonar_url:-http://$sonar_hostname}"
sonar_url="${sonar_url%/}"
sonar_token_fichier="outputs/$env.sonarqube-token"

# --- Verrou -----------------------------------------------------------------------------------------

# Les commandes du bootstrap sont des docker compose exec séparés : le verrou est tenu, pendant tout le
# script, par un détenteur lancé en coprocessus. C'est un sh du conteneur gitlab-runner qui garde le
# verrou (fd 9) jusqu'à la fin de son entrée standard. Script terminé, en échec, interrompu ou tué :
# entrée fermée, verrou libéré par le noyau. Dans toutes ses branches, le détenteur attend la fin de
# son entrée avant de sortir, pour que ses réponses restent lisibles. Son entrée n'est ouverte que par
# le script (descripteur du coprocessus, fermé au lancement des commandes) : seule sa fin la ferme.
verrou_pid="" verrou_in="" verrou_out="" erreurs_rails=""

nettoyer() {
  local code=$? i
  if [[ -n "$erreurs_rails" ]]; then rm -f "$erreurs_rails"; fi
  if [[ -n "$verrou_pid" ]]; then
    exec {verrou_in}>&-
    # Attente bornée : la fin de l'entrée se propage au conteneur (par SSH pour une instance distante)
    for ((i = 0; i < 20; i++)); do
      kill -0 "$verrou_pid" 2> /dev/null || break
      sleep 0.5
    done
    if kill -0 "$verrou_pid" 2> /dev/null; then
      echo "Attention : le détenteur du verrou ne s'est pas arrêté, interrompu (verrou libéré à la fin de sa connexion)." >&2
      kill "$verrou_pid" 2> /dev/null || true
    fi
    wait "$verrou_pid" 2> /dev/null || true
  fi
  exit "$code"
}
trap nettoyer EXIT

prendre_verrou() {
  local detenteur reponse ligne lignes=()
  detenteur="$(id -un)@${HOSTNAME:-$(uname -n)} (pid $$), depuis le $(date '+%F %T %z')"
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  coproc verrou_detenteur {
    exec docker compose --env-file "$env_file" exec -T gitlab-runner sh -c '
      if ! (: >> "$1") 2> /dev/null; then echo "ECHEC $1 inaccessible en écriture"; exec cat > /dev/null; fi
      exec 9>> "$1"
      if ! flock -w "$3" 9; then echo OCCUPE; cat "$1"; echo FIN; exec cat > /dev/null; fi
      printf "%s\n" "$2" > "$1"
      echo PRIS
      exec cat > /dev/null' sh "$FICHIER_VERROU" "$detenteur" 5
  }
  # shellcheck disable=SC2154 # variables créées par coproc
  verrou_pid="$verrou_detenteur_PID" verrou_in="${verrou_detenteur[1]}"
  # Copie de la sortie du détenteur : bash ferme les descripteurs du coprocessus dès qu'il s'arrête
  exec {verrou_out}<&"${verrou_detenteur[0]}"
  if ! IFS= read -r -t "$ATTENTE_VERROU" -u "$verrou_out" reponse; then
    erreur "verrou $FICHIER_VERROU : pas de réponse du conteneur gitlab-runner en $ATTENTE_VERROU s (voir ci-dessus)"
  fi
  case "$reponse" in
    PRIS) ;;
    OCCUPE)
      while IFS= read -r -t 10 -u "$verrou_out" ligne && [[ "$ligne" != FIN ]]; do lignes+=("$ligne"); done
      {
        echo "Erreur : un autre make bootstrap est en cours sur l'instance $env (verrou $FICHIER_VERROU du conteneur gitlab-runner)."
        echo "  Dernier détenteur connu : ${lignes[*]:-inconnu}"
        echo "  Aucune modification faite. Attendre la fin de cette exécution, puis relancer make bootstrap ENV=$env."
      } >&2
      exit 1
      ;;
    *) erreur "verrou $FICHIER_VERROU : réponse inattendue du conteneur gitlab-runner : $reponse" ;;
  esac
  exec {verrou_out}<&-
}

# Détenteur toujours actif : sinon (conteneur gitlab-runner redémarré, connexion SSH coupée), le verrou
# est perdu et une autre exécution a pu le prendre
verrou_tenu() {
  kill -0 "$verrou_pid" 2> /dev/null \
    || erreur "verrou $FICHIER_VERROU perdu (conteneur gitlab-runner redémarré, connexion SSH coupée ?) : relancer make bootstrap ENV=$env"
}

# --- Fonctions ------------------------------------------------------------------------------------

# Attend qu'une commande réussisse : <libellé> <délai en s> <commande…>
attendre() {
  local libelle="$1" delai="$2" debut=$SECONDS
  shift 2
  until "$@"; do
    ((SECONDS - debut < delai)) || return 1
    echo "    $libelle : pas encore, nouvel essai dans $PAS s ($((SECONDS - debut)) s écoulées)..."
    sleep "$PAS"
  done
}

gitlab_pret() { dc exec -T gitlab curl -sf -o /dev/null http://localhost/-/readiness 2>/dev/null; }

# URL publique joignable depuis le runner (alias Traefik, certificat) : 200 ou 401 sur /api/v4/version.
# Nom résolu par le DNS du conteneur, comme le fait le runner, puis imposé à curl (--resolve) : curl
# résoudrait de lui-même tout *.localhost vers 127.0.0.1. Certificat vérifié avec la CA du runner
# (ca_runner) si elle est définie, sinon avec le magasin système ; jamais sans vérification.
derniere_erreur=""
url_publique_joignable() {
  local sortie port=80
  [[ "$url" == https://* ]] && port=443
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  sortie="$(dc exec -T gitlab-runner sh -c '
    h="$1" p="$2" u="$3" ca="$4"
    ip="$(getent ahostsv4 "$h" | awk "{ print \$1; exit }")"
    [ -n "$ip" ] || { echo "résolution de $h impossible"; exit 1; }
    set --
    if [ -n "$ca" ]; then set -- --cacert "$ca"; fi
    exec curl -sS "$@" -o /dev/null -w "%{http_code}" --resolve "$h:$p:$ip" "$u/api/v4/version"' \
    sh "$hostname" "$port" "$url" "$ca_runner" 2>&1)" || true
  derniere_erreur="$sortie"
  [[ "$sortie" =~ (200|401)$ ]]
}

# Fonctions Ruby communes : appel de l'API GitLab depuis le conteneur gitlab, jeton lu sur l'entrée
# standard (jamais en argument), réponse JSON décodée
# shellcheck disable=SC2016 # code Ruby
readonly RUBY_API='
require "json"
require "net/http"
JETON = STDIN.gets.to_s.chomp
def api(methode, chemin, params = nil)
  uri = URI("http://localhost/api/v4#{chemin}")
  req = Net::HTTP.const_get(methode.capitalize).new(uri)
  req["PRIVATE-TOKEN"] = JETON
  req.set_form_data(params) if params
  rep = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  corps = rep.body.to_s
  [rep.code.to_i, corps.empty? ? nil : (JSON.parse(corps) rescue corps)]
end
def api!(methode, chemin, attendus, params = nil)
  code, corps = api(methode, chemin, params)
  abort("API GitLab #{methode.upcase} #{chemin} : HTTP #{code} : #{corps}") unless Array(attendus).include?(code)
  corps
end
'

# Exécute du code Ruby (après RUBY_API) dans le conteneur gitlab : <code> [arguments…]. Les lignes de
# stdin_extra (secrets) suivent le PAT sur l'entrée standard, où le code Ruby les lit (STDIN.gets)
stdin_extra=()
gitlab_api() {
  local code="$1"
  shift
  printf '%s\n' "$pat" "${stdin_extra[@]}" | dc exec -T gitlab "$RUBY" -e "$RUBY_API$code" -- "$@"
}

# Blocs [[runners]] de config.toml, une ligne par bloc, champs séparés par \037 :
# id, name, url, clone_url, executor, image, network_mode, tls-ca-file, helper_image. Les jetons ne sont
# jamais extraits.
# shellcheck disable=SC2016 # programme awk
readonly AWK_BLOCS='
function sortir() { if (dans) printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\037%s\n", id, nom, url, clone, exe, image, reseau, ca, helper }
function val(l) { sub(/^[^=]*= */, "", l); gsub(/^"|"$/, "", l); return l }
/^\[\[runners\]\]/ { sortir(); dans = 1; id = nom = url = clone = exe = image = reseau = ca = helper = ""; next }
/^\[/ { sortir(); dans = 0; next }
dans && /^[ \t]*id[ \t]*=/ { id = val($0) }
dans && /^[ \t]*name[ \t]*=/ { nom = val($0) }
dans && /^[ \t]*url[ \t]*=/ { url = val($0) }
dans && /^[ \t]*clone_url[ \t]*=/ { clone = val($0) }
dans && /^[ \t]*executor[ \t]*=/ { exe = val($0) }
dans && /^[ \t]*image[ \t]*=/ { image = val($0) }
dans && /^[ \t]*network_mode[ \t]*=/ { reseau = val($0) }
dans && /^[ \t]*tls-ca-file[ \t]*=/ { ca = val($0) }
dans && /^[ \t]*helper_image[ \t]*=/ { helper = val($0) }
END { sortir() }
'

# Réécrit config.toml en ne gardant que le bloc [[runners]] d'id <garder> (le reste du fichier intact)
# shellcheck disable=SC2016 # programme awk
readonly AWK_FILTRE='
function vider() { if (dans && id == garder) printf "%s", tampon; tampon = ""; dans = 0 }
/^\[\[runners\]\]/ { vider(); dans = 1; id = ""; tampon = $0 "\n"; next }
/^\[/ { vider(); print; next }
dans { tampon = tampon $0 "\n"; if ($0 ~ /^[ \t]*id[ \t]*=/) { v = $0; sub(/^[^=]*= */, "", v); id = v }; next }
{ print }
END { vider() }
'

blocs_runner() {
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  dc exec -T gitlab-runner sh -c '[ -f "$1" ] || exit 0; exec awk "$2" "$1"' sh "$CONFIG_RUNNER" "$AWK_BLOCS"
}

filtrer_config_runner() { # <id à garder, ou - pour aucun>
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  dc exec -T gitlab-runner sh -c '
    set -e
    umask 077
    f="$1"
    [ -f "$f" ] || exit 0
    awk -v garder="$2" "$3" "$f" > "$f.tmp"
    if cmp -s "$f" "$f.tmp"; then rm -f "$f.tmp"; else mv "$f.tmp" "$f"; echo modifie; fi' \
    sh "$CONFIG_RUNNER" "$1" "$AWK_FILTRE"
}

# --- 1. Disponibilité --------------------------------------------------------------------------------

etape "Disponibilité de GitLab"
for service in gitlab gitlab-runner; do
  [[ -n "$(dc ps -q --status running "$service")" ]] \
    || erreur "service $service arrêté : démarrer l'instance (make deploy ENV=$env)"
done
prendre_verrou
echo "    Verrou de l'instance pris ($FICHIER_VERROU, conteneur gitlab-runner)."

# CA privée : utilisée seulement en TLS_MODE=custom, URL en https et ca.pem monté dans le runner ; sinon
# magasin système (comportement de letsencrypt et none)
ca_runner=""
if [[ "$tls_mode" == custom && "$url" == https://* ]]; then
  if dc exec -T gitlab-runner test -s "$CA_CONTENEUR"; then
    ca_runner="$CA_CONTENEUR"
    echo "    CA privée du runner : $CA_CONTENEUR (config/certs/ca/ca.pem)."
  elif [[ -f config/certs/ca/ca.pem ]]; then
    {
      echo "Attention : config/certs/ca/ca.pem présente sur le poste mais pas dans gitlab-runner :"
      echo "  make deploy ENV=$env pour la monter, puis relancer make bootstrap ENV=$env."
    } >&2
  fi
fi
docker network inspect "$reseau" > /dev/null 2>&1 \
  || erreur "réseau Docker $reseau introuvable sur la cible (GITLAB_RUNNER_NETWORK, PLATFORM_NETWORK)"
if [[ "$reseau" != "$reseau_plateforme" ]]; then
  {
    echo "Attention : réseau des jobs ($reseau) différent du réseau de la plateforme ($reseau_plateforme)."
    echo "  Les jobs clonent par $clone_url et joignent SonarQube par SONAR_HOST_URL, joignables seulement"
    echo "  sur le réseau de la plateforme : le réseau $reseau doit le permettre, sinon tous les jobs"
    echo "  échoueront (docs/bootstrap.md)."
  } >&2
fi
attendre "GitLab" "$ATTENTE_GITLAB" gitlab_pret \
  || erreur "GitLab n'est pas prêt après $((ATTENTE_GITLAB / 60)) min (docker compose logs gitlab)"
echo "    GitLab est prêt."
if ! attendre "URL publique $url depuis le runner" "$ATTENTE_URL" url_publique_joignable; then
  echo "Dernière réponse : $derniere_erreur" >&2
  erreur "$url injoignable depuis gitlab-runner (Traefik, certificat : docs/exposition.md, docs/certificats.md)"
fi
echo "    $url joignable depuis le runner."

# --- 2. Jeton d'accès personnel d'administration ----------------------------------------------------

etape "Jeton d'accès personnel root ($PAT_NOM)"
# shellcheck disable=SC2016 # code Ruby
code_pat='
root = User.find_by_username("root") or abort("Compte root introuvable.")
nom = ENV.fetch("BOOTSTRAP_PAT_NOM")
root.personal_access_tokens.active.where(name: nom).find_each do |t|
  r = PersonalAccessTokens::RevokeService.new(root, token: t).execute
  abort("Révocation du jeton #{t.id} impossible : #{r.message}") unless r.success?
  puts "REVOQUE=#{t.id}"
end
r = PersonalAccessTokens::CreateService.new(
  current_user: root, target_user: root,
  organization_id: Organizations::Organization.default_organization.id,
  params: { name: nom, scopes: %w[api admin_mode], expires_at: Date.today + 1 }
).execute
abort("Création du jeton impossible : #{r.message}") unless r.success?
t = r.payload[:personal_access_token]
puts "EXPIRATION=#{t.expires_at}"
puts "PAT=#{t.token}"
'
erreurs_rails="$(mktemp)"
if ! sortie_pat="$(dc exec -T -e BOOTSTRAP_PAT_NOM="$PAT_NOM" gitlab gitlab-rails runner "$code_pat" 2> "$erreurs_rails")"; then
  cat "$erreurs_rails" >&2
  erreur "création du jeton d'accès personnel impossible (voir ci-dessus)"
fi
pat="$(sed -n 's/^PAT=//p' <<<"$sortie_pat" | tail -n1)"
[[ -n "$pat" ]] || { cat "$erreurs_rails" >&2; erreur "jeton d'accès personnel absent de la sortie de gitlab-rails"; }
expiration="$(sed -n 's/^EXPIRATION=//p' <<<"$sortie_pat" | tail -n1)"
revoques="$(grep -c '^REVOQUE=' <<<"$sortie_pat" || true)"
echo "    Jeton créé (expire le $expiration) ; $revoques ancien(s) jeton(s) révoqué(s)."

# --- 3. Variables CI d'instance SonarQube ---------------------------------------------------------------

etape "Variables CI d'instance SonarQube (SONAR_HOST_URL, SONAR_TOKEN)"
# Création ou mise à jour d'une variable d'instance : <clé> <masquée 0|1> <description>, valeur en
# dernière ligne de l'entrée standard (jamais en argument). La réponse du GET contient la valeur : seuls
# des marqueurs sont affichés, jamais un corps de réponse.
# shellcheck disable=SC2016 # code Ruby
code_variable='
cle, masquee, description = ARGV[0], ARGV[1] == "1", ARGV[2]
valeur = STDIN.gets.to_s.chomp
attendu = { "value" => valeur, "masked" => masquee, "protected" => false, "raw" => true,
            "variable_type" => "env_var", "description" => description }
params = attendu.transform_values(&:to_s)
def motif(corps) = corps.is_a?(Hash) ? " : #{corps["message"]}" : ""
code, actuel = api("get", "/admin/ci/variables/#{cle}")
case code
when 404
  c, corps = api("post", "/admin/ci/variables", params.merge("key" => cle))
  abort("Création de la variable #{cle} : HTTP #{c}#{motif(corps)}") unless c == 201
  puts "CREEE"
when 200
  if attendu.all? { |k, v| actuel[k] == v }
    puts "INCHANGEE"
  else
    c, corps = api("put", "/admin/ci/variables/#{cle}", params)
    abort("Mise à jour de la variable #{cle} : HTTP #{c}#{motif(corps)}") unless c == 200
    puts "MAJ"
  end
else
  abort("Lecture de la variable #{cle} : HTTP #{code}")
end
'
definir_variable() { # <clé> <masquée 0|1> <valeur>
  local sortie
  stdin_extra=("$3")
  sortie="$(gitlab_api "$code_variable" "$1" "$2" "$MARQUEUR")" || sortie=""
  stdin_extra=()
  case "$sortie" in
    CREEE) echo "    $1 créée." ;;
    MAJ) echo "    $1 mise à jour." ;;
    INCHANGEE) echo "    $1 déjà à jour : rien à faire." ;;
    *) erreur "variable CI d'instance $1 : écriture impossible (voir ci-dessus)" ;;
  esac
}

# Token valide pour SonarQube : api/authentication/validate depuis le conteneur sonarqube, token dans la
# configuration curl lue sur l'entrée standard (jamais en argument). Format déjà contrôlé : sans " ni \.
token_sonar_valide() { # <token>
  local reponse
  reponse="$(printf 'url = "http://localhost:9000/api/authentication/validate"\nuser = "%s:"\n' "$1" \
    | dc exec -T sonarqube curl -sS -K - 2> /dev/null)" || return 1
  [[ "$reponse" == *'"valid":true'* ]]
}

etat_sonar_url="non posée" etat_sonar_token="non posée"
if [[ " $(dc config --services | paste -sd ' ' -) " != *" sonarqube "* ]]; then
  echo "    Service sonarqube absent de l'instance : étape ignorée."
  etat_sonar_url="non posée (service sonarqube absent)" etat_sonar_token="$etat_sonar_url"
else
  verrou_tenu
  # URL des jobs : publique (alias réseau de Traefik), sauf hostname *.localhost (que libcurl résout vers
  # 127.0.0.1) et CA privée montée dans le runner (que la JVM du scanner n'utilise pas) : nom de service
  if est_hostname_local "$sonar_hostname"; then
    sonar_host_url="$SONAR_URL_INTERNE" raison="interne : hostname local"
  elif [[ -n "$ca_runner" ]]; then
    sonar_host_url="$SONAR_URL_INTERNE" raison="interne : CA privée"
  else
    sonar_host_url="$sonar_url" raison="URL publique"
  fi
  definir_variable SONAR_HOST_URL 0 "$sonar_host_url"
  etat_sonar_url="$sonar_host_url ($raison)"

  # Token : celui du fichier, s'il est valide. Un token révoqué (bootstrap lancé depuis un autre poste)
  # remplacerait le token courant de GitLab : la variable est alors laissée telle quelle.
  token_sonar=""
  if [[ -f "$sonar_token_fichier" ]]; then IFS= read -r token_sonar < "$sonar_token_fichier" || true; fi
  if [[ -z "$token_sonar" ]]; then
    {
      echo "Attention : $sonar_token_fichier absent ou vide : SONAR_TOKEN non mise à jour."
      echo "  Lancer make bootstrap ENV=$env depuis ce poste (docs/analyse-sonarqube.md)."
    } >&2
    etat_sonar_token="non mise à jour (token local absent)"
  # Règle de masquage de GitLab : 8 caractères au moins, alphabet Base64 (les tokens SonarQube s'y tiennent)
  elif [[ ! "$token_sonar" =~ ^[A-Za-z0-9_]{8,}$ ]]; then
    echo "Attention : $sonar_token_fichier ne contient pas un token SonarQube : SONAR_TOKEN non mise à jour." >&2
    etat_sonar_token="non mise à jour (token local illisible)"
  elif ! token_sonar_valide "$token_sonar"; then
    {
      echo "Attention : token de $sonar_token_fichier refusé par SonarQube (révoqué depuis un autre poste ?)"
      echo "  ou SonarQube injoignable : SONAR_TOKEN non mise à jour. Lancer make bootstrap ENV=$env"
      echo "  (docs/analyse-sonarqube.md)."
    } >&2
    etat_sonar_token="non mise à jour (token local refusé par SonarQube)"
  else
    definir_variable SONAR_TOKEN 1 "$token_sonar"
    etat_sonar_token="masquée, token de $sonar_token_fichier (valeur non affichée)"
  fi
  unset token_sonar
fi

# --- 4. Runner d'instance ------------------------------------------------------------------------------

etape "Runner d'instance « $description » (réseau des jobs : $reseau)"
verrou_tenu
# Blocs de config.toml : candidats conformes à la configuration attendue, et tous les ids présents
candidats=() ids_config=()
while IFS=$'\037' read -r b_id b_nom b_url b_clone b_exe b_image b_reseau b_ca b_helper; do
  [[ -n "$b_id" ]] && ids_config+=("$b_id")
  if [[ -n "$b_id" && "$b_nom" == "$description" && "$b_url" == "$url" && "$b_clone" == "$clone_url" \
    && "$b_exe" == docker && "$b_image" == "$RUNNER_IMAGE" && "$b_reseau" == "$reseau" \
    && "$b_ca" == "$ca_runner" && "$b_helper" == "$helper_image" ]]; then
    candidats+=("$b_id")
  fi
done < <(blocs_runner)

# Image auxiliaire tirée sur la cible (même moteur Docker que le runner) : erreur claire avant tout
# ré-enregistrement ; simple avertissement si un runner conforme existe déjà (relance idempotente)
if [[ -n "$helper_image" ]]; then
  version_runner="$(dc exec -T gitlab-runner gitlab-runner --version | awk '$1 == "Version:" { print $2; exit }')"
  [[ "$version_runner" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] \
    || erreur "version du runner illisible (« $version_runner ») : image de développement sans helper publié ?"
  image_helper_courante="$helper_depot:v$version_runner"
  if docker pull -q "$image_helper_courante" > /dev/null; then
    echo "    Image auxiliaire $image_helper_courante disponible sur la cible."
  elif ((${#candidats[@]} > 0)); then
    echo "Attention : image auxiliaire $image_helper_courante non téléchargeable (GITLAB_RUNNER_HELPER_IMAGE) ; les jobs échoueront." >&2
  else
    erreur "image auxiliaire $image_helper_courante non téléchargeable sur la cible (GITLAB_RUNNER_HELPER_IMAGE, docs/bootstrap.md)"
  fi
fi

# Runner courant = premier candidat existant côté serveur. Suppression côté serveur des autres runners
# de config.toml et des runners d'instance portant le marqueur : aucun orphelin, même après perte du
# volume du runner ou changement de description.
# shellcheck disable=SC2016 # code Ruby
code_nettoyage='
candidats, ids_config, marqueur = ARGV[0].split(","), ARGV[1].split(","), ARGV[2]
courant = candidats.find do |id|
  code, d = api("get", "/runners/#{id}")
  code == 200 && d["runner_type"] == "instance_type"
end
supprimer = ids_config - [courant]
page = 1
loop do
  liste = api!("get", "/runners/all?type=instance_type&per_page=100&page=#{page}", 200)
  break if liste.empty?
  liste.each do |r|
    id = r["id"].to_s
    next if id == courant || supprimer.include?(id)
    supprimer << id if api!("get", "/runners/#{id}", 200)["maintenance_note"] == marqueur
  end
  page += 1
end
supprimer.uniq.each do |id|
  code, _ = api("delete", "/runners/#{id}")
  abort("Suppression du runner #{id} : HTTP #{code}") unless [204, 404].include?(code)
  puts "SUPPRIME=#{id}" if code == 204
end
puts "COURANT=#{courant}"
'
liste_candidats="$(IFS=,; echo "${candidats[*]}")"
liste_ids="$(IFS=,; echo "${ids_config[*]}")"
sortie_nettoyage="$(gitlab_api "$code_nettoyage" "$liste_candidats" "$liste_ids" "$MARQUEUR")" \
  || erreur "inventaire des runners impossible (voir ci-dessus)"
courant="$(sed -n 's/^COURANT=//p' <<<"$sortie_nettoyage")"
while IFS= read -r id; do
  echo "    Runner $id supprimé côté serveur (ancien ou orphelin)."
done < <(sed -n 's/^SUPPRIME=//p' <<<"$sortie_nettoyage")

# Retire de config.toml les runners révoqués côté serveur, avant tout ré-enregistrement
dc exec -T gitlab-runner gitlab-runner verify --delete \
  || echo "Attention : gitlab-runner verify --delete a échoué ; config.toml filtré ci-dessous." >&2
# Repli : un bloc dont l'URL ne résout plus (hostname ou TLS_MODE changé) échappe à verify
if [[ -n "$(filtrer_config_runner "${courant:--}")" ]]; then
  echo "    config.toml : blocs autres que le runner courant retirés."
fi

if [[ -n "$courant" ]]; then
  echo "    Runner déjà enregistré et conforme (id=$courant) : rien à faire."
else
  verrou_tenu
  # shellcheck disable=SC2016 # code Ruby
  code_creation='
d = api!("post", "/user/runners", 201,
  { "runner_type" => "instance_type", "description" => ARGV[0], "maintenance_note" => ARGV[1] })
puts "ID=#{d["id"]}"
puts "JETON=#{d["token"]}"
'
  sortie_creation="$(gitlab_api "$code_creation" "$description" "$MARQUEUR")" \
    || erreur "création du runner impossible (voir ci-dessus)"
  courant="$(sed -n 's/^ID=//p' <<<"$sortie_creation")"
  jeton_runner="$(sed -n 's/^JETON=//p' <<<"$sortie_creation")"
  [[ -n "$courant" && -n "$jeton_runner" ]] || erreur "réponse inattendue de POST /user/runners"
  options_docker=(--docker-image "$RUNNER_IMAGE" --docker-network-mode "$reseau")
  if [[ -n "$helper_image" ]]; then options_docker+=(--docker-helper-image "$helper_image"); fi
  # CA privée : écrite dans config.toml (tls-ca-file), utilisée par register, verify et les requêtes
  # de jobs, transmise aux jobs (CI_SERVER_TLS_CA_FILE) et au clone du helper
  options_ca=()
  [[ -n "$ca_runner" ]] && options_ca=(--tls-ca-file "$ca_runner")
  # Jeton transmis par l'environnement (-e sans valeur) : absent des arguments de processus
  CI_SERVER_TOKEN="$jeton_runner" dc exec -T -e CI_SERVER_TOKEN gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "$url" \
    --clone-url "$clone_url" \
    --executor docker \
    "${options_docker[@]}" \
    --description "$description" \
    "${options_ca[@]}"
  unset jeton_runner sortie_creation
  echo "    Runner enregistré (id=$courant)."
fi

# Contact du runner avec GitLab : statut « online »
# shellcheck disable=SC2016 # code Ruby
code_statut='puts api!("get", "/runners/#{ARGV[0]}", 200)["status"]'
runner_en_ligne() { [[ "$(gitlab_api "$code_statut" "$courant")" == online ]]; }
attendre "Runner $courant en ligne" "$ATTENTE_EN_LIGNE" runner_en_ligne \
  || erreur "le runner $courant n'est pas en ligne après $ATTENTE_EN_LIGNE s (docker compose logs gitlab-runner)"
verrou_tenu

echo
echo "Bootstrap GitLab terminé ($env) :"
echo "  Runner     : id=$courant, « $description », jobs sur le réseau $reseau (image $RUNNER_IMAGE)"
echo "  Helper     : ${helper_image:-image standard de GitLab (registry.gitlab.com)}"
echo "  URL        : $url (clone des jobs : $clone_url)"
echo "  CA         : ${ca_runner:-aucune (magasin système)}"
echo "  CI SonarQube : SONAR_HOST_URL $etat_sonar_url"
echo "                 SONAR_TOKEN $etat_sonar_token"
echo "  Jeton root : $PAT_NOM, scopes api et admin_mode, expire le $expiration (valeur non affichée)"
echo "  Runners    : $url/admin/runners"
