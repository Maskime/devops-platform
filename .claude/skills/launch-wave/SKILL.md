---
name: launch-wave
description: Lance la vague courante d'une épopée (une session Claude par US dans tmux), ou nettoie les worktrees des US terminées
argument-hint: <épopée> [--nettoyer]  (ex : 1, 1 --nettoyer)
disable-model-invocation: true
---

Lance la vague courante de l'épopée, ou nettoie ses worktrees : $ARGUMENTS

Chaque US est implémentée dans **sa propre session Claude interactive** (`/implement-us`), dans son
propre worktree git, dans une fenêtre de la session tmux `epic-<N>`. Le skill ne fait que préparer et
ouvrir ces sessions : il n'implémente rien lui-même et n'a pas besoin de connaître le plan de
`/plan-epic`, qui est déjà reporté dans les dépendances des issues.

## Initialisation

Normalise l'argument en numéro d'épopée `<N>` (`1`, `Épopée 1`, `[Épopée 1]`). Si l'argument est absent
ou illisible, demande-le à l'opérateur. `--nettoyer` sélectionne le mode nettoyage ; sinon, mode
lancement.

Collecte l'état de l'épopée :

```bash
.claude/scripts/find-us.sh <N>
```

Pour toute dépendance vers une autre épopée, `find-us.sh <code>` donne son statut.

## Mode lancement

### 1. Vague courante

La vague courante est l'ensemble des US de l'épopée au statut **nouvelle** dont **toutes** les
dépendances déclarées (section `## Dépendances`, dans l'épopée ou hors épopée) sont **terminées**.

- Ne relance jamais une US **en cours** ou **en revue** : sa session existe déjà ou sa PR attend un
  merge.
- Si la vague courante est vide, explique ce qui bloque (ex : « 1-3 attend le merge de la PR de 1-2 »,
  « toutes les US sont terminées ») et arrête-toi.

### 2. Confirmation

Présente à l'opérateur, avant toute action :

- les US à lancer (code, issue, titre) et le worktree de chacune (`../<repo>-us-<N>-<X>`) ;
- les US en cours ou en revue, et celles qui attendent une dépendance ;
- les risques : US de la vague qui modifient les mêmes fichiers, et US dont un critère exige de
  démarrer la plateforme — deux plateformes démarrées en même temps se disputent les mêmes ports hôte
  et ~4 Go de RAM chacune : l'opérateur devra séquencer ces vérifications.

Demande confirmation (outil `AskUserQuestion`, sélection multiple des US à lancer, toutes cochées par
défaut dans la question).

### 3. Ouverture des sessions

Pour chaque US confirmée :

```bash
.claude/scripts/us-worktree.sh ouvrir <N>-<X>
```

Le script est idempotent : il réutilise un worktree ou une fenêtre tmux existants. Il crée le worktree
depuis `origin/main`, y copie `envs/*.env` et `.claude/settings.local.json` (ignorés par git), puis
ouvre la fenêtre `us-<N>-<X>` dans la session tmux `epic-<N>`, qui lance `claude '/implement-us <N>-<X>'`.

### 4. Résumé

Affiche les sessions ouvertes et comment les rejoindre :

```bash
tmux attach -t epic-<N>     # puis Ctrl-b w pour choisir une fenêtre, Ctrl-b d pour se détacher
```

Rappelle que chaque session s'arrête à la validation du plan (sortie du mode plan) et attend
l'opérateur, et qu'une fois les PR de la vague mergées, `/launch-wave <N>` lance la vague suivante.

## Mode nettoyage (`--nettoyer`)

1. Liste les worktrees du repo (`git worktree list`) correspondant à des US de l'épopée
   (`../<repo>-us-<N>-<X>`).
2. Ne retiens que ceux dont la US est **terminée** (issue fermée). Les autres sont conservés et listés
   avec leur statut.
3. Présente la liste à l'opérateur et demande confirmation.
4. Pour chaque US confirmée :
   ```bash
   .claude/scripts/us-worktree.sh fermer <N>-<X>
   ```
   Le script refuse de supprimer un worktree contenant des modifications non commitées : signale-le à
   l'opérateur, sans forcer. Il supprime la branche locale si elle est mergée, la conserve sinon
   (ex : squash merge) — indique alors la commande `git branch -D <branche>` sans l'exécuter.
5. Lance `.claude/scripts/check-epics.sh` et signale les épopées prêtes à être clôturées.

## Résumé final

Affiche : épopée, mode, US lancées ou nettoyées, US ignorées et pourquoi, commande `tmux attach` le cas
échéant.
