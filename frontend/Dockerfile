# syntax=docker/dockerfile:1
# Image frontend Talago Royal: build Flutter Web → disajikan Nginx (sekaligus reverse proxy ke backend).

# ── Build Flutter Web dengan versi SDK yang sama persis dengan tim & CI ──
FROM debian:bookworm-slim AS build
ARG FLUTTER_VERSION=3.44.1
RUN apt-get update \
 && apt-get install -y --no-install-recommends git curl unzip xz-utils ca-certificates \
 && rm -rf /var/lib/apt/lists/*
RUN git clone --depth 1 --branch ${FLUTTER_VERSION} https://github.com/flutter/flutter.git /opt/flutter
ENV PATH="/opt/flutter/bin:/opt/flutter/bin/cache/dart-sdk/bin:${PATH}" \
    FLUTTER_SUPPRESS_ANALYTICS=true \
    CI=true
RUN flutter config --no-analytics --enable-web \
 && flutter precache --web --no-android --no-ios --no-linux --no-windows --no-macos --no-fuchsia
WORKDIR /app
COPY pubspec.yaml pubspec.lock ./
RUN flutter pub get
COPY . .
# Kosong = aplikasi memanggil API di origin yang sama (diteruskan Nginx ke backend).
ARG API_BASE_URL=
RUN flutter build web --release --dart-define=API_BASE_URL=${API_BASE_URL}

# ── Sajikan dengan Nginx ──
FROM nginx:1.27-alpine
COPY nginx.conf /etc/nginx/conf.d/default.conf
COPY --from=build /app/build/web /usr/share/nginx/html
EXPOSE 80
HEALTHCHECK --interval=10s --timeout=3s --retries=5 CMD wget -qO- http://127.0.0.1/healthz >/dev/null || exit 1
