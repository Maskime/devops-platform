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

# 3. docker compose config pour chaque environnement (dont l'exemple)
section "docker compose config"
if [[ -f compose.yml ]]; then
  shopt -s nullglob dotglob
  env_files=(envs/*.env envs/.env.example)
  shopt -u dotglob
  ((${#env_files[@]})) || ko "aucun fichier dans envs/"
  for f in "${env_files[@]}"; do
    if docker compose --env-file "$f" -f compose.yml config -q; then ok "$f"; else ko "$f"; fi
  done
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

# 3 quater. Ports publiés : le web passe par Traefik (routage par hostname), aucun autre service web
#           ne publie de port. Liste blanche service:port cible, contrôlée pour chaque environnement.
section "ports publiés"
PORTS_AUTORISES=(traefik:80 gitlab:22 portainer:8000)
if [[ -f compose.yml ]]; then
  for f in "${env_files[@]}"; do
    # Sortie normalisée : blocs `ports:` (4 espaces) d'un service (2 espaces), `target:` à 8 espaces
    if ! config="$(docker compose --env-file "$f" -f compose.yml config 2>/dev/null)"; then
      ko "$f : configuration illisible"; continue
    fi
    mapfile -t publies < <(awk '
      /^[^ ]/ { dans_services = ($0 == "services:"); next }
      !dans_services { next }
      /^  [^ ]/ { service = $1; sub(/:$/, "", service); dans_ports = 0; next }
      /^    [^ ]/ { dans_ports = ($1 == "ports:"); next }
      dans_ports && /^        target:/ { print service ":" $2 }
    ' <<< "$config")
    if ((${#publies[@]} == 0)); then
      ko "$f : aucun port publié lu (format de docker compose config inattendu ?)"; continue
    fi
    interdits=()
    for p in "${publies[@]}"; do
      [[ " ${PORTS_AUTORISES[*]} " == *" $p "* ]] || interdits+=("$p")
    done
    if ((${#interdits[@]})); then
      ko "$f : port(s) publié(s) hors liste autorisée (${PORTS_AUTORISES[*]}) : ${interdits[*]}"
    else
      ok "$f : ${publies[*]}"
    fi
  done
else
  ok "pas encore de compose.yml"
fi

# 4. Chaque variable interpolée par compose est documentée dans envs/.env.example
#    ($${…} = échappement compose, ignoré ; minuscules = variables shell des healthchecks)
section "variables documentées"
if [[ -f compose.yml && -f envs/.env.example ]]; then
  mapfile -t compose_vars < <(grep -ohE '(^|[^$])\$\{[A-Z][A-Z0-9_]*' compose.yml compose/*.yml \
    | sed -E 's/.*\$\{//' | sort -u)
  missing=0
  for v in "${compose_vars[@]}"; do
    # Variables internes : fournie par Compose / définie par le garde-fou de lancement (section 6 bis)
    [[ "$v" == COMPOSE_PROJECT_NAME || "$v" == PLATFORM_GARDE_FOU ]] && continue
    grep -qE "^#?${v}=" envs/.env.example || { ko "$v absente de envs/.env.example"; missing=1; }
  done
  ((missing)) || ok "${#compose_vars[@]} variable(s) (dont 2 internes)"
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
  done < <(grep -nE '^[[:space:]]*image:' compose.yml compose/*.yml)
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
if [[ -f compose.yml ]] && grep -nE '^[[:space:]]*container_name:' compose.yml compose/*.yml; then
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
  for f in compose/*.yml; do
    m="$(basename "$f" .yml)"
    grep -qE "^x-garde-fou-${m}: \"\\$\{PLATFORM_GARDE_FOU:\?" "$f" || ko "$f : extension x-garde-fou-${m} absente"
    refus_attendu "PLATFORM_GARDE_FOU" "$f seul" -f "$f"
  done
  refus_attendu "projet-autorise/devops-platform-garde-fou-test.env" "-p devops-platform-garde-fou-test" \
    -p devops-platform-garde-fou-test
  nb_includes="$(grep -cE '^  - path: compose/' compose.yml)"
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
