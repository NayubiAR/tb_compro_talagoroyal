# syntax=docker/dockerfile:1
# Image backend Talago Royal (REST API + Socket.IO + scheduler).

FROM node:24-bookworm-slim AS base
RUN apt-get update \
 && apt-get install -y --no-install-recommends openssl ca-certificates \
 && rm -rf /var/lib/apt/lists/*
WORKDIR /app

# ── Dependensi produksi + Prisma Client ──
FROM base AS deps
COPY package.json package-lock.json ./
COPY prisma ./prisma
RUN npm ci --omit=dev --ignore-scripts \
 && npx prisma generate \
 # Unduh schema engine sekarang (dipakai `migrate deploy` saat start) agar runtime tidak perlu menulis ke node_modules.
 && DATABASE_URL="mysql://u:p@localhost:3306/db" npx prisma migrate diff --from-empty --to-schema-datamodel prisma/schema.prisma --script > /dev/null

# ── Runtime ──
FROM base AS runtime
# LibreOffice opsional untuk konversi .doc/.docx → PDF (image ±600 MB lebih besar).
ARG WITH_LIBREOFFICE=false
RUN if [ "$WITH_LIBREOFFICE" = "true" ]; then \
      apt-get update \
      && apt-get install -y --no-install-recommends libreoffice-writer-nogui fonts-dejavu-core fonts-liberation \
      && rm -rf /var/lib/apt/lists/*; \
    fi
ENV NODE_ENV=production \
    PORT=4000 \
    UPLOAD_DIR=/app/uploads \
    TZ=Asia/Jakarta
COPY --from=deps /app/node_modules ./node_modules
COPY . .
RUN mkdir -p /app/uploads/print && chown -R node:node /app/uploads /app/samples
USER node
EXPOSE 4000
HEALTHCHECK --interval=10s --timeout=5s --start-period=60s --retries=6 \
  CMD node -e "fetch('http://127.0.0.1:4000/api/health').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "scripts/docker-start.js"]
