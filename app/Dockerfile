# syntax=docker/dockerfile:1

# --- build Flutter web bundle -----------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# Browser-reachable URLs baked in at build time (--dart-define). Override via
# docker compose build args when deploying to a remote dev server.
ARG API_BASE_URL=http://localhost:8123/api/v1
ARG SITEOPS_BASE_URL=https://dev-siteops-platform.transvolt.org/api/v1
# Set ENVIRONMENT=production in .env so a mistaken localhost bake-in fails the
# build instead of shipping a broken public UI. Local/dev leave unset.
ARG ENVIRONMENT=development

RUN case "${ENVIRONMENT}" in \
      production|prod) \
        case "${API_BASE_URL}" in \
          *localhost*|*127.0.0.1*) \
            echo "ERROR: API_BASE_URL=${API_BASE_URL} still points at localhost while ENVIRONMENT=${ENVIRONMENT}." >&2; \
            echo "Set API_PUBLIC_URL (or WEB_API_BASE_URL) to the browser-reachable URL, e.g. https://dev-emm.transvolt.org/api/v1" >&2; \
            exit 1 ;; \
        esac ;; \
    esac \
 && flutter build web --release \
    --pwa-strategy=none \
    --dart-define=API_BASE_URL=${API_BASE_URL} \
    --dart-define=SITEOPS_BASE_URL=${SITEOPS_BASE_URL}

# --- serve static files -----------------------------------------------------
FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost/ >/dev/null || exit 1
