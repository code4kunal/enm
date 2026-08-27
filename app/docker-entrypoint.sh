#!/bin/sh
# Writes config.json from env vars at container START, not image build —
# the point being that one image serves dev/staging/prod by varying these
# vars alone. See lib/data/api/runtime_config.dart for the client side.
set -eu

API_BASE_URL="${API_BASE_URL:-http://localhost:8123/api/v1}"
SITEOPS_BASE_URL="${SITEOPS_BASE_URL:-https://platform-service.transvolt.in/api/v1}"
ENVIRONMENT="${ENVIRONMENT:-development}"

# Same guard the old build-time check made, moved to the stage where it
# actually applies now: refuse to serve a public build pointed at localhost.
case "$ENVIRONMENT" in
  production|prod)
    case "$API_BASE_URL" in
      *localhost*|*127.0.0.1*)
        echo "ERROR: API_BASE_URL=$API_BASE_URL still points at localhost while ENVIRONMENT=$ENVIRONMENT." >&2
        echo "Set API_BASE_URL to the browser-reachable URL, e.g. https://dev-emm.transvolt.org/api/v1" >&2
        exit 1
        ;;
    esac
    ;;
esac

cat > /usr/share/nginx/html/config.json <<EOF
{
  "apiBaseUrl": "${API_BASE_URL}",
  "siteopsBaseUrl": "${SITEOPS_BASE_URL}"
}
EOF

exec nginx -g 'daemon off;'
