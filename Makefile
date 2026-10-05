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

.PHONY: help verify check-secrets install-hooks init check-env-name check-env deploy reload-certs bootstrap-legacy

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

# Nom d'instance : exigé sur la ligne de commande (jamais hérité du shell) et au bon format
check-env-name:
	@if [[ "$(origin ENV)" != "command line" ]]; then \
	  if [[ "$(origin ENV)" == "environment" ]]; then \
	    echo "ENV hérité du shell ($${ENV}) ignoré : passer l'instance explicitement, make $(MAKECMDGOALS) ENV=<env>" >&2; \
	  else \
	    echo "ENV non défini : make $(MAKECMDGOALS) ENV=<env>" >&2; \
	  fi; exit 1; \
	fi
	@[[ "$${ENV}" =~ ^[a-z0-9][a-z0-9_-]*$$ ]] || { echo "ENV invalide : $${ENV} (attendu : minuscules, chiffres, - et _)" >&2; exit 1; }

init: check-env-name ## [ENV] Génère envs/ENV.env (questions, secrets aléatoires) ; FORCE=1 pour régénérer
	@# FORCE et NOUVEAUX_MDP écrasent des secrets : acceptés seulement sur la ligne de commande
	@for v in "FORCE:$(origin FORCE)" "NOUVEAUX_MDP:$(origin NOUVEAUX_MDP)"; do \
	  if [[ "$${v#*:}" == "environment" ]]; then \
	    echo "$${v%%:*} hérité du shell refusé : le passer explicitement, make init ENV=$(ENV) $${v%%:*}=1" >&2; exit 1; \
	  fi; \
	done
	@FORCE="$(FORCE)" NOUVEAUX_MDP="$(NOUVEAUX_MDP)" scripts/init-env.sh "$(ENV)"

# Garde-fous communs aux cibles qui agissent sur une instance (ENV exigé sur la ligne de commande)
check-env: check-env-name
	@[[ -f "$(ENV_FILE)" ]] || { echo "Fichier introuvable : $(ENV_FILE) (le générer : make init ENV=$(ENV))" >&2; exit 1; }
	@if grep -nE '^[A-Z0-9_]+=change_me' "$(ENV_FILE)" >&2; then \
	  echo "Valeurs d'exemple encore présentes dans $(ENV_FILE) (voir ci-dessus) : à remplacer." >&2; exit 1; \
	fi
	@# Même règle dans scripts/verify.sh (section « images épinglées ») : à garder synchronisées
	@if grep -nE '^[A-Z0-9_]+_VERSION=["'"'"']?(latest)?["'"'"']?[[:space:]]*$$' "$(ENV_FILE)" >&2; then \
	  echo "Version vide ou « latest » dans $(ENV_FILE) (voir ci-dessus) : épingler un tag." >&2; exit 1; \
	fi
	@# Profil effectif, comme Compose : variable du shell prioritaire, sinon dernière affectation du
	@# fichier (guillemets englobants retirés), sinon medium. Lu avant `config` : un profil inconnu y
	@# échouerait avec un message peu parlant (env file introuvable).
	@if [[ -n "$${PLATFORM_PROFILE+x}" ]]; then profil="$${PLATFORM_PROFILE}"; else \
	  profil="$$(sed -nE "s/^[[:space:]]*PLATFORM_PROFILE=[\"']?([^\"']*)[\"']?[[:space:]]*$$/\1/p" "$(ENV_FILE)" | tail -n1)"; \
	fi; \
	profil="$${profil:-medium}"; \
	profils="$$(cd config/profiles && ls -- *.env | sed 's/\.env$$//' | paste -sd ' ' -)"; \
	if [[ ! "$$profil" =~ ^[a-z0-9_-]+$$ || ! -f "config/profiles/$$profil.env" ]]; then \
	  echo "PLATFORM_PROFILE invalide : $$profil (profils disponibles : $$profils)" >&2; exit 1; \
	fi; \
	if [[ -n "$${PLATFORM_PROFILE+x}" ]]; then \
	  echo "Attention : PLATFORM_PROFILE=$$profil vient du shell et remplace la valeur de $(ENV_FILE)." >&2; \
	fi
	@# Mot de passe admin Portainer : passé par un secret Compose (source environment), que Compose ne
	@# peut pas rendre obligatoire sans l'afficher dans `config`. Même lecture que le profil ; valeur
	@# jamais affichée. Portainer refuse un mot de passe de moins de 12 caractères.
	@cle=PORTAINER_ADMIN_PASSWORD; \
	if [[ -n "$${!cle+x}" ]]; then mdp="$${!cle}"; else \
	  mdp="$$(sed -nE "s/^[[:space:]]*$${cle}=[\"']?([^\"']*)[\"']?[[:space:]]*$$/\1/p" "$(ENV_FILE)" | tail -n1)"; \
	fi; \
	if (( $${#mdp} < 12 )); then \
	  echo "PORTAINER_ADMIN_PASSWORD absent ou trop court dans $(ENV_FILE) (12 caractères minimum, voir envs/.env.example)." >&2; exit 1; \
	fi
	@scripts/check-env-urls.sh "$(ENV_FILE)"
	@$(COMPOSE) config -q || { echo "Configuration invalide pour $(ENV_FILE) (voir ci-dessus)." >&2; exit 1; }
	@scripts/check-loki-config.sh "$(ENV_FILE)" >/dev/null

deploy: check-env ## [ENV] Démarre l'instance ENV en local et attend que tous les services soient healthy
	@# Conteneurs en double (lancés hors compose.yml ou sous un autre projet) : refus avant `up`
	@scripts/check-doublons.sh "$(ENV_FILE)"
	@# Compose reconnecte les conteneurs existants à un réseau renommé (PLATFORM_NETWORK) sans les
	@# recréer : leur NetworkMode vise encore l'ancien réseau, supprimé, et ils ne redémarrent plus.
	@# Dans ce cas, recréation forcée (volumes conservés). Un conteneur peut n'être que sur un réseau
	@# dédié (socket-proxy) : son réseau principal est comparé à l'ensemble des réseaux déclarés.
	@reseaux=" $$($(COMPOSE) config | sed -n '/^networks:/,/^[^ ]/ s/^    name: //p' | paste -sd ' ' -) "; \
	options=(); \
	for id in $$($(COMPOSE) ps -aq); do \
	  mode="$$(docker inspect -f '{{.HostConfig.NetworkMode}}' "$$id")"; \
	  if [[ "$$reseaux" != *" $$mode "* ]]; then \
	    echo "Réseau modifié ($$mode, absent de :$$reseaux) : recréation des conteneurs."; options=(--force-recreate); break; \
	  fi; \
	done; \
	set -x; $(COMPOSE) up -d --wait --wait-timeout 900 "$${options[@]}"
	@$(COMPOSE) ps --format 'table {{.Service}}\t{{.Status}}'

reload-certs: check-env ## [ENV] Recharge les certificats de config/certs/ (TLS_MODE=custom) : Traefik recréé
	@# Mode effectif lu comme le profil (check-env) : variable du shell, sinon dernière affectation
	@if [[ -n "$${TLS_MODE+x}" ]]; then mode="$${TLS_MODE}"; else \
	  mode="$$(sed -nE "s/^[[:space:]]*TLS_MODE=[\"']?([^\"']*)[\"']?[[:space:]]*$$/\1/p" "$(ENV_FILE)" | tail -n1)"; \
	fi; \
	if [[ "$${mode:-none}" != custom ]]; then \
	  echo "reload-certs : réservé à TLS_MODE=custom ($(ENV_FILE) : TLS_MODE=$${mode:-none})." >&2; exit 1; \
	fi
	@# Certificats déjà contrôlés par check-env. Traefik ne relit pas les fichiers de certificat :
	@# recréation (montages relus, y compris après un remplacement par mv), coupure de quelques secondes.
	$(COMPOSE) up -d --wait --force-recreate traefik

# Temporaire : scripts repris de Software Factory, qui créent des données de test (projet
# factory-test, analyse SonarQube). Remplacé par `make bootstrap` (épopée 5).
bootstrap-legacy: check-env ## [ENV] [Temporaire] Bootstrap repris de la factory (crée des données de test) ; FORCER=1 hors local
	@if [[ "$(ENV)" != "local" && "$(FORCER)" != "1" ]]; then \
	  echo "bootstrap-legacy crée des données de test : réservé à ENV=local (FORCER=1 pour passer outre)." >&2; exit 1; \
	fi
	ENV=$(ENV) scripts/legacy/setup-all.sh
