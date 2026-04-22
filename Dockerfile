# syntax=docker/dockerfile:1

FROM node:22-alpine AS base

ENV PNPM_HOME=/pnpm
ENV PATH=$PNPM_HOME:$PATH
WORKDIR /app

RUN corepack enable && corepack prepare pnpm@latest --activate

# ---- Dependencies (all, for build) ----
FROM base AS deps

RUN apk add --no-cache libc6-compat
COPY package.json pnpm-lock.yaml pnpm-workspace.yaml ./
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm fetch --frozen-lockfile \
    && pnpm install --offline --frozen-lockfile --config.confirmModulesPurge=false

# ---- Builder ----
FROM base AS builder

COPY --from=deps /app/node_modules ./node_modules
COPY . .
COPY docker/proxy.ts ./src

ARG BASE_PATH
ARG NODE_OPTIONS="--max-old-space-size=3072"
ENV BASE_PATH=$BASE_PATH
ENV NODE_OPTIONS=$NODE_OPTIONS
ENV NEXT_TELEMETRY_DISABLED=1
ENV DATABASE_URL="postgresql://user:pass@localhost:5432/dummy"

RUN pnpm build-db \
    && pnpm build-tracker \
    && pnpm build-recorder \
    && pnpm build-geo \
    && pnpm exec next build --webpack

# ---- Pruned standalone output ----
FROM alpine:3 AS standalone-pruned

COPY --from=builder /app/.next/standalone /app/
COPY --from=builder /app/.next/static /app/.next/static

RUN find /app/node_modules/.pnpm -maxdepth 1 -type d \( \
         -name '@img+*' -o -name 'sharp@*' -o -name 'next@*' \
         -o -name '@prisma+client@7.6*' -o -name 'react@*' -o -name 'react-dom@*' \
         -o -name '@types+react*' \
    \) -exec rm -rf {} +; \
    find /app/node_modules -name "*.wasm" -not -name "*postgresql*" -not -name "*schema*" -delete; \
    find /app/node_modules -name "*.wasm-base64.*" -not -name "*postgresql*" -not -name "*schema*" -delete; \
    find /app/node_modules -name "generator-build" -type d -exec rm -rf {} +; \
    find /app/node_modules -name "*.map" -delete; \
    true

# ---- Runtime deps (production only) ----
FROM base AS deps-prod

RUN apk add --no-cache libc6-compat
ARG PRISMA_VERSION="7.6.0"
RUN --mount=type=cache,id=pnpm-store,target=/pnpm/store \
    pnpm --allow-build='@prisma/engines' add npm-run-all dotenv chalk semver \
    prisma@${PRISMA_VERSION} \
    @prisma/client@${PRISMA_VERSION} \
    @prisma/adapter-pg@${PRISMA_VERSION}

# ---- Pruned runtime deps ----
FROM alpine:3 AS deps-pruned

COPY --from=deps-prod /app/node_modules /app/node_modules

RUN find /app/node_modules -name "*.map" -delete; \
    find /app/node_modules -name "LICENSE*" -delete; \
    find /app/node_modules -name "CHANGELOG*" -delete; \
    find /app/node_modules -name "*.md" -not -name "README.md" -delete; \
    find /app/node_modules -type d \( -name test -o -name tests -o -name __tests__ -o -name docs -o -name doc -o -name examples -o -name example \) -prune -exec rm -rf {} +; \
    find /app/node_modules/.pnpm -maxdepth 1 -type d \( \
         -name '@prisma+studio-*' -o -name '@electric-sql+pglite*' \
         -o -name '@img+*' -o -name 'sharp@*' -o -name 'next@*' \
         -o -name 'effect@*' -o -name 'fast-check@*' -o -name 'mysql2@*' \
         -o -name 'chevrotain@*' -o -name 'hono@*' \
         -o -name 'jiti@*' -o -name 'remeda@*' -o -name 'es-abstract@*' \
         -o -name 'lodash@*' -o -name 'csstype@*' -o -name 'react@*' \
         -o -name 'react-dom@*' -o -name '@types+react@*' \
         -o -name '@types+react-dom@*' -o -name '@prisma+client@7.6*' \
         -o -name '@prisma+get-platform@7.2*' -o -name '@hono+*' \
         -o -name 'consola@*' -o -name 'node-fetch-native@*' \
    \) -exec rm -rf {} +; \
    find /app/node_modules -name "*.wasm" -not -name "*postgresql*" -not -name "*schema*" -delete; \
    find /app/node_modules -name "*.wasm-base64.*" -not -name "*postgresql*" -not -name "*schema*" -delete; \
    find /app/node_modules -name "generator-build" -type d -exec rm -rf {} +; \
    true

# ---- Runner ----
FROM node:22-alpine AS runner

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1
ARG NODE_OPTIONS
ENV NODE_OPTIONS=$NODE_OPTIONS

RUN apk add --no-cache curl \
    && addgroup --system --gid 1001 nodejs \
    && adduser --system --uid 1001 nextjs \
    && rm -rf /usr/local/lib/node_modules/npm \
    /usr/local/lib/node_modules/corepack \
    /usr/local/include \
    /usr/local/share

WORKDIR /app

COPY --from=deps-pruned /app/node_modules ./node_modules
COPY --from=builder /app/package.json ./package.json
COPY --from=builder /app/public ./public
COPY --from=builder /app/prisma ./prisma
COPY --from=builder /app/prisma.config.ts ./prisma.config.ts
COPY --from=builder /app/scripts ./scripts
COPY --from=builder /app/generated ./generated
COPY --from=standalone-pruned /app/ ./

USER nextjs

EXPOSE 3000

ENV HOSTNAME=0.0.0.0
ENV PORT=3000
ENV PATH=/app/node_modules/.bin:$PATH

HEALTHCHECK --interval=30s --timeout=5s --start-period=60s --retries=3 \
    CMD curl -f http://localhost:3000/api/heartbeat || exit 1

CMD ["sh", "-c", "node scripts/check-db.js && node scripts/update-tracker.js && node server.js"]
