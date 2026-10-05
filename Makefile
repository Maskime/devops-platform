# Point d'entrée opérateur. `make` (ou `make help`) liste les cibles disponibles.
# Toute cible documentée par un commentaire `## description` apparaît dans l'aide.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

# Instance ciblée : make <cible> ENV=<env> (fichier envs/<env>.env)
ENV ?=
ENV_FILE := envs/$(ENV).env
COMPOSE := docker compose --env-file $(ENV_FILE)

.PHONY: help verify check-secrets install-hooks check-env deploy bootstrap-legacy

help: ## Affiche cette aide
	@echo "Usage : make <cible> [ENV=<env>]"
	@echo "Les cibles marquées [ENV] exigent ENV=<env> (fichier envs/<env>.env)."
	@echo
	@echo "Cibles disponibles :"
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_-]+:.*## / { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

verify: ## Vérifications statiques : shellcheck, yamllint, compose, secrets (Docker requis)
	@scripts/verify.sh

check-secrets: ## Recherche de secrets dans le dépôt (fichiers suivis et non suivis non ignorés)
	@scripts/check-secrets.sh

install-hooks: ## Active le hook pre-commit optionnel de recherche de secrets (.githooks/)
	@git config core.hooksPath .githooks
	@echo "Hooks actifs : .githooks/ (les hooks de .git/hooks ne sont plus exécutés)."
	@echo "Désactivation : git config --unset core.hooksPath"

# Garde-fous communs aux cibles qui agissent sur une instance (ENV exigé sur la ligne de commande)
check-env:
	@if [[ "$(origin ENV)" != "command line" ]]; then \
	  if [[ "$(origin ENV)" == "environment" ]]; then \
	    echo "ENV hérité du shell ($${ENV}) ignoré : passer l'instance explicitement, make $(MAKECMDGOALS) ENV=<env>" >&2; \
	  else \
	    echo "ENV non défini : make $(MAKECMDGOALS) ENV=<env>" >&2; \
	  fi; exit 1; \
	fi
	@[[ "$${ENV}" =~ ^[a-z0-9][a-z0-9_-]*$$ ]] || { echo "ENV invalide : $${ENV} (attendu : minuscules, chiffres, - et _)" >&2; exit 1; }
	@[[ -f "$(ENV_FILE)" ]] || { echo "Fichier introuvable : $(ENV_FILE) (copier envs/.env.example)" >&2; exit 1; }
	@if grep -nE '^[A-Z0-9_]+=change_me' "$(ENV_FILE)" >&2; then \
	  echo "Valeurs d'exemple encore présentes dans $(ENV_FILE) (voir ci-dessus) : à remplacer." >&2; exit 1; \
	fi
	@if grep -nE '^[A-Z0-9_]+_VERSION=["'"'"']?(latest)?["'"'"']?[[:space:]]*$$' "$(ENV_FILE)" >&2; then \
	  echo "Version vide ou « latest » dans $(ENV_FILE) (voir ci-dessus) : épingler un tag." >&2; exit 1; \
	fi
	@$(COMPOSE) config -q || { echo "Configuration invalide pour $(ENV_FILE) (voir ci-dessus)." >&2; exit 1; }

deploy: check-env ## [ENV] Démarre l'instance ENV en local et attend que tous les services soient healthy
	@# Compose reconnecte les conteneurs existants à un réseau renommé (PLATFORM_NETWORK) sans les
	@# recréer : leur NetworkMode vise encore l'ancien réseau, supprimé, et ils ne redémarrent plus.
	@# Dans ce cas, recréation forcée (volumes conservés).
	@reseau="$$($(COMPOSE) config | sed -n '/^networks:/,/^[^ ]/ s/^    name: //p' | head -n1)"; \
	options=(); \
	for id in $$($(COMPOSE) ps -aq); do \
	  mode="$$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$$id")"; \
	  if [[ "$$mode" != "$$reseau" ]]; then \
	    echo "Réseau modifié ($$mode → $$reseau) : recréation des conteneurs."; options=(--force-recreate); break; \
	  fi; \
	done; \
	set -x; $(COMPOSE) up -d --wait --wait-timeout 900 "$${options[@]}"
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}'

# Temporaire : scripts repris de Software Factory, qui créent des données de test (projet
# factory-test, analyse SonarQube). Remplacé par `make bootstrap` (épopée 5).
bootstrap-legacy: check-env ## [ENV] [Temporaire] Bootstrap repris de la factory (crée des données de test) ; FORCER=1 hors local
	@if [[ "$(ENV)" != "local" && "$(FORCER)" != "1" ]]; then \
	  echo "bootstrap-legacy crée des données de test : réservé à ENV=local (FORCER=1 pour passer outre)." >&2; exit 1; \
	fi
	ENV=$(ENV) scripts/legacy/setup-all.sh
