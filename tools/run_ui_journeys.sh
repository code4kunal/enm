#!/usr/bin/env bash
# Run the UI journeys in real Chrome.
#
# chromedriver has to be listening before `flutter drive` starts and gone
# afterwards, so it is started and reaped here rather than left to a human to
# remember.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$ROOT/app"
API_BASE="${API_BASE:-http://localhost:8123/api/v1}"
TARGET="${1:-integration_test/smoke_boots_test.dart}"
# Matches the Makefile's FLUTTER ?= flutter, so a non-PATH SDK works either way.
FLUTTER="${FLUTTER:-flutter}"

"$ROOT/tools/fetch_chromedriver.sh"

"$APP/.tooling/chromedriver" --port=4444 >/dev/null 2>&1 &
DRIVER_PID=$!
trap 'kill "$DRIVER_PID" 2>/dev/null || true' EXIT

for _ in $(seq 1 20); do
  curl -sf -m 2 http://localhost:4444/status >/dev/null && break
  sleep 1
done

cd "$APP"
"$FLUTTER" drive \
  --driver=test_driver/integration_test.dart \
  --target="$TARGET" \
  -d web-server --browser-name=chrome \
  --dart-define=API_BASE_URL="$API_BASE"
