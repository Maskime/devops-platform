#!/usr/bin/env bash
# Reconstitue le « poste de l'opérateur » sur un runner GitHub Actions éphémère, à partir des secrets de
# l'environnement GitHub de l'instance (.github/workflows/deploy.yml, docs/deploiement-github.md) :
#   - INSTANCE_ENV    : contenu de envs/<env>.env (DEPLOY_SSH obligatoire), écrit en 600 ;
#   - SSH_PRIVATE_KEY : clé privée dédiée au déploiement, sans phrase de passe ;
#   - SSH_KNOWN_HOSTS : ligne(s) known_hosts du serveur, vérifiées par l'opérateur ;
#   - TLS_MODE=custom : TLS_CERT_PEM et TLS_KEY_PEM (obligatoires), TLS_CA_PEM (facultatif), déposés
#     dans config/certs/.
# Les valeurs sensibles sont masquées dans les logs (::add-mask::) avant toute écriture ; aucune valeur
# n'est affichée. Idempotent : une nouvelle exécution réécrit les mêmes fichiers.
#
# Usage : scripts/ci/preparer-poste.sh <env>   (GitHub Actions uniquement : ~/.ssh/config est réécrit)
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
# shellcheck source=scripts/lib/env.sh
source "$ROOT/scripts/lib/env.sh"

erreur() { echo "Erreur : $*" >&2; exit 1; }

# Marqueur de ~/.ssh/config écrit par ce script : un fichier sans marqueur n'est jamais remplacé
readonly MARQUEUR_SSH="# Géré par scripts/ci/preparer-poste.sh (devops-platform)"

(($# == 1)) || erreur "usage : $0 <env>"
env="$1"
[[ "$env" =~ ^[a-z0-9][a-z0-9_-]*$ ]] || erreur "nom d'instance invalide : $env (minuscules, chiffres, - et _)"
[[ "${GITHUB_ACTIONS:-}" == true ]] \
  || erreur "réservé à GitHub Actions (réécrit ~/.ssh/config) ; sur un poste, suivre docs/deploiement.md"

# Secrets obligatoires : absents si l'environnement GitHub « $env » n'existe pas (GitHub le crée alors
# vide au premier run) ou n'est pas renseigné
manquants=()
for cle in INSTANCE_ENV SSH_PRIVATE_KEY SSH_KNOWN_HOSTS; do
  [[ -n "${!cle:-}" ]] || manquants+=("$cle")
done
((${#manquants[@]} == 0)) || erreur "secret(s) absent(s) de l'environnement GitHub « $env » : ${manquants[*]}
  Créer l'environnement et ses secrets avant tout run : docs/deploiement-github.md"

# --- Masquage, avant toute écriture ou commande -----------------------------------------------------

# Valeur masquée dans la suite du job, ligne par ligne (::add-mask:: ne porte que sur une ligne). Les
# lignes plus courtes que <longueur min> (délimiteurs PEM, fins de base64) ne sont pas masquées : sans
# gain, elles rendraient les logs illisibles. % échappé (%25) : le runner décode les commandes.
masquer() { # <valeur> [<longueur min>, défaut 8]
  local v="$1" min="${2:-8}" ligne
  [[ -n "$v" ]] || return 0
  while IFS= read -r ligne || [[ -n "$ligne" ]]; do
    ligne="${ligne%$'\r'}"
    if ((${#ligne} >= min)); then echo "::add-mask::${ligne//%/%25}"; fi
  done <<< "$v"
}

# Toutes les formes sous lesquelles une valeur du fichier peut apparaître : brute, sans guillemets
# englobants (lecture de Compose et des scripts), sans commentaire de fin de ligne (« val  # … » non
# entre guillemets), et interpolée par Compose ($$ → $)
masquer_valeur_fichier() { # <valeur brute>
  local brute="$1" valeur forme
  valeur="$brute"
  if [[ "$valeur" =~ ^\"(.*)\"$ || "$valeur" =~ ^\'(.*)\'$ ]]; then
    valeur="${BASH_REMATCH[1]}"
  elif [[ "$valeur" =~ ^(.*[^[:space:]])[[:space:]]+#.*$ ]]; then
    valeur="${BASH_REMATCH[1]}"
  fi
  for forme in "$brute" "$valeur" "${valeur//\$\$/\$}"; do masquer "$forme"; done
}

nb_masques=0
while IFS= read -r ligne || [[ -n "$ligne" ]]; do
  ligne="${ligne%$'\r'}"
  [[ "$ligne" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Z0-9_]+)=(.*)$ ]] || continue
  cle="${BASH_REMATCH[2]}" brute="${BASH_REMATCH[3]}"
  [[ "$cle" =~ $MOTIF_CLE_SENSIBLE && -n "$brute" ]] || continue
  masquer_valeur_fichier "$brute"
  nb_masques=$((nb_masques + 1))
done <<< "$INSTANCE_ENV"
masquer "$SSH_PRIVATE_KEY"
masquer "${TLS_KEY_PEM:-}"

# Cible contrôlée avant toute écriture (même lecture que scripts/instance.sh), puis masquée : les logs
# d'un dépôt public sont lisibles par tous, et scripts/instance.sh affiche DEPLOY_SSH
deploy_ssh="$(env_valeur_fichier <(printf '%s\n' "$INSTANCE_ENV") DEPLOY_SSH)"
[[ -n "$deploy_ssh" ]] || erreur "DEPLOY_SSH vide dans INSTANCE_ENV : une instance locale n'a pas de sens sur un runner éphémère"
[[ "$deploy_ssh" =~ ^ssh://([^@/[:space:]]+@)?([^@:/[:space:]]+)(:([0-9]{1,5}))?$ ]] \
  || erreur "DEPLOY_SSH invalide dans INSTANCE_ENV (attendu : ssh://[utilisateur@]hôte[:port])"
hote="${BASH_REMATCH[2]}" port="${BASH_REMATCH[4]:-22}"
masquer "$deploy_ssh"
masquer "${deploy_ssh#ssh://}" 4
masquer "$hote" 4
echo "Masquage : $nb_masques valeur(s) sensible(s) du fichier d'instance, DEPLOY_SSH, clé SSH${TLS_KEY_PEM:+ et clé TLS}."

# --- Fichiers -----------------------------------------------------------------------------------

umask 077

# Écrit <contenu> dans <fichier> (droits <mode>) s'il diffère, de façon atomique
ecrire() { # <fichier> <mode> <contenu>
  local fichier="$1" mode="$2" tmp
  if [[ -f "$fichier" ]] && [[ "$(cat "$fichier")" == "$3" ]]; then
    chmod "$mode" "$fichier"
    echo "  ✔ $fichier"
    return 0
  fi
  tmp="$(mktemp "$fichier.XXXXXX")"
  printf '%s\n' "$3" > "$tmp"
  chmod "$mode" "$tmp"
  mv -f "$tmp" "$fichier"
  echo "  ➜ $fichier écrit"
}

echo "Fichier d'instance :"
env_file="envs/$env.env"
ecrire "$env_file" 600 "$INSTANCE_ENV"

echo "SSH :"
mkdir -p "$HOME/.ssh"
chmod 700 "$HOME/.ssh"
ecrire "$HOME/.ssh/id_deploy" 600 "$SSH_PRIVATE_KEY"
ecrire "$HOME/.ssh/known_hosts_deploy" 600 "$SSH_KNOWN_HOSTS"
# Entrée attendue : « hôte » sur le port 22, « [hôte]:port » sinon (format de ssh-keyscan -p)
if [[ "$port" == 22 ]]; then entree="$hote"; else entree="[$hote]:$port"; fi
ssh-keygen -F "$entree" -f "$HOME/.ssh/known_hosts_deploy" >/dev/null \
  || erreur "SSH_KNOWN_HOSTS ne contient aucune clé pour $entree (hôte de DEPLOY_SSH) : docs/deploiement-github.md"
ssh-keygen -y -f "$HOME/.ssh/id_deploy" >/dev/null 2>&1 \
  || erreur "SSH_PRIVATE_KEY illisible (clé privée OpenSSH sans phrase de passe attendue)"
if [[ -f "$HOME/.ssh/config" ]] && [[ "$(head -n1 "$HOME/.ssh/config")" != "$MARQUEUR_SSH" ]]; then
  erreur "$HOME/.ssh/config existe et n'est pas géré par ce script : non remplacé"
fi
# Clé d'hôte vérifiée (jamais StrictHostKeyChecking=no), aucune question, connexion multiplexée : Compose
# ouvre une connexion SSH par requête concurrente (docs/deploiement.md, « Contexte Docker »)
ecrire "$HOME/.ssh/config" 600 "$MARQUEUR_SSH
Host $hote
  IdentityFile ~/.ssh/id_deploy
  IdentitiesOnly yes
  UserKnownHostsFile ~/.ssh/known_hosts_deploy
  StrictHostKeyChecking yes
  BatchMode yes
  ServerAliveInterval 30
  ControlMaster auto
  ControlPath ~/.ssh/cm-%C
  ControlPersist 10m"

tls_mode="$(env_valeur_fichier "$env_file" TLS_MODE)"
if [[ "$tls_mode" == custom ]]; then
  echo "Certificats (TLS_MODE=custom) :"
  manquants=()
  for cle in TLS_CERT_PEM TLS_KEY_PEM; do [[ -n "${!cle:-}" ]] || manquants+=("$cle"); done
  ((${#manquants[@]} == 0)) || erreur "TLS_MODE=custom : secret(s) absent(s) de l'environnement GitHub « $env » : ${manquants[*]}"
  ecrire config/certs/cert.pem 644 "$TLS_CERT_PEM"
  ecrire config/certs/key.pem 600 "$TLS_KEY_PEM"
  if [[ -n "${TLS_CA_PEM:-}" ]]; then
    ecrire config/certs/ca/ca.pem 644 "$TLS_CA_PEM"
  elif [[ -f config/certs/ca/ca.pem ]]; then
    rm -f config/certs/ca/ca.pem
    echo "  ➜ config/certs/ca/ca.pem retiré (TLS_CA_PEM absent)"
  fi
fi

echo "Poste prêt : instance $env, TLS_MODE=${tls_mode:-none} (cible DEPLOY_SSH masquée dans les logs)."
