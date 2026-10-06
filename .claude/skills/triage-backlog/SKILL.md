---
name: triage-backlog
description: Catégorise par priorité (high, moderate, low) les issues de dette qui n'ont que le label backlog
disable-model-invocation: true
---

Attribue un label de priorité aux issues de dette non encore catégorisées.

Cette commande est en **lecture seule** jusqu'à l'étape 3 : ne modifie aucune issue avant la
validation de l'opérateur.

## Étape 1 — Collecte

```bash
.claude/skills/triage-backlog/scripts/list-untriaged.sh
```

Le script affiche la description GitHub des labels `high`, `moderate` et `low`, puis chaque issue
ouverte dont le **seul** label est `backlog` (numéro, titre, URL, corps). Une issue qui porte déjà un
autre label (priorité, `user-story`, thème…) est ignorée. Si aucune issue n'est listée, indique-le et
arrête-toi.

## Étape 2 — Catégorisation

Pour chaque issue, choisis **un seul** label parmi `high`, `moderate`, `low`. La **description GitHub
des labels**, affichée par le script, est le seul référentiel : rattache chaque issue au label dont la
description correspond le mieux, sans critère supplémentaire.

Appuie-toi sur le corps de l'issue et, si besoin, sur l'état actuel du repo (la dette a pu être
partiellement traitée depuis). Justifie chaque choix en une phrase qui cite l'élément concret retenu
(risque de sécurité ou de perte de données, blocage, simple amélioration, besoin hypothétique…). En cas
d'hésitation entre deux labels, retiens le plus bas et signale l'hésitation.

Si une issue te semble déjà résolue, obsolète ou en doublon, signale-le sans la catégoriser ni la
fermer : l'opérateur décide.

## Étape 3 — Validation et application

Présente un tableau trié par priorité proposée : issue (numéro, titre), label proposé, justification,
hésitation éventuelle. Demande à l'opérateur ce qu'il valide ou corrige, puis, pour les seules issues
validées :

```bash
.claude/skills/github/scripts/gh-api.sh POST /issues/<num>/labels '{"labels":["<label>"]}'
```

Cet appel ajoute le label sans retirer `backlog`. Relance ensuite `list-untriaged.sh` et vérifie que
les issues traitées n'y figurent plus.

## Résumé final

Affiche le nombre d'issues catégorisées par label, les issues laissées sans label (et pourquoi) et
celles signalées comme résolues, obsolètes ou en doublon.
