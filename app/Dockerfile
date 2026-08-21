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

RUN flutter build web --release \
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
