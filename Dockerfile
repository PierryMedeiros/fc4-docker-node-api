# syntax=docker/dockerfile:1

# Versões fixadas (nunca `latest` ou sem tag). O digest garante builds
# reproduzíveis mesmo que a tag seja repontada no registry.
# node:22.23.1-alpine embute o Node 22.23.1, que corrige as CVEs do runtime
# presentes em imagens mais antigas (ver reports/scout-cves.txt e o README).
ARG NODE_VERSION=22.23.1
ARG NODE_ALPINE_DIGEST=sha256:16e22a550f3863206a3f701448c45f7912c6896a62de43add43bb9c86130c3e2

########################################################################
# base — só os manifests de dependências.
# Copiar package.json + lockfile ANTES do código-fonte maximiza o cache:
# enquanto as dependências não mudam, a camada de `npm ci` é reaproveitada.
########################################################################
FROM node:${NODE_VERSION}-alpine@${NODE_ALPINE_DIGEST} AS base
WORKDIR /app
COPY package.json package-lock.json ./

########################################################################
# dev — todas as dependências (inclui devDependencies), hot reload,
# usuário não-root. É a imagem usada no compose.yaml de desenvolvimento.
########################################################################
FROM base AS dev
ENV NODE_ENV=development
RUN --mount=type=cache,target=/root/.npm \
    npm ci --include=dev
COPY . .
# O código copiado como root passa a pertencer ao usuário `node` (uid 1000),
# que já existe na imagem oficial. O watch/sync do compose escreve como esse
# usuário durante o desenvolvimento.
RUN chown -R node:node /app
USER node
EXPOSE 3000
CMD ["npm", "run", "dev"]

########################################################################
# prod-deps — apenas dependências de produção, para copiar na imagem final.
########################################################################
FROM base AS prod-deps
ENV NODE_ENV=production
RUN --mount=type=cache,target=/root/.npm \
    npm ci --omit=dev

########################################################################
# build — compila o TypeScript para dist/ (inclui dist/db/migrate.js).
########################################################################
FROM base AS build
ENV NODE_ENV=development
RUN --mount=type=cache,target=/root/.npm \
    npm ci --include=dev
COPY . .
RUN npm run build

########################################################################
# production — imagem enxuta rodando como usuário não-root. Contém apenas o
# código compilado, as dependências de produção e o init que aplica as
# migrações antes de subir o servidor.
########################################################################
FROM node:${NODE_VERSION}-alpine@${NODE_ALPINE_DIGEST} AS production
ENV NODE_ENV=production
ENV PORT=3000
WORKDIR /app

# Runtime não precisa de gerenciadores de pacotes. Removê-los reduz a superfície
# de ataque e elimina CVEs que vêm empacotadas com o npm (ex.: sigstore,
# picomatch) — nenhum deles é dependência da aplicação.
RUN rm -rf \
      /usr/local/lib/node_modules/npm \
      /usr/local/lib/node_modules/corepack \
      /usr/local/bin/npm /usr/local/bin/npx /usr/local/bin/corepack \
      /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*

COPY --from=prod-deps /app/node_modules ./node_modules
COPY --from=build /app/dist ./dist
COPY --from=build /app/package.json ./package.json
COPY docker/start.js ./start.js

# Usuário não-root já presente na imagem oficial (uid 1000).
USER node
EXPOSE 3000

# Healthcheck embutido na imagem: usa o fetch global do Node 22 (sem depender
# de curl/wget) para validar GET /health.
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD ["node", "-e", "fetch(`http://127.0.0.1:${process.env.PORT||3000}/health`).then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"]

LABEL org.opencontainers.image.title="flags-api" \
      org.opencontainers.image.description="API REST de feature flags em Node.js + TypeScript com persistência em PostgreSQL" \
      org.opencontainers.image.version="1.0.0" \
      org.opencontainers.image.source="https://github.com/PierryMedeiros/fc4-docker-node-api"

# exec form: o processo Node vira PID 1 e recebe SIGTERM/SIGINT diretamente,
# garantindo o encerramento gracioso.
ENTRYPOINT ["node"]
CMD ["start.js"]
