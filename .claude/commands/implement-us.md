---
description: Implémente une user story (issue GitHub) avec plan/critique/correction, puis ouvre la PR
argument-hint: <épopée>-<us>  (ex : 1-2)
---

Implémente la user story $ARGUMENTS.

## Initialisation

Normalise l'argument en code `<N>-<X>` : `1-2`, `1 2`, `US 1-2` et `[US 1-2]` désignent tous la US 2 de
l'épopée 1. Si l'argument est absent ou illisible, demande-le à l'opérateur.

GitHub est la source de vérité. Récupère l'issue :

```bash
.claude/scripts/find-us.sh <N>-<X>
```

Affiche son numéro, son titre, son **statut** (nouvelle, en cours, en revue, terminée), son énoncé, ses
critères d'acceptation et ses dépendances avant de commencer.
Si la US est **terminée** (issue fermée), signale-le et demande à l'opérateur s'il faut continuer.
Les statuts **en cours** et **en revue** sont traités à l'étape 0 du workflow.

---

## Traitement de la user story

Lis le fichier `.claude/workflows/us-implementation.md` et applique exactement les étapes qu'il contient.

---

## Résumé final

Affiche : US traitée (code, issue, lien de la PR, statut final de la US), statut de chaque critère, issues backlog créées,
résultat de `verify.sh`.
