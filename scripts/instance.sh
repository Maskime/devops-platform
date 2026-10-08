#!/usr/bin/env bash
# Pilote une instance, locale ou distante : make deploy, down, status, reload-certs, bootstrap
# (qui régénère aussi le fichier de sortie outputs/<env>.env), smoke (scripts/smoke.sh).
#   - DEPLOY_SSH vide ou absente de envs/<env>.env : moteur Docker courant du poste (comme avant) ;
#   - DEPLOY_SSH=ssh://[user@]hôte[:port] : contexte Docker SSH devops-platform-<env> (créé ou mis à
#     jour), fichiers de config montés par les services copiés sur l'hôte dans
#     ${DEPLOY_DIR}/config-<empreinte> (PLATFORM_CONFIG_DIR), CA privée de TLS_MODE=custom dans
#     ${DEPLOY_DIR}/ca-<empreinte> (PLATFORM_CA_DIR), garde-fou ${DEPLOY_DIR}/instance.
# DEPLOY_SSH et DEPLOY_DIR sont lues dans le fichier uniquement (jamais depuis le shell) : la cible
# d'une commande ne dépend que du fichier de l'instance. Documentation : docs/deploiement.md.
#
# Usage : scripts/instance.sh <deploy|down|status|reload-certs|smoke> <env>
#         scripts/instance.sh bootstrap <env> [sonarqube] [gitlab]   (défaut : toutes les étapes)
#         scripts/instance.sh compose <env> <arguments docker compose…>   (commande manuelle)
# Garde-fous de configuration (make check-env) : appliqués par le Makefile avant deploy et reload-certs.
# Variables transmises par le Makefile : FORCER=1 (garde-fou de l'hôte), ROTATION=1 (bootstrap : token
# d'analyse SonarQube remplacé, voir scripts/bootstrap/sonarqube.sh), CONFIRMER=1 (down d'une instance
# distante sans question, obligatoire hors terminal).
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
# shellcheck source=scripts/lib/verrou.sh
source "$ROOT/scripts/lib/verrou.sh"
# Verrou hérité par scripts/bootstrap/gitlab.sh : jamais repris du shell de l'opérateur
unset VERROU_PID_HERITE

# Copie et nettoyage des fichiers de config sur l'hôte cible (dernière stable, tag figé par son digest)
readonly BUSYBOX_IMAGE="busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e"
readonly DEPLOY_DIR_DEFAUT=/opt/devops-platform
readonly ENGINE_MIN=25
readonly WAIT_TIMEOUT=900
readonly PARALLELISME_SSH=4
# Étapes de make bootstrap, dans l'ordre d'exécution (scripts/bootstrap/<étape>.sh) : SonarQube
# d'abord, son token d'analyse servant à la configuration de GitLab
readonly ETAPES_BOOTSTRAP=(sonarqube gitlab)
# Fichiers de config/ montés par les services (les env_file, lus par Compose sur le poste, n'en font
# pas partie). TLS_MODE=custom : fichiers de compose/tls/custom.yml en plus. La CA facultative, montée
# par gitlab-runner et sonarqube (compose/tls/gitlab/custom.yml, compose/tls/sonarqube/custom.yml), a sa
# propre copie et sa propre empreinte : un autre changement de config ne recrée pas ces services, et
# seul ca.pem est copié (jamais une clé de CA déposée à côté).
readonly CONFIG_MONTEE=(loki/loki-config.yaml promtail/promtail-config.yaml grafana/provisioning)
readonly CONFIG_MONTEE_CUSTOM=(traefik/tls-custom.yml certs/cert.pem certs/key.pem)
readonly CA_CUSTOM=config/certs/ca/ca.pem
# Verrou de l'instance, dans le volume du runner (même fichier dans scripts/bootstrap/gitlab.sh et
# scripts/smoke.sh)
readonly FICHIER_VERROU=/etc/gitlab-runner/.bootstrap.lock

erreur() { echo "Erreur : $*" >&2; exit 1; }

usage() {
  echo "Usage : $0 <deploy|down|status|reload-certs|smoke> <env>" >&2
  echo "        $0 bootstrap <env> $(printf '[%s] ' "${ETAPES_BOOTSTRAP[@]}")" >&2
  echo "        $0 compose <env> <arguments docker compose…>" >&2
  exit 1
}

(($# >= 2)) || usage
action="$1" env="$2"
shift 2
case "$action" in
  deploy | down | status | reload-certs | smoke) (($# == 0)) || usage ;;
  bootstrap)
    # Étapes demandées (toutes par défaut), dédoublonnées et remises dans l'ordre d'exécution
    demandees=" ${*:-${ETAPES_BOOTSTRAP[*]}} "
    for e in "$@"; do [[ " ${ETAPES_BOOTSTRAP[*]} " == *" $e "* ]] || usage; done
    etapes=()
    for e in "${ETAPES_BOOTSTRAP[@]}"; do [[ "$demandees" == *" $e "* ]] && etapes+=("$e"); done
    ;;
  compose) (($#)) || usage ;;
  *) usage ;;
esac
[[ "$env" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || erreur "ENV invalide : $env (attendu : minuscules, chiffres, - et _)"
env_file="envs/$env.env"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file (le générer : make init ENV=$env)"

compose=(docker compose --env-file "$env_file")
deploy_ssh="$(env_valeur_fichier "$env_file" DEPLOY_SSH)"
deploy_dir="$(env_valeur_fichier "$env_file" DEPLOY_DIR)"
deploy_dir="${deploy_dir:-$DEPLOY_DIR_DEFAUT}"
contexte="devops-platform-$env"

# --- Cible ---------------------------------------------------------------------------------------

# Contexte SSH créé ou mis à jour (idempotent), puis exporté pour toutes les commandes docker
preparer_contexte_distant() {
  [[ "$deploy_ssh" =~ ^ssh://([^@/[:space:]]+@)?[^@:/[:space:]]+(:[0-9]{1,5})?$ ]] \
    || erreur "DEPLOY_SSH invalide dans $env_file : $deploy_ssh (attendu : ssh://[utilisateur@]hôte[:port])"
  [[ "$deploy_dir" =~ ^/[A-Za-z0-9._/-]*[A-Za-z0-9._-]$ && "/$deploy_dir/" != *"/../"* && "/$deploy_dir/" != *"/./"* ]] \
    || erreur "DEPLOY_DIR invalide dans $env_file : $deploy_dir (chemin absolu, sans espace ni « .. », différent de /)"
  if [[ -n "${DOCKER_HOST:-}" ]]; then
    echo "Attention : DOCKER_HOST=$DOCKER_HOST ignoré (il primerait sur le contexte $contexte)." >&2
    unset DOCKER_HOST
  fi

  # Pré-test non interactif : une clé d'hôte inconnue ou une clé SSH absente échoue au lieu de bloquer.
  # -n : l'entrée standard reste à la commande appelée (compose exec -T alimenté par un pipe).
  local version
  if ! version="$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$deploy_ssh" \
      "docker version --format '{{.Server.Version}}'" 2>&1)"; then
    echo "$version" >&2
    echo "Connexion à $deploy_ssh impossible ou Docker inaccessible (voir ci-dessus). Vérifier :" >&2
    echo "  - ssh $deploy_ssh fonctionne sans mot de passe ni question (clé SSH, hôte dans known_hosts) ;" >&2
    echo "  - l'utilisateur distant accède à Docker (root, ou groupe docker) ;" >&2
    echo "  - le serveur est préparé (scripts/host-prereqs.sh, docs/serveur.md)." >&2
    exit 1
  fi
  version="$(tail -n1 <<<"$version")"
  if [[ ! "$version" =~ ^([0-9]+)\. ]] || ((BASH_REMATCH[1] < ENGINE_MIN)); then
    erreur "Docker Engine $version sur $deploy_ssh : version $ENGINE_MIN.0 minimale (docs/serveur.md)"
  fi

  local actuel
  actuel="$(docker context inspect -f '{{.Endpoints.docker.Host}}' "$contexte" 2>/dev/null || true)"
  if [[ -z "$actuel" ]]; then
    docker context create "$contexte" --description "devops-platform : $env_file" \
      --docker "host=$deploy_ssh" >/dev/null 2>&1 || erreur "création du contexte Docker $contexte impossible"
    echo "Contexte Docker $contexte créé ($deploy_ssh)."
  elif [[ "$actuel" != "$deploy_ssh" ]]; then
    docker context update "$contexte" --docker "host=$deploy_ssh" >/dev/null 2>&1 \
      || erreur "mise à jour du contexte Docker $contexte impossible"
    echo "Contexte Docker $contexte mis à jour ($actuel → $deploy_ssh)."
  fi
  export DOCKER_CONTEXT="$contexte"
  # Chaque requête concurrente de Compose ouvre sa propre connexion SSH : au-delà d'une dizaine de
  # connexions simultanées, sshd en coupe (MaxStartups, 10:30:100 par défaut). Parallélisme borné,
  # valeur du shell prioritaire.
  export COMPOSE_PARALLEL_LIMIT="${COMPOSE_PARALLEL_LIMIT:-$PARALLELISME_SSH}"
}

afficher_cible() {
  local moteur
  moteur="$(docker info --format '{{.Name}}' 2>/dev/null || echo '?')"
  if [[ -n "$deploy_ssh" ]]; then
    echo "Instance $env : $deploy_ssh (contexte Docker $contexte, moteur $moteur, config dans $deploy_dir)"
  else
    echo "Instance $env : moteur Docker local (contexte $(docker context show), moteur $moteur)"
  fi
}

# Conteneur utilitaire sur l'hôte cible (aucun réseau)
utilitaire() { docker run --rm --network none "$@"; }

# Garde-fou : deux fichiers d'env vers le même hôte piloteraient le même projet Compose (mêmes volumes).
# Marqueur ${DEPLOY_DIR}/instance = nom de l'env, écrit au premier déploiement (ecrire=1).
# shellcheck disable=SC2016 # scripts exécutés par le sh du conteneur
verifier_instance() { # <ecrire : 0|1>
  local marqueur parent base
  if (($1)); then
    marqueur="$(utilitaire -v "$deploy_dir:/dst" "$BUSYBOX_IMAGE" sh -c \
      'chmod 700 /dst; [ -f /dst/instance ] || printf "%s\n" "$1" > /dst/instance; cat /dst/instance' sh "$env")"
  else
    # Lecture seule, par le parent : ne crée pas DEPLOY_DIR sur un hôte jamais déployé
    parent="$(dirname "$deploy_dir")" base="$(basename "$deploy_dir")"
    marqueur="$(utilitaire -v "$parent:/parent:ro" "$BUSYBOX_IMAGE" sh -c \
      'cat "/parent/$1/instance" 2>/dev/null || true' sh "$base")"
  fi
  [[ -z "$marqueur" || "$marqueur" == "$env" ]] && return 0
  if [[ "${FORCER:-}" != 1 ]]; then
    echo "Erreur : $deploy_ssh ($deploy_dir) héberge l'instance « $marqueur », pas « $env »." >&2
    echo "  Une seule instance par hôte : vérifier DEPLOY_SSH dans $env_file et envs/$marqueur.env." >&2
    echo "  Si $env remplace volontairement $marqueur sur cet hôte : FORCER=1." >&2
    exit 1
  fi
  echo "Attention : instance « $marqueur » remplacée par « $env » sur $deploy_ssh (FORCER=1)." >&2
  if (($1)); then
    utilitaire -v "$deploy_dir:/dst" "$BUSYBOX_IMAGE" sh -c 'printf "%s\n" "$1" > /dst/instance' sh "$env"
  fi
}

# --- Fichiers de config sur l'hôte cible -----------------------------------------------------------

config_montee() {
  local tls_mode
  tls_mode="$(env_valeur "$env_file" TLS_MODE)"
  printf '%s\n' "${CONFIG_MONTEE[@]}"
  if [[ "$tls_mode" == custom ]]; then printf '%s\n' "${CONFIG_MONTEE_CUSTOM[@]}"; fi
  return 0
}

sha256() { if command -v sha256sum >/dev/null; then sha256sum "$@"; else shasum -a 256 "$@"; fi; }

# Empreinte (12 caractères) des chemins et contenus des fichiers montés : un changement de config
# change le répertoire source, donc Compose recrée les services qui montent la configuration (et eux seuls)
empreinte_config() {
  local chemins
  mapfile -t chemins < <(config_montee)
  (cd config && find "${chemins[@]}" -type f | LC_ALL=C sort | while IFS= read -r f; do sha256 "$f"; done) \
    | sha256 | cut -c1-12
}

# Empreinte (12 caractères) du contenu de la CA privée, « vide » sans ca.pem
empreinte_ca() {
  if [[ -f "$CA_CUSTOM" ]]; then sha256 <"$CA_CUSTOM" | cut -c1-12; else echo vide; fi
}

# Copie idempotente dans ${DEPLOY_DIR}/config-<empreinte> (rien n'est envoyé si elle existe déjà) :
# extraction dans un .tmp puis renommage ; propriétaire root, lecture seule pour les autres (grafana,
# loki ne tournent pas en root), clé privée en 600 (traefik tourne en root), DEPLOY_DIR en 700.
copier_config() {
  local chemins resultat
  mapfile -t chemins < <(config_montee)
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  resultat="$(COPYFILE_DISABLE=1 tar -C config --format=ustar -cf - "${chemins[@]}" \
    | utilitaire -i -v "$deploy_dir:/dst" "$BUSYBOX_IMAGE" sh -c '
        set -e
        chmod 700 /dst
        d="/dst/config-$1"
        if [ -d "$d" ]; then cat >/dev/null; echo "déjà présente"; exit 0; fi
        rm -rf "$d.tmp"
        mkdir "$d.tmp"
        tar -xo -f - -C "$d.tmp"
        chown -R 0:0 "$d.tmp"
        chmod -R u=rwX,go=rX "$d.tmp"
        if [ -f "$d.tmp/certs/key.pem" ]; then chmod 600 "$d.tmp/certs/key.pem"; fi
        mv "$d.tmp" "$d"
        echo "copiée"' sh "$empreinte")"
  echo "Configuration $deploy_dir/config-$empreinte : $resultat."
  if [[ -n "${PLATFORM_CA_DIR:-}" ]]; then copier_ca; fi
}

# CA privée (TLS_MODE=custom) dans ${DEPLOY_DIR}/ca-<empreinte>, même méthode que copier_config.
# Répertoire créé même vide (ca-vide) : monté par gitlab-runner et sonarqube, CA fournie ou non.
copier_ca() {
  local resultat archive=(true)
  [[ -f "$CA_CUSTOM" ]] && archive=(tar -C "$(dirname "$CA_CUSTOM")" --format=ustar -cf - ca.pem)
  # shellcheck disable=SC2016 # script exécuté par le sh du conteneur
  resultat="$(COPYFILE_DISABLE=1 "${archive[@]}" \
    | utilitaire -i -v "$deploy_dir:/dst" "$BUSYBOX_IMAGE" sh -c '
        set -e
        d="/dst/ca-$1"
        if [ -d "$d" ]; then cat >/dev/null; echo "déjà présente"; exit 0; fi
        rm -rf "$d.tmp"
        mkdir "$d.tmp"
        if [ "$1" != vide ]; then tar -xo -f - -C "$d.tmp"; else cat >/dev/null; fi
        chown -R 0:0 "$d.tmp"
        chmod -R u=rwX,go=rX "$d.tmp"
        mv "$d.tmp" "$d"
        echo "copiée"' sh "$empreinte_ca")"
  echo "CA privée $PLATFORM_CA_DIR : $resultat."
}

# Supprime les copies (config-*, ca-*) qu'aucun conteneur du projet ne monte plus (non bloquant)
nettoyer_config() {
  local ids gardees
  mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$projet")
  gardees="config-$empreinte"
  if [[ -n "${PLATFORM_CA_DIR:-}" ]]; then gardees+=" ${PLATFORM_CA_DIR##*/}"; fi
  if ((${#ids[@]})); then
    gardees+=" $(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "${ids[@]}" \
      | sed -n "s#^$deploy_dir/\(\(config\|ca\)-[^/]*\).*#\1#p" | sort -u | paste -sd ' ' -)"
  fi
  # shellcheck disable=SC2016,SC2086 # script exécuté par le sh du conteneur ; liste découpée voulue
  utilitaire -v "$deploy_dir:/dst" "$BUSYBOX_IMAGE" sh -c '
      racine="$1"; shift
      cd /dst
      for d in config-* ca-*; do
        [ -e "$d" ] || continue
        case " $* " in *" $d "*) continue ;; esac
        rm -rf "$d" && echo "Copie de configuration supprimée : $racine/$d"
      done' sh "$deploy_dir" $gardees \
    || echo "Attention : nettoyage des anciennes copies de configuration impossible (sans incidence)." >&2
}

# --- CA privée (TLS_MODE=custom) ------------------------------------------------------------------

# Attend que chaque service soit healthy (après un restart, qui n'attend pas)
attendre_sante() { # <service>...
  local fin=$((SECONDS + WAIT_TIMEOUT)) service id etat
  for service in "$@"; do
    while :; do
      id="$("${compose[@]}" ps -q "$service")"
      etat="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$id" 2>/dev/null || true)"
      [[ "$etat" == healthy ]] && break
      ((SECONDS < fin)) || erreur "$service n'est pas healthy après ${WAIT_TIMEOUT} s (état : ${etat:-absent}) : voir scripts/instance.sh compose $env logs $service"
      sleep 5
    done
  done
}

# gitlab-runner et sonarqube lisent la CA à leur démarrage : un changement de CA leur est appliqué ici
# (make deploy, make reload-certs), à eux seuls, avec arrêt gracieux du runner (compose/gitlab.yml).
#   - distant : la CA a sa copie ca-<empreinte> (PLATFORM_CA_DIR) ; un conteneur qui monte une autre
#     copie est recréé (`up` l'a déjà fait dans make deploy) ;
#   - local : le répertoire monté est le même ; un conteneur démarré avant la dernière modification de
#     config/certs/ca/ (ctime : cp, mv, suppression, y compris cp -p) est redémarré. Rien ne dépend
#     d'une variable de scripts/instance.sh : un `docker compose` direct ne recrée rien.
# Ajout ou retrait de la CA : le runner doit aussi être ré-enregistré (make bootstrap, tls-ca-file).
appliquer_ca() {
  [[ "$(env_valeur "$env_file" TLS_MODE)" == custom ]] || return 0
  local services service id source demarre modif=0 f a_appliquer=() delai
  services=" $("${compose[@]}" config --services | paste -sd ' ' -) "
  if [[ -z "$deploy_ssh" ]]; then
    for f in "${CA_CUSTOM%/*}" "$CA_CUSTOM"; do
      if [[ -e "$f" ]] && (($(stat -c %Z "$f") > modif)); then modif="$(stat -c %Z "$f")"; fi
    done
  fi
  for service in gitlab-runner sonarqube; do
    [[ "$services" == *" $service "* ]] || continue
    id="$("${compose[@]}" ps -q --status running "$service")"
    [[ -n "$id" ]] || continue
    if [[ -n "$deploy_ssh" ]]; then
      source="$(docker inspect -f '{{range .Mounts}}{{if eq .Destination "/etc/devops-platform/ca"}}{{.Source}}{{end}}{{end}}' "$id")"
      [[ "$source" != "$PLATFORM_CA_DIR" ]] && a_appliquer+=("$service")
    else
      demarre="$(date -d "$(docker inspect -f '{{.State.StartedAt}}' "$id")" +%s)"
      ((modif > demarre)) && a_appliquer+=("$service")
    fi
  done
  if ((${#a_appliquer[@]})); then
    echo "CA privée modifiée : ${a_appliquer[*]} à redémarrer."
    if [[ " ${a_appliquer[*]} " == *" gitlab-runner "* ]]; then
      delai="$(env_valeur "$env_file" GITLAB_RUNNER_STOP_GRACE_PERIOD)"
      echo "  Arrêt gracieux du runner : il ne prend plus de job et attend la fin des jobs en cours (au plus ${delai:-1h})."
      echo "  Interrompu (Ctrl-C), relancer la commande : le runner peut rester arrêté jusque-là."
    fi
    if [[ -n "$deploy_ssh" ]]; then
      # Recréation sur la nouvelle copie ; d'autres changements en attente sur ces services sont appliqués aussi
      (set -x; "${compose[@]}" up -d --no-deps --wait --wait-timeout "$WAIT_TIMEOUT" "${a_appliquer[@]}")
    else
      (set -x; "${compose[@]}" restart "${a_appliquer[@]}")
      attendre_sante "${a_appliquer[@]}"
    fi
    echo "CA privée appliquée à ${a_appliquer[*]}."
  else
    echo "CA privée inchangée pour gitlab-runner et sonarqube."
  fi
  verifier_ca_runner
}

# Avertit si la présence de la CA ne correspond plus à l'enregistrement du runner (tls-ca-file de
# config.toml, posé par make bootstrap) ; runner arrêté ou pas encore enregistré : rien
verifier_ca_runner() {
  local enregistree=0 presente=0
  [[ -n "$("${compose[@]}" ps -q --status running gitlab-runner 2>/dev/null)" ]] || return 0
  "${compose[@]}" exec -T gitlab-runner test -s /etc/gitlab-runner/config.toml 2>/dev/null || return 0
  if "${compose[@]}" exec -T gitlab-runner grep -qE '^[[:space:]]*tls-ca-file[[:space:]]*=' \
      /etc/gitlab-runner/config.toml 2>/dev/null; then enregistree=1; fi
  [[ -f "$CA_CUSTOM" ]] && presente=1
  ((enregistree == presente)) && return 0
  if ((presente)); then
    echo "Attention : $CA_CUSTOM ajoutée, mais le runner est enregistré sans CA (tls-ca-file)." >&2
  else
    echo "Attention : $CA_CUSTOM retirée, mais le runner est enregistré avec une CA (tls-ca-file) : il ne joint plus GitLab." >&2
  fi
  echo "  Lancer make bootstrap ENV=$env (ré-enregistrement du runner)." >&2
}

# --- Récapitulatif -------------------------------------------------------------------------------

recapitulatif() {
  local tls_mode schema=http hote port_ssh libelle service
  tls_mode="$(env_valeur "$env_file" TLS_MODE)"
  [[ "${tls_mode:-none}" != none ]] && schema=https
  echo
  echo "URLs de l'instance $env :"
  for libelle in GitLab SonarQube Grafana Portainer PlantUML; do
    service="${libelle,,}"
    hote="$(env_valeur "$env_file" "${service^^}_HOSTNAME")"
    printf '  %-10s %s://%s\n' "$libelle" "$schema" "${hote:-$service.localhost}"
  done
  hote="$(env_valeur "$env_file" GITLAB_HOSTNAME)"
  port_ssh="$(env_valeur "$env_file" GITLAB_SSH_PORT)"
  printf '  %-10s ssh://git@%s:%s\n' "SSH GitLab" "${hote:-gitlab.localhost}" "${port_ssh:-2222}"
}

# Arrêt d'une instance distante : confirmation avant tout contact avec le serveur. En terminal, le nom
# de l'instance est à retaper (l'hôte affiché révèle une faute sur ENV) ; hors terminal, CONFIRMER=1.
confirmer_arret() {
  case "${CONFIRMER:-}" in
    1) return 0 ;;
    '') ;;
    *) erreur "CONFIRMER invalide : $CONFIRMER (attendu : 1)" ;;
  esac
  [[ -t 0 ]] || erreur "arrêt de l'instance distante $env ($deploy_ssh) : confirmation requise hors terminal, make down ENV=$env CONFIRMER=1"
  local reponse=""
  echo "Arrêt de l'instance $env sur $deploy_ssh : conteneurs supprimés (volumes conservés), services indisponibles." >&2
  read -r -p "Taper le nom de l'instance ($env) pour confirmer : " reponse || true
  [[ "$reponse" == "$env" ]] || erreur "arrêt annulé (réponse différente de « $env »)."
}

# --- Actions -------------------------------------------------------------------------------------

if [[ -n "$deploy_ssh" ]]; then
  if [[ "$action" == down ]]; then confirmer_arret; fi
  preparer_contexte_distant
  empreinte="$(empreinte_config)"
  export PLATFORM_CONFIG_DIR="$deploy_dir/config-$empreinte"
  unset PLATFORM_CA_DIR
  if [[ "$(env_valeur "$env_file" TLS_MODE)" == custom ]]; then
    empreinte_ca="$(empreinte_ca)"
    export PLATFORM_CA_DIR="$deploy_dir/ca-$empreinte_ca"
  fi
else
  # Variables internes : en local, les montages lisent config/ du repo
  unset PLATFORM_CONFIG_DIR PLATFORM_CA_DIR
  # Répertoire de la CA facultative, monté par gitlab-runner et sonarqube en TLS_MODE=custom (versionné
  # vide ; recréé s'il a disparu, sinon `up` échouerait : « bind source path does not exist »)
  if [[ "$(env_valeur "$env_file" TLS_MODE)" == custom ]]; then mkdir -p config/certs/ca; fi
fi
config="$("${compose[@]}" config)"
projet="$(sed -n 's/^name: //p' <<<"$config" | head -n1)"

case "$action" in
  deploy)
    afficher_cible
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 1; copier_config; fi
    # Conteneurs en double (lancés hors compose.yml ou sous un autre projet) : refus avant `up`
    scripts/check-doublons.sh "$env_file"
    # Compose reconnecte les conteneurs existants à un réseau renommé (PLATFORM_NETWORK) sans les
    # recréer : leur NetworkMode vise encore l'ancien réseau, supprimé, et ils ne redémarrent plus.
    # Dans ce cas, recréation forcée (volumes conservés). Un conteneur peut n'être que sur un réseau
    # dédié (socket-proxy) : son réseau principal est comparé à l'ensemble des réseaux déclarés.
    reseaux=" $(sed -n '/^networks:/,/^[^ ]/ s/^    name: //p' <<<"$config" | paste -sd ' ' -) "
    options=()
    for id in $("${compose[@]}" ps -aq); do
      mode="$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$id")"
      if [[ "$reseaux" != *" $mode "* ]]; then
        echo "Réseau modifié ($mode, absent de :$reseaux) : recréation des conteneurs."
        options=(--force-recreate)
        break
      fi
    done
    (set -x; "${compose[@]}" up -d --wait --wait-timeout "$WAIT_TIMEOUT" "${options[@]}")
    appliquer_ca
    if [[ -n "$deploy_ssh" ]]; then nettoyer_config; fi
    "${compose[@]}" ps -a --format 'table {{.Service}}\t{{.Status}}'
    recapitulatif
    ;;
  down)
    afficher_cible
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 0; fi
    "${compose[@]}" down
    echo "Instance $env arrêtée : conteneurs supprimés, volumes conservés (make deploy ENV=$env pour la relancer)."
    ;;
  status)
    afficher_cible
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 0; fi
    echo
    "${compose[@]}" ps -a --format 'table {{.Service}}\t{{.Status}}\t{{.Image}}'
    recapitulatif
    ;;
  reload-certs)
    # Traefik ne relit pas les fichiers de certificat : recréation (montages relus, y compris après un
    # remplacement par mv ; en distant, nouvelle copie de config), coupure de quelques secondes. Puis
    # CA privée appliquée à gitlab-runner et sonarqube si elle a changé (appliquer_ca).
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 1; copier_config; fi
    (set -x; "${compose[@]}" up -d --wait --wait-timeout "$WAIT_TIMEOUT" --force-recreate traefik)
    appliquer_ca
    if [[ -n "$deploy_ssh" ]]; then nettoyer_config; fi
    ;;
  bootstrap)
    # Configuration de l'instance déployée (docs/bootstrap.md) : cible Docker (contexte SSH d'une
    # instance distante) et garde-fou préparés une seule fois, hérités par les scripts de
    # scripts/bootstrap/. Aucune copie de config : les étapes n'utilisent que exec et ps, sans
    # recréer de service ; une étape qui en recréerait un devrait d'abord passer par copier_config.
    afficher_cible
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 0; fi
    services=" $("${compose[@]}" config --services | paste -sd ' ' -) "
    # Verrou de l'instance tenu pendant toutes les étapes : un make smoke ou un autre make bootstrap ne
    # peut s'intercaler ni pendant la rotation du token SonarQube, ni entre elle et sa pose dans GitLab.
    # Runner arrêté : pas de verrou ici, l'étape GitLab s'arrête d'elle-même (service arrêté).
    if [[ "$services" == *" gitlab-runner "* && -n "$("${compose[@]}" ps -q --status running gitlab-runner)" ]]; then
      trap verrou_liberer EXIT
      verrou_prendre gitlab-runner "$FICHIER_VERROU" "make bootstrap ENV=$env"
      echo "Verrou de l'instance pris ($FICHIER_VERROU, conteneur gitlab-runner)."
      export VERROU_PID_HERITE="$verrou_pid"
    fi
    # Fichier de sortie outputs/<env>.env régénéré après chaque étape réussie : une étape en échec
    # après une rotation du token SonarQube ne laisse pas un token révoqué (docs/sortie-instance.md)
    export SORTIE_SERVICES="$services" SORTIE_ETAPES=""
    for etape in "${etapes[@]}"; do
      echo
      if [[ "$services" != *" $etape "* ]]; then
        echo "==> Bootstrap $etape : service $etape absent de l'instance, étape ignorée."
        continue
      fi
      echo "==> Bootstrap $etape"
      "scripts/bootstrap/$etape.sh" "$env_file"
      SORTIE_ETAPES="${SORTIE_ETAPES:+$SORTIE_ETAPES }$etape"
      scripts/bootstrap/outputs.sh "$env_file"
    done
    ;;
  smoke)
    # Smoke test (docs/smoke-test.md) : cible préparée comme pour bootstrap, garde-fou en lecture seule ;
    # NETTOYER transmis par l'environnement
    afficher_cible
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 0; fi
    scripts/smoke.sh "$env_file"
    ;;
  compose)
    # Commande manuelle (exec, logs, restart…) avec la cible et les montages de l'instance
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 1; copier_config >&2; fi
    exec "${compose[@]}" "$@"
    ;;
esac
