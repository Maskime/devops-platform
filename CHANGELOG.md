# Journal des modifications

Toutes les modifications notables de ce projet sont documentées dans ce fichier.

Le format est basé sur [Keep a Changelog](https://keepachangelog.com/fr/1.1.0/),
et ce projet adhère au [Semantic Versioning](https://semver.org/lang/fr/spec/v2.0.0.html).

## [Non publié]

### Ajouté

- README présentant la plateforme et sa cible de déploiement.
- Licence MIT.
- `.gitignore` excluant les fichiers d'environnement (`envs/*.env`, sauf `envs/.env.example`),
  les sorties du bootstrap (`outputs/`) et les certificats fournis (`config/certs/`).
- Arborescence `compose/`, `config/`, `envs/`, `scripts/`.
- Makefile auto-documenté : `make help` (cible par défaut) et `make verify`.
- Ce journal des modifications.

[Non publié]: https://github.com/Maskime/devops-platform/commits/main
