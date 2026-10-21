#!/usr/bin/env bash
# Sauvegarde et restauration à froid des volumes à état d'une instance (make backup, make restore),
# lancées par scripts/instance.sh, qui positionne la cible Docker (contexte SSH d'une instance distante),
# les variables de l'instance (PLATFORM_CONFIG_DIR, COMPOSE_PROFILES) et le garde-fou de l'hôte.
# Les données transitent par le poste : un conteneur busybox lit ou écrit chaque volume sur l'hôte de
# l'instance, le flux tar passe par l'entrée ou la sortie standard de `docker run`. Seul Docker est
# requis sur l'hôte. Documentation : docs/sauvegarde.md.
#
# Usage : [DESTINATION=<répertoire>] [AVEC_LOKI=1] scripts/sauvegarde.sh sauvegarder envs/<env>.env
#         [FORCER=1] scripts/sauvegarde.sh restaurer envs/<env>.env <répertoire de sauvegarde>
# La restauration ne redémarre pas l'instance : make restore enchaîne make deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/verrou.sh
source "$ROOT/scripts/lib/verrou.sh"
# shellcheck source=scripts/lib/images.sh
source "$ROOT/scripts/lib/images.sh"

# Volumes à état sauvegardés (clé du volume dans compose/*.yml) et service qui écrit chacun : la version
# d'image de ce service est celle qui a produit les données. loki_data seulement avec AVEC_LOKI=1.
# Exclus : sonarqube_extensions (rempli depuis l'image), *_logs, promtail_positions.
readonly VOLUMES=(gitlab_config gitlab_data gitlab_runner_config sonarqube_db sonarqube_data grafana_data
  portainer_data traefik_acme loki_data)
declare -rA SERVICE_VOLUME=([gitlab_config]=gitlab [gitlab_data]=gitlab [gitlab_runner_config]=gitlab-runner
  [sonarqube_db]=sonarqube-db [sonarqube_data]=sonarqube [grafana_data]=grafana [portainer_data]=portainer
  [traefik_acme]=traefik [loki_data]=loki)
# Volume vidé par la restauration, rempli depuis l'image de SonarQube à sa recréation (plugin community
# branch de la version restaurée, docs/montee-de-version.md)
readonly VOLUME_EXTENSIONS=sonarqube_extensions
readonly FORMAT=1 MANIFESTE=manifeste.txt EMPREINTES=SHA256SUMS
readonly WAIT_TIMEOUT=900
# Verrou de l'instance (scripts/instance.sh, scripts/smoke.sh) : volume du runner
readonly FICHIER_VERROU=/etc/gitlab-runner/.bootstrap.lock

erreur() { echo "Erreur : $*" >&2; exit 1; }
etape() { echo; echo "==> $*"; }

usage() {
  echo "Usage : $0 sauvegarder envs/<env>.env" >&2
  echo "        $0 restaurer envs/<env>.env <répertoire de sauvegarde>" >&2
  exit 1
}

(($# >= 2)) || usage
action="$1" env_file="$2"
case "$action" in
  sauvegarder) (($# == 2)) || usage ;;
  restaurer) (($# == 3)) || usage; sauvegarde="${3%/}" ;;
  *) usage ;;
esac
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file"
env="$(basename "$env_file" .env)"

dc() { docker compose --env-file "$env_file" "$@"; }

# Garde-fou : lancé hors make, une instance distante serait cherchée sur le moteur local
if [[ -n "$(env_valeur_fichier "$env_file" DEPLOY_SSH)" && "${DOCKER_CONTEXT:-}" != "devops-platform-$env" ]]; then
  erreur "instance distante (DEPLOY_SSH dans $env_file) : lancer make backup ou make restore ENV=$env"
fi
case "${FORCER:-}" in 1 | "") ;; *) erreur "FORCER invalide : $FORCER (attendu : 1)" ;; esac
case "${AVEC_LOKI:-}" in 1 | "" | 0) ;; *) erreur "AVEC_LOKI invalide : $AVEC_LOKI (attendu : 1)" ;; esac

# Empreinte SHA-256 de l'entrée standard (sha256sum, ou shasum sur macOS)
empreinte_sha256() {
  if command -v sha256sum > /dev/null; then sha256sum; else shasum -a 256; fi | cut -d' ' -f1
}

# Conteneur utilitaire sur l'hôte de l'instance (aucun réseau)
utilitaire() { docker run --rm --network none "$@"; }

# Volume existant sur l'hôte : testé sans `docker run -v`, qui créerait un volume vide sans les labels
# de Compose
volume_existe() { docker volume inspect "$1" > /dev/null 2>&1; }

# Volume existant et non vide
volume_non_vide() {
  volume_existe "$1" || return 1
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  [[ "$(utilitaire -v "$1:/v:ro" "$BUSYBOX_IMAGE" sh -c 'ls -A /v | head -n1')" != "" ]]
}

# Image utilitaire présente sur l'hôte avant tout arrêt (hôte sans accès au registre : échec immédiat)
preparer_utilitaire() {
  docker image inspect "$BUSYBOX_IMAGE" > /dev/null 2>&1 && return 0
  docker pull -q "$BUSYBOX_IMAGE" > /dev/null || erreur "image $BUSYBOX_IMAGE indisponible sur l'hôte de l'instance"
}

config="$(dc config)"
projet="$(sed -n 's/^name: //p' <<< "$config" | head -n1)"
services=" $(dc config --services | paste -sd ' ' -) "
# Nom Docker de chaque volume déclaré par la configuration effective (TLS_MODE, briques actives)
declare -A NOM_VOLUME=()
while read -r cle nom; do NOM_VOLUME[$cle]="$nom"; done < <(awk '
  /^volumes:/ { dans = 1; next }
  dans && /^[^ ]/ { dans = 0 }
  dans && /^  [A-Za-z0-9_.-]+:$/ { cle = $1; sub(/:$/, "", cle) }
  dans && /^    name: / { print cle, $2 }' <<< "$config")

# Image configurée d'un service (celle que make deploy lancerait), lue dans sa propre définition :
# `config --images <service>` liste aussi les images de ses dépendances (depends_on), triées par nom
image_config() {
  awk -v service="  $1:" '
    /^services:/ { dans = 1; next }
    dans && /^[^ ]/ { dans = 0 }
    dans && /^  [^ ]/ { courant = ($0 == service) }
    dans && courant && /^    image: / { print $2; exit }' <<< "$config"
}

# --- Sauvegarde ----------------------------------------------------------------------------------

services_arretes=()
redemarrer() {
  ((${#services_arretes[@]})) || return 0
  # Un second Ctrl-C n'interrompt pas le redémarrage
  trap '' INT
  etape "Redémarrage : ${services_arretes[*]}"
  # Conteneurs existants redémarrés tels quels : ni recréation ni configuration appliquée
  if ! dc up -d --no-recreate --no-deps --wait --wait-timeout "$WAIT_TIMEOUT" "${services_arretes[@]}"; then
    echo "Attention : redémarrage incomplet, voir make status ENV=$env (make deploy ENV=$env pour relancer)." >&2
    return 1
  fi
  services_arretes=()
}

partiel=""
fin_sauvegarde() {
  local code=$?
  verrou_liberer
  redemarrer || code=1
  if ((code != 0)) && [[ -n "$partiel" && -d "$partiel" ]]; then
    echo "Sauvegarde incomplète conservée pour diagnostic, à supprimer : $partiel" >&2
  fi
  exit "$code"
}

sauvegarder() {
  local destination horodatage nom final cle nom_vol service id image architecture fichier
  local empreinte debut duree avec_loki="${AVEC_LOKI:-0}" a_sauver=() en_cours=() delai cible

  etape "Contrôles avant l'arrêt de l'instance $env"
  destination="${DESTINATION:-${XDG_DATA_HOME:-$HOME/.local/share}/devops-platform/sauvegardes/$env}"
  umask 077
  mkdir -p -- "$destination" || erreur "répertoire de destination impossible à créer : $destination"
  destination="$(cd -- "$destination" && pwd)"
  [[ -w "$destination" ]] || erreur "répertoire de destination non inscriptible : $destination"
  horodatage="$(date -u +%Y%m%dT%H%M%SZ)"
  nom="$env-$horodatage"
  final="$destination/$nom"
  [[ ! -e "$final" ]] || erreur "$final existe déjà"

  for cle in "${VOLUMES[@]}"; do
    [[ "$cle" == loki_data && "$avec_loki" != 1 ]] && continue
    [[ -n "${NOM_VOLUME[$cle]:-}" ]] || continue
    a_sauver+=("$cle")
  done
  ((${#a_sauver[@]})) || erreur "aucun volume à sauvegarder dans la configuration de $env_file"

  # Version d'image ayant produit les données : celle du conteneur, comparée à la configuration (un tag
  # changé dans le fichier sans make deploy fausserait le manifeste)
  declare -A image_service=() id_service=()
  for cle in "${a_sauver[@]}"; do
    nom_vol="${NOM_VOLUME[$cle]}" service="${SERVICE_VOLUME[$cle]}"
    volume_existe "$nom_vol" || erreur "volume $nom_vol absent de l'hôte : instance jamais déployée ? (make deploy ENV=$env)"
    [[ -n "${image_service[$service]:-}" ]] && continue
    [[ "$services" == *" $service "* ]] || erreur "service $service (volume $cle) absent de la configuration"
    id="$(dc ps -aq "$service" | head -n1)"
    [[ -n "$id" ]] || erreur "conteneur $service absent (instance arrêtée par make down ?) : make deploy ENV=$env, puis relancer"
    image="$(docker inspect -f '{{.Config.Image}}' "$id")"
    if [[ "$image" != "$(image_config "$service")" ]]; then
      echo "Erreur : $service tourne avec $image, mais $env_file configure $(image_config "$service")." >&2
      echo "  Le manifeste doit porter la version qui a produit les données : make deploy ENV=$env," >&2
      echo "  ou remettre la version en service dans $env_file, puis relancer." >&2
      exit 1
    fi
    image_service[$service]="$image"
    id_service[$service]="$(docker inspect -f '{{.Image}}' "$id")"
  done
  architecture="$(docker info --format '{{.Architecture}}')"
  preparer_utilitaire
  echo "Volumes : ${a_sauver[*]}"
  echo "Destination : $final"

  partiel="$final.partiel"
  rm -rf -- "$partiel"
  mkdir -m 700 -- "$partiel"
  trap fin_sauvegarde EXIT
  mapfile -t en_cours < <(dc ps --status running --services)

  # Verrou de l'instance : aucun make bootstrap ni make smoke en cours ou à venir jusqu'à l'arrêt du
  # runner, qui le libère (détenteur arrêté avec le conteneur)
  if [[ " ${en_cours[*]} " == *" gitlab-runner "* ]]; then
    verrou_prendre gitlab-runner "$FICHIER_VERROU" "make backup ENV=$env"
    echo "Verrou de l'instance pris ($FICHIER_VERROU, conteneur gitlab-runner)."
  fi

  etape "Arrêt de l'instance $env"
  debut=$SECONDS
  services_arretes=("${en_cours[@]}")
  if [[ " ${en_cours[*]} " == *" gitlab-runner "* ]]; then
    delai="$(env_valeur "$env_file" GITLAB_RUNNER_STOP_GRACE_PERIOD)"
    echo "Arrêt gracieux du runner : il ne prend plus de job et attend la fin des jobs en cours (au plus ${delai:-1h})."
    dc stop gitlab-runner
  fi
  dc stop

  etape "Archivage"
  for cle in "${a_sauver[@]}"; do
    fichier="$cle.tar.gz"
    printf '  %-22s ' "$cle"
    # Sockets laissées par les services (gitlab_data) : ignorées par tar, sans incidence
    utilitaire -v "${NOM_VOLUME[$cle]}:/source:ro" "$BUSYBOX_IMAGE" tar -czf - -C /source . \
      > "$partiel/$fichier" 2> >(grep -v 'socket ignored$' >&2)
    tar -tzf "$partiel/$fichier" > /dev/null || erreur "archive $fichier illisible"
    empreinte="$(empreinte_sha256 < "$partiel/$fichier")"
    printf '%s  %s\n' "$empreinte" "$fichier" >> "$partiel/$EMPREINTES"
    du -h "$partiel/$fichier" | cut -f1
  done
  redemarrer
  duree=$((SECONDS - debut))
  cible="$(env_valeur_fichier "$env_file" DEPLOY_SSH)"

  {
    echo "format=$FORMAT"
    echo "instance=$env"
    echo "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "cible=${cible:-local}"
    echo "architecture=$architecture"
    for service in "${!image_service[@]}"; do
      echo "image=$service ${image_service[$service]} ${id_service[$service]}"
    done | LC_ALL=C sort
    for cle in "${a_sauver[@]}"; do
      echo "volume=$cle $cle.tar.gz $(grep " $cle.tar.gz\$" "$partiel/$EMPREINTES" | cut -d' ' -f1)"
    done
  } > "$partiel/$MANIFESTE"
  mv -- "$partiel" "$final"
  partiel=""

  echo
  echo "Sauvegarde terminée : $final ($(du -sh "$final" | cut -f1), instance arrêtée ${duree} s)."
  echo "  Contient des secrets (bases, clés SSH d'hôte de GitLab) : à conserver en lieu sûr."
  echo "  Restauration : make restore ENV=$env SAUVEGARDE=$final"
}

# --- Restauration --------------------------------------------------------------------------------

# Manifeste lu par motifs stricts (jamais sourcé) : m_<clé> pour les valeurs simples, tableaux pour les
# images et les volumes
lire_manifeste() {
  local ligne
  m_format="" m_instance="" m_date="" m_architecture="" m_cible=""
  declare -gA m_image=() m_fichier=() m_empreinte=()
  m_volumes=()
  [[ -f "$sauvegarde/$MANIFESTE" ]] || erreur "manifeste introuvable : $sauvegarde/$MANIFESTE"
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    if [[ "$ligne" =~ ^(format|instance|date|architecture|cible)=([^[:space:]]*)$ ]]; then
      printf -v "m_${BASH_REMATCH[1]}" '%s' "${BASH_REMATCH[2]}"
    elif [[ "$ligne" =~ ^image=([a-z0-9-]+)\ ([^[:space:]]+)\ [^[:space:]]*$ ]]; then
      m_image[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
    elif [[ "$ligne" =~ ^volume=([a-z_]+)\ ([a-z_]+\.tar\.gz)\ ([0-9a-f]{64})$ ]]; then
      [[ " ${VOLUMES[*]} " == *" ${BASH_REMATCH[1]} "* && "${BASH_REMATCH[2]}" == "${BASH_REMATCH[1]}.tar.gz" ]] \
        || erreur "manifeste : volume inattendu ($ligne)"
      m_volumes+=("${BASH_REMATCH[1]}")
      m_fichier[${BASH_REMATCH[1]}]="${BASH_REMATCH[2]}"
      m_empreinte[${BASH_REMATCH[1]}]="${BASH_REMATCH[3]}"
    else
      erreur "manifeste : ligne illisible ($ligne)"
    fi
  done < "$sauvegarde/$MANIFESTE"
  [[ "$m_format" == "$FORMAT" ]] || erreur "manifeste : format ${m_format:-absent} (attendu : $FORMAT)"
  ((${#m_volumes[@]})) || erreur "manifeste : aucun volume"
}

restaurer() {
  local cle service image nom_vol empreinte refus=() non_vides=() architecture fichier
  [[ -d "$sauvegarde" ]] || erreur "sauvegarde introuvable : $sauvegarde"
  sauvegarde="$(cd -- "$sauvegarde" && pwd)"

  etape "Contrôle de la sauvegarde $sauvegarde"
  lire_manifeste
  [[ "$m_instance" == "$env" ]] \
    || erreur "sauvegarde de l'instance « $m_instance », pas « $env » (secrets de $env_file différents)"
  echo "Instance $m_instance, sauvegardée le $m_date ($m_cible, $m_architecture) : ${m_volumes[*]}"

  for cle in "${m_volumes[@]}"; do
    fichier="$sauvegarde/${m_fichier[$cle]}"
    [[ -f "$fichier" ]] || erreur "archive manquante : $fichier"
    empreinte="$(empreinte_sha256 < "$fichier")"
    [[ "$empreinte" == "${m_empreinte[$cle]}" ]] || erreur "empreinte de $fichier différente du manifeste : archive altérée"
  done
  echo "Empreintes vérifiées."

  # Volumes de la sauvegarde absents de la configuration (TLS_MODE, brique désactivée) : refus ; volumes
  # sauvegardables de la configuration absents de la sauvegarde : laissés tels quels
  for cle in "${m_volumes[@]}"; do
    [[ -n "${NOM_VOLUME[$cle]:-}" ]] || refus+=("volume $cle sauvegardé, absent de la configuration de $env_file")
  done
  for cle in "${VOLUMES[@]}"; do
    if [[ -n "${NOM_VOLUME[$cle]:-}" && -z "${m_fichier[$cle]:-}" ]]; then
      echo "Attention : volume $cle absent de la sauvegarde, laissé tel quel." >&2
    fi
  done
  # Versions d'image des services qui écrivent les volumes restaurés : identiques à la sauvegarde
  for cle in "${m_volumes[@]}"; do
    service="${SERVICE_VOLUME[$cle]}"
    [[ -n "${NOM_VOLUME[$cle]:-}" ]] || continue
    image="$(image_config "$service")"
    if [[ "$image" != "${m_image[$service]:-}" ]]; then
      refus+=("$service : $image configurée dans $env_file, ${m_image[$service]:-inconnue} dans la sauvegarde")
      m_image[$service]="$image"  # un seul message par service
    fi
  done
  architecture="$(docker info --format '{{.Architecture}}')"
  [[ "$architecture" == "$m_architecture" ]] \
    || refus+=("architecture de l'hôte $architecture, sauvegarde prise sur $m_architecture")
  if ((${#refus[@]})); then
    echo "Erreur : restauration refusée, instance inchangée :" >&2
    printf '  - %s\n' "${refus[@]}" >&2
    echo "  Version d'image : remettre dans $env_file la version de la sauvegarde (retour arrière," >&2
    echo "  docs/sauvegarde.md)." >&2
    exit 1
  fi
  echo "Versions d'image et architecture conformes."

  preparer_utilitaire
  for cle in "${m_volumes[@]}"; do
    if volume_non_vide "${NOM_VOLUME[$cle]}"; then non_vides+=("$cle"); fi
  done
  if ((${#non_vides[@]})); then
    if [[ "${FORCER:-}" != 1 ]]; then
      echo "Erreur : volumes non vides sur l'hôte de l'instance $env : ${non_vides[*]}." >&2
      echo "  Leur contenu serait remplacé par celui de la sauvegarde ; instance inchangée." >&2
      echo "  Si c'est voulu : make restore ENV=$env SAUVEGARDE=$sauvegarde FORCER=1" >&2
      exit 1
    fi
    echo "Attention : volumes non vides remplacés (FORCER=1) : ${non_vides[*]}." >&2
  fi

  trap verrou_liberer EXIT
  if [[ "$services" == *" gitlab-runner "* && -n "$(dc ps -q --status running gitlab-runner)" ]]; then
    verrou_prendre gitlab-runner "$FICHIER_VERROU" "make restore ENV=$env"
    echo "Verrou de l'instance pris ($FICHIER_VERROU, conteneur gitlab-runner)."
  fi

  etape "Arrêt de l'instance $env (conteneurs supprimés, volumes conservés)"
  dc down
  verrou_liberer
  trap 'echo "Restauration interrompue : instance arrêtée, volumes partiellement restaurés. Relancer make restore ENV=$env SAUVEGARDE=$sauvegarde FORCER=1." >&2' EXIT

  etape "Restauration des volumes"
  if [[ -n "${NOM_VOLUME[$VOLUME_EXTENSIONS]:-}" ]] && volume_existe "${NOM_VOLUME[$VOLUME_EXTENSIONS]}"; then
    docker volume rm "${NOM_VOLUME[$VOLUME_EXTENSIONS]}" > /dev/null
    echo "  $VOLUME_EXTENSIONS supprimé (rempli depuis l'image de SonarQube à son démarrage)."
  fi
  for cle in "${m_volumes[@]}"; do
    nom_vol="${NOM_VOLUME[$cle]}"
    printf '  %-22s ' "$cle"
    # Volume créé avec les labels de Compose, qui le reconnaît ensuite comme le sien
    if ! volume_existe "$nom_vol"; then
      docker volume create --label "com.docker.compose.project=$projet" \
        --label "com.docker.compose.volume=$cle" "$nom_vol" > /dev/null
    fi
    # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
    utilitaire -i -v "$nom_vol:/cible" "$BUSYBOX_IMAGE" sh -c '
        set -e
        cd /cible
        rm -rf -- ./* ./.[!.]* ./..?*
        tar -xzf - --numeric-owner -C /cible' < "$sauvegarde/${m_fichier[$cle]}"
    echo "restauré"
  done
  trap - EXIT
  echo
  echo "Volumes restaurés depuis $sauvegarde."
}

case "$action" in
  sauvegarder) sauvegarder ;;
  restaurer) restaurer ;;
esac
