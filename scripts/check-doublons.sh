#!/usr/bin/env bash
# Détecte les conteneurs en double sur les volumes ou le réseau d'une instance (`make deploy`, avant `up`).
# Le garde-fou de compose.yml refuse les lancements hors compose.yml ou sous un autre nom de projet ;
# ce contrôle repère les doublons créés en le contournant (ou avant sa mise en place) :
#   - volume de l'instance monté par un conteneur d'un autre projet Compose, ou hors Compose ;
#   - réseau de l'instance utilisé par un conteneur d'un autre projet Compose. Les conteneurs sans
#     label Compose (jobs CI du runner, `docker run --network`) y sont légitimes et ignorés. Le réseau
#     des jobs (GITLAB_RUNNER_NETWORK) n'est pas contrôlé : les projets co-localisés le rejoignent
#     (docs/branchement-projet.md), et un doublon d'un service de la plateforme reste repéré par ses
#     volumes ou par les autres réseaux de l'instance.
# Lecture seule : aucun conteneur n'est modifié.
#
# Usage : scripts/check-doublons.sh <fichier env>   (depuis la racine du repo ou ailleurs)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"
LABEL_PROJET="com.docker.compose.project"

erreur() { echo "Erreur : $*" >&2; exit 1; }

(($# == 1)) || erreur "usage : $0 <fichier env>"
env_file="$1"
[[ -f "$env_file" ]] || erreur "fichier introuvable : $env_file"

config="$(docker compose --project-directory "$ROOT" -f "$ROOT/compose.yml" --env-file "$env_file" config)"
projet="$(sed -n 's/^name: //p' <<<"$config" | head -n1)"
[[ -n "$projet" ]] || erreur "nom de projet introuvable dans la configuration compose"
mapfile -t volumes < <(sed -n '/^volumes:/,/^[^ ]/ s/^    name: //p' <<<"$config")
mapfile -t reseaux < <(sed -n '/^networks:/,/^[^ ]/ s/^    name: //p' <<<"$config")
reseau_ci="$(reseau_jobs "$env_file")" || exit 1

# Doublons indexés par identifiant (un conteneur peut monter plusieurs volumes)
declare -A doublons=()
signaler() { # <id> <nom> <projet> <ressource>
  doublons["$1"]="$(printf '%s  %-40s projet : %-20s %s' "$1" "$2" "${3:-(hors Compose)}" "$4")"
}
format="{{.ID}} {{.Names}} {{.Label \"$LABEL_PROJET\"}}"
for v in "${volumes[@]}"; do
  while read -r id nom proj; do
    [[ "$proj" == "$projet" ]] || signaler "$id" "$nom" "$proj" "volume $v"
  done < <(docker ps -a --filter "volume=$v" --format "$format")
done
for r in "${reseaux[@]}"; do
  [[ "$r" != "$reseau_ci" ]] || continue
  while read -r id nom proj; do
    [[ -z "$proj" || "$proj" == "$projet" || -n "${doublons[$id]:-}" ]] || signaler "$id" "$nom" "$proj" "réseau $r"
  done < <(docker ps -a --filter "network=$r" --format "$format")
done

((${#doublons[@]} == 0)) && exit 0

{
  echo "Conteneurs en double sur les ressources de l'instance (projet attendu : $projet) :"
  printf '  %s\n' "${doublons[@]}"
  echo
  echo "Ils ont été lancés hors de compose.yml ou sous un autre nom de projet (-f compose/<module>.yml, -p) :"
  echo "deux conteneurs sur les mêmes volumes risquent de corrompre les données de l'instance."
  echo "Les supprimer (les volumes sont conservés), puis relancer make deploy ENV=<env> :"
  # Identifiants, pas noms de conteneur : exception au contrôle de verify.sh
  echo "  docker rm -f ${!doublons[*]}"  # check-noms: id
  echo "Ne jamais utiliser docker compose down -v ni docker volume rm : les volumes sont ceux de l'instance."
} >&2
exit 1
