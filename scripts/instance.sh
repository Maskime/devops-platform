#!/usr/bin/env bash
# Pilote une instance, locale ou distante : make deploy, down, status, reload-certs.
#   - DEPLOY_SSH vide ou absente de envs/<env>.env : moteur Docker courant du poste (comme avant) ;
#   - DEPLOY_SSH=ssh://[user@]hôte[:port] : contexte Docker SSH devops-platform-<env> (créé ou mis à
#     jour), fichiers de config montés par les services copiés sur l'hôte dans
#     ${DEPLOY_DIR}/config-<empreinte> (PLATFORM_CONFIG_DIR), garde-fou ${DEPLOY_DIR}/instance.
# DEPLOY_SSH et DEPLOY_DIR sont lues dans le fichier uniquement (jamais depuis le shell) : la cible
# d'une commande ne dépend que du fichier de l'instance. Documentation : docs/deploiement.md.
#
# Usage : scripts/instance.sh <deploy|down|status|reload-certs> <env>
#         scripts/instance.sh compose <env> <arguments docker compose…>   (commande manuelle)
# Garde-fous de configuration (make check-env) : appliqués par le Makefile avant deploy et reload-certs.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"

# Copie et nettoyage des fichiers de config sur l'hôte cible (dernière stable, tag figé par son digest)
readonly BUSYBOX_IMAGE="busybox:1.38.0@sha256:fd7dc98638c8e305f4dc34e979f1c0fdfdcaeb0fbf8fcff77ae834b6da3d7e6e"
readonly DEPLOY_DIR_DEFAUT=/opt/devops-platform
readonly ENGINE_MIN=25
readonly WAIT_TIMEOUT=900
readonly PARALLELISME_SSH=4
# Fichiers de config/ montés par les services (les env_file, lus par Compose sur le poste, n'en font
# pas partie). TLS_MODE=custom : fichiers de compose/tls/custom.yml en plus.
readonly CONFIG_MONTEE=(loki/loki-config.yaml promtail/promtail-config.yaml grafana/provisioning)
readonly CONFIG_MONTEE_CUSTOM=(traefik/tls-custom.yml certs/cert.pem certs/key.pem)

erreur() { echo "Erreur : $*" >&2; exit 1; }

usage() {
  echo "Usage : $0 <deploy|down|status|reload-certs> <env>" >&2
  echo "        $0 compose <env> <arguments docker compose…>" >&2
  exit 1
}

(($# >= 2)) || usage
action="$1" env="$2"
shift 2
case "$action" in
  deploy | down | status | reload-certs) (($# == 0)) || usage ;;
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

  # Pré-test non interactif : une clé d'hôte inconnue ou une clé SSH absente échoue au lieu de bloquer
  local version
  if ! version="$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$deploy_ssh" \
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
  [[ "$tls_mode" == custom ]] && printf '%s\n' "${CONFIG_MONTEE_CUSTOM[@]}"
  return 0
}

# Empreinte (12 caractères) des chemins et contenus des fichiers montés : un changement de config
# change le répertoire source, donc Compose recrée exactement les services concernés
empreinte_config() {
  local sha=(sha256sum) chemins
  command -v sha256sum >/dev/null || sha=(shasum -a 256)
  mapfile -t chemins < <(config_montee)
  (cd config && find "${chemins[@]}" -type f | LC_ALL=C sort | while IFS= read -r f; do "${sha[@]}" "$f"; done) \
    | "${sha[@]}" | cut -c1-12
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
}

# Supprime les copies qu'aucun conteneur du projet ne monte plus (non bloquant)
nettoyer_config() {
  local ids gardees
  mapfile -t ids < <(docker ps -aq --filter "label=com.docker.compose.project=$projet")
  gardees="config-$empreinte"
  if ((${#ids[@]})); then
    gardees+=" $(docker inspect -f '{{range .Mounts}}{{.Source}}{{"\n"}}{{end}}' "${ids[@]}" \
      | sed -n "s#^$deploy_dir/\(config-[^/]*\).*#\1#p" | sort -u | paste -sd ' ' -)"
  fi
  # shellcheck disable=SC2016,SC2086 # script exécuté par le sh du conteneur ; liste découpée voulue
  utilitaire -v "$deploy_dir:/dst" "$BUSYBOX_IMAGE" sh -c '
      racine="$1"; shift
      cd /dst
      for d in config-*; do
        [ -e "$d" ] || continue
        case " $* " in *" $d "*) continue ;; esac
        rm -rf "$d" && echo "Copie de configuration supprimée : $racine/$d"
      done' sh "$deploy_dir" $gardees \
    || echo "Attention : nettoyage des anciennes copies de configuration impossible (sans incidence)." >&2
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

# --- Actions -------------------------------------------------------------------------------------

if [[ -n "$deploy_ssh" ]]; then
  preparer_contexte_distant
  empreinte="$(empreinte_config)"
  export PLATFORM_CONFIG_DIR="$deploy_dir/config-$empreinte"
else
  # Variable interne : en local, les montages lisent config/ du repo
  unset PLATFORM_CONFIG_DIR
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
    # remplacement par mv ; en distant, nouvelle copie de config), coupure de quelques secondes.
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 1; copier_config; fi
    (set -x; "${compose[@]}" up -d --wait --force-recreate traefik)
    if [[ -n "$deploy_ssh" ]]; then nettoyer_config; fi
    ;;
  compose)
    # Commande manuelle (exec, logs, restart…) avec la cible et les montages de l'instance
    if [[ -n "$deploy_ssh" ]]; then verifier_instance 1; copier_config >&2; fi
    exec "${compose[@]}" "$@"
    ;;
esac
