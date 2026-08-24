# syntax=docker/dockerfile:1

# --- build Flutter web bundle -----------------------------------------------
FROM ghcr.io/cirruslabs/flutter:stable AS build

WORKDIR /app

COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get

COPY . .

# Browser-reachable URLs are NOT baked in here — they're written to
# config.json by docker-entrypoint.sh when the container starts, so this one
# image is portable across dev/staging/prod. See
# lib/data/api/runtime_config.dart for the client-side read of that file.
RUN flutter build web --release --pwa-strategy=none

# --- serve static files -----------------------------------------------------
FROM nginx:alpine

COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY docker-entrypoint.sh /docker-entrypoint.sh
RUN chmod +x /docker-entrypoint.sh
COPY --from=build /app/build/web /usr/share/nginx/html

EXPOSE 80

HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD wget -qO- http://localhost/ >/dev/null || exit 1

ENTRYPOINT ["/docker-entrypoint.sh"]
