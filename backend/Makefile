.PHONY: up down logs build migrate revision seed test lint fmt shell psql clean

up:            ## build + start api and postgres
	docker compose up --build -d
	@echo "API: http://localhost:8000/api/v1/docs"

down:
	docker compose down

clean:
	docker compose down -v

logs:
	docker compose logs -f api

build:
	docker compose build

migrate:
	docker compose exec api alembic upgrade head

revision:
	docker compose exec api alembic revision --autogenerate -m "$(m)"

seed:
	docker compose exec api python -m scripts.seed

psql:
	docker compose exec db psql -U enm -d enm

shell:
	docker compose exec api bash

# --- local dev (venv) ---------------------------------------------------
venv:
	/opt/homebrew/bin/python3.11 -m venv .venv && .venv/bin/pip install -r requirements-dev.txt

test:
	docker compose up -d db
	@docker compose exec -T db psql -U enm -d postgres -c "DROP DATABASE IF EXISTS enm_test" >/dev/null
	@docker compose exec -T db psql -U enm -d postgres -c "CREATE DATABASE enm_test" >/dev/null
	.venv/bin/pytest -q

lint:
	.venv/bin/ruff check app scripts tests alembic

fmt:
	.venv/bin/ruff format app scripts tests alembic
	.venv/bin/ruff check --fix app scripts tests alembic
