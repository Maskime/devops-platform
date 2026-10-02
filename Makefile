# Point d'entrée opérateur. `make` (ou `make help`) liste les cibles disponibles.
# Toute cible documentée par un commentaire `## description` apparaît dans l'aide.

SHELL := bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help
MAKEFLAGS += --no-print-directory

.PHONY: help verify

help: ## Affiche cette aide
	@echo "Usage : make <cible>"
	@echo
	@echo "Cibles disponibles :"
	@awk 'BEGIN { FS = ":.*## " } /^[a-zA-Z0-9_-]+:.*## / { printf "  %-15s %s\n", $$1, $$2 }' $(MAKEFILE_LIST)

verify: ## Vérifications statiques : shellcheck, yamllint, compose, secrets (Docker requis)
	@.claude/scripts/verify.sh
