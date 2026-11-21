---
name: triage-backlog
description: Catégorise par priorité (high, moderate, low) les issues de dette qui n'ont que le label backlog, vérifie qu'elles ne sont pas déjà résolues et rédige un brief pour agent quand elles sont délégables
disable-model-invocation: true
---

Attribue un label de priorité aux issues de dette non encore catégorisées et, pour celles qu'un agent
peut traiter seul, poste un brief qui servira de contrat.

Cette commande est en **lecture seule** jusqu'à l'étape 4 : ne modifie aucune issue avant la
validation de l'opérateur.

## Étape 1 — Collecte

```bash
.claude/skills/triage-backlog/scripts/list-untriaged.sh
```

Le script affiche la description GitHub des labels `high`, `moderate` et `low`, puis chaque issue
ouverte dont le **seul** label est `backlog` (numéro, titre, URL, corps). Une issue qui porte déjà un
autre label (priorité, `user-story`, thème…) est ignorée. Si aucune issue n'est listée, indique-le et
arrête-toi.

Lis aussi `GLOSSARY.md` : il donne les termes du domaine qui servent à l'étape 2.

## Étape 2 — Déjà résolue ?

Pour chaque issue, vérifie dans le repo si la dette a été traitée depuis qu'elle a été relevée :

1. Ramène la demande à un **concept du domaine** (terme du glossaire, service, variable
   d'`envs/<env>.env`, script, cible `make`), pas seulement aux mots de l'issue, qui ont pu vieillir.
2. Cherche ce concept dans le code, `docs/` et `CHANGELOG.md`, et consulte `git log` sur les
   fichiers concernés depuis la date de création de l'issue.
3. Conclus : **résolue** (cite où la correction se trouve : fichier, commit ou PR), **partiellement
   résolue** (dis ce qui reste) ou **non résolue**. Note où tu as cherché, pour que l'opérateur puisse
   juger de la recherche.

Une issue résolue, obsolète ou en doublon n'est pas catégorisée ni fermée : signale-la avec la preuve,
l'opérateur décide. Une issue partiellement résolue est catégorisée sur ce qui reste.

## Étape 3 — Catégorisation et délégabilité

Pour chaque issue restante, choisis **un seul** label parmi `high`, `moderate`, `low`. La
**description GitHub des labels**, affichée par le script, est le seul référentiel : rattache chaque
issue au label dont la description correspond le mieux, sans critère supplémentaire. Justifie chaque
choix en une phrase qui cite l'élément concret retenu (risque de sécurité ou de perte de données,
blocage, simple amélioration, besoin hypothétique…). En cas d'hésitation entre deux labels, retiens le
plus bas et signale l'hésitation.

Indique ensuite si l'issue est **délégable** à un agent sans intervention humaine :

- **oui** si le comportement attendu est clair et vérifiable depuis le repo (`make verify`, smoke
  test, instance locale) ;
- **non** sinon, en nommant la raison : arbitrage de conception, montée de version à risque (voir
  CLAUDE.md), accès à un serveur ou à un compte externe, vérification manuelle, besoin encore flou.

## Étape 4 — Validation et application

Présente un tableau trié par priorité proposée : issue (numéro, titre), label proposé, justification,
hésitation éventuelle, délégable (oui/non et raison). Liste à part les issues signalées à l'étape 2.
Demande à l'opérateur ce qu'il valide ou corrige, puis, pour les seules issues validées :

```bash
.claude/skills/github/scripts/gh-api.sh POST /issues/<num>/labels '{"labels":["<label>"]}'
```

Cet appel ajoute le label sans retirer `backlog`.

Pour chaque issue validée comme **délégable**, rédige le brief selon [brief.md](brief.md), montre-le à
l'opérateur, puis poste-le une fois validé et ajoute le label `pret-pour-agent` :

```bash
.claude/skills/github/scripts/gh-api.sh POST /issues/<num>/comments '{"body":"<brief>"}'
.claude/skills/github/scripts/gh-api.sh POST /issues/<num>/labels '{"labels":["pret-pour-agent"]}'
```

Ne pose ce label qu'une fois le brief posté : il signale qu'un agent peut prendre l'issue en se fiant
au brief.

Relance enfin `list-untriaged.sh` et vérifie que les issues traitées n'y figurent plus.

## Résumé final

Affiche le nombre d'issues catégorisées par label, les issues passées en `pret-pour-agent`, les issues laissées sans label
(et pourquoi) et celles signalées comme résolues, obsolètes ou en doublon, avec leur preuve.
