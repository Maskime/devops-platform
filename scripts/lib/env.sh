#!/usr/bin/env bash
# Lecture d'un fichier d'environnement d'instance (envs/<env>.env), partagée par
# scripts/check-env-urls.sh (make check-env), scripts/instance.sh (make deploy, down, status) et les
# scripts de bootstrap et de smoke test.
# Fichier à sourcer : ne modifie pas les options du shell appelant.

# Dernière affectation de <clé> dans <fichier>, guillemets englobants retirés (vide si absente)
env_valeur_fichier() { # <fichier> <clé>
  local ligne valeur=""
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    ligne="${ligne%$'\r'}"
    if [[ "$ligne" =~ ^[[:space:]]*(export[[:space:]]+)?$2=(.*)$ ]]; then
      valeur="${BASH_REMATCH[2]}"
      if [[ "$valeur" =~ ^\"(.*)\"$ || "$valeur" =~ ^\'(.*)\'$ ]]; then
        valeur="${BASH_REMATCH[1]}"
      fi
    fi
  done < "$1"
  printf '%s' "$valeur"
}

# Valeur effective, comme Compose : variable du shell prioritaire, sinon dernière affectation du fichier
env_valeur() { # <fichier> <clé>
  if [[ -n "${!2+x}" ]]; then printf '%s' "${!2}"; else env_valeur_fichier "$1" "$2"; fi
}

# Réseau Docker dédié <clé> (défaut <défaut>), contrôlé : nom Docker valide, distinct de tout réseau de
# la plateforme (compose/*.yml) et de l'autre réseau dédié (<clé autre>, défaut <défaut autre>). Sur le
# réseau de la plateforme, un job ou un projet co-localisé joindrait bases, Loki et nginx de GitLab ; sur
# un réseau socket-proxy* (proxys de socket, ancien réseau commun compris), l'API Docker (variables
# d'environnement, donc secrets, des conteneurs) ; sur un réseau *-proxy (gitlab-proxy, grafana-proxy),
# le sous-réseau auquel GitLab ou Grafana fait confiance (X-Forwarded-For, identité) ; confondus, réseau
# des jobs et réseau des consommateurs exposeraient les projets co-localisés aux jobs CI. Nom sur stdout ; motif du refus sur stderr (code 1).
reseau_dedie_valide() { # <fichier> <clé> <défaut> <clé autre> <défaut autre>
  local reseau autre plateforme
  reseau="$(env_valeur "$1" "$2")"
  reseau="${reseau:-$3}"
  autre="$(env_valeur "$1" "$4")"
  autre="${autre:-$5}"
  plateforme="$(env_valeur "$1" PLATFORM_NETWORK)"
  plateforme="${plateforme:-devops-platform}"
  if [[ ! "$reseau" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
    echo "$2 invalide : $reseau (nom de réseau Docker attendu)." >&2
  elif [[ "$reseau" == "$plateforme" || "$reseau" == devops-platform_socket-proxy* \
    || "$reseau" == devops-platform_*-proxy ]]; then
    echo "$2 invalide : $reseau est un réseau de la plateforme ; jobs CI et projets co-localisés" >&2
    echo "  doivent être sur des réseaux dédiés (docs/gitlab-proxy.md, « Runner et jobs CI »)." >&2
  elif [[ "$reseau" == "$autre" ]]; then
    echo "$2 invalide : $reseau est aussi le réseau $4 ; jobs CI et projets co-localisés" >&2
    echo "  doivent être sur des réseaux distincts (docs/gitlab-proxy.md, « Runner et jobs CI »)." >&2
  else
    printf '%s' "$reseau"
    return 0
  fi
  echo "  Corriger dans $1 : $2=$3 (ou commenter la ligne)" >&2
  return 1
}

# Réseau des jobs CI (GITLAB_RUNNER_NETWORK, défaut devops-platform_ci), contrôlé par reseau_dedie_valide
reseau_jobs() { # <fichier>
  reseau_dedie_valide "$1" GITLAB_RUNNER_NETWORK devops-platform_ci CONSUMER_NETWORK devops-platform_consumers
}

# Réseau des projets co-localisés (CONSUMER_NETWORK, défaut devops-platform_consumers), contrôlé par
# reseau_dedie_valide
reseau_consommateurs() { # <fichier>
  reseau_dedie_valide "$1" CONSUMER_NETWORK devops-platform_consumers GITLAB_RUNNER_NETWORK devops-platform_ci
}

# Adresse IPv4 pointée → entier sur stdout ; code 1 si invalide
ipv4_entier() { # <adresse>
  [[ "$1" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]] || return 1
  local octet valeur=0
  for octet in "${BASH_REMATCH[@]:1:4}"; do
    ((10#$octet <= 255)) || return 1
    valeur=$((valeur * 256 + 10#$octet))
  done
  echo "$valeur"
}

# Sous-réseau <clé> (défaut <défaut>) d'un lien interne Traefik → service : CIDR IPv4, préfixe de 16 à 29
# (au moins 6 adresses). Valeur effective sur stdout ; motif du refus sur stderr (code 1).
sous_reseau_valide() { # <fichier> <clé> <défaut>
  local cidr
  cidr="$(env_valeur "$1" "$2")"
  cidr="${cidr:-$3}"
  if [[ "$cidr" =~ ^([0-9.]+)/([0-9]{2})$ ]] && ipv4_entier "${BASH_REMATCH[1]}" > /dev/null \
    && ((10#${BASH_REMATCH[2]} >= 16 && 10#${BASH_REMATCH[2]} <= 29)); then
    printf '%s' "$cidr"
    return 0
  fi
  echo "$2 invalide : $cidr (CIDR IPv4 attendu, préfixe de /16 à /29)." >&2
  echo "  Corriger dans $1 : $2=$3 (ou commenter la ligne)" >&2
  return 1
}

# Bornes d'un CIDR valide : « première dernière » adresses (entiers) sur stdout
cidr_bornes() { # <cidr>
  local base taille
  base="$(ipv4_entier "${1%/*}")"
  taille=$((1 << (32 - 10#${1#*/})))
  base=$((base / taille * taille))
  echo "$base $((base + taille - 1))"
}

# Sous-réseau du lien Traefik → GitLab (GITLAB_PROXY_SUBNET, défaut 172.31.254.0/28) : GitLab fait
# confiance à X-Forwarded-For depuis ce sous-réseau (Traefik, GitLab, passerelle Docker).
sous_reseau_gitlab_proxy_valide() { # <fichier>
  sous_reseau_valide "$1" GITLAB_PROXY_SUBNET 172.31.254.0/28 > /dev/null
}

# Lien Traefik → Grafana (docs/sso.md, « Grafana ») : sous-réseau GRAFANA_PROXY_SUBNET (défaut
# 172.31.254.16/28), sans chevauchement avec GITLAB_PROXY_SUBNET (Docker refuserait de créer le réseau),
# et adresse fixe de Traefik GRAFANA_PROXY_IP_TRAEFIK (défaut 172.31.254.30), seule source dont Grafana
# accepte l'identité : dans le sous-réseau, hors adresse réseau, broadcast et première adresse (passerelle
# Docker, c'est-à-dire l'hôte). Motif du refus sur stderr (code 1).
reseau_grafana_proxy_valide() { # <fichier>
  local cidr gitlab ip n bornes bornes_gitlab
  cidr="$(sous_reseau_valide "$1" GRAFANA_PROXY_SUBNET 172.31.254.16/28)" || return 1
  read -r -a bornes <<<"$(cidr_bornes "$cidr")"
  if gitlab="$(sous_reseau_valide "$1" GITLAB_PROXY_SUBNET 172.31.254.0/28 2> /dev/null)"; then
    read -r -a bornes_gitlab <<<"$(cidr_bornes "$gitlab")"
    if ((bornes[0] <= bornes_gitlab[1] && bornes_gitlab[0] <= bornes[1])); then
      echo "GRAFANA_PROXY_SUBNET ($cidr) chevauche GITLAB_PROXY_SUBNET ($gitlab) : choisir des plages disjointes." >&2
      echo "  Corriger dans $1 : GRAFANA_PROXY_SUBNET=172.31.254.16/28 (ou commenter la ligne)" >&2
      return 1
    fi
  fi
  ip="$(env_valeur "$1" GRAFANA_PROXY_IP_TRAEFIK)"
  ip="${ip:-172.31.254.30}"
  if ! n="$(ipv4_entier "$ip")" || ((n <= bornes[0] + 1 || n >= bornes[1])); then
    echo "GRAFANA_PROXY_IP_TRAEFIK invalide : $ip (adresse IPv4 de GRAFANA_PROXY_SUBNET $cidr attendue," >&2
    echo "  hors adresse réseau, broadcast et première adresse, réservée à la passerelle Docker)." >&2
    echo "  Corriger dans $1 : GRAFANA_PROXY_IP_TRAEFIK=172.31.254.30 (ou commenter la ligne)" >&2
    return 1
  fi
}

# Serveur MCP SonarQube (service sonarqube-mcp, profil Compose du même nom) : SONARQUBE_MCP_ENABLED
# vaut true ou false ; vide ou absente : actif sauf en TLS_MODE=none (jetons utilisateur en clair).
# Code 0 si actif, 1 sinon, 2 si la valeur est invalide (motif sur stderr).
sonarqube_mcp_actif() { # <fichier>
  local valeur mode
  valeur="$(env_valeur "$1" SONARQUBE_MCP_ENABLED)"
  case "${valeur,,}" in
    true) return 0 ;;
    false) return 1 ;;
    '')
      mode="$(env_valeur "$1" TLS_MODE)"
      [[ "${mode:-none}" != none ]] && return 0
      return 1
      ;;
    *)
      echo "SONARQUBE_MCP_ENABLED invalide : $valeur (true, false, ou absente : actif sauf en TLS_MODE=none)." >&2
      return 2
      ;;
  esac
}
