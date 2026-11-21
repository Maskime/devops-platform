# Brief pour agent

Le brief est un commentaire posté sur l'issue de dette. Il devient le **contrat** de l'agent qui la
traitera : le corps de l'issue et la discussion ne sont que du contexte. L'issue peut attendre des
semaines avant d'être prise ; le brief doit rester valable pendant ce temps.

## Règles

- **Durable.** Décris des comportements, des variables d'`envs/<env>.env`, des services compose, des
  cibles `make`, des commandes de scripts. Pas de numéro de ligne ; un chemin de fichier seulement s'il
  est stable et structurant (`envs/<env>.env`, `docs/<sujet>.md`).
- **Comportemental.** Dis **ce que** la plateforme doit faire, pas comment l'implémenter : l'agent
  explorera le repo lui-même.
- **Critères vérifiables.** Chaque critère se vérifie indépendamment (commande, sortie attendue,
  état d'un service, `make verify` qui passe).
- **Périmètre borné.** Liste ce qui n'est **pas** à faire, pour éviter les débordements.
- **Conventions du repo.** Rappelle seulement celles qui s'appliquent ici (idempotence, aucune
  valeur d'instance en dur, version épinglée, documentation dans `docs/`…), sans recopier CLAUDE.md.

## Gabarit

```markdown
> *Brief rédigé par IA lors du triage du backlog.*

## Brief pour agent

**Résumé :** une phrase sur ce qui doit changer.

**Comportement actuel :**
Ce qui se passe aujourd'hui (le défaut, ou le point de départ de l'amélioration).

**Comportement attendu :**
Ce qui doit se passer une fois le travail fait, cas limites et erreurs compris.

**Points d'appui :**
- Service, script, variable ou cible `make` concerné, et ce qui doit y changer.

**Critères d'acceptation :**
- [ ] Critère vérifiable 1
- [ ] Critère vérifiable 2

**Hors périmètre :**
- Ce qui ne doit pas être modifié dans cette issue.
```

## Exemple

```markdown
> *Brief rédigé par IA lors du triage du backlog.*

## Brief pour agent

**Résumé :** le smoke test doit nettoyer le projet GitLab qu'il crée, même en cas d'échec.

**Comportement actuel :**
Le smoke test crée un projet GitLab de test puis le supprime à la dernière étape. Si une étape
intermédiaire échoue, le script s'arrête (`set -e`) et le projet reste sur l'instance.

**Comportement attendu :**
Le projet de test est supprimé à la sortie du smoke test, qu'il réussisse ou échoue. Le code de
sortie du smoke test reste celui de l'étape qui a échoué.

**Points d'appui :**
- La création et la suppression du projet de test dans le smoke test.

**Critères d'acceptation :**
- [ ] Après un smoke test réussi, aucun projet de test ne reste sur l'instance.
- [ ] Après un smoke test interrompu par une étape en échec, aucun projet de test ne reste.
- [ ] Le code de sortie d'un smoke test en échec est non nul.
- [ ] `make verify` passe.

**Hors périmètre :**
- Le nettoyage des données SonarQube créées par le smoke test.
- Le contenu des vérifications elles-mêmes.
```
