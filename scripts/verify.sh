#!/usr/bin/env bash
# Vérifications statiques du repo (`make verify`, étape 5 du workflow d'implémentation).
# Les linters tournent dans des conteneurs : rien à installer sur l'hôte hormis Docker.
# Code de sortie non nul si au moins une vérification échoue.
set -uo pipefail

ROOT="$(git rev-parse --show-toplevel)"
cd "$ROOT" || exit 1
failed=0

# Images des linters : tag versionné ou digest (contrôlé par la section « images épinglées »).
# yamllint : aucun tag versionné publié, le tag 1 est figé par son digest.
SHELLCHECK_IMAGE="koalaman/shellcheck:v0.11.0"
YAMLLINT_IMAGE="cytopia/yamllint:1@sha256:596fb19eb71e55ba5b2fa56d8c18a615ec82adc8d3bf2d73918cb78c8f3240fb"

section() { echo; echo "==> $*"; }
ko() { echo "    ✖ $*"; failed=1; }
ok() { echo "    ✔ $*"; }

# 1. shellcheck sur tous les scripts versionnés ou nouveaux
section "shellcheck"
mapfile -t sh_files < <(git ls-files --cached --others --exclude-standard '*.sh')
if ((${#sh_files[@]})); then
  if docker run --rm -v "$ROOT:/mnt:ro" -w /mnt "$SHELLCHECK_IMAGE" -x "${sh_files[@]}"; then
    ok "${#sh_files[@]} script(s)"
  else
    ko "shellcheck"
  fi
else
  ok "aucun script"
fi
# Script de nettoyage embarqué dans host-prereqs.sh (heredoc PRUNE), installé tel quel sur les serveurs
PRUNE_SOURCE=scripts/host-prereqs.sh
if [[ -f "$PRUNE_SOURCE" ]]; then
  prune_ligne="$(grep -n "<<'PRUNE'\$" "$PRUNE_SOURCE" | cut -d: -f1 | head -n1)"
  prune_script="$(sed -n "/<<'PRUNE'\$/,/^PRUNE\$/{//!p}" "$PRUNE_SOURCE")"
  if [[ -z "$prune_ligne" || "$prune_script" != '#!/usr/bin/env bash'* ]]; then
    ko "$PRUNE_SOURCE : heredoc PRUNE introuvable ou sans shebang"
  elif docker run --rm -i "$SHELLCHECK_IMAGE" -s bash - <<<"$prune_script"; then
    ok "$PRUNE_SOURCE : script de nettoyage embarqué"
  else
    ko "$PRUNE_SOURCE : script de nettoyage embarqué (ligne N ci-dessus = ligne $((prune_ligne)) + N du fichier)"
  fi
fi

# 2. yamllint (config relaxed : on vise les erreurs de syntaxe, pas le style)
section "yamllint"
mapfile -t yml_files < <(git ls-files --cached --others --exclude-standard '*.yml' '*.yaml')
if ((${#yml_files[@]})); then
  if docker run --rm -v "$ROOT:/data:ro" -w /data "$YAMLLINT_IMAGE" \
      -d "{extends: relaxed, rules: {line-length: disable}}" "${yml_files[@]}"; then
    ok "${#yml_files[@]} fichier(s)"
  else
    ko "yamllint"
  fi
else
  ok "aucun fichier YAML"
fi

# 3. docker compose config pour chaque environnement (dont l'exemple), et pour chaque mode TLS
section "docker compose config"
shopt -s nullglob
tls_modes=(compose/tls/*.yml)
shopt -u nullglob
tls_modes=("${tls_modes[@]##*/}") tls_modes=("${tls_modes[@]%.yml}")
# Variables obligatoires d'un mode, absentes de l'exemple (lignes commentées) : valeurs de test
# fournies quand un mode est imposé (ACME_EMAIL : TLS_MODE=letsencrypt)
VARS_MODE_TLS=(ACME_EMAIL=verify@devops-platform.test)
if [[ -f compose.yml ]]; then
  shopt -s nullglob dotglob
  env_files=(envs/*.env envs/.env.example)
  shopt -u dotglob
  ((${#env_files[@]})) || ko "aucun fichier dans envs/"
  for f in "${env_files[@]}"; do
    if docker compose --env-file "$f" -f compose.yml config -q; then ok "$f"; else ko "$f"; fi
  done
  # Chaque overlay de mode TLS (compose/tls/<mode>.yml et compose/tls/gitlab/<mode>.yml), sur l'exemple
  for mode in "${tls_modes[@]}"; do
    if env "${VARS_MODE_TLS[@]}" TLS_MODE="$mode" docker compose --env-file envs/.env.example -f compose.yml config -q; then
      ok "envs/.env.example, TLS_MODE=$mode"
    else
      ko "envs/.env.example, TLS_MODE=$mode"
    fi
  done
  # Chaque challenge ACME de TLS_MODE=letsencrypt (config/traefik/acme-<challenge>.env), sur l'exemple
  shopt -s nullglob
  for c in config/traefik/acme-*.env; do
    c="${c##*/acme-}" c="${c%.env}"
    if env "${VARS_MODE_TLS[@]}" TLS_MODE=letsencrypt ACME_CHALLENGE="$c" \
        docker compose --env-file envs/.env.example -f compose.yml config -q; then
      ok "envs/.env.example, TLS_MODE=letsencrypt, ACME_CHALLENGE=$c"
    else
      ko "envs/.env.example, TLS_MODE=letsencrypt, ACME_CHALLENGE=$c"
    fi
  done
  shopt -u nullglob
else
  ok "pas encore de compose.yml"
fi

# 3 bis. Profils de dimensionnement : chacun se résout dans compose et tous définissent les mêmes clés
#        (une clé absente ferait échouer le reconfigure GitLab au démarrage, invisible pour `config`)
section "profils de dimensionnement"
shopt -s nullglob
profile_files=(config/profiles/*.env)
shopt -u nullglob
if [[ -f compose.yml ]] && ((${#profile_files[@]})); then
  ref_keys="$(grep -oE '^[A-Z][A-Z0-9_]*=' "${profile_files[0]}" | sort)"
  for f in "${profile_files[@]}"; do
    p="$(basename "$f" .env)"
    if PLATFORM_PROFILE="$p" docker compose --env-file envs/.env.example -f compose.yml config -q; then
      ok "$p : compose"
    else
      ko "$p : compose"
    fi
    keys="$(grep -oE '^[A-Z][A-Z0-9_]*=' "$f" | sort)"
    if [[ "$keys" == "$ref_keys" ]]; then
      ok "$p : mêmes clés que ${profile_files[0]}"
    else
      ko "$p : clés différentes de ${profile_files[0]} : $(comm -3 <(echo "$ref_keys") <(echo "$keys") | tr -d '=\t' | paste -sd ' ' -)"
    fi
  done
else
  ok "aucun profil"
fi

# 3 ter. Configuration Loki de chaque environnement (rétention, -verify-config avec l'image résolue).
#        Télécharge l'image Loki à la première exécution (accès au registre requis).
section "configuration Loki"
if [[ -f compose.yml ]]; then
  shopt -s nullglob dotglob
  env_files=(envs/*.env envs/.env.example)
  shopt -u nullglob dotglob
  for f in "${env_files[@]}"; do
    if msg="$(scripts/check-loki-config.sh "$f" 2>&1)"; then ok "${msg##*$'\n'}"; else echo "$msg"; ko "$f : Loki"; fi
  done
else
  ok "pas encore de compose.yml"
fi

# 3 quater. Ports publiés : seuls 80 (et 443, TLS) via Traefik et le SSH GitLab (US 3-6). Le web passe
#           par Traefik (routage par hostname). Liste blanche service:publié:cible, contrôlée pour chaque
#           environnement et pour chaque mode TLS (sur l'exemple) ; `*` = port publié libre
#           (GITLAB_SSH_PORT). `expose` ne publie rien (non contrôlé).
#           Un network_mode host, service:… ou container:… contournerait la liste : refusé.
section "ports publiés"
# traefik:443:443 : HTTPS (TLS_MODE custom ou letsencrypt, overlay compose/tls/<mode>.yml)
PORTS_AUTORISES=(traefik:80:80 traefik:443:443 'gitlab:*:22')
# Configuration résolue d'une cible <fichier env>[|<TLS_MODE imposé>] (sections 3 quater et quinquies)
config_cible() {
  local env_file="${1%%|*}" variables=()
  [[ "$1" == *"|"* ]] && variables=(TLS_MODE="${1#*|}" "${VARS_MODE_TLS[@]}")
  env "${variables[@]}" docker compose --env-file "$env_file" -f compose.yml config 2>/dev/null
}
port_autorise() { # <service:publié:cible>
  local a
  for a in "${PORTS_AUTORISES[@]}"; do
    # shellcheck disable=SC2053 # motif voulu : `*` de la liste blanche
    [[ "$1" == $a ]] && return 0
  done
  return 1
}
if [[ -f compose.yml ]]; then
  # Cible : <fichier env>[|<TLS_MODE imposé>]
  cibles=("${env_files[@]}")
  for mode in "${tls_modes[@]}"; do cibles+=("envs/.env.example|$mode"); done
  for cible in "${cibles[@]}"; do
    f="${cible%%|*}" mode=""
    [[ "$cible" == *"|"* ]] && mode="${cible#*|}" f="$f, TLS_MODE=$mode"
    # Sortie normalisée : service à 2 espaces, `ports:` / `network_mode:` à 4, éléments `- ` à 6,
    # champs `target:` / `published:` à 8
    if ! config="$(config_cible "$cible")"; then
      ko "$f : configuration illisible"; continue
    fi
    mapfile -t publies < <(awk '
      function sortir() { if (cible != "") print service ":" (publie == "" ? "?" : publie) ":" cible; cible = publie = "" }
      /^[^ ]/ { sortir(); dans_services = ($0 == "services:"); dans_ports = 0; next }
      !dans_services { next }
      /^  [^ ]/ { sortir(); service = $1; sub(/:$/, "", service); dans_ports = 0; next }
      /^    [^ ]/ { sortir(); dans_ports = ($1 == "ports:"); next }
      dans_ports && /^      - / { sortir() }
      dans_ports && /^ +(- )?target:/ { cible = $NF }
      dans_ports && /^ +(- )?published:/ { publie = $NF; gsub(/"/, "", publie) }
      END { sortir() }
    ' <<< "$config")
    mapfile -t modes < <(awk '
      /^[^ ]/ { dans_services = ($0 == "services:"); next }
      dans_services && /^  [^ ]/ { service = $1; sub(/:$/, "", service); next }
      dans_services && /^    network_mode:/ { print service ":" $2 }
    ' <<< "$config")
    if ((${#publies[@]} == 0)); then
      ko "$f : aucun port publié lu (format de docker compose config inattendu ?)"; continue
    fi
    interdits=()
    for p in "${publies[@]}"; do
      port_autorise "$p" || interdits+=("$p")
    done
    for m in "${modes[@]}"; do
      [[ "${m#*:}" =~ ^(host|service:|container:) ]] && interdits+=("network_mode ${m}")
    done
    if ((${#interdits[@]})); then
      ko "$f : exposition hors liste autorisée (${PORTS_AUTORISES[*]}) : ${interdits[*]}"
    else
      ok "$f : ${publies[*]}"
    fi
  done
else
  ok "pas encore de compose.yml"
fi

# 3 quinquies. Accès au socket Docker : seuls le proxy filtrant (socket-proxy) et les services hors
#              périmètre (gitlab-runner, portainer) montent un socket Docker (cible ou source
#              contenant docker.sock, ou /run, /var/run, /run/user/<uid> entiers). Le réseau dédié
#              socket-proxy est interne, réservé au proxy et à ses clients (traefik, promtail), et
#              le proxy n'est sur aucun autre réseau. Mêmes cibles que la section précédente.
section "accès au socket Docker"
SOCKET_AUTORISES=(gitlab-runner portainer socket-proxy)
CLIENTS_PROXY=(socket-proxy traefik promtail)
dans_liste() { # <valeur> <éléments…>
  local v="$1" e; shift
  for e in "$@"; do [[ "$e" == "$v" ]] && return 0; done
  return 1
}
if [[ -f compose.yml ]]; then
  for cible in "${cibles[@]}"; do
    f="${cible%%|*}" mode=""
    [[ "$cible" == *"|"* ]] && mode="${cible#*|}" f="$f, TLS_MODE=$mode"
    if ! config="$(config_cible "$cible")"; then
      ko "$f : configuration illisible"; continue
    fi
    # Montages (service:source:cible) et réseaux (service:clé) des services ; réseau socket-proxy
    # déclaré interne. Sortie normalisée : clés de service à 4 espaces, éléments à 6, champs à 8.
    mapfile -t montages < <(awk '
      function sortir() { if (src != "" || dst != "") print service ":" src ":" dst; src = dst = "" }
      /^[^ ]/ { sortir(); dans_services = ($0 == "services:"); dans_vol = 0; next }
      !dans_services { next }
      /^  [^ ]/ { sortir(); service = $1; sub(/:$/, "", service); dans_vol = 0; next }
      /^    [^ ]/ { sortir(); dans_vol = ($1 == "volumes:"); next }
      dans_vol && /^      - / { sortir() }
      dans_vol && /^ +(- )?source:/ { src = $NF }
      dans_vol && /^ +(- )?target:/ { dst = $NF }
      END { sortir() }
    ' <<< "$config")
    mapfile -t reseaux < <(awk '
      /^[^ ]/ { dans_services = ($0 == "services:"); dans_net = 0; next }
      !dans_services { next }
      /^  [^ ]/ { service = $1; sub(/:$/, "", service); dans_net = 0; next }
      /^    [^ ]/ { dans_net = ($1 == "networks:"); next }
      dans_net && /^      [^ -]/ { r = $1; sub(/:$/, "", r); print service ":" r }
    ' <<< "$config")
    interne="$(awk '
      /^[^ ]/ { dans = ($0 == "networks:"); next }
      dans && /^  [^ ]/ { reseau = $1; next }
      dans && reseau == "socket-proxy:" && /^    internal: true$/ { print "oui" }
    ' <<< "$config")"
    if ((${#montages[@]} == 0 || ${#reseaux[@]} == 0)); then
      ko "$f : aucun montage ou réseau lu (format de docker compose config inattendu ?)"; continue
    fi
    interdits=()
    for m in "${montages[@]}"; do
      s="${m%%:*}" reste="${m#*:}" src="${reste%%:*}" dst="${reste#*:}"
      if [[ "$src" == *docker.sock* || "$dst" == *docker.sock* || "$src" =~ ^/(var/)?run/?$ \
            || "$src" =~ ^/run/user/[0-9]+/?$ ]]; then
        dans_liste "$s" "${SOCKET_AUTORISES[@]}" || interdits+=("socket monté par $s ($src)")
      fi
    done
    for r in "${reseaux[@]}"; do
      s="${r%%:*}" n="${r#*:}"
      if [[ "$n" == socket-proxy ]]; then
        dans_liste "$s" "${CLIENTS_PROXY[@]}" || interdits+=("$s sur le réseau socket-proxy")
      elif [[ "$s" == socket-proxy ]]; then
        interdits+=("socket-proxy sur le réseau $n")
      fi
    done
    [[ "$interne" == oui ]] || interdits+=("réseau socket-proxy absent ou non interne")
    if ((${#interdits[@]})); then
      ko "$f : $(printf '%s ; ' "${interdits[@]}" | sed 's/ ; $//')"
    else
      ok "$f : socket monté par ${SOCKET_AUTORISES[*]} au plus ; réseau socket-proxy interne (${CLIENTS_PROXY[*]})"
    fi
  done
else
  ok "pas encore de compose.yml"
fi

# 4. Chaque variable interpolée par compose est documentée dans envs/.env.example
#    ($${…} = échappement compose, ignoré ; minuscules = variables shell des healthchecks)
section "variables documentées"
if [[ -f compose.yml && -f envs/.env.example ]]; then
  # Variables interpolées, et sources `environment: <VAR>` des secrets (lues sans interpolation)
  mapfile -t compose_vars < <({
    grep -ohE '(^|[^$])\$\{[A-Z][A-Z0-9_]*' compose.yml compose/*.yml compose/tls/*.yml compose/tls/gitlab/*.yml | sed -E 's/.*\$\{//'
    awk '/^[^ ]/ { s = ($0 == "secrets:") } s && /^    environment: [A-Z]/ { print $2 }' compose.yml compose/*.yml compose/tls/*.yml compose/tls/gitlab/*.yml
  } | sort -u)
  missing=0
  for v in "${compose_vars[@]}"; do
    # Variables internes : fournie par Compose / définie par le garde-fou de lancement (section 6 bis) /
    # positionnée par scripts/instance.sh (copie de config/ sur l'hôte d'une instance distante)
    [[ "$v" == COMPOSE_PROJECT_NAME || "$v" == PLATFORM_GARDE_FOU || "$v" == PLATFORM_CONFIG_DIR ]] && continue
    grep -qE "^#?${v}=" envs/.env.example || { ko "$v absente de envs/.env.example"; missing=1; }
  done
  ((missing)) || ok "${#compose_vars[@]} variable(s) (dont 3 internes)"
else
  ok "pas encore de compose.yml"
fi

# 5. Images épinglées : deux instances installées à des dates différentes doivent être identiques
#    (procédure de montée de version : docs/montee-de-version.md)
section "images épinglées"
# Tag versionné : contient une version majeure.mineure (refuse latest, 1, 17, lts, alpine…) ou un digest
tag_versionne() { [[ "$1" =~ [0-9]+\.[0-9]+ || "$1" == *@sha256:* ]]; }
# Référence d'image complète (<dépôt>:<tag> ou <dépôt>[:<tag>]@sha256:…)
image_versionnee() {
  local nom="${1##*/}"
  [[ "$nom" == *@sha256:* ]] || { [[ "$nom" == *:* ]] && tag_versionne "${nom#*:}"; }
}
images_ko=0
nb_images=0
if [[ -f compose.yml ]]; then
  # Chaque image compose : <dépôt>:${<NOM>_VERSION:-<tag>}, défaut identique à envs/.env.example
  motif_image='^[[:space:]]*image:[[:space:]]*[^[:space:]$]+:\$\{([A-Z][A-Z0-9_]*_VERSION):-([^}]*)\}[[:space:]]*$'
  while IFS=: read -r fichier num ligne; do
    nb_images=$((nb_images + 1))
    if [[ ! "$ligne" =~ $motif_image ]]; then
      ko "$fichier:$num : image non paramétrée (attendu : <dépôt>:\${<NOM>_VERSION:-<tag>})"
      images_ko=1; continue
    fi
    var="${BASH_REMATCH[1]}" defaut="${BASH_REMATCH[2]}"
    if ! tag_versionne "$defaut"; then
      ko "$fichier:$num : défaut de $var non versionné ($defaut)"; images_ko=1
    fi
    doc="$(sed -nE "s/^#?${var}=[\"']?([^\"']*)[\"']?[[:space:]]*\$/\1/p" envs/.env.example | head -n1)"
    if [[ "$doc" != "$defaut" ]]; then
      ko "$var : défaut compose ($defaut) ≠ envs/.env.example (${doc:-absent})"; images_ko=1
    fi
  done < <(grep -nE '^[[:space:]]*image:' compose.yml compose/*.yml compose/tls/*.yml compose/tls/gitlab/*.yml)
fi
# Images lancées par les scripts : variables *_IMAGE à tag versionné ou digest
while IFS=: read -r fichier num ligne; do
  nb_images=$((nb_images + 1))
  valeur="${ligne#*=}" valeur="${valeur//[\"\']/}"
  image_versionnee "$valeur" || { ko "$fichier:$num : image non versionnée ($valeur)"; images_ko=1; }
done < <(git ls-files --cached --others --exclude-standard '*.sh' | sort -u \
  | xargs -r grep -nE '^[[:space:]]*(readonly[[:space:]]+)?[A-Z][A-Z0-9_]*_IMAGE=' /dev/null)
# Aucun tag latest explicite (motif sans le littéral, pour ne pas détecter ce script)
if git ls-files --cached --others --exclude-standard compose.yml compose scripts Makefile | sort -u \
    | xargs -r grep -nE '[:]latest([^A-Za-z0-9_.-]|$)' /dev/null; then
  ko "tag latest explicite (voir ci-dessus)"; images_ko=1
fi
# Instances locales : même règle que la cible check-env du Makefile (à garder synchronisées)
shopt -s nullglob
for f in envs/*.env; do
  if grep -nHE '^[A-Z0-9_]+_VERSION=["'"'"']?(latest)?["'"'"']?[[:space:]]*$' "$f"; then
    ko "$f : version vide ou latest (voir ci-dessus)"; images_ko=1
  fi
done
shopt -u nullglob
((images_ko)) || ok "$nb_images image(s)"

# 6. Noms de conteneurs : Compose les attribue, les scripts ciblent les services
#    (`docker compose exec <service>`). Commentaires ignorés ; `docker run` et `docker inspect <id>` admis.
section "noms de conteneurs"
if [[ -f compose.yml ]] && grep -nE '^[[:space:]]*container_name:' compose.yml compose/*.yml compose/tls/*.yml compose/tls/gitlab/*.yml; then
  ko "nom de conteneur fixé dans un fichier compose (voir ci-dessus)"
else
  ok "aucun nom fixé dans les fichiers compose"
fi
mapfile -t cible_files < <(git ls-files --cached --others --exclude-standard 'scripts/*.sh' Makefile)
# Exception : ligne marquée `check-noms: id` (conteneurs désignés par leur identifiant)
if ((${#cible_files[@]})) && grep -nE '^[^#]*\bdocker (container )?(exec|logs|cp|restart|stop|start|kill|rm)\b' \
    "${cible_files[@]}" | grep -v 'check-noms: id'; then
  ko "conteneur ciblé par son nom (voir ci-dessus) : passer par docker compose <commande> <service>"
else
  ok "${#cible_files[@]} fichier(s) (scripts, Makefile) : services ciblés par compose"
fi

# 6 bis. Garde-fou de lancement : un module seul ou un autre nom de projet doit être refusé au
#        chargement (conteneurs en double sur les volumes de l'instance). Variables du shell neutralisées ;
#        un refus ne compte que s'il vient du garde-fou (motif attendu dans la sortie).
section "garde-fou de lancement"
if [[ -f compose.yml ]]; then
  compose_propre() { env -u COMPOSE_PROJECT_NAME -u PLATFORM_GARDE_FOU docker compose --env-file envs/.env.example "$@" config -q 2>&1; }
  refus_attendu() { # <motif> <description> <arguments compose…>
    local motif="$1" desc="$2" sortie; shift 2
    if sortie="$(compose_propre "$@")"; then
      ko "$desc : accepté (refus attendu)"
    elif grep -q -- "$motif" <<<"$sortie"; then
      ok "$desc : refusé"
    else
      ko "$desc : refusé pour une autre raison : $sortie"
    fi
  }
  if sortie="$(compose_propre)"; then ok "compose.yml : accepté"; else ko "compose.yml : refusé : $sortie"; fi
  for f in compose/*.yml compose/tls/*.yml compose/tls/gitlab/*.yml; do
    m="$(basename "$f" .yml)"
    case "$f" in
      compose/tls/gitlab/*) m="tls-gitlab-$m" ;;
      compose/tls/*) m="tls-$m" ;;
    esac
    grep -qE "^x-garde-fou-${m}: \"\\$\{PLATFORM_GARDE_FOU:\?" "$f" || ko "$f : extension x-garde-fou-${m} absente"
    refus_attendu "PLATFORM_GARDE_FOU" "$f seul" -f "$f"
  done
  refus_attendu "projet-autorise/devops-platform-garde-fou-test.env" "-p devops-platform-garde-fou-test" \
    -p devops-platform-garde-fou-test
  # Entrées d'include (chemin simple ou liste de chemins fusionnés)
  nb_includes="$(grep -cE '^  - path:' compose.yml)"
  # shellcheck disable=SC2016 # ${COMPOSE_PROJECT_NAME} littéral, interpolé par Compose
  nb_gardes="$(grep -cxF '    env_file: compose/projet-autorise/${COMPOSE_PROJECT_NAME}.env' compose.yml)"
  if ((nb_includes == nb_gardes)); then
    ok "$nb_includes include(s) avec env_file compose/projet-autorise/\${COMPOSE_PROJECT_NAME}.env"
  else
    ko "compose.yml : $((nb_includes - nb_gardes)) include(s) sans env_file du garde-fou"
  fi
  if grep -nE '^#?[[:space:]]*PLATFORM_GARDE_FOU=' envs/.env.example; then
    ko "envs/.env.example définit PLATFORM_GARDE_FOU (neutraliserait le garde-fou des modules)"
  fi
else
  ok "pas encore de compose.yml"
fi

# 7. Secrets : délégué au garde-fou du repo (fichiers suivis et non suivis non ignorés)
section "secrets"
if scripts/check-secrets.sh; then ok "rien à signaler"; else ko "secrets (voir ci-dessus)"; fi

echo
if ((failed)); then echo "Vérification : ÉCHEC"; exit 1; fi
echo "Vérification : OK"
