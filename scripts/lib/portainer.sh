#!/usr/bin/env bash
# Appels à l'API de Portainer, partagés par scripts/bootstrap/gitlab.sh (make bootstrap) et
# scripts/smoke.sh (make smoke) : connexion de Portainer à GitLab (OAuth) et comptes des membres de
# SSO_GROUPE_ADMIN (docs/sso.md, « Portainer »). Fichier à sourcer, après scripts/lib/gitlab.sh : ne
# modifie pas les options du shell appelant.
#
# Contrat avec l'appelant : celui de scripts/lib/gitlab.sh (dc, erreur, pat, stdin_extra). Le code Ruby
# s'exécute dans le conteneur gitlab (Ruby embarqué, après RUBY_API) : API GitLab en http://localhost,
# API Portainer en http://portainer:9000 (réseau de la plateforme, sans passerelle ni TLS). Entrée
# standard : PAT root, mot de passe du compte admin local de Portainer, puis les lignes de stdin_extra.
# Aucun secret en argument de processus.

# Équipe Portainer des comptes gérés par make bootstrap (créés pour les membres de SSO_GROUPE_ADMIN)
readonly PORTAINER_EQUIPE="devops-platform-sso"
# Scope demandé par Portainer à GitLab (lecture de l'identité) : celui de l'application OAuth
# devops-platform-portainer (scripts/bootstrap/gitlab.sh)
readonly PORTAINER_SCOPES="read_user"
# Compte admin local (créé au premier démarrage par --admin-password-file, compose/tools.yml) : compte
# de secours, identifiant 1
readonly PORTAINER_ADMIN="admin"

# Fonctions Ruby : appel de l'API Portainer avec le jeton de session de l'admin local, membres d'un
# groupe GitLab.
# shellcheck disable=SC2016 # code Ruby
readonly RUBY_PORTAINER="
PORTAINER_EQUIPE = '$PORTAINER_EQUIPE'
PORTAINER_SCOPES = '$PORTAINER_SCOPES'
PORTAINER_ADMIN = '$PORTAINER_ADMIN'"'
PORTAINER_MDP = STDIN.gets.to_s.chomp
$portainer_jwt = nil
def portainer(methode, chemin, corps = nil)
  uri = URI("http://portainer:9000/api#{chemin}")
  req = Net::HTTP.const_get(methode.capitalize).new(uri)
  req["Authorization"] = "Bearer #{$portainer_jwt}" if $portainer_jwt
  if corps
    req["Content-Type"] = "application/json"
    req.body = JSON.generate(corps)
  end
  rep = Net::HTTP.start(uri.host, uri.port, open_timeout: 10, read_timeout: 60) { |h| h.request(req) }
  texte = rep.body.to_s
  [rep.code.to_i, texte.empty? ? nil : (JSON.parse(texte) rescue texte)]
rescue SystemCallError, SocketError, Net::OpenTimeout, Net::ReadTimeout => e
  [0, e.message]
end
def portainer!(methode, chemin, attendus, corps = nil)
  code, rep = portainer(methode, chemin, corps)
  abort("API Portainer #{methode.upcase} #{chemin} : HTTP #{code} : #{rep}") unless Array(attendus).include?(code)
  rep
end
# Une seule tentative : Portainer limite les échecs de connexion
def portainer_connexion!(nom)
  code, rep = portainer("post", "/auth", { username: nom, password: PORTAINER_MDP })
  if code == 422 || code == 401 || code == 403
    abort("PORTAINER_ADMIN_PASSWORD refusé par Portainer pour le compte #{nom} (HTTP #{code}) : mot de passe changé dans l interface ? Le reporter dans envs/<env>.env (docs/sso.md, « Portainer »).")
  end
  abort("Connexion à Portainer impossible : HTTP #{code} : #{rep}") unless code == 200 && rep.is_a?(Hash) && rep["jwt"]
  $portainer_jwt = rep["jwt"]
end
# Membres actifs d un groupe GitLab (chemin complet), membres hérités des groupes parents compris,
# invitations en attente et comptes de service (bots) exclus : { nom en minuscules => nom }
def membres_groupe(chemin)
  return {} if chemin.empty?
  code, groupe = api("get", "/groups/#{URI.encode_www_form_component(chemin)}")
  abort("Groupe GitLab « #{chemin} » (SSO_GROUPE_ADMIN) introuvable : HTTP #{code}.") unless code == 200
  membres, page = [], 1
  loop do
    lot = api!("get", "/groups/#{groupe["id"]}/members/all?per_page=100&page=#{page}", 200)
    break if lot.empty?
    membres.concat(lot)
    page += 1
  end
  resultat = {}
  membres.uniq { |m| m["id"] }.each do |m|
    next unless m["state"] == "active" && m["membership_state"] != "awaiting"
    next if api!("get", "/users/#{m["id"]}", 200)["bot"]
    resultat[m["username"].downcase] = m["username"]
  end
  resultat
end
'

# Exécute du code Ruby (après RUBY_API et RUBY_PORTAINER) dans le conteneur gitlab : <code> [arguments…].
# Mot de passe admin Portainer lu dans le fichier d'instance (env_file de l'appelant), jamais affiché.
# shellcheck disable=SC2154 # env_file, pat et stdin_extra : contrat avec l'appelant
portainer_api() {
  local code="$1" mdp
  shift
  mdp="$(env_valeur_fichier "$env_file" PORTAINER_ADMIN_PASSWORD)"
  [[ -n "$mdp" ]] || erreur "PORTAINER_ADMIN_PASSWORD absent de $env_file"
  printf '%s\n' "$pat" "$mdp" "${stdin_extra[@]}" \
    | dc exec -T gitlab "$RUBY" -e "$RUBY_API$RUBY_PORTAINER$code" -- "$@"
}

# Portainer prêt à répondre (API joignable depuis le conteneur gitlab, sans authentification)
portainer_pret() {
  dc exec -T gitlab curl -sf -o /dev/null --max-time 5 http://portainer:9000/api/system/status 2> /dev/null
}

# Configuration de Portainer par make bootstrap. Arguments : groupe (SSO_GROUPE_ADMIN, vide possible),
# URL d'autorisation (publique), URI de redirection, identifiant client ; secret client sur l'entrée
# standard (stdin_extra). Ordre : plan des comptes calculé et contrôlé avant toute modification
# (compte non géré hors du groupe : arrêt sans rien changer), puis réglages OAuth (avant les créations :
# Portainer exige un mot de passe tant que l'authentification interne est active), puis comptes.
# Marqueurs : MEMBRES, CREE, ADOPTE, SUPPRIME, COMPTES, EQUIPE.
# shellcheck disable=SC2016,SC2034 # code Ruby, lu par l'appelant
readonly CODE_PORTAINER_CONFIG='
groupe, autorisation, retour, client_id = ARGV
secret = STDIN.gets.to_s.chomp
abort("Secret client de Portainer absent.") if secret.empty?
equipe_nom, admin_nom = PORTAINER_EQUIPE, PORTAINER_ADMIN
membres = membres_groupe(groupe)
puts "MEMBRES=#{membres.size}"
portainer_connexion!(admin_nom)

utilisateurs = portainer!("get", "/users", 200)
secours = utilisateurs.find { |u| u["Id"] == 1 } or abort("Compte admin local (identifiant 1) introuvable dans Portainer.")
if membres.key?(secours["Username"].downcase)
  abort("Membre de #{groupe} homonyme du compte admin local de Portainer (#{secours["Username"]}) : il en prendrait l identité ; renommer l un des deux.")
end
equipe = portainer!("get", "/teams", 200).find { |t| t["Name"] == equipe_nom }
geres = equipe ? portainer!("get", "/team_memberships", 200).select { |m| m["TeamID"] == equipe["Id"] }.map { |m| m["UserID"] } : []
autres = utilisateurs.reject { |u| u["Id"] == 1 }
etrangers = autres.reject { |u| geres.include?(u["Id"]) || membres.key?(u["Username"].downcase) }
unless etrangers.empty?
  noms = etrangers.map { |u| u["Username"] }.sort.join(", ")
  abort("Compte(s) Portainer non géré(s) et hors de #{groupe.empty? ? "SSO_GROUPE_ADMIN (vide)" : groupe} : #{noms}. Un utilisateur GitLab homonyme y entrerait par OAuth : les supprimer (ou les renommer) dans Portainer, ou ajouter les personnes au groupe, puis relancer make bootstrap (docs/sso.md, « Portainer »). Aucune modification faite.")
end

reglages = { AuthenticationMethod: 3, OAuthSettings: {
  ClientID: client_id, ClientSecret: secret, AuthorizationURI: autorisation,
  AccessTokenURI: "http://gitlab/oauth/token", ResourceURI: "http://gitlab/api/v4/user",
  RedirectURI: retour, UserIdentifier: "username", Scopes: PORTAINER_SCOPES,
  OAuthAutoCreateUsers: false, DefaultTeamID: 0, SSO: true, LogoutURI: "", AuthStyle: 1 } }
portainer!("put", "/settings", 200, reglages)

unless equipe
  equipe = portainer!("post", "/teams", 200, { Name: equipe_nom })
  puts "EQUIPE=créée"
end
par_nom = autres.to_h { |u| [u["Username"].downcase, u] }
membres.each do |cle, nom|
  u = par_nom[cle]
  if u.nil?
    u = portainer!("post", "/users", 200, { Username: nom, Role: 1 })
    puts "CREE=#{nom}"
  else
    portainer!("put", "/users/#{u["Id"]}", 200, { Role: 1 }) unless u["Role"] == 1
    puts "ADOPTE=#{u["Username"]}" unless geres.include?(u["Id"]) && u["Role"] == 1
  end
  unless geres.include?(u["Id"])
    portainer!("post", "/team_memberships", 200, { UserID: u["Id"], TeamID: equipe["Id"], Role: 2 })
  end
end
autres.each do |u|
  next if membres.key?(u["Username"].downcase)
  portainer!("delete", "/users/#{u["Id"]}", 204)
  puts "SUPPRIME=#{u["Username"]}"
end
puts "COMPTES=#{membres.size}"
'

# Contrôle par make smoke de la configuration posée par make bootstrap. Arguments : groupe
# (SSO_GROUPE_ADMIN), URL d'autorisation, URI de redirection, identifiant client attendus. Connexion
# par le compte admin local (preuve que l'accès de secours fonctionne), réglages OAuth comparés aux
# valeurs attendues, comptes limités à l'admin local et aux membres du groupe. Marqueurs : ECART (réglage
# différent), ETRANGER (compte hors du groupe), COMPTES.
# shellcheck disable=SC2016,SC2034 # code Ruby, lu par l'appelant
readonly CODE_PORTAINER_CONTROLE='
groupe, autorisation, retour, client_id = ARGV
membres = membres_groupe(groupe)
portainer_connexion!(PORTAINER_ADMIN)
r = portainer!("get", "/settings", 200)
o = r["OAuthSettings"] || {}
attendus = { "AuthenticationMethod" => [r["AuthenticationMethod"], 3], "ClientID" => [o["ClientID"], client_id],
  "AuthorizationURI" => [o["AuthorizationURI"], autorisation], "RedirectURI" => [o["RedirectURI"], retour],
  "AccessTokenURI" => [o["AccessTokenURI"], "http://gitlab/oauth/token"],
  "ResourceURI" => [o["ResourceURI"], "http://gitlab/api/v4/user"], "UserIdentifier" => [o["UserIdentifier"], "username"],
  "Scopes" => [o["Scopes"], PORTAINER_SCOPES], "OAuthAutoCreateUsers" => [o["OAuthAutoCreateUsers"], false] }
attendus.each { |cle, (lu, voulu)| puts "ECART=#{cle} : #{lu.inspect} au lieu de #{voulu.inspect}" unless lu == voulu }
comptes = portainer!("get", "/users", 200).reject { |u| u["Id"] == 1 }
comptes.each { |u| puts "ETRANGER=#{u["Username"]}" unless membres.key?(u["Username"].downcase) }
puts "COMPTES=#{comptes.size}"
'

# Utilisateur GitLab de test du smoke test (hors de SSO_GROUPE_ADMIN), créé ou réutilisé et débloqué.
# Arguments : nom, groupe. Marqueur : ID. Arrêt s'il est membre du groupe ou s'il a un compte Portainer.
# shellcheck disable=SC2016,SC2034 # code Ruby, lu par l'appelant
readonly CODE_PORTAINER_TEST='
nom, groupe = ARGV
abort("Utilisateur de test #{nom} membre de #{groupe} : le retirer du groupe.") if membres_groupe(groupe).key?(nom.downcase)
existants = api!("get", "/users?username=#{nom}", 200)
u = existants.first || api!("post", "/users", 201, { "username" => nom, "name" => "Smoke test devops-platform",
  "email" => "#{nom}@example.com", "force_random_password" => "true", "skip_confirmation" => "true" })
api!("post", "/users/#{u["id"]}/unblock", 201) if u["state"] == "blocked"
abort("Utilisateur de test #{nom} dans l état #{u["state"]}.") unless %w[active blocked].include?(u["state"])
portainer_connexion!(PORTAINER_ADMIN)
if portainer!("get", "/users", 200).any? { |c| c["Username"].downcase == nom.downcase }
  abort("Compte Portainer #{nom} présent : make bootstrap le signale ou le supprime.")
end
puts "ID=#{u["id"]}"
'

# Connexion OAuth à Portainer avec un code d'autorisation (entrée standard, stdin_extra), sans jeton
# admin : réponse de POST /api/auth/oauth/validate. Marqueurs : CODE, MESSAGE.
# shellcheck disable=SC2016,SC2034 # code Ruby, lu par l'appelant
readonly CODE_PORTAINER_OAUTH='
code_auth = STDIN.gets.to_s.chomp
code, rep = portainer("post", "/auth/oauth/validate", { code: code_auth })
puts "CODE=#{code}"
puts "MESSAGE=#{rep.is_a?(Hash) ? rep["message"] : rep.to_s[0, 200]}"
'
