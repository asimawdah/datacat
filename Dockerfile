# syntax=docker/dockerfile:1
FROM node:22-bookworm-slim AS build
WORKDIR /app
RUN corepack enable && corepack prepare pnpm@10.11.0 --activate
COPY . .
RUN pnpm install --frozen-lockfile --filter @workspace/api-server... --filter @workspace/web...
RUN BASE_PATH=/ pnpm run build:selfhost

FROM node:22-bookworm-slim AS runtime
ENV NODE_ENV=production PORT=3000 DATACAT_DOWNLOADS_DIR=/app/downloads
WORKDIR /app
RUN mkdir -p /app/downloads && chown node:node /app/downloads
COPY --from=build --chown=node:node /app/artifacts/api-server/dist ./artifacts/api-server/dist
COPY --from=build --chown=node:node /app/artifacts/web/dist ./artifacts/web/dist
COPY --from=build --chown=node:node /app/LICENSE /app/NOTICE /app/THIRD_PARTY_LICENSES.md ./
USER node
EXPOSE 3000
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s \
  CMD node -e "fetch('http://localhost:3000/api/readyz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
CMD ["node", "--enable-source-maps", "artifacts/api-server/dist/index.mjs"]
