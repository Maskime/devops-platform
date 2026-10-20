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
# d'environnement, donc secrets, des conteneurs) ; sur gitlab-proxy, le sous-réseau auquel GitLab fait
# confiance pour X-Forwarded-For ; confondus, réseau des jobs et réseau des consommateurs exposeraient
# les projets co-localisés aux jobs CI. Nom sur stdout ; motif du refus sur stderr (code 1).
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
    || "$reseau" == devops-platform_gitlab-proxy ]]; then
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

# Sous-réseau du lien Traefik → GitLab (GITLAB_PROXY_SUBNET, défaut 172.31.254.0/28) : CIDR IPv4,
# préfixe de 16 à 29 (au moins 6 adresses : Traefik, GitLab, passerelle). Motif du refus sur stderr.
sous_reseau_gitlab_proxy_valide() { # <fichier>
  local cidr octet
  cidr="$(env_valeur "$1" GITLAB_PROXY_SUBNET)"
  cidr="${cidr:-172.31.254.0/28}"
  if [[ "$cidr" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})/([0-9]{2})$ ]] \
    && ((10#${BASH_REMATCH[5]} >= 16 && 10#${BASH_REMATCH[5]} <= 29)); then
    for octet in "${BASH_REMATCH[@]:1:4}"; do ((10#$octet <= 255)) || break; done
    ((10#$octet <= 255)) && return 0
  fi
  echo "GITLAB_PROXY_SUBNET invalide : $cidr (CIDR IPv4 attendu, préfixe de /16 à /29)." >&2
  echo "  Corriger dans $1 : GITLAB_PROXY_SUBNET=172.31.254.0/28 (ou commenter la ligne)" >&2
  return 1
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
