# CLAUDE.md

Ce fichier guide Claude Code (claude.ai/code) dans ce repo.

## Projet

Plateforme DevOps auto-hébergée, déployable à l'identique sur des serveurs distincts : GitLab CE + Runner,
SonarQube Community Edition (+ plugin community branch) avec PostgreSQL, Grafana + Loki + Promtail,
Portainer, PlantUML, Traefik en reverse proxy. Extraite de l'infrastructure de *Software Factory*
(`~/dev/actual-software-factory/infrastructure/`, source en **lecture seule**).

Hors périmètre : Temporal, serveurs MCP, workers et tout ce qui est propre à Software Factory.

## Principes

- **Une instance = un fichier `envs/<env>.env`.** Aucune valeur propre à une instance (hostname, port,
  réseau, secret, version) en dur dans les fichiers compose ou les scripts.
- **Instances vierges.** Le bootstrap ne crée aucune donnée de test ; les données de test vivent dans
  le smoke test.
- **`TLS_MODE` ∈ {`letsencrypt`, `custom`, `none`}**, choisi par instance.
- **Versions épinglées.** Jamais de tag `:latest`.
- **Repo public.** Aucun secret versionné : `envs/*.env`, `outputs/` et `config/certs/` sont gitignored.

## Conventions

- Scripts Bash : `#!/usr/bin/env bash`, `set -euo pipefail`, **idempotents**, messages et commentaires
  en français, doivent passer shellcheck.
- Les scripts ciblent les services via `docker compose exec <service>`, jamais par `container_name`.
- Documentation, issues, PR et messages de commit en français. Commits au format Conventional Commits
  (`feat(gitlab): …`, `fix(sonarqube): …`, `docs: …`), avec `Refs #<num>` vers l'issue.
- Une branche et une PR par user story (`us/<N>-<X>-<slug>`) ; l'opérateur merge.
- **Le README reste court** : présentation, démarrage rapide, configuration en quelques phrases,
  commandes, liens vers `docs/`. Toute documentation d'exploitation (mécanisme, limites, procédure,
  tableau de réglages) va dans une page `docs/<sujet>.md`, existante ou nouvelle, référencée par une
  ligne dans la section « Documentation » du README. Pas de numéro d'US dans la documentation : le
  suivi vit sur GitHub et dans le `CHANGELOG.md`.

## Dépendances et versions d'images

1. Avant d'ajouter ou de monter une image, vérifie la dernière version stable (Docker Hub, releases GitHub).
2. Épingle cette version.
3. Si elle introduit une rupture (chemin de mise à jour GitLab, changement de schéma SonarQube…),
   **ne rétrograde pas en silence** : signale-le à l'opérateur, qui décide.

## Outillage

- **Ne pas utiliser le CLI `gh`.** GitHub passe par le skill `github` (`.claude/skills/github/`) :
  API REST via `scripts/gh-api.sh`, push via `scripts/git-push.sh` (token dans
  `~/.config/github/token`, jamais affiché ni versionné), suivi des US via `scripts/find-us.sh`.
- Vérifications statiques : `make verify` (`scripts/verify.sh`, linters dans des conteneurs, seul
  Docker requis).
- Sessions parallèles : [herdr](https://herdr.dev). La session principale doit tourner dans herdr
  pour `/launch-wave`.

## Suivi

**GitHub est la source de vérité** (https://github.com/Maskime/devops-platform/issues).

- Épopées : issues avec le label `epic`, titrées `[Épopée N] …`, avec un milestone par épopée.
- User stories : sub-issues de l'épopée, label `user-story`, titrées `[US N-X] …`.
- Dette relevée en cours d'implémentation : issues avec le label `backlog`.

**Notation :** `us: N-X` désigne la user story X de l'épopée N.

## Skills

Chaque skill vit dans `.claude/skills/<nom>/` (`SKILL.md`, scripts et références). Le skill `github`
n'est pas une commande : Claude le charge dès qu'il doit accéder à GitHub.

| Commande | Rôle |
|---|---|
| `/implement-us <N>-<X>` | Implémente une US (cycle défini dans `.claude/skills/implement-us/workflow.md`) et ouvre la PR |
| `/plan-epic <N>` | Analyse les US d'une épopée et établit des vagues de livraison parallélisables |
| `/launch-wave <N> [--nettoyer]` | Ouvre une session `/implement-us` par US de la vague courante (worktree + workspace herdr), ou nettoie les worktrees des US terminées |
