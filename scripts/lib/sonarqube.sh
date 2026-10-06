#!/usr/bin/env bash
# Appels à l'API SonarQube depuis le conteneur sonarqube, partagés par scripts/bootstrap/sonarqube.sh
# (make bootstrap) et scripts/smoke.sh (make smoke). Fichier à sourcer : ne modifie pas les options du
# shell appelant.
#
# Contrat avec l'appelant : dc <arguments docker compose…>, docker compose de l'instance (--env-file).
# Identifiants transmis à curl par l'entrée standard (fichier de configuration -K -), jamais en argument.

readonly SONAR_API=http://localhost:9000

# Chaîne entre guillemets pour un fichier de config curl (\ et " échappés)
cfg() { local v="${1//\\/\\\\}"; printf '"%s"' "${v//\"/\\\"}"; }

# sonar_api <GET|POST> <chemin> <utilisateur:secret | ""> [paramètre=valeur…]
# Positionne CODE (code HTTP, 000 si SonarQube injoignable) et CORPS. Retour non nul si l'exec échoue
# (conteneur arrêté). Paramètres encodés (data-urlencode, ajoutés à l'URL en GET) : un mot de passe
# contenant + & % reste intact.
CODE='' CORPS=''
sonar_api() {
  local methode="$1" chemin="$2" identite="$3" config sortie p
  shift 3
  config="url = $(cfg "$SONAR_API$chemin")"$'\n'
  [[ -n "$identite" ]] && config+="user = $(cfg "$identite")"$'\n'
  if [[ "$methode" == POST ]]; then config+='request = "POST"'$'\n'; elif (($#)); then config+='get'$'\n'; fi
  for p in "$@"; do config+="data-urlencode = $(cfg "$p")"$'\n'; done
  CODE='' CORPS=''
  sortie="$(dc exec -T sonarqube curl -sS -K - -w '\n%{http_code}' <<<"$config" 2>/dev/null)" || {
    # curl injoignable (SonarQube en démarrage) : code 000 en dernière ligne, exec réussi pour nous
    [[ "$sortie" =~ (^|$'\n')000$ ]] || return 1
  }
  CODE="${sortie##*$'\n'}"
  CORPS="${sortie%"$CODE"}"
  CORPS="${CORPS%$'\n'}"
}

# Champ booléen "valid" de api/authentication/validate (toujours HTTP 200)
identite_valide() { sonar_api GET /api/authentication/validate "$1" && [[ "$CORPS" == *'"valid":true'* ]]; }
