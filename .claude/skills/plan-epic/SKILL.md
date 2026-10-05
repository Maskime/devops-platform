---
name: plan-epic
description: Analyse les US d'une épopée et établit des vagues de livraison parallélisables
argument-hint: <épopée>  (ex : 2)
disable-model-invocation: true
---

Établis les vagues de livraison de l'épopée $ARGUMENTS.

Une **vague** est un ensemble d'US qui peuvent être implémentées en parallèle (une branche et une PR
chacune, via `/implement-us`) ; une vague ne démarre que lorsque les PR de la vague précédente dont elle
dépend sont mergées.

## Initialisation

Normalise l'argument en numéro d'épopée `<N>` : `2`, `Épopée 2` et `[Épopée 2]` désignent tous
l'épopée 2. Si l'argument est absent ou illisible, demande-le à l'opérateur.

Cette commande est en **lecture seule** jusqu'à l'étape 4 : ne crée ni branche, ni commit, ni
modification GitHub avant la validation de l'opérateur.

## Étape 1 — Collecte

```bash
.claude/skills/github/scripts/find-us.sh <N>
```

Le script affiche l'épopée puis, pour chacune de ses US : statut (nouvelle, en cours, en revue,
terminée), branche et PR éventuelles, énoncé, critères d'acceptation et dépendances déclarées
(section `## Dépendances`). Pour une dépendance vers une autre épopée, `find-us.sh <code>` donne son
statut.

## Étape 2 — Analyse des dépendances

Pour chaque US non terminée, établis l'ensemble de ses dépendances. Appuie-toi sur son énoncé, ses
critères d'acceptation, l'état actuel du repo et, si besoin, la source dans software-factory
(`~/dev/actual-software-factory/infrastructure/`, **lecture seule**).

1. **Dépendances déclarées** : celles de la section `## Dépendances`. Une dépendance **terminée** est
   satisfaite ; signale toute dépendance déclarée qui te paraît injustifiée, sans la retirer.
2. **Dépendances implicites** : la US consomme quelque chose qu'une autre US produit (arborescence,
   fichier compose, variable de `envs/*.env`, cible Makefile, script, label Traefik…), dans l'épopée ou
   dans une autre. Chaque dépendance retenue doit être justifiée par un élément concret (fichier,
   variable, critère d'acceptation).
3. **Conflits de fichiers** : deux US parallèles qui modifient les mêmes fichiers (`Makefile`,
   `compose.yml`, `envs/.env.example`, `CHANGELOG.md`, `README.md`…). Distingue :
   - **conflit mineur** : ajouts disjoints dans un même fichier (nouvelle cible Makefile, nouvelle
     variable), résolu par un simple rebase → les US restent parallèles ;
   - **conflit structurel** : les deux US réécrivent la même partie d'un fichier ou l'une change la
     structure dont l'autre dépend → séquentialise-les (dépendance implicite).
4. **Vérification à l'exécution** : une US dont un critère exige de démarrer la plateforme (GitLab,
   ~4 Go de RAM) ne peut pas être vérifiée en même temps qu'une autre sur la même machine ; signale-le
   sans en faire une dépendance.

Ne transforme pas en dépendance une simple préférence d'ordre : en cas de doute, laisse les US en
parallèle et mentionne le risque. Si les dépendances forment un cycle, arrête-toi et présente-le à
l'opérateur.

Calcule ensuite les vagues : une US entre dans la vague 1 + la plus haute vague de ses dépendances non
terminées de l'épopée (vague 1 si elle n'en a pas). Une dépendance non terminée **hors épopée** ne
place pas la US dans une vague mais la marque **bloquée** tant qu'elle n'est pas terminée.

## Étape 3 — Plan de livraison

Présente :

1. Un tableau par vague : US (code, issue, titre), statut, dépendances (déclarées / implicites), fichiers
   principaux touchés, risques de conflit.
2. Les **dépendances implicites** proposées, chacune avec sa justification.
3. Les **blocages hors épopée** : US d'autres épopées à terminer d'abord.
4. Le **chemin critique** (plus longue chaîne de dépendances) et le nombre de vagues.
5. Le lancement : `/launch-wave <N>` (`<N>` = numéro de l'épopée) lance la vague courante, déduite
   des dépendances déclarées sur GitHub, avec une session `/implement-us` par US dans son propre
   worktree. La même commande lance la vague suivante une fois les PR mergées.

Les US **terminées** sont listées à part ; les US **en cours** ou **en revue** restent dans leur vague
avec leur statut.

## Étape 4 — Mise à jour de GitHub (après validation)

GitHub est la source de vérité : les dépendances implicites validées doivent y figurer, sinon
`/implement-us` ne les vérifiera pas. Demande à l'opérateur ce qu'il valide, puis, pour les seuls
éléments acceptés :

1. **Dépendances** : ajoute chaque dépendance retenue dans la section `## Dépendances` de l'issue
   concernée (crée la section avant `## Notes`, ou en fin de corps, si elle n'existe pas), au format
   existant `- [US <N>-<X>] <titre>`. Lis le corps avec `gh-api.sh GET /issues/<num>`, modifie-le, puis
   `gh-api.sh PATCH /issues/<num> '{"body":"…"}'` (construis le JSON avec `python3 -c 'import json…'`
   pour un échappement correct). Relance ensuite `find-us.sh <N>` et vérifie que les dépendances
   déclarées correspondent désormais au plan présenté.
2. **Plan sur l'épopée** (si l'opérateur le souhaite) : publie le plan de livraison en commentaire de
   l'issue de l'épopée (`gh-api.sh POST /issues/<num>/comments '{"body":"…"}'`).

## Résumé final

Affiche : épopée analysée, nombre de vagues et composition de chacune, dépendances ajoutées sur GitHub,
commentaire publié (lien) le cas échéant.
