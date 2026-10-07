#!/usr/bin/env bash
# Appels à l'API SonarQube depuis le conteneur sonarqube et format du token d'analyse, partagés par
# scripts/bootstrap/sonarqube.sh, scripts/bootstrap/gitlab.sh (make bootstrap), scripts/smoke.sh
# (make smoke) et scripts/bootstrap/outputs.sh. Fichier à sourcer : ne modifie pas les options du shell
# appelant, ne fait que des définitions (aucun appel Docker au chargement).
#
# Contrat avec l'appelant : dc <arguments docker compose…>, docker compose de l'instance (--env-file).
# Identifiants transmis à curl par l'entrée standard (fichier de configuration -K -), jamais en argument.

readonly SONAR_API=http://localhost:9000
# Format d'un token d'analyse : règle de masquage des variables CI GitLab (8 caractères au moins,
# alphabet Base64), à laquelle les tokens SonarQube se tiennent. Garantit aussi l'absence de " et \
# (configuration curl) et de tout caractère à protéger dans outputs/<env>.env.
# shellcheck disable=SC2034 # utilisée par les scripts qui sourcent ce fichier
readonly MOTIF_TOKEN_SONAR='^[A-Za-z0-9_]{8,}$' # motif, pas une valeur (check-secrets: ignore)

# Compte technique d'analyse (login) et nom de son token d'analyse (des noms, pas des valeurs). Le token
# du même nom porté autrefois par le compte admin est l'ancien token d'analyse, révoqué par l'étape
# GitLab une fois SONAR_TOKEN mise à jour (docs/bootstrap-sonarqube.md).
# shellcheck disable=SC2034 # utilisées par les scripts qui sourcent ce fichier
readonly SONAR_ANALYSE_LOGIN=devops-platform-analyse SONAR_TOKEN_NOM=devops-platform-analyse # noms (check-secrets: ignore)
# Stockage du token sur l'instance, dans le conteneur sonarqube (volume sonarqube_data) : token et
# login de son compte propriétaire (fichier .compte)
readonly SONAR_STOCKAGE_DIR=/opt/sonarqube/data/devops-platform
# shellcheck disable=SC2034 # utilisées par les scripts qui sourcent ce fichier
readonly SONAR_STOCKAGE="$SONAR_STOCKAGE_DIR/analyse-token" SONAR_STOCKAGE_COMPTE="$SONAR_STOCKAGE_DIR/analyse-token.compte"

# Contenu d'un fichier du stockage de l'instance : vide si le fichier n'existe pas, retour non nul s'il
# est illisible ou si le service est injoignable (à ne pas confondre avec un fichier absent)
sonar_stockage_lire() { # <chemin>
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  dc exec -T sonarqube sh -c '[ -e "$1" ] || exit 0; cat "$1"' sh "$1" </dev/null 2>/dev/null
}

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
