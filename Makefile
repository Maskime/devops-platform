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

.PHONY: help verify check-env deploy

help: ## Affiche cette aide
	@echo "Usage : make <cible> [ENV=<env>]"
	@echo
	@echo "Cibles disponibles :"
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_-]+:.*## / { printf "  %-18s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

verify: ## Vérifications statiques : shellcheck, yamllint, compose, secrets (Docker requis)
	@.claude/scripts/verify.sh

# Garde-fous communs aux cibles qui agissent sur une instance
check-env:
	@[[ -n "$(ENV)" ]] || { echo "ENV non défini : make <cible> ENV=<env>" >&2; exit 1; }
	@[[ -f "$(ENV_FILE)" ]] || { echo "Fichier introuvable : $(ENV_FILE) (copier envs/.env.example)" >&2; exit 1; }
	@if grep -nE '^[A-Z0-9_]+=change_me' "$(ENV_FILE)" >&2; then \
	  echo "Valeurs d'exemple encore présentes dans $(ENV_FILE) (voir ci-dessus) : à remplacer." >&2; exit 1; \
	fi

deploy: check-env ## Démarre l'instance ENV en local et attend que tous les services soient healthy
	$(COMPOSE) up -d --wait --wait-timeout 900
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}'
