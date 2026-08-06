#!/bin/sh
# Sink deploy script — pulls the prebuilt image and starts the container.
#
# The dashboard/API password is passed as a command-line argument, so it never
# needs to be stored in a .env file. Other optional settings can still go in
# .env (see docker/.env.example) — the argument only overrides NUXT_SITE_TOKEN.
#
# Usage (run from anywhere in the repo):
#   ./docker/deploy.sh <NUXT_SITE_TOKEN>
set -eu

# Resolve the repo root (one directory above this script).
SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
cd "$SCRIPT_DIR/.."

if [ "$#" -lt 1 ] || [ -z "$1" ]; then
  echo "Usage: $0 <NUXT_SITE_TOKEN>" >&2
  echo "  Example: $0 password" >&2
  echo "  (This is your dashboard login + API password, >= 8 chars.)" >&2
  exit 1
fi

export NUXT_SITE_TOKEN="$1"

# Pull the latest prebuilt image, then start (or update) the container.
# Data lives in the sink-state volume and is untouched by updates.
docker compose pull
docker compose up -d

echo ""
echo "Sink is up. Open http://<server-ip>:3000/dashboard/links and sign in."
