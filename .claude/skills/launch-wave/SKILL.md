---
name: launch-wave
description: Lance la vague courante d'une épopée (une session Claude par US, dans herdr), ou nettoie les worktrees des US terminées
argument-hint: <épopée> [--nettoyer]  (ex : 1, 1 --nettoyer)
disable-model-invocation: true
---

Lance la vague courante de l'épopée, ou nettoie ses worktrees : $ARGUMENTS

Chaque US est implémentée dans **sa propre session Claude interactive** (`/implement-us`), dans son
propre worktree git, ouvert comme workspace [herdr](https://herdr.dev) : l'opérateur suit les sessions
dans la barre latérale de herdr (état `blocked` quand une session attend sa réponse) et y répond
directement. Le skill ne fait que préparer et ouvrir ces sessions : il n'implémente rien lui-même et
n'a pas besoin de connaître le plan de `/plan-epic`, qui est déjà reporté dans les dépendances des
issues.

## Prérequis : session principale dans herdr

```bash
test "${HERDR_ENV:-}" = 1 && herdr status
```

Si `HERDR_ENV` n'est pas défini, arrête-toi sans rien piloter : la session courante ne tourne pas dans
herdr, et la CLI agirait sur la session de l'opérateur depuis l'extérieur. Indique-lui de lancer
`herdr`, puis `claude` depuis le repo dans le panneau ouvert, et de relancer `/launch-wave`.

La CLI installée fait foi pour la syntaxe : en cas de doute ou d'erreur de syntaxe, consulte
`herdr --skill` et `herdr <groupe>` (ex : `herdr worktree`). Ne lance jamais `herdr` seul (il ouvre
l'interface) ni `herdr server stop`. Les commandes renvoient du JSON : lis les identifiants dans les
réponses, ne les devine pas.

## Initialisation

Normalise l'argument en numéro d'épopée `<N>` (`1`, `Épopée 1`, `[Épopée 1]`). Si l'argument est absent
ou illisible, demande-le à l'opérateur. `--nettoyer` sélectionne le mode nettoyage ; sinon, mode
lancement.

Repères, valables même si la session tourne dans un worktree :

- `<root>` : repo principal, première entrée de `git worktree list --porcelain` ;
- `<dir>` : worktree de la US, `$(dirname <root>)/$(basename <root>)-us-<N>-<X>` ;
- `us-<N>-<X>` : libellé du workspace herdr et nom de l'agent.

Collecte l'état de l'épopée :

```bash
.claude/skills/github/scripts/find-us.sh <N>
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

- les US à lancer (code, issue, titre) et le worktree de chacune (`<dir>`) ;
- les US en cours ou en revue, et celles qui attendent une dépendance ;
- les risques : US de la vague qui modifient les mêmes fichiers, et US dont un critère exige de
  démarrer la plateforme — deux plateformes démarrées en même temps se disputent les mêmes ports hôte
  et ~4 Go de RAM chacune : l'opérateur devra séquencer ces vérifications.

Demande confirmation (outil `AskUserQuestion`, sélection multiple des US à lancer, toutes cochées par
défaut dans la question).

### 3. Ouverture des sessions

Pour chaque US confirmée, dans l'ordre (chaque étape est idempotente) :

1. **Worktree** — s'il n'existe pas encore, crée-le détaché depuis `origin/main` (`/implement-us`
   crée lui-même sa branche) :
   ```bash
   git -C <root> fetch --quiet origin
   git -C <root> worktree add --detach <dir> origin/main
   ```
2. **Fichiers locaux** — copie, sans jamais écraser, les fichiers ignorés par git dont la session a
   besoin, s'ils existent dans `<root>` : `envs/*.env` et `.claude/settings.local.json`
   (`cp -n`).
3. **Workspace herdr** :
   ```bash
   herdr worktree open --cwd <root> --path <dir> --label us-<N>-<X> --no-focus
   ```
   Retiens `.result.workspace.workspace_id` et `.result.root_pane.pane_id`. Si
   `.result.already_open` vaut `true` et que `herdr agent list` montre déjà un agent dans ce
   workspace, la session existe : passe à la US suivante. Si le pane racine n'est plus disponible
   (pas à l'invite du shell), prends un pane shell libre via `herdr pane list --workspace <id>`.
4. **Session Claude** — démarre Claude sans argument, puis envoie la commande :
   ```bash
   herdr agent start us-<N>-<X> --kind claude --pane <pane_id> --timeout 60000
   herdr agent prompt us-<N>-<X> '/implement-us <N>-<X>'
   ```
   `agent start` ne rend la main (et ne nomme l'agent) qu'une fois Claude au repos : avec un premier
   prompt passé après `--`, Claude se met aussitôt au travail et la commande échoue en `timeout`, la
   session tournant pourtant sans nom (rattrapage : `herdr agent rename <pane_id> us-<N>-<X>`).
   N'ajoute pas `--wait` à `agent prompt` : il attendrait la fin de la planification.
   - `agent_not_ready` : la session est bloquée au démarrage (ex : confiance dans le dossier). Lis
     l'écran (`herdr agent read us-<N>-<X> --source visible`) et présente-le à l'opérateur, sans
     répondre à sa place.
   - Nom déjà pris par un agent vivant : la session existe déjà, ne la remplace pas.

Ne réponds jamais à la place de l'opérateur à une session bloquée et n'envoie aucun prompt à une
session d'US (`agent prompt`, `agent send-keys`) sans qu'il le demande.

### 4. Résumé

Affiche l'état des sessions (`herdr agent list`, filtré sur les agents `us-<N>-*`) et rappelle :

- chaque session s'arrête à la validation de son plan (sortie du mode plan) et passe en `blocked` :
  l'opérateur la rejoint depuis la barre latérale de herdr pour répondre ;
- l'opérateur peut demander à la session principale l'état des sessions à tout moment
  (`herdr agent list`) ;
- une fois les PR de la vague mergées, `/launch-wave <N>` lance la vague suivante.

## Mode nettoyage (`--nettoyer`)

1. Liste les worktrees du repo correspondant à des US de l'épopée (`<dir>` de chaque US) :
   ```bash
   herdr worktree list --cwd <root>
   ```
   Pour chacun, note sa branche et `open_workspace_id` (absent si le worktree n'est pas ouvert dans
   herdr, par exemple créé à la main ou par l'ancien lancement tmux).
2. Ne retiens que ceux dont la US est **terminée** (issue fermée). Les autres sont conservés et listés
   avec leur statut.
3. Repère les sessions encore ouvertes : `herdr agent list`, agents dont le `workspace_id` est
   l'`open_workspace_id` du worktree. **Supprimer le worktree ferme son workspace et tue la session
   Claude sans prévenir**, même en plein travail : signale chaque session ouverte avec son état.
4. Présente la liste à l'opérateur et demande confirmation.
5. Pour chaque US confirmée :
   - workspace herdr ouvert : `herdr worktree remove --workspace <open_workspace_id>` ;
   - sinon : `git -C <root> worktree remove <dir>`.

   Jamais de `--force` ni de `--group`. Les deux refusent un worktree contenant des modifications ou des
   fichiers non suivis (`dirty_worktree_requires_force` côté herdr) : signale-le à l'opérateur et
   conserve le worktree. La branche locale n'est pas supprimée : supprime-la avec
   `git -C <root> branch -d <branche>` si elle est mergée ; sinon (ex : squash merge), conserve-la et
   indique la commande `git branch -D <branche>` sans l'exécuter.
6. Lance `.claude/skills/github/scripts/check-epics.sh` et signale les épopées prêtes à être clôturées.

## Résumé final

Affiche : épopée, mode, US lancées ou nettoyées, US ignorées et pourquoi, état des sessions herdr le
cas échéant.
