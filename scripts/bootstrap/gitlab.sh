#!/usr/bin/env bash
# Bootstrap GitLab d'une instance déployée : attente de GitLab, jeton d'accès personnel (PAT)
# d'administration renouvelé, runner d'instance enregistré. Aucune donnée de test créée ; idempotent.
# Lancé par `make bootstrap ENV=<env>` (scripts/instance.sh bootstrap), qui positionne la cible Docker
# (contexte SSH d'une instance distante). Documentation : docs/bootstrap.md.
#
# Usage : scripts/bootstrap/gitlab.sh envs/<env>.env
#
# Les appels à l'API GitLab partent du conteneur gitlab (http://localhost) : ils ne dépendent ni du
# DNS, ni du TLS, ni de l'emplacement du poste. Le JSON est traité par le Ruby embarqué de l'image
# GitLab : rien à installer sur le poste. Les jetons ne passent jamais en argument de processus.
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
readonly RUBY=/opt/gitlab/embedded/bin/ruby
readonly ATTENTE_GITLAB=900 ATTENTE_URL=300 ATTENTE_EN_LIGNE=120 PAS=10

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

# URL publique : même règle que l'external_url de GitLab (compose/gitlab.yml, url_derivee)
hostname="$(env_valeur "$env_file" GITLAB_HOSTNAME)"
hostname="${hostname:-gitlab.localhost}"
url="$(env_valeur "$env_file" GITLAB_EXTERNAL_URL)"
url="${url:-$(url_derivee "$hostname" "$(env_valeur "$env_file" TLS_MODE)")}"
url="${url%/}"
# Clone des jobs : URL publique (alias réseau de Traefik), sauf *.localhost, que libcurl (donc git)
# résout toujours vers 127.0.0.1 : nom de service Docker (docs/gitlab-proxy.md)
if est_hostname_local "$hostname"; then clone_url="http://gitlab"; else clone_url="$url"; fi

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
# résoudrait de lui-même tout *.localhost vers 127.0.0.1.
derniere_erreur=""
url_publique_joignable() {
  local sortie port=80
  [[ "$url" == https://* ]] && port=443
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  sortie="$(dc exec -T gitlab-runner sh -c '
    ip="$(getent ahostsv4 "$1" | awk "{ print \$1; exit }")"
    [ -n "$ip" ] || { echo "résolution de $1 impossible"; exit 1; }
    exec curl -sS -o /dev/null -w "%{http_code}" --resolve "$1:$2:$ip" "$3/api/v4/version"' \
    sh "$hostname" "$port" "$url" 2>&1)" || true
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

# Exécute du code Ruby (après RUBY_API) dans le conteneur gitlab : <code> [arguments…]
gitlab_api() {
  local code="$1"
  shift
  printf '%s\n' "$pat" | dc exec -T gitlab "$RUBY" -e "$RUBY_API$code" -- "$@"
}

# Blocs [[runners]] de config.toml, une ligne par bloc, champs séparés par \037 :
# id, name, url, clone_url, executor, image, network_mode. Les jetons ne sont jamais extraits.
# shellcheck disable=SC2016 # programme awk
readonly AWK_BLOCS='
function sortir() { if (dans) printf "%s\037%s\037%s\037%s\037%s\037%s\037%s\n", id, nom, url, clone, exe, image, reseau }
function val(l) { sub(/^[^=]*= */, "", l); gsub(/^"|"$/, "", l); return l }
/^\[\[runners\]\]/ { sortir(); dans = 1; id = nom = url = clone = exe = image = reseau = ""; next }
/^\[/ { sortir(); dans = 0; next }
dans && /^[ \t]*id[ \t]*=/ { id = val($0) }
dans && /^[ \t]*name[ \t]*=/ { nom = val($0) }
dans && /^[ \t]*url[ \t]*=/ { url = val($0) }
dans && /^[ \t]*clone_url[ \t]*=/ { clone = val($0) }
dans && /^[ \t]*executor[ \t]*=/ { exe = val($0) }
dans && /^[ \t]*image[ \t]*=/ { image = val($0) }
dans && /^[ \t]*network_mode[ \t]*=/ { reseau = val($0) }
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
docker network inspect "$reseau" > /dev/null 2>&1 \
  || erreur "réseau Docker $reseau introuvable sur la cible (GITLAB_RUNNER_NETWORK, PLATFORM_NETWORK)"
if [[ "$reseau" != "$reseau_plateforme" ]]; then
  {
    echo "Attention : réseau des jobs ($reseau) différent du réseau de la plateforme ($reseau_plateforme)."
    echo "  Les jobs clonent par $clone_url, joignable seulement sur le réseau de la plateforme :"
    echo "  le réseau $reseau doit le permettre, sinon tous les jobs échoueront (docs/bootstrap.md)."
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
trap 'rm -f "$erreurs_rails"' EXIT
if ! sortie_pat="$(dc exec -T -e BOOTSTRAP_PAT_NOM="$PAT_NOM" gitlab gitlab-rails runner "$code_pat" 2> "$erreurs_rails")"; then
  cat "$erreurs_rails" >&2
  erreur "création du jeton d'accès personnel impossible (voir ci-dessus)"
fi
pat="$(sed -n 's/^PAT=//p' <<<"$sortie_pat" | tail -n1)"
[[ -n "$pat" ]] || { cat "$erreurs_rails" >&2; erreur "jeton d'accès personnel absent de la sortie de gitlab-rails"; }
expiration="$(sed -n 's/^EXPIRATION=//p' <<<"$sortie_pat" | tail -n1)"
revoques="$(grep -c '^REVOQUE=' <<<"$sortie_pat" || true)"
echo "    Jeton créé (expire le $expiration) ; $revoques ancien(s) jeton(s) révoqué(s)."

# --- 3. Runner d'instance ------------------------------------------------------------------------------

etape "Runner d'instance « $description » (réseau des jobs : $reseau)"
# Blocs de config.toml : candidats conformes à la configuration attendue, et tous les ids présents
candidats=() ids_config=()
while IFS=$'\037' read -r b_id b_nom b_url b_clone b_exe b_image b_reseau; do
  [[ -n "$b_id" ]] && ids_config+=("$b_id")
  if [[ -n "$b_id" && "$b_nom" == "$description" && "$b_url" == "$url" && "$b_clone" == "$clone_url" \
    && "$b_exe" == docker && "$b_image" == "$RUNNER_IMAGE" && "$b_reseau" == "$reseau" ]]; then
    candidats+=("$b_id")
  fi
done < <(blocs_runner)

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
  # Jeton transmis par l'environnement (-e sans valeur) : absent des arguments de processus
  CI_SERVER_TOKEN="$jeton_runner" dc exec -T -e CI_SERVER_TOKEN gitlab-runner gitlab-runner register \
    --non-interactive \
    --url "$url" \
    --clone-url "$clone_url" \
    --executor docker \
    --docker-image "$RUNNER_IMAGE" \
    --docker-network-mode "$reseau" \
    --description "$description"
  unset jeton_runner sortie_creation
  echo "    Runner enregistré (id=$courant)."
fi

# Contact du runner avec GitLab : statut « online »
# shellcheck disable=SC2016 # code Ruby
code_statut='puts api!("get", "/runners/#{ARGV[0]}", 200)["status"]'
runner_en_ligne() { [[ "$(gitlab_api "$code_statut" "$courant")" == online ]]; }
attendre "Runner $courant en ligne" "$ATTENTE_EN_LIGNE" runner_en_ligne \
  || erreur "le runner $courant n'est pas en ligne après $ATTENTE_EN_LIGNE s (docker compose logs gitlab-runner)"

echo
echo "Bootstrap GitLab terminé ($env) :"
echo "  Runner     : id=$courant, « $description », jobs sur le réseau $reseau (image $RUNNER_IMAGE)"
echo "  URL        : $url (clone des jobs : $clone_url)"
echo "  Jeton root : $PAT_NOM, scopes api et admin_mode, expire le $expiration (valeur non affichée)"
echo "  Runners    : $url/admin/runners"
