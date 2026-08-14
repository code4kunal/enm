# Transvolt E&M — one command for both halves.
#
# The two sides have different toolchains in different directories, which is
# why "run the tests" used to be four commands and why they drifted. Everything
# CI runs is a target here, so what runs on a laptop and what runs on a push
# are the same thing.

SHELL := /bin/bash
.DEFAULT_GOAL := help

BACKEND  := backend
APP      := app
PY       := $(BACKEND)/.venv/bin/python
FLUTTER  ?= flutter
API_PORT ?= 8123
API_BASE ?= http://localhost:$(API_PORT)/api/v1

.PHONY: help
help: ## List the targets
	@grep -hE '^[a-zA-Z_-]+:.*?## ' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[1m%-16s\033[0m %s\n", $$1, $$2}'

# --- setup -------------------------------------------------------------------

.PHONY: install
install: install-backend install-app ## Install both toolchains

.PHONY: install-backend
install-backend: ## Create the venv and install requirements
	@test -d $(BACKEND)/.venv || python3 -m venv $(BACKEND)/.venv
	@$(PY) -m pip install --quiet --upgrade pip
	@$(PY) -m pip install --quiet -r $(BACKEND)/requirements.txt
	@$(PY) -m pip install --quiet pytest pytest-asyncio ruff pypdf

.PHONY: install-app
install-app: ## Fetch Dart packages
	@cd $(APP) && $(FLUTTER) pub get

# --- the things CI runs ------------------------------------------------------

.PHONY: check
check: lint test contract ## Everything. Run this before pushing.

.PHONY: lint
lint: lint-backend lint-app ## Lint both halves

.PHONY: lint-backend
lint-backend:
	@cd $(BACKEND) && .venv/bin/ruff check app tests scripts

.PHONY: lint-app
lint-app:
	@cd $(APP) && $(FLUTTER) analyze

.PHONY: test
test: test-backend test-app ## Test both halves

.PHONY: test-backend
test-backend: ## Needs Postgres — `make db` first
	@cd $(BACKEND) && .venv/bin/python -m pytest -q

.PHONY: test-app
test-app:
	@cd $(APP) && $(FLUTTER) test

.PHONY: contract
contract: ## Check the client's assumptions against the API's schema
	@$(PY) tools/check_contract.py

# --- running -----------------------------------------------------------------

.PHONY: db
db: ## Just Postgres, for running the backend tests
	@cd $(BACKEND) && docker compose up -d db
	@cd $(BACKEND) && docker compose exec -T db bash -c \
		'until pg_isready -U enm >/dev/null 2>&1; do sleep 1; done'
	@cd $(BACKEND) && docker compose exec -T db \
		psql -U enm -d enm -c "SELECT 1" >/dev/null && echo "db ready"

.PHONY: up
up: ## Postgres + the API on $(API_PORT), migrated
	@cd $(BACKEND) && API_PORT=$(API_PORT) docker compose up -d --build
	@echo "api on http://localhost:$(API_PORT)$${API_PREFIX:-/api/v1}"

.PHONY: down
down: ## Stop everything
	@cd $(BACKEND) && docker compose down

.PHONY: seed
seed: ## Master data + the super admin. Idempotent.
	@cd $(BACKEND) && docker compose exec -T -e PYTHONPATH=/srv api python scripts/seed.py

.PHONY: web
web: ## Serve the Flutter client against the local API
	@cd $(APP) && $(FLUTTER) run -d chrome --dart-define=API_BASE_URL=$(API_BASE)

.PHONY: logs
logs:
	@cd $(BACKEND) && docker compose logs -f api

# --- release -----------------------------------------------------------------

.PHONY: build
build: build-app ## Build the release artefacts

.PHONY: build-app
build-app: ## Static web bundle into app/build/web
	@cd $(APP) && $(FLUTTER) build web --dart-define=API_BASE_URL=$(API_BASE)

.PHONY: migrate
migrate: ## Run migrations against DATABASE_URL, on their own
	@cd $(BACKEND) && .venv/bin/python -m alembic upgrade head

.PHONY: migrate-check
migrate-check: ## Prove the migrations reverse, on a throwaway database
	@cd $(BACKEND) && docker compose exec -T db \
		psql -U enm -d enm -c "DROP DATABASE IF EXISTS enm_migrate" \
		-c "CREATE DATABASE enm_migrate" >/dev/null
	@cd $(BACKEND) && DATABASE_URL=postgresql+asyncpg://enm:enm@localhost:5433/enm_migrate \
		bash -c '.venv/bin/python -m alembic upgrade head \
		&& .venv/bin/python -m alembic downgrade base \
		&& .venv/bin/python -m alembic upgrade head' >/dev/null
	@echo "migrations reverse cleanly"

.PHONY: openapi
openapi: ## Write the current API schema to openapi.json
	@$(PY) -c "import json,sys; sys.path.insert(0,'$(BACKEND)'); \
from app.main import app; \
print(json.dumps(app.openapi(), indent=2))" > openapi.json
	@echo "wrote openapi.json"
