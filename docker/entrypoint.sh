#!/bin/sh
# Sink container entrypoint.
#
# 1. Build .dev.vars from the container's NUXT_* environment variables
#    (wrangler dev reads local secrets from .dev.vars).
# 2. Apply D1 schema migrations to the local state (idempotent).
# 3. Start the app on the workerd runtime in local (miniflare) mode.
set -eu

# --- 1. Generate .dev.vars from environment ---
# Values are double-quoted so special characters (#, spaces, =) survive
# dotenv parsing in .dev.vars.
: > /app/.dev.vars
env | grep '^NUXT_' | while IFS='=' read -r key value; do
  printf '%s="%s"\n' "$key" "$value" >> /app/.dev.vars
done

if ! grep -q '^NUXT_SITE_TOKEN=.' /app/.dev.vars; then
  echo "ERROR: NUXT_SITE_TOKEN is not set. Add it to the container environment" >&2
  echo "       (see docker/README.md / docker/.env.example)." >&2
  exit 1
fi

# --- 2. Apply D1 migrations (safe to run on every start) ---
node_modules/.bin/wrangler d1 migrations apply sink --local --config wrangler.dev.jsonc

# --- 3. Run the app ---
# Cloudflare bindings are simulated locally; state persists in /app/.wrangler.
exec node_modules/.bin/wrangler dev --config wrangler.dev.jsonc --port 3000 --ip 0.0.0.0
