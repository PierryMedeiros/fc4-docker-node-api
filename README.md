# Flags API — Containerização (Dev à Produção)

API REST de feature flags em Node.js + TypeScript com PostgreSQL, containerizada em
dois ambientes: **desenvolvimento** (produtivo, com watch e ferramentas de apoio) e
**produção** (imagem enxuta, sem gerenciadores de pacote, não-root, publicada no
Docker Hub com SBOM e provenance).

## Sobre a entrega

O `Dockerfile` é multi-stage (`base` → `dev` / `build` / `prod-deps` → `production`).
O desenvolvimento sobe com `docker compose up`: o serviço `db` (PostgreSQL) fica
`healthy`, a aplicação aplica as migrações e sobe em modo watch, respondendo em
`http://localhost:3000`. A produção consome a imagem publicada no Docker Hub via
`compose.prod.yaml`, sem `build`, com restart policy e limites de CPU/memória; as
migrações são aplicadas pelo próprio init da imagem (`docker/start.js`) antes de o
servidor começar a escutar.

O código da aplicação (`src/`, `package.json`, `package-lock.json`, `tsconfig.json`,
migrações) **não foi alterado** — a entrega é 100% de containerização. Os únicos
arquivos novos são de infraestrutura: `Dockerfile`, `.dockerignore`, `compose.yaml`,
`compose.prod.yaml`, `.env.example` e `docker/start.js`.

## Imagem no Docker Hub

- **Repositório:** https://hub.docker.com/r/pierrymedeiros/flags-api
- **Pull:**
  ```bash
  docker pull pierrymedeiros/flags-api:1.0.0
  ```
- **Digest do manifest (multi-arch):** `sha256:af77c09af1df61bee7d6f71b8af54bb227900f3862f50baad43450d6ceeb6be6`
  As tags `1.0.0` e `latest` apontam para o **mesmo digest**.
- **Plataformas:** `linux/amd64` e `linux/arm64`.

### Comparação de tamanho (dev × produção)

| Imagem       | Estágio      | Tamanho (`docker image ls`) |
|--------------|--------------|-----------------------------|
| `flags-api`  | `dev`        | **453 MB** (inclui devDependencies e toolchain) |
| `pierrymedeiros/flags-api:1.0.0` | `production` | **236 MB** (só runtime + deps de produção) |

Quebra da imagem de produção: a base `node:22.23.1-alpine` responde por ~224 MB
(o runtime do Node), as dependências de produção (`express`, `pg`, `dotenv`) por
~5,5 MB e o código compilado (`dist/`) por ~100 KB. Compactada (o que trafega no
`pull`), a imagem tem ~58 MB.

## Decisões técnicas

### Imagem base de produção: `node:22.23.1-alpine`

Comparei duas alternativas reais medindo tamanho e CVEs (Docker Scout) no momento
da entrega:

| Base considerada | Node embutido | Tamanho base | CVEs (Scout) | Observação |
|------------------|---------------|--------------|--------------|------------|
| `gcr.io/distroless/nodejs22-debian12` | **22.22.0** | ~204 MB | **1 CRITICAL + 17 HIGH** | Sem shell/gerenciador (ótimo), mas o binário do Node embutido estava desatualizado (CVE-2025-55130, corrigida só no 22.22.2) e o Google ainda não havia reconstruído a imagem. Inviável sob o critério "zero CRITICAL". |
| **`node:22.23.1-alpine`** (escolhida) | **22.23.1** | ~224 MB | **0 após hardening** | Node atualizado (corrige a CRITICAL e as HIGH do runtime). Alpine é enxuta; removo os gerenciadores de pacote no estágio final para reduzir a superfície de ataque. |

**Por que Alpine e não a distroless (que é ~20 MB menor):** o critério mais duro do
desafio é *zero CVE CRITICAL na imagem publicada*. A distroless, embora tenha menos
superfície de ataque por não ter shell, dependia de um Node desatualizado no momento
da entrega — e não há como corrigir o runtime de uma imagem que você não reconstrói.
A Alpine me deu o Node 22.23.1 (patch mais recente), zerando a CRITICAL na origem.
Para recuperar parte da vantagem de superfície de ataque da distroless, o estágio
`production` **remove `npm`, `npx`, `corepack` e `yarn`** — que não são necessários em
runtime e, inclusive, traziam as 2 únicas CVEs HIGH remanescentes (empacotadas com o
npm: `sigstore` e `picomatch`, nenhuma dependência da aplicação). Resultado final:
**0C / 0H / 0M / 0L**.

### Estratégia de cache de build

- **Estágio `base` só com os manifests:** `COPY package.json package-lock.json`
  acontece **antes** de qualquer `COPY . .`. Enquanto as dependências não mudam, a
  camada de `npm ci` é reaproveitada e um `rebuild` após editar código-fonte não
  reinstala nada.
- **Cache de download do npm:** todas as instalações usam
  `RUN --mount=type=cache,target=/root/.npm`, então o cache do npm persiste **entre
  builds** (não fica preso na camada). Rebuilds baixam só o que faltar.
- **Multi-stage separando deps de dev e de produção:** `prod-deps` roda
  `npm ci --omit=dev` isolado, e a imagem final copia apenas esse `node_modules`
  enxuto — devDependencies (tsx, typescript, @types) nunca chegam à produção.

## Como rodar (desenvolvimento)

Pré-requisitos: Docker com Compose v2 e Buildx.

```bash
cp .env.example .env
docker compose up            # sobe db + app; migrações aplicadas automaticamente
```

A API responde em `http://localhost:3000` assim que o `db` fica `healthy` e as
migrações rodam. Teste:

```bash
curl http://localhost:3000/health        # {"status":"ok","db":"up"}
curl http://localhost:3000/flags         # []  (200)
curl -X POST http://localhost:3000/flags \
  -H 'Content-Type: application/json' \
  -d '{"key":"dark-mode","description":"Ativa o tema escuro","enabled":true}'
```

### Watch (hot reload)

```bash
docker compose watch
```

- Alterar um arquivo em `src/` → **sync** para dentro do container; o `tsx watch`
  recarrega sozinho, **sem rebuild**.
- Alterar `package.json` ou `package-lock.json` → **rebuild** automático da imagem.

### Ferramentas de apoio (profile `tools`)

```bash
docker compose --profile tools up -d
```

Sobe o **Adminer** (cliente web de PostgreSQL) em **http://localhost:8081**.
Servidor: `db` · usuário/senha/base conforme o `.env`.

## Como rodar (produção)

Consome a imagem publicada no Docker Hub (não faz build local):

```bash
cp .env.example .env
docker compose -f compose.prod.yaml up -d
docker compose -f compose.prod.yaml ps     # app e db aparecem como "healthy"
curl http://localhost:3000/flags           # 200
```

As migrações são aplicadas pelo init da própria imagem antes de o servidor escutar.
Todos os serviços têm `restart: unless-stopped` e limites de CPU/memória; os dados do
PostgreSQL ficam em volume nomeado (nenhum bind mount de código).

## Segurança e supply chain

Comandos de verificação (imagem publicada):

```bash
# Usuário não-root
docker image inspect pierrymedeiros/flags-api:1.0.0 --format '{{.Config.User}}'   # node

# Labels OCI e HEALTHCHECK
docker image inspect pierrymedeiros/flags-api:1.0.0 \
  --format '{{json .Config.Labels}}{{"\n"}}{{json .Config.Healthcheck}}'

# Plataformas + attestations (SBOM e provenance) sem baixar a imagem
docker buildx imagetools inspect pierrymedeiros/flags-api:1.0.0

# Escaneamento de vulnerabilidades
docker scout cves pierrymedeiros/flags-api:1.0.0 --platform linux/amd64
```

- **Usuário não-root:** roda como `node` (uid 1000).
- **Labels OCI:** `title`, `description`, `version` e `source` declaradas na imagem.
- **HEALTHCHECK:** embutido na imagem, valida `GET /health` via `fetch` global do
  Node (sem depender de curl/wget).
- **SBOM + provenance:** publicados como attestations junto do manifest (SLSA
  provenance + SBOM SPDX com 103 pacotes), um par por plataforma.
- **Encerramento gracioso:** `node` é PID 1 (exec form) e recebe SIGTERM; `docker stop`
  encerra em **~0,3 s**, bem abaixo do timeout de 10 s.

### Docker Scout — resumo

Relatório completo em [`reports/scout-cves.txt`](reports/scout-cves.txt).

```
0C   0H   0M   0L      No vulnerable packages detected
```

**Zero CVE CRITICAL** e **zero HIGH**. Isso foi alcançado por decisão de base (Node
22.23.1, que corrige as CVEs de runtime das imagens anteriores) e pela remoção dos
gerenciadores de pacote no estágio de produção (que carregavam as 2 únicas HIGH
remanescentes — `sigstore` e `picomatch`, ambas dependências do npm, não da app).
Não há CVEs HIGH remanescentes a justificar.

## Validação (critério → comando)

| Critério de aceite | Comando de verificação |
|---|---|
| Estágios `dev`, `build`, `production` no Dockerfile | `grep -E '^FROM .* AS (dev\|build\|production)' Dockerfile` |
| `docker build --target dev/production` sem erro | `docker build --target dev . && docker build --target production .` |
| `.dockerignore` exclui `node_modules`, `dist`, `.git`, `.env` | `cat .dockerignore` |
| Instalações usam cache mount | `grep -- '--mount=type=cache' Dockerfile` |
| Dev sobe e `GET /flags` = 200 | `cp .env.example .env && docker compose up -d && curl -s -o /dev/null -w '%{http_code}' localhost:3000/flags` |
| `db` healthcheck + `app` depende `service_healthy` | `grep -A3 condition compose.yaml` |
| Watch: sync em `src/`, rebuild em `package.json` | `docker compose watch` (editar `src/…` e `package.json`) |
| Profile `tools` → Adminer em 8081 | `docker compose --profile tools up -d && curl -s -o /dev/null -w '%{http_code}' localhost:8081` |
| App roda não-root (UID ≠ 0) | `docker compose exec app id -u` |
| `.env` não versionado, `.env.example` sim | `git check-ignore .env && git ls-files .env.example` |
| Manifest com amd64 + arm64 | `docker buildx imagetools inspect pierrymedeiros/flags-api:1.0.0` |
| Attestations SBOM + provenance | `docker buildx imagetools inspect pierrymedeiros/flags-api:1.0.0` |
| `1.0.0` e `latest` = mesmo digest | `docker buildx imagetools inspect pierrymedeiros/flags-api:1.0.0` / `:latest` |
| Tamanho da imagem (amd64) | `docker pull --platform linux/amd64 pierrymedeiros/flags-api:1.0.0 && docker image ls pierrymedeiros/flags-api` |
| User não-root + HEALTHCHECK + labels OCI | `docker image inspect pierrymedeiros/flags-api:1.0.0` |
| Container fica `healthy` | `docker compose -f compose.prod.yaml ps` |
| `docker stop` < 10 s | `time docker stop <container>` |
| Zero CVE CRITICAL | `docker scout cves pierrymedeiros/flags-api:1.0.0` |
| Prod sem `build`, imagem por tag semver | `grep -E 'image:\|build:' compose.prod.yaml` |
| Restart policy + limites de recursos | `grep -E 'restart:\|limits:\|cpus:\|memory:' compose.prod.yaml` |
| Volume nomeado, sem bind mount de código | `grep -A2 volumes: compose.prod.yaml` |
| Prod sobe e `GET /flags` = 200 | `cp .env.example .env && docker compose -f compose.prod.yaml up -d && curl -s -o /dev/null -w '%{http_code}' localhost:3000/flags` |

## Estrutura da entrega

```
.
├── Dockerfile              # multi-stage: base → dev / build / prod-deps → production
├── .dockerignore
├── compose.yaml            # desenvolvimento (watch, healthcheck, profile tools)
├── compose.prod.yaml       # produção (imagem do Hub, restart, limites)
├── .env.example            # credenciais de desenvolvimento local
├── docker/
│   └── start.js            # init de produção: migrações → servidor (PID 1)
├── reports/
│   └── scout-cves.txt      # saída completa do docker scout cves
├── src/                    # aplicação (não alterada)
├── package.json            # (não alterado)
├── package-lock.json       # (não alterado)
└── tsconfig.json           # (não alterado)
```
