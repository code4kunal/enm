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
SITEOPS_BASE ?= https://platform-service.transvolt.in/api/v1

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
	@$(PY) -m pip install --quiet -r $(BACKEND)/requirements-dev.txt

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

# Locally the database comes from docker compose and is worth provisioning
# first; on CI it is a service container and there is no compose stack to talk
# to. GitHub sets CI=true.
DB_DEP := $(if $(CI),,db)

.PHONY: test-backend
test-backend: $(DB_DEP) ## Provisions Postgres first, unless CI already has it
	@cd $(BACKEND) && .venv/bin/python -m pytest -q

.PHONY: test-app
test-app:
	@cd $(APP) && $(FLUTTER) test

.PHONY: contract
contract: ## Check the client's assumptions against the API's schema
	@$(PY) tools/check_contract.py

# --- QA floor ----------------------------------------------------------------

.PHONY: qa-driver
qa-driver: ## Fetch a chromedriver matching the installed Chrome
	@./tools/fetch_chromedriver.sh

QA_PORT  ?= 8124
QA_BASE  ?= http://localhost:$(QA_PORT)/api/v1

.PHONY: qa-up
qa-up: ## Scratch database cloned from dev, plus an API of its own
	@./tools/qa_stack.sh up

.PHONY: qa-down
qa-down: ## Stop the QA API and drop the scratch database
	@./tools/qa_stack.sh down

.PHONY: qa-api
qa-api: ## API journeys against the isolated QA stack
	@QA_API_BASE=$(QA_BASE) $(PY) -m pytest qa/api -q

.PHONY: qa-ui
qa-ui: ## UI journeys in real Chrome against a running API
	@API_BASE=$(QA_BASE) FLUTTER=$(FLUTTER) ./tools/run_ui_journeys.sh $(TARGET)

.PHONY: qa-smoke
qa-smoke: qa-api qa-ui ## The QA floor. Both halves, against the isolated stack.

# --- running -----------------------------------------------------------------

.PHONY: db
db: ## Postgres plus the test database, recreated if `down -v` took it
	@cd $(BACKEND) && docker compose up -d db
	@cd $(BACKEND) && docker compose exec -T db bash -c 'until pg_isready -U enm >/dev/null 2>&1; do sleep 1; done'
	@# Already there is the normal case, so a failure here is not news.
	@cd $(BACKEND) && docker compose exec -T db createdb -U enm enm_test 2>/dev/null || true
	@cd $(BACKEND) && docker compose exec -T db psql -U enm -d enm_test -qc "CREATE EXTENSION IF NOT EXISTS pg_trgm"
	@echo "db ready (enm + enm_test)"

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
	@cd $(APP) && $(FLUTTER) run -d chrome \
		--dart-define=API_BASE_URL=$(API_BASE) \
		--dart-define=SITEOPS_BASE_URL=$(SITEOPS_BASE)

.PHONY: token
token: ## Mint a platform-shaped token for testing. PERM=/SITE= to shape it.
	@$(PY) tools/dev_token.py $(if $(USERNAME),--user $(USERNAME),) 		$(foreach p,$(PERM),--perm $(p)) $(foreach s,$(SITE),--site $(s)) 		$(if $(ADMIN),--admin,)

.PHONY: logs
logs:
	@cd $(BACKEND) && docker compose logs -f api

# --- release -----------------------------------------------------------------

.PHONY: build
build: build-app ## Build the release artefacts

.PHONY: build-app
build-app: ## Static web bundle into app/build/web
	@cd $(APP) && $(FLUTTER) build web \
		--dart-define=API_BASE_URL=$(API_BASE) \
		--dart-define=SITEOPS_BASE_URL=$(SITEOPS_BASE)

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
