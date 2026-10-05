#!/usr/bin/env bash
# Lecture d'un fichier d'environnement d'instance (envs/<env>.env), partagée par
# scripts/check-env-urls.sh (make check-env) et scripts/instance.sh (make deploy, down, status).
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
