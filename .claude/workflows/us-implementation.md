# Workflow d'implémentation d'une user story

Six étapes, à appliquer dans l'ordre. `<N>-<X>` désigne le code de la US, `#<num>` son issue GitHub.

### Étape 0 — Préparation

1. Vérifie que l'arbre de travail est propre (`git status --porcelain` vide). Sinon, arrête-toi et demande à l'opérateur.
2. Mets `main` à jour : `git switch main && git pull --ff-only` (repo public, pas d'authentification nécessaire).
3. Vérifie les **dépendances** listées dans l'issue : chaque issue référencée doit être fermée
   (`.claude/scripts/find-us.sh <code>` affiche l'état). Si une dépendance est encore ouverte,
   signale-le à l'opérateur et demande s'il faut continuer.
4. Crée la branche `us/<N>-<X>-<slug>` (slug court, kebab-case, sans accents) depuis `main`.

### Étape 1 — Planification

Entre en mode plan (outil `EnterPlanMode`).

Analyse :
- la user story et ses critères d'acceptation ;
- l'état actuel du repo (fichiers à créer ou modifier) ;
- si la US reprend un élément existant, la source dans software-factory :
  `~/dev/actual-software-factory/infrastructure/` (**lecture seule** — ne jamais modifier ce repo).

Produis un plan détaillé : liste ordonnée d'actions concrètes avec les fichiers concernés, et pour chaque
critère d'acceptation, comment il sera vérifié (statiquement ou en exécution).
Tu n'as pas besoin de la validation du plan pour passer à l'étape 2.

### Étape 2 — Critique du plan (agent indépendant)

Toujours en mode plan, délègue la review à un sous-agent via l'outil `Agent` :

- `subagent_type` : `"Plan"`
- `prompt` : brief autonome contenant intégralement :
  - le texte de la user story (énoncé, critères d'acceptation, dépendances, notes) ;
  - le plan détaillé produit à l'étape 1 ;
  - le contexte projet minimal : plateforme Docker Compose (GitLab CE + Runner, SonarQube + PostgreSQL,
    Grafana/Loki/Promtail, Portainer, PlantUML, Traefik), déployée sur des serveurs distincts, une instance
    décrite entièrement par `envs/<env>.env`, `TLS_MODE` ∈ {letsencrypt, custom, none}, scripts Bash
    idempotents, versions d'images épinglées, repo public (aucun secret versionné) ;
  - la consigne : identifier les défauts en trois catégories :
    - **Grave** : bloque l'implémentation correcte — critère d'acceptation oublié, mauvaise architecture,
      risque de régression, perte de données, secret exposé, script non idempotent
    - **Modéré** : dette technique acceptable pour l'instant — validation manquante, cas limite non géré
    - **Esthétique** : acceptable en l'état — nommage sous-optimal, organisation perfectible

Attends le retour complet du sous-agent avant de passer à l'étape 3.

### Étape 3 — Révision

1. Intègre les corrections des points **Grave** dans le plan.
2. Présente le plan révisé final, en listant à part les points **Modéré** retenus pour le backlog,
   puis sors du mode plan (outil `ExitPlanMode`) — c'est le point de validation par l'opérateur.
3. Une fois sorti du mode plan, crée une issue GitHub par point **Modéré** :
   ```bash
   .claude/scripts/gh-api.sh POST /issues '{"title":"[Backlog] <résumé>","labels":["backlog"],"body":"Relevé lors de la critique de #<num> ([US <N>-<X>]).\n\n<description du point>"}'
   ```
   Les points **Esthétique** ne sont pas tracés.

### Étape 4 — Implémentation

Exécute le plan révisé en respectant `CLAUDE.md`. Commits atomiques au format Conventional Commits,
en français, référençant l'issue :

```
feat(gitlab): paramétrer le port SSH

Refs #<num>
```

### Étape 5 — Vérification

1. Lance `.claude/scripts/verify.sh` (shellcheck, yamllint, `docker compose config` par environnement,
   détection de secrets) et corrige toute erreur avant de continuer.
2. Si un critère porte sur un comportement d'exécution (service `healthy`, URL accessible, script qui
   passe), vérifie-le réellement sur l'environnement `local`. Préviens l'opérateur avant de démarrer GitLab
   (plusieurs minutes, ~4 Go de RAM). Un critère qui exige un serveur distant est marqué
   **non vérifiable localement** — ne le présente jamais comme satisfait.
3. Pour chaque critère d'acceptation, indique explicitement **satisfait**, **non satisfait** ou
   **non vérifiable localement**, avec la preuve (commande et sortie pertinente).
4. Si un critère est **non satisfait**, retourne à l'étape 4.

### Étape 6 — Livraison

1. Pousse la branche : `.claude/scripts/git-push.sh`.
2. Ouvre la PR vers `main` :
   ```bash
   .claude/scripts/gh-api.sh POST /pulls '{"title":"[US <N>-<X>] <titre>","head":"<branche>","base":"main","body":"…"}'
   ```
   Corps de la PR : résumé des changements, tableau des critères avec leur statut, points Modéré créés
   (liens vers les issues), `Closes #<num>`, puis la ligne d'attribution Claude Code.
3. Coche dans le corps de l'issue `#<num>` les critères **satisfaits** (et uniquement eux) :
   lis le corps avec `gh-api.sh GET /issues/<num>`, remplace `- [ ]` par `- [x]` sur les lignes concernées,
   puis `gh-api.sh PATCH /issues/<num> '{"body":"…"}'` (construis le JSON avec `python3 -c 'import json…'`
   pour un échappement correct).
4. Ne merge pas la PR : c'est l'opérateur qui merge.
