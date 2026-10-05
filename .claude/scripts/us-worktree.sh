#!/usr/bin/env bash
# Ouvre ou ferme l'espace de travail d'une user story : un worktree git à côté du repo principal
# et une fenêtre tmux qui y exécute `claude '/implement-us <code>'` (idempotent).
# Usage : us-worktree.sh <ouvrir|fermer> <épopée>-<us>
#   ouvrir — crée le worktree ../<repo>-us-<code> depuis origin/main, y copie les fichiers locaux
#            ignorés par git (envs/*.env, .claude/settings.local.json), puis ouvre la fenêtre
#            us-<code> dans la session tmux epic-<épopée>
#   fermer — ferme la fenêtre tmux, supprime le worktree (refuse s'il contient des modifications
#            non commitées) et sa branche locale si elle est mergée
set -euo pipefail

USAGE="Usage : us-worktree.sh <ouvrir|fermer> <épopée>-<us> (ex : ouvrir 1-2)"
(($# == 2)) || { echo "$USAGE" >&2; exit 1; }
action="$1" code="$2"
[[ "$code" =~ ^[0-9]+-[0-9]+$ ]] || { echo "$USAGE" >&2; exit 1; }

# Repo principal (première entrée de `git worktree list`), même si on est lancé depuis un worktree
root="$(git worktree list --porcelain | sed -n '1s/^worktree //p')"
dir="$(dirname "$root")/$(basename "$root")-us-$code"
session="epic-${code%%-*}"
window="us-$code"

ouvrir() {
  if [[ -d "$dir" ]]; then
    echo "Worktree déjà présent : $dir"
  else
    git -C "$root" fetch --quiet origin
    git -C "$root" worktree add --quiet --detach "$dir" origin/main
    echo "Worktree créé : $dir"
  fi

  # Fichiers locaux ignorés par git dont la session a besoin (jamais écrasés)
  local f
  for f in "$root"/envs/*.env "$root/.claude/settings.local.json"; do
    [[ -f "$f" ]] || continue
    mkdir -p "$(dirname "$dir/${f#"$root"/}")"
    cp -n "$f" "$dir/${f#"$root"/}"
  done

  tmux has-session -t "$session" 2>/dev/null \
    || tmux new-session -d -s "$session" -n pilotage -c "$root"
  if tmux list-windows -t "$session" -F '#W' | grep -qx "$window"; then
    echo "Fenêtre tmux déjà ouverte : $session:$window"
  else
    # Le shell reprend la main à la sortie de claude : la fenêtre reste ouverte
    tmux new-window -d -t "$session:" -n "$window" -c "$dir" \
      "claude '/implement-us $code'; exec \"\${SHELL:-bash}\""
    echo "Fenêtre tmux ouverte : $session:$window"
  fi
}

fermer() {
  if [[ ! -d "$dir" ]]; then
    echo "Aucun worktree pour la US $code."
  elif [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
    echo "Modifications non commitées dans $dir : worktree conservé." >&2
    exit 1
  else
    local branch
    branch="$(git -C "$dir" branch --show-current)"
    git -C "$root" worktree remove "$dir"
    echo "Worktree supprimé : $dir"
    if [[ -n "$branch" ]]; then
      if git -C "$root" branch -d "$branch" >/dev/null 2>&1; then
        echo "Branche locale supprimée : $branch"
      else
        echo "Branche locale conservée (non mergée localement, ex. squash merge) : $branch"
      fi
    fi
  fi
  tmux kill-window -t "$session:$window" 2>/dev/null || true
}

case "$action" in
  ouvrir) ouvrir ;;
  fermer) fermer ;;
  *) echo "$USAGE" >&2; exit 1 ;;
esac
