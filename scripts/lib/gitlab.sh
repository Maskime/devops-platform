#!/usr/bin/env bash
# Appels à l'API GitLab depuis le conteneur gitlab, partagés par scripts/bootstrap/gitlab.sh (make
# bootstrap) et scripts/smoke.sh (make smoke). Fichier à sourcer : ne modifie pas les options du shell
# appelant.
#
# Contrat avec l'appelant :
#   - dc <arguments docker compose…> : docker compose de l'instance (--env-file) ;
#   - erreur <message> : affiche le message et arrête le script ;
#   - pat : jeton d'accès personnel root (positionné par creer_pat_root) ;
#   - stdin_extra : tableau de lignes secrètes transmises après le jeton (vide par défaut).
#
# Les appels partent du conteneur gitlab (http://localhost) : ils ne dépendent ni du DNS, ni du TLS,
# ni de l'emplacement du poste. Le JSON est traité par le Ruby embarqué de l'image GitLab : rien à
# installer sur le poste. Les jetons ne passent jamais en argument de processus.

readonly RUBY=/opt/gitlab/embedded/bin/ruby
# Pause entre deux essais de attendre (secondes)
readonly PAS=10

stdin_extra=()

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

# Fonctions Ruby communes : appel de l'API GitLab depuis le conteneur gitlab, jeton lu sur l'entrée
# standard (jamais en argument), réponse JSON décodée. Corps envoyé en formulaire (params), ou en JSON
# (json:) pour les paramètres structurés (actions d'un commit).
# shellcheck disable=SC2016 # code Ruby
readonly RUBY_API='
require "json"
require "net/http"
JETON = STDIN.gets.to_s.chomp
def api(methode, chemin, params = nil, json: nil)
  uri = URI("http://localhost/api/v4#{chemin}")
  req = Net::HTTP.const_get(methode.capitalize).new(uri)
  req["PRIVATE-TOKEN"] = JETON
  req.set_form_data(params) if params
  if json
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(json)
  end
  rep = Net::HTTP.start(uri.host, uri.port) { |h| h.request(req) }
  corps = rep.body.to_s
  [rep.code.to_i, corps.empty? ? nil : (JSON.parse(corps) rescue corps)]
end
def api!(methode, chemin, attendus, params = nil, json: nil)
  code, corps = api(methode, chemin, params, json: json)
  abort("API GitLab #{methode.upcase} #{chemin} : HTTP #{code} : #{corps}") unless Array(attendus).include?(code)
  corps
end
'

# Exécute du code Ruby (après RUBY_API) dans le conteneur gitlab : <code> [arguments…]. Les lignes de
# stdin_extra (secrets) suivent le PAT sur l'entrée standard, où le code Ruby les lit (STDIN.gets)
gitlab_api() {
  local code="$1"
  shift
  printf '%s\n' "$pat" "${stdin_extra[@]}" | dc exec -T gitlab "$RUBY" -e "$RUBY_API$code" -- "$@"
}

# Jeton d'accès personnel root <nom> (scopes api et admin_mode, expire le lendemain), créé par
# gitlab-rails runner après révocation de tous les jetons actifs du même nom. Positionne pat,
# pat_expiration et pat_revoques (nombre de jetons révoqués). Valeur jamais affichée.
# shellcheck disable=SC2016 # code Ruby
readonly CODE_PAT='
root = User.find_by_username("root") or abort("Compte root introuvable.")
nom = ENV.fetch("PAT_NOM")
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
pat="" pat_expiration="" pat_revoques=""
creer_pat_root() { # <nom>
  local erreurs sortie
  erreurs="$(mktemp)"
  if ! sortie="$(dc exec -T -e PAT_NOM="$1" gitlab gitlab-rails runner "$CODE_PAT" 2> "$erreurs")"; then
    cat "$erreurs" >&2
    rm -f "$erreurs"
    erreur "création du jeton d'accès personnel impossible (voir ci-dessus)"
  fi
  pat="$(sed -n 's/^PAT=//p' <<<"$sortie" | tail -n1)"
  if [[ -z "$pat" ]]; then
    cat "$erreurs" >&2
    rm -f "$erreurs"
    erreur "jeton d'accès personnel absent de la sortie de gitlab-rails"
  fi
  rm -f "$erreurs"
  # shellcheck disable=SC2034 # lue par l'appelant
  pat_expiration="$(sed -n 's/^EXPIRATION=//p' <<<"$sortie" | tail -n1)"
  # shellcheck disable=SC2034 # lue par l'appelant
  pat_revoques="$(grep -c '^REVOQUE=' <<<"$sortie" || true)"
}
