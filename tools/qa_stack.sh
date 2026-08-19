#!/usr/bin/env bash
# Bring up an isolated stack for the QA floor: a scratch database cloned from
# dev, and an API of its own on a separate port.
#
# The clone is what makes the floor both isolated and realistic. A freshly
# migrated database has no depot data, so every report test would skip; a copy
# of dev carries MBMT's real month. The floor can then create, edit and delete
# whatever it likes without touching the database you work in.
#
#   tools/qa_stack.sh up      create the database and start the API
#   tools/qa_stack.sh down    stop the API and drop the database
#   tools/qa_stack.sh status
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BACKEND="$ROOT/backend"
QA_DB="${QA_DB:-enm_qa}"
QA_PORT="${QA_PORT:-8124}"
SOURCE_DB="${SOURCE_DB:-enm}"
PIDFILE="$ROOT/.qa-api.pid"
LOGFILE="$ROOT/.qa-api.log"

assert_isolated() {
  # Write a marker through the API and prove it landed in the scratch database
  # and not in dev. A stack that quietly serves dev is worse than no stack:
  # every run would pollute the database it claims to protect.
  local code="QAISO$$"
  local tok
  tok=$(curl -sf -m 10 -X POST "http://localhost:$QA_PORT/api/v1/auth/login" \
        -H 'Content-Type: application/json' \
        -d '{"user_id":"KUNAL","password":"admin"}' \
        | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p')
  [ -n "$tok" ] || { echo "isolation check: cannot log in" >&2; exit 1; }
  curl -sf -m 10 -X POST "http://localhost:$QA_PORT/api/v1/sites" \
    -H "Authorization: Bearer $tok" -H 'Content-Type: application/json' \
    -d "{\"code\":\"$code\",\"name\":\"isolation probe\"}" >/dev/null || true
  local in_qa in_dev
  in_qa=$(psql_db "$QA_DB" -tAc "select count(*) from sites where code='$code'" | tr -d ' ')
  in_dev=$(psql_db "$SOURCE_DB" -tAc "select count(*) from sites where code='$code'" | tr -d ' ')
  psql_db "$QA_DB" -q -c "delete from sites where code='$code'" >/dev/null 2>&1 || true
  psql_db "$SOURCE_DB" -q -c "delete from sites where code='$code'" >/dev/null 2>&1 || true
  if [ "$in_qa" != "1" ] || [ "$in_dev" != "0" ]; then
    echo "ISOLATION BROKEN: probe landed in $QA_DB=$in_qa $SOURCE_DB=$in_dev" >&2
    echo "the API on :$QA_PORT is not serving $QA_DB — refusing to continue" >&2
    down >/dev/null 2>&1
    exit 1
  fi
}

psql_db() { (cd "$BACKEND" && docker compose exec -T db psql -U enm -d "$1" "${@:2}"); }

up() {
  echo "cloning $SOURCE_DB -> $QA_DB"
  psql_db postgres -q -c "DROP DATABASE IF EXISTS $QA_DB" >/dev/null
  # TEMPLATE needs no other session on the source; dev's API holds one, so
  # dump and restore instead of CREATE DATABASE ... TEMPLATE.
  psql_db postgres -q -c "CREATE DATABASE $QA_DB" >/dev/null
  (cd "$BACKEND" && docker compose exec -T db bash -c \
     "pg_dump -U enm -d $SOURCE_DB --no-owner --no-privileges | psql -U enm -q -d $QA_DB") >/dev/null
  echo "starting API on :$QA_PORT against $QA_DB"
  # `export` inside the subshell, not a `VAR=value cmd` prefix. With the
  # prefix, `cd ... && VAR=x nohup ... &` parses so the assignment never
  # reaches uvicorn, which then silently falls back to backend/.env and serves
  # the database this stack exists to protect.
  (
    cd "$BACKEND"
    export DATABASE_URL="postgresql+asyncpg://enm:enm@localhost:5433/$QA_DB"
    export ENVIRONMENT=development
    export JWT_SECRET=qa-floor-scratch-secret
    export NOTIFICATIONS_ENABLED=false
    nohup .venv/bin/python -m uvicorn app.main:app --port "$QA_PORT" \
      --log-level warning > "$LOGFILE" 2>&1 &
    echo $! > "$PIDFILE"
  )
  for _ in $(seq 1 40); do
    if curl -sf -m 2 "http://localhost:$QA_PORT/api/v1/health" >/dev/null; then
      assert_isolated
      echo "qa stack ready: http://localhost:$QA_PORT/api/v1 -> $QA_DB"; return 0
    fi
    sleep 1
  done
  echo "API did not come up; last log lines:" >&2; tail -20 "$LOGFILE" >&2; exit 1
}

down() {
  if [ -f "$PIDFILE" ]; then kill "$(cat "$PIDFILE")" 2>/dev/null || true; rm -f "$PIDFILE"; fi
  pkill -f "app.main:app --port $QA_PORT" 2>/dev/null || true
  sleep 1
  psql_db postgres -q -c "DROP DATABASE IF EXISTS $QA_DB" >/dev/null 2>&1 || true
  echo "qa stack down, $QA_DB dropped"
}

status() {
  curl -sf -m 2 "http://localhost:$QA_PORT/api/v1/health" >/dev/null \
    && echo "api :$QA_PORT up" || echo "api :$QA_PORT down"
  psql_db postgres -tAc "select count(*) from pg_database where datname='$QA_DB'" \
    | tr -d ' ' | sed "s/^1$/$QA_DB exists/;s/^0$/$QA_DB absent/"
}

case "${1:-up}" in
  up) up ;; down) down ;; status) status ;;
  *) echo "usage: $0 {up|down|status}" >&2; exit 1 ;;
esac
