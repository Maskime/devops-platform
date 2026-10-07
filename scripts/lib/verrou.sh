#!/usr/bin/env bash
# Verrou d'instance (flock) tenu dans un conteneur, partagé par scripts/instance.sh (make bootstrap),
# scripts/bootstrap/gitlab.sh, scripts/bootstrap/sonarqube.sh et scripts/smoke.sh (make smoke). Fichier
# à sourcer : ne modifie pas les options du shell appelant. Documentation : docs/bootstrap.md.
#
# Contrat avec l'appelant :
#   - env_file : fichier de l'instance (envs/<env>.env), env : nom de l'instance ;
#   - erreur <message> : affiche le message et arrête le script ;
#   - verrou_liberer appelé par le trap EXIT du script.
# Un seul verrou par processus : bash ne gère qu'un coprocessus actif à la fois.
#
# Les commandes des scripts sont des docker compose exec séparés : le verrou est tenu, pendant tout le
# script, par un détenteur lancé en coprocessus. C'est un sh du conteneur qui garde le verrou (fd 9)
# jusqu'à la fin de son entrée standard. Script terminé, en échec, interrompu ou tué : entrée fermée,
# verrou libéré par le noyau. Dans toutes ses branches, le détenteur attend la fin de son entrée avant
# de sortir, pour que ses réponses restent lisibles. Son entrée n'est ouverte que par le script
# (descripteur du coprocessus, fermé au lancement des commandes) et par le battement : seule leur fin
# la ferme.

# Attente de la réponse du détenteur (s), attente du verrou dans le conteneur (s), période du battement
# (s) et pas de surveillance du script par le battement (s)
readonly VERROU_ATTENTE=60 VERROU_ATTENTE_FLOCK=5 VERROU_BATTEMENT=30 VERROU_PAS=5

verrou_pid="" verrou_in="" verrou_battement_pid="" verrou_herite=0
verrou_fichier="" verrou_service="" verrou_commande=""

# Prend le verrou <fichier> du conteneur <service> ; <commande> (ex. make smoke ENV=x) est enregistrée
# comme détenteur et proposée à la relance. S'arrête si le verrou est occupé.
verrou_prendre() { # <service> <fichier> <commande>
  local detenteur reponse ligne lignes=() sortie
  verrou_service="$1" verrou_fichier="$2" verrou_commande="$3"
  detenteur="$3 par $(id -un)@${HOSTNAME:-$(uname -n)} (pid $$), depuis le $(date '+%F %T %z')"
  # shellcheck disable=SC2016,SC2154 # script exécuté par le sh du conteneur ; env_file de l'appelant
  coproc verrou_detenteur {
    exec docker compose --env-file "$env_file" exec -T "$verrou_service" sh -c '
      command -v flock > /dev/null 2>&1 || { echo "ECHEC flock absent du conteneur"; exec cat > /dev/null; }
      umask 077
      mkdir -p "$(dirname "$1")" 2> /dev/null
      if ! (: >> "$1") 2> /dev/null; then echo "ECHEC $1 inaccessible en écriture"; exec cat > /dev/null; fi
      exec 9>> "$1"
      if ! flock -w "$3" 9; then echo OCCUPE; cat "$1"; echo FIN; exec cat > /dev/null; fi
      printf "%s\n" "$2" > "$1"
      echo PRIS
      exec cat > /dev/null' sh "$verrou_fichier" "$detenteur" "$VERROU_ATTENTE_FLOCK"
  }
  # shellcheck disable=SC2154 # variables créées par coproc
  verrou_pid="$verrou_detenteur_PID" verrou_in="${verrou_detenteur[1]}"
  # Copie de la sortie du détenteur : bash ferme les descripteurs du coprocessus dès qu'il s'arrête
  exec {sortie}<&"${verrou_detenteur[0]}"
  if ! IFS= read -r -t "$VERROU_ATTENTE" -u "$sortie" reponse; then
    erreur "verrou $verrou_fichier : pas de réponse du conteneur $verrou_service en $VERROU_ATTENTE s (voir ci-dessus)"
  fi
  case "$reponse" in
    PRIS) ;;
    OCCUPE)
      while IFS= read -r -t 10 -u "$sortie" ligne && [[ "$ligne" != FIN ]]; do lignes+=("$ligne"); done
      # shellcheck disable=SC2154 # env fourni par l'appelant
      {
        echo "Erreur : une autre opération (make bootstrap, make smoke) est en cours sur l'instance $env"
        echo "  (verrou $verrou_fichier du conteneur $verrou_service)."
        echo "  Dernier détenteur connu : ${lignes[*]:-inconnu}"
        echo "  Aucune modification faite. Attendre la fin de cette exécution, puis relancer $verrou_commande."
      } >&2
      exit 1
      ;;
    ECHEC*) erreur "verrou $verrou_fichier (conteneur $verrou_service) : ${reponse#ECHEC }" ;;
    *) erreur "verrou $verrou_fichier : réponse inattendue du conteneur $verrou_service : $reponse" ;;
  esac
  exec {sortie}<&-
  verrou_battre
}

# Battement (#108) : une ligne vide toutes les VERROU_BATTEMENT s sur l'entrée du détenteur, que son
# cat absorbe. Ce trafic du poste vers l'instance garde active la connexion qui tient le verrou (SSH du
# contexte Docker d'une instance distante) face aux délais d'inactivité (pare-feu, NAT, sshd). Le
# battement tient une copie de l'entrée : il s'arrête dès que le script disparaît (vérifié toutes les
# VERROU_PAS s, y compris après un kill -9), ou dès qu'une écriture échoue (détenteur arrêté).
verrou_battre() {
  local parent=$$ fd
  exec {fd}>&"$verrou_in"
  (
    trap - EXIT
    while :; do
      for ((i = 0; i < VERROU_BATTEMENT / VERROU_PAS; i++)); do
        # Copie de l'entrée fermée pour sleep : seul ce sous-shell la tient
        sleep "$VERROU_PAS" {fd}>&-
        kill -0 "$parent" 2> /dev/null || exit 0
      done
      printf '\n' >&"$fd" || exit 0
    done
  ) < /dev/null > /dev/null 2>&1 &
  verrou_battement_pid=$!
  exec {fd}>&-
}

# Verrou tenu par le processus parent (scripts/instance.sh) : <pid du détenteur> <service> <fichier>
# <commande>. Seul verrou_tenu agit ; la libération revient au parent.
verrou_heriter() {
  verrou_pid="$1" verrou_service="$2" verrou_fichier="$3" verrou_commande="$4" verrou_herite=1
  [[ "$verrou_pid" =~ ^[0-9]+$ ]] || erreur "verrou hérité invalide (pid : $verrou_pid)"
  verrou_tenu
}

# Détenteur toujours actif : sinon (conteneur redémarré, connexion SSH coupée), le verrou est perdu et
# une autre exécution a pu le prendre
verrou_tenu() {
  kill -0 "$verrou_pid" 2> /dev/null \
    || erreur "verrou $verrou_fichier perdu (conteneur $verrou_service redémarré, connexion SSH coupée ?) : relancer $verrou_commande"
}

# Libération, pour le trap EXIT : sans effet si aucun verrou n'a été pris ou s'il est hérité. Aucune
# commande ne peut échouer (set -e) : le code de sortie du script est conservé.
verrou_liberer() {
  local i
  ((verrou_herite)) && return 0
  if [[ -n "$verrou_battement_pid" ]]; then
    kill "$verrou_battement_pid" 2> /dev/null || true
    wait "$verrou_battement_pid" 2> /dev/null || true
    verrou_battement_pid=""
  fi
  [[ -n "$verrou_pid" ]] || return 0
  # Descripteur peut-être déjà fermé par bash (détenteur arrêté)
  { exec {verrou_in}>&-; } 2> /dev/null || true
  # Attente bornée : la fin de l'entrée se propage au conteneur (par SSH pour une instance distante)
  for ((i = 0; i < 20; i++)); do
    kill -0 "$verrou_pid" 2> /dev/null || break
    sleep 0.5
  done
  if kill -0 "$verrou_pid" 2> /dev/null; then
    echo "Attention : le détenteur du verrou ne s'est pas arrêté, interrompu (verrou libéré à la fin de sa connexion)." >&2
    kill "$verrou_pid" 2> /dev/null || true
  fi
  wait "$verrou_pid" 2> /dev/null || true
  verrou_pid=""
}
