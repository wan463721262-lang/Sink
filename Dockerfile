# syntax=docker/dockerfile:1

# =============================================================================
# Sink — self-hosted Docker image.
#
# The app runs on Cloudflare's workerd runtime in local (miniflare) mode, the
# same way the project's own local-dev/self-host workflow does: `wrangler dev`
# with a config that omits the remote-only `ai` binding. The Cloudflare
# bindings (D1, KV, R2, Analytics) are simulated locally and their state is
# persisted under /app/.wrangler (mount a volume there).
# =============================================================================

# ---------------------------------------------------------------------------
# Stage 1: build the Nuxt worker (.output) with pnpm
# ---------------------------------------------------------------------------
FROM node:22-bookworm AS build

ENV PNPM_HOME="/pnpm"
ENV PATH="${PNPM_HOME}:${PATH}"

# pnpm is pinned by package.json "packageManager" (pnpm@11.11.0)
RUN npm install -g pnpm@11.11.0

WORKDIR /app

# Public runtime config is inlined into the client bundle at build time, so it
# can only be changed via build args (not at runtime).
ARG NUXT_PUBLIC_PREVIEW_MODE=""
ARG NUXT_PUBLIC_SLUG_DEFAULT_LENGTH="6"
ARG NUXT_PUBLIC_KV_BATCH_LIMIT="50"
ENV NUXT_PUBLIC_PREVIEW_MODE="${NUXT_PUBLIC_PREVIEW_MODE}" \
    NUXT_PUBLIC_SLUG_DEFAULT_LENGTH="${NUXT_PUBLIC_SLUG_DEFAULT_LENGTH}" \
    NUXT_PUBLIC_KV_BATCH_LIMIT="${NUXT_PUBLIC_KV_BATCH_LIMIT}"

# Optional registry mirror for slow/blocked networks, e.g.
#   docker build --build-arg REGISTRY=https://registry.npmmirror.com ...
ARG REGISTRY=""
RUN if [ -n "${REGISTRY}" ]; then \
      npm config set registry "${REGISTRY}" && pnpm config set registry "${REGISTRY}"; \
    fi

# The full source tree is required: pnpm postinstall runs build:map + nuxt prepare.
COPY . .

# The prepare hook (simple-git-hooks) needs a git repo to install into.
RUN git init -q .

# postinstall (build:map + nuxt prepare) and prepare (simple-git-hooks) run here.
RUN pnpm install --frozen-lockfile

# prebuild (build:sphere) + nuxt build; the build script sets an 8 GB heap.
RUN pnpm build

# ---------------------------------------------------------------------------
# Stage 2: runtime — run the built worker on workerd (local/miniflare mode)
# ---------------------------------------------------------------------------
FROM node:22-bookworm AS runtime

WORKDIR /app

ENV NODE_ENV=production

# Built worker + full dependency tree (wrangler, workerd, bundled app deps).
COPY --from=build /app/.output /app/.output
COPY --from=build /app/node_modules /app/node_modules
COPY --from=build /app/drizzle /app/drizzle
COPY --from=build /app/package.json /app/pnpm-workspace.yaml /app/

# Local-bindings config (no `ai` binding) and the startup script.
COPY docker/wrangler.dev.jsonc /app/wrangler.dev.jsonc
COPY docker/entrypoint.sh /app/entrypoint.sh
RUN chmod +x /app/entrypoint.sh

# Local binding state (SQLite D1 + KV + R2 + Analytics simulation) persists here.
VOLUME ["/app/.wrangler"]

EXPOSE 3000

ENTRYPOINT ["/app/entrypoint.sh"]
