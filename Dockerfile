# syntax=docker/dockerfile:1
#
# Production image for wacrm. Multi-stage so the runtime layer carries
# only the standalone server bundle, not the full dependency tree or the
# source. Built for Coolify's GitHub-App deploy, but there is nothing
# Coolify-specific in here — it runs anywhere Docker does.
#
#   docker build \
#     --build-arg NEXT_PUBLIC_SUPABASE_URL=https://xxx.supabase.co \
#     --build-arg NEXT_PUBLIC_SUPABASE_ANON_KEY=eyJ... \
#     --build-arg NEXT_PUBLIC_SITE_URL=https://crm.example.com \
#     -t wacrm .

# ---------------------------------------------------------------------
# builder — install and compile.
#
# Deliberately one stage, not the conventional deps/builder split. That
# split exists to cache installs, but `COPY package.json package-lock.json`
# ahead of `COPY . .` already earns the same cache hit: edits to src/ do
# not invalidate the `npm ci` layer. What the split adds is a
# `COPY --from=deps /app/node_modules` of ~670 MB across a stage
# boundary, which BuildKit materialises as a second full copy on disk.
# On a small Coolify host that is where the build dies.
# ---------------------------------------------------------------------
FROM node:24-alpine AS builder

# Next 16 builds with Turbopack, whose native binaries are glibc-linked.
# Alpine ships musl, so without the compat shim `next build` aborts with
# "Error loading shared library ld-linux-x86-64.so.2".
RUN apk add --no-cache libc6-compat

WORKDIR /app
COPY package.json package-lock.json ./

# `npm ci` (not `install`) so the lockfile is authoritative and the build
# is reproducible. Dev dependencies are required — `next build` runs the
# TypeScript compiler and ESLint.
RUN npm ci

COPY . .

# NEXT_PUBLIC_* are inlined into the client JS bundle by `next build`.
# They are NOT read from the container environment at runtime, so setting
# them only as Coolify runtime env vars leaves the browser Supabase client
# constructed with `undefined` — the dashboard then fails every request
# with an opaque fetch error and no server-side trace.
#
# In Coolify: set these under Environment Variables and tick "Build
# Variable" on each, which is what forwards them as --build-arg.
#
# Tick it on these three ONLY. Coolify injects every build-marked var as
# an `ARG NAME=<literal value>` prepended to each stage, so anything
# ticked here is written into the image's build history in plaintext and
# is readable by anyone who can pull the image. ENCRYPTION_KEY,
# SUPABASE_SERVICE_ROLE_KEY, META_APP_SECRET and AUTOMATION_CRON_SECRET
# are read at request time, never at build time — leave them unticked.
ARG NEXT_PUBLIC_SUPABASE_URL
ARG NEXT_PUBLIC_SUPABASE_ANON_KEY
ARG NEXT_PUBLIC_SITE_URL
ENV NEXT_PUBLIC_SUPABASE_URL=${NEXT_PUBLIC_SUPABASE_URL}
ENV NEXT_PUBLIC_SUPABASE_ANON_KEY=${NEXT_PUBLIC_SUPABASE_ANON_KEY}
ENV NEXT_PUBLIC_SITE_URL=${NEXT_PUBLIC_SITE_URL}

# Next encrypts Server Action closure variables with a key generated
# fresh on every build. During a rolling deploy the old and new container
# hold different keys, so an action minted by one is rejected by the other
# with "Failed to find Server Action". Pin the key to keep deploys
# seamless. Generate once with:  openssl rand -base64 32
# Optional — omit it and single-container deploys still work, at the cost
# of a hard refresh for anyone mid-session during a redeploy.
ARG NEXT_SERVER_ACTIONS_ENCRYPTION_KEY
ENV NEXT_SERVER_ACTIONS_ENCRYPTION_KEY=${NEXT_SERVER_ACTIONS_ENCRYPTION_KEY}

ENV NEXT_TELEMETRY_DISABLED=1
RUN npm run build

# ---------------------------------------------------------------------
# runner — minimal production layer.
# ---------------------------------------------------------------------
FROM node:24-alpine AS runner
WORKDIR /app

ENV NODE_ENV=production
ENV NEXT_TELEMETRY_DISABLED=1

# Drop root. A container breakout via the public webhook endpoint should
# not land on a root shell.
RUN addgroup -g 1001 -S nodejs \
 && adduser -S nextjs -u 1001

# `output: 'standalone'` writes a server bundle plus the traced subset of
# node_modules, but deliberately leaves out public/ and .next/static/ —
# upstream assumes a CDN fronts them. Copy both in or every asset 404s
# and the app renders unstyled. public/opus/ carries the opus-recorder
# worker the inbox voice-note composer loads at runtime.
COPY --from=builder /app/public ./public
COPY --from=builder --chown=nextjs:nodejs /app/.next/standalone ./
COPY --from=builder --chown=nextjs:nodejs /app/.next/static ./.next/static

USER nextjs

EXPOSE 3000
ENV PORT=3000
# Bind all interfaces — the default localhost bind is unreachable from
# outside the container, so Coolify's proxy would see a dead upstream.
ENV HOSTNAME=0.0.0.0

# Exec form, so node runs as PID 1 and receives SIGTERM directly. The
# WhatsApp webhook returns 200 immediately and finishes its DB writes
# inside `after()`, which Next drains only on a clean shutdown signal.
# A shell-form CMD would fork a /bin/sh that swallows SIGTERM, and every
# in-flight inbound message would be dropped on redeploy.
CMD ["node", "server.js"]
