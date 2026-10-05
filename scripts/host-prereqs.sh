#!/usr/bin/env bash
# Prépare un serveur pour la plateforme : Docker Engine + plugin Compose, vm.max_map_count (SonarQube),
# /etc/docker/daemon.json borné (rotation des logs, cache de build), ports du pare-feu (ufw, firewalld).
# Idempotent : chaque étape contrôle l'état avant d'agir ; une ré-exécution ne modifie rien.
# Autonome (aucun autre fichier du repo requis), exécuté sur le serveur en root. Documentation :
# docs/serveur.md.
#
# Usage : sudo bash host-prereqs.sh [--port-ssh-gitlab <port>] [--sans-https] [--redemarrer-docker]
set -euo pipefail

# Sorties analysées (ufw, apt, sysctl) en anglais et tri des noms de fichiers en ordre octet
export LC_ALL=C DEBIAN_FRONTEND=noninteractive

readonly ENGINE_MIN=25.0
readonly COMPOSE_MIN=2.24.0
readonly MAX_MAP_COUNT_MIN=524288
# Trié après 99-sysctl.conf (lien vers /etc/sysctl.conf sur Debian/Ubuntu) : appliqué en dernier
readonly SYSCTL_FICHIER=/etc/sysctl.d/99-zz-devops-platform.conf
readonly DAEMON_JSON=/etc/docker/daemon.json
readonly LOG_MAX_SIZE=10m LOG_MAX_FILE=3
readonly CACHE_BUILD_MAX=10GB
# Dépôt officiel Docker (https://docs.docker.com/engine/install/)
readonly DOCKER_CLE=/etc/apt/keyrings/docker.asc
readonly DOCKER_CLE_EMPREINTE=9DC858229FC7DD38854AE2D88D81803C0EBFCD88
readonly DOCKER_SOURCE=/etc/apt/sources.list.d/docker.sources
readonly PAQUETS_DOCKER=(docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin)
readonly PAQUETS_PREREQUIS=(ca-certificates curl gnupg jq)

port_ssh_gitlab=2222
https=1
redemarrer_docker=0
os_id="" os_codename=""
modifications=0
alertes=()

titre() { echo; echo "==> $*"; }
conforme() { echo "    ✔ $*"; }
modifie() { echo "    ➜ $*"; modifications=$((modifications + 1)); }
alerte() { echo "    ⚠ $*"; alertes+=("$*"); }
erreur() { echo "Erreur : $*" >&2; exit 1; }

aide() {
  cat <<'EOF'
Usage : sudo bash host-prereqs.sh [options]

Prépare le serveur pour la plateforme (idempotent) : Docker Engine et plugin Compose,
vm.max_map_count, /etc/docker/daemon.json, ports du pare-feu (ufw ou firewalld actif).

Options :
  --port-ssh-gitlab <port>  Port SSH de GitLab publié sur l'hôte (GITLAB_SSH_PORT, défaut : 2222)
  --sans-https              N'ouvre pas 443 (instance en TLS_MODE=none)
  --redemarrer-docker       Autorise le redémarrage de Docker pour appliquer daemon.json même si des
                            conteneurs tournent (ils sont arrêtés puis relancés selon leur politique)
  -h, --aide                Affiche cette aide
EOF
}

# Vrai si la version $1 est supérieure ou égale à $2
version_ge() { printf '%s\n%s\n' "$2" "$1" | sort -V -C; }

paquet_installe() { [[ "$(dpkg-query -W -f='${Status}' "$1" 2>/dev/null)" == "install ok installed" ]]; }

apt_gere() { [[ "$os_id" == debian || "$os_id" == ubuntu ]]; }

# Remplace $2 par le contenu de $1 (fichier temporaire du même répertoire) s'il diffère.
# Retourne 0 si le fichier a été modifié, 1 sinon (temporaire supprimé).
installer_fichier() { # <temporaire> <destination> <mode>
  if [[ -f "$2" ]] && cmp -s "$1" "$2"; then rm -f "$1"; return 1; fi
  chmod "$3" "$1"
  mv -f "$1" "$2"
}

lire_options() {
  while (($#)); do
    case "$1" in
      --port-ssh-gitlab)
        (($# >= 2)) || erreur "--port-ssh-gitlab attend un port"
        port_ssh_gitlab="$2"; shift ;;
      --port-ssh-gitlab=*) port_ssh_gitlab="${1#*=}" ;;
      --sans-https) https=0 ;;
      --redemarrer-docker) redemarrer_docker=1 ;;
      -h | --aide | --help) aide; exit 0 ;;
      *) aide >&2; erreur "option inconnue : $1" ;;
    esac
    shift
  done
  if [[ ! "$port_ssh_gitlab" =~ ^[1-9][0-9]{0,4}$ ]] || ((port_ssh_gitlab > 65535)); then
    erreur "--port-ssh-gitlab : entier de 1 à 65535 attendu ($port_ssh_gitlab)"
  fi
  if ((port_ssh_gitlab == 80 || port_ssh_gitlab == 443)); then
    erreur "--port-ssh-gitlab : 80 et 443 sont réservés à Traefik"
  fi
}

# --- Étape 0 : contrôles -----------------------------------------------------------------------------

controles() {
  titre "Contrôles"
  ((EUID == 0)) || erreur "à exécuter en root : sudo bash $0 $*"
  command -v systemctl >/dev/null || erreur "systemd requis (systemctl introuvable)"
  [[ -r /etc/os-release ]] || erreur "/etc/os-release introuvable : distribution inconnue"
  # shellcheck disable=SC1091 # fichier du système
  os_id="$(. /etc/os-release && echo "${ID:-}")"
  # shellcheck disable=SC1091
  os_codename="$(. /etc/os-release && echo "${VERSION_CODENAME:-}")"
  if apt_gere; then
    [[ -n "$os_codename" ]] || erreur "VERSION_CODENAME absent de /etc/os-release"
    conforme "distribution : $os_id $os_codename (installation gérée par apt)"
  else
    # Dérivés (Mint, Pop!_OS…) et autres familles : leur codename ne correspond pas au dépôt Docker
    if ! command -v dockerd >/dev/null || ! docker compose version >/dev/null 2>&1; then
      erreur "distribution $os_id non gérée : installer Docker Engine et le plugin Compose, puis relancer"
    fi
    command -v jq >/dev/null || erreur "jq requis : l'installer, puis relancer"
    conforme "distribution : $os_id (installation non gérée, Docker déjà présent)"
  fi
}

# --- Étape 1 : Docker Engine et plugin Compose ----------------------------------------------------------

# Installations de Docker incompatibles avec celle du dépôt officiel : refus, procédure dans la doc
provenance_docker() {
  if command -v snap >/dev/null && snap list docker >/dev/null 2>&1; then
    erreur "Docker installé par snap (ignore /etc/docker/daemon.json) : le désinstaller (snap remove docker), puis relancer — voir docs/serveur.md"
  fi
  if apt_gere; then
    local p
    for p in docker.io podman-docker; do
      if paquet_installe "$p"; then
        erreur "paquet $p installé (conflit avec docker-ce du dépôt officiel) : le désinstaller, puis relancer — voir docs/serveur.md"
      fi
    done
  fi
}

prerequis_apt() {
  local manquants=() p
  for p in "${PAQUETS_PREREQUIS[@]}"; do paquet_installe "$p" || manquants+=("$p"); done
  if ((${#manquants[@]})); then
    apt-get -qq update </dev/null
    apt-get -qq install -y "${manquants[@]}" </dev/null >/dev/null
    modifie "paquets installés : ${manquants[*]}"
  else
    conforme "paquets prérequis : ${PAQUETS_PREREQUIS[*]}"
  fi
}

depot_docker() {
  # Source déjà déclarée par ailleurs (ancienne procédure, docker.list) : réutilisée, une seconde
  # déclaration avec une autre clé ferait échouer apt (« Conflicting values set for option Signed-By »)
  local existante
  existante="$(grep -rlsE '^[^#]*download\.docker\.com' /etc/apt/sources.list /etc/apt/sources.list.d/ \
    | grep -vxF "$DOCKER_SOURCE" || true)"
  if [[ -n "$existante" ]]; then
    conforme "dépôt Docker déjà déclaré : $(paste -sd ' ' - <<<"$existante")"
    return
  fi

  local change=0 tmp empreintes
  install -d -m 0755 /etc/apt/keyrings
  tmp="$(mktemp /etc/apt/keyrings/.docker.asc.XXXXXX)"
  curl -fsSL "https://download.docker.com/linux/$os_id/gpg" -o "$tmp" || { rm -f "$tmp"; erreur "téléchargement de la clé du dépôt Docker"; }
  empreintes="$(gpg --show-keys --with-colons "$tmp" 2>/dev/null | awk -F: '$1 == "fpr" { print $10 }')"
  if ! grep -qxF "$DOCKER_CLE_EMPREINTE" <<<"$empreintes"; then
    rm -f "$tmp"; erreur "clé du dépôt Docker inattendue (empreinte attendue : $DOCKER_CLE_EMPREINTE)"
  fi
  if installer_fichier "$tmp" "$DOCKER_CLE" 0644; then change=1; modifie "clé du dépôt Docker : $DOCKER_CLE"; fi

  tmp="$(mktemp /etc/apt/sources.list.d/.docker.sources.XXXXXX)"
  cat >"$tmp" <<EOF
Types: deb
URIs: https://download.docker.com/linux/$os_id
Suites: $os_codename
Components: stable
Architectures: $(dpkg --print-architecture)
Signed-By: $DOCKER_CLE
EOF
  if installer_fichier "$tmp" "$DOCKER_SOURCE" 0644; then change=1; modifie "dépôt Docker : $DOCKER_SOURCE"; fi

  if ((change)); then
    apt-get -qq update </dev/null
  else
    conforme "dépôt Docker : $DOCKER_SOURCE"
  fi
}

paquets_docker_manquants() {
  local p
  for p in "${PAQUETS_DOCKER[@]}"; do paquet_installe "$p" || echo "$p"; done
}

# Version de l'Engine : installée, sinon celle qu'apt installera
version_engine() {
  local v=""
  if command -v dockerd >/dev/null; then
    v="$(dockerd --version)"
  elif apt_gere; then
    v="$(apt-cache policy docker-ce | sed -n 's/^ *Candidate: //p')"
  fi
  # 29.1.2, 5:29.1.2-1~debian.13~trixie, Docker version 29.1.2, build … → 29.1.2
  v="${v#*:}"
  grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' <<<"$v" | head -n1 || true
}

installer_docker() {
  local manquants
  mapfile -t manquants < <(paquets_docker_manquants)
  if ((${#manquants[@]})); then
    apt-get -qq install -y "${manquants[@]}" </dev/null >/dev/null
    modifie "paquets Docker installés : ${manquants[*]}"
  else
    conforme "paquets Docker : ${PAQUETS_DOCKER[*]}"
  fi
}

verifier_versions() {
  local engine compose
  engine="$(version_engine)"
  [[ -n "$engine" ]] || erreur "version de Docker Engine illisible"
  version_ge "$engine" "$ENGINE_MIN" \
    || erreur "Docker Engine $engine trop ancien (minimum $ENGINE_MIN) : le mettre à jour (redémarre les conteneurs) — voir docs/serveur.md"
  compose="$(docker compose version --short 2>/dev/null || true)"
  compose="${compose#v}"
  [[ -n "$compose" ]] || erreur "plugin Docker Compose introuvable (docker compose version)"
  version_ge "$compose" "$COMPOSE_MIN" \
    || erreur "Docker Compose $compose trop ancien (minimum $COMPOSE_MIN) — voir docs/serveur.md"
  conforme "versions : Engine $engine (≥ $ENGINE_MIN), Compose $compose (≥ $COMPOSE_MIN)"
}

service_docker() {
  if systemctl is-enabled --quiet docker.service; then
    conforme "service docker activé au démarrage"
  else
    systemctl enable --quiet docker.service
    modifie "service docker activé au démarrage"
  fi
  if systemctl is-active --quiet docker.service; then
    conforme "service docker démarré"
  else
    systemctl start docker.service
    modifie "service docker démarré"
  fi
}

# --- Étape 2 : /etc/docker/daemon.json ------------------------------------------------------------------

# Clés gérées. Cache de build : seuil haut (defaultMaxUsedSpace) depuis l'Engine 28 ; avant,
# defaultKeepStorage (dépréciée depuis, équivalente à defaultReservedSpace).
daemon_json_gere() { # <version engine>
  local recent=false
  version_ge "$1" 28.0 && recent=true
  jq -n --arg size "$LOG_MAX_SIZE" --arg file "$LOG_MAX_FILE" --arg max "$CACHE_BUILD_MAX" --argjson recent "$recent" '{
    "log-driver": "json-file",
    "log-opts": { "max-size": $size, "max-file": $file },
    "builder": { "gc": ({ "enabled": true }
      + (if $recent then { "defaultMaxUsedSpace": $max } else { "defaultKeepStorage": $max } end)) }
  }'
}

daemon_json() {
  local engine gere existant cible tmp sauvegarde
  engine="$(version_engine)"
  [[ -n "$engine" ]] || erreur "version de Docker Engine introuvable (ni installée, ni proposée par apt)"
  version_ge "$engine" "$ENGINE_MIN" \
    || erreur "Docker Engine $engine trop ancien (minimum $ENGINE_MIN) : le mettre à jour (redémarre les conteneurs) — voir docs/serveur.md"
  gere="$(daemon_json_gere "$engine")"

  existant='{}'
  if [[ -s "$DAEMON_JSON" ]]; then
    existant="$(jq -e 'if type == "object" then . else error("objet attendu") end' "$DAEMON_JSON" 2>/dev/null)" \
      || erreur "$DAEMON_JSON n'est pas un objet JSON valide : le corriger, puis relancer"
  fi

  # Fusion : autres clés conservées ; log-opts remplacé en bloc (des options d'un autre pilote de logs
  # empêcheraient dockerd de démarrer) ; une seule clé de seuil du cache de build
  cible="$(jq -S --argjson g "$gere" '
    . * { "log-driver": $g["log-driver"], "builder": $g.builder }
    | .["log-opts"] = $g["log-opts"]
    | if $g.builder.gc.defaultMaxUsedSpace then del(.builder.gc.defaultKeepStorage) else . end
  ' <<<"$existant")"

  # Valeurs de l'opérateur remplacées : signalées
  local chemin avant
  for chemin in '["log-driver"]' '["log-opts"]' '["builder","gc","enabled"]' \
      '["builder","gc","defaultMaxUsedSpace"]' '["builder","gc","defaultKeepStorage"]'; do
    avant="$(jq -c --argjson p "$chemin" 'getpath($p)' <<<"$existant")"
    [[ "$avant" == null || "$avant" == "$(jq -c --argjson p "$chemin" 'getpath($p)' <<<"$cible")" ]] && continue
    alerte "$DAEMON_JSON : $(jq -r 'join(".")' <<<"$chemin") = $avant remplacé"
  done

  if [[ "$(jq -S . <<<"$existant")" == "$cible" && -f "$DAEMON_JSON" ]]; then
    conforme "$DAEMON_JSON : logs json-file ($LOG_MAX_SIZE × $LOG_MAX_FILE), cache de build ≤ $CACHE_BUILD_MAX"
  else
    install -d -m 0755 /etc/docker
    tmp="$(mktemp /etc/docker/.daemon.json.XXXXXX)"
    printf '%s\n' "$cible" >"$tmp"
    if command -v dockerd >/dev/null && ! dockerd --validate --config-file "$tmp" >/dev/null 2>&1; then
      dockerd --validate --config-file "$tmp" >&2 || true
      rm -f "$tmp"; erreur "configuration Docker refusée par dockerd --validate (voir ci-dessus)"
    fi
    if [[ -f "$DAEMON_JSON" ]]; then
      sauvegarde="$DAEMON_JSON.$(date +%Y%m%d-%H%M%S).bak"
      cp -p "$DAEMON_JSON" "$sauvegarde"
      echo "    sauvegarde : $sauvegarde"
    fi
    chmod 0644 "$tmp"
    mv -f "$tmp" "$DAEMON_JSON"
    modifie "$DAEMON_JSON : logs json-file ($LOG_MAX_SIZE × $LOG_MAX_FILE), cache de build ≤ $CACHE_BUILD_MAX"
  fi
}

# dockerd ne relit pas les logs ni le cache de build à chaud : redémarrage si le fichier est plus récent
# que le démarrage du service. Jamais d'interruption de conteneurs sans --redemarrer-docker.
appliquer_daemon_json() {
  systemctl is-active --quiet docker.service || return 0
  local depuis debut
  depuis="$(systemctl show docker.service -p ActiveEnterTimestamp --value)"
  debut="$(date -d "$depuis" +%s 2>/dev/null || echo 0)"
  if (($(stat -c %Y "$DAEMON_JSON") <= debut)); then
    conforme "$DAEMON_JSON pris en compte par dockerd"
    return
  fi
  local nb
  nb="$(docker ps -q | wc -l)"
  if ((nb == 0 || redemarrer_docker)); then
    systemctl restart docker.service
    modifie "service docker redémarré pour appliquer $DAEMON_JSON ($nb conteneur(s) en cours)"
  else
    alerte "$DAEMON_JSON pas encore appliqué : $nb conteneur(s) en cours. Redémarrer Docker hors production (systemctl restart docker) ou relancer avec --redemarrer-docker"
  fi
}

# --- Étape 3 : vm.max_map_count ---------------------------------------------------------------------

# Dernière valeur de vm.max_map_count fixée par un fichier sysctl (vide si absente)
valeur_sysctl() { sed -nE 's/^[[:space:]]*-?vm[./]max_map_count[[:space:]]*=[[:space:]]*([0-9]+).*/\1/p' "$1" | tail -n1; }

max_map_count() {
  local courant persiste cible
  courant="$(sysctl -n vm.max_map_count)"
  persiste="$( [[ -f "$SYSCTL_FICHIER" ]] && valeur_sysctl "$SYSCTL_FICHIER" || true)"
  # Jamais abaissé : un réglage plus élevé (courant ou déjà persisté) est conservé
  cible="$MAX_MAP_COUNT_MIN"
  ((courant > cible)) && cible="$courant"
  ((${persiste:-0} > cible)) && cible="$persiste"

  local tmp
  tmp="$(mktemp /etc/sysctl.d/.devops-platform.XXXXXX)"
  printf '# Géré par host-prereqs.sh (devops-platform) : Elasticsearch de SonarQube\nvm.max_map_count = %s\n' "$cible" >"$tmp"
  if installer_fichier "$tmp" "$SYSCTL_FICHIER" 0644; then
    modifie "$SYSCTL_FICHIER : vm.max_map_count = $cible"
  else
    conforme "$SYSCTL_FICHIER : vm.max_map_count = $cible"
  fi

  if ((courant < cible)); then
    sysctl -q -w "vm.max_map_count=$cible"
    modifie "vm.max_map_count appliqué : $courant → $cible"
  else
    conforme "vm.max_map_count courant : $courant"
  fi

  # Valeur au démarrage : fichiers lus par systemd-sysctl / sysctl --system, par nom (le premier
  # répertoire l'emporte pour un même nom), puis /etc/sysctl.conf (lu en dernier par sysctl --system).
  # Un fichier appliqué après le nôtre avec une valeur inférieure l'annulerait au redémarrage.
  local -A vus=()
  local d f nom v suivants=()
  for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d; do
    for f in "$d"/*.conf; do
      [[ -f "$f" ]] || continue
      nom="${f##*/}"
      [[ -n "${vus[$nom]:-}" ]] && continue
      vus[$nom]="$f"
      [[ "$nom" > "${SYSCTL_FICHIER##*/}" ]] && suivants+=("$f")
    done
  done
  [[ -f /etc/sysctl.conf ]] && suivants+=(/etc/sysctl.conf)
  for f in "${suivants[@]}"; do
    v="$(valeur_sysctl "$f")"
    if [[ -n "$v" ]] && ((v < cible)); then
      erreur "$f fixe vm.max_map_count = $v, appliqué après $SYSCTL_FICHIER : la valeur retomberait au redémarrage. Supprimer cette ligne (ou la porter à $cible), puis relancer"
    fi
  done
  conforme "aucun fichier sysctl ne l'abaisse au démarrage"
}

# --- Étape 4 : pare-feu ---------------------------------------------------------------------------

pare_feu() {
  local ports=(80/tcp) p actif=0
  ((https)) && ports+=(443/tcp)
  ports+=("$port_ssh_gitlab/tcp")

  if command -v ufw >/dev/null && [[ "$(ufw status 2>/dev/null | head -n1)" == "Status: active" ]]; then
    actif=1
    local sortie
    for p in "${ports[@]}"; do
      sortie="$(ufw allow "$p")"
      if grep -q '^Rule added' <<<"$sortie"; then modifie "ufw : $p autorisé"; else conforme "ufw : $p autorisé"; fi
    done
  fi

  if command -v firewall-cmd >/dev/null && [[ "$(firewall-cmd --state 2>/dev/null || true)" == running ]]; then
    actif=1
    local zone ajout=0
    zone="$(firewall-cmd --get-default-zone)"
    for p in "${ports[@]}"; do
      if firewall-cmd --permanent --zone="$zone" --query-port="$p" >/dev/null; then
        conforme "firewalld (zone $zone) : $p autorisé"
      else
        firewall-cmd --permanent --zone="$zone" --add-port="$p" >/dev/null
        ajout=1
        modifie "firewalld (zone $zone) : $p autorisé"
      fi
    done
    ((ajout)) && firewall-cmd --reload >/dev/null
  fi

  if ((actif)); then
    echo "    Les ports publiés par Docker contournent ufw et firewalld : la plateforme n'en publie que"
    echo "    ${ports[*]} (contrôlé par make verify) ; voir docs/serveur.md."
  else
    # Activer un pare-feu pourrait couper l'accès SSH à l'hôte : laissé à l'opérateur
    conforme "aucun pare-feu actif (ufw, firewalld) : rien à ouvrir"
  fi
}

main() {
  lire_options "$@"
  controles "$@"

  titre "Docker Engine et plugin Compose"
  provenance_docker
  local installation=0
  if apt_gere; then
    prerequis_apt
    if [[ -n "$(paquets_docker_manquants)" ]]; then
      installation=1
      depot_docker
    fi
  fi

  # Avant l'installation : le premier démarrage de dockerd prend le fichier en compte
  titre "Configuration du démon Docker"
  daemon_json

  if ((installation)); then
    titre "Installation de Docker"
    installer_docker
  fi
  titre "Service Docker"
  verifier_versions
  service_docker
  appliquer_daemon_json

  titre "vm.max_map_count (Elasticsearch de SonarQube)"
  max_map_count

  titre "Pare-feu"
  pare_feu

  echo
  echo "Prérequis : $modifications modification(s)."
  if ((${#alertes[@]})); then
    echo "À traiter :"
    printf '  ⚠ %s\n' "${alertes[@]}"
  fi
}

main "$@"
