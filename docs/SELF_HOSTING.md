# Self-hosting DataCat

DataCat requires PostgreSQL 14+ and a single Node.js process. The production process
serves the API, built UI, `/install.sh`, `/downloads`, and telemetry intake. No hosted
account or external service is needed.

## 1. Clean Ubuntu host

Start with Ubuntu 24.04, at least 2 CPU cores and 4 GB RAM for a small installation.
Capacity depends on ingestion volume, retention and query workload; monitor disk
usage and size PostgreSQL accordingly.

```sh
sudo apt-get update
sudo apt-get install -y ca-certificates curl gnupg git openssl postgresql postgresql-contrib python3-venv
# Install current Node 22 LTS from the official NodeSource repository.
curl -fsSL https://deb.nodesource.com/setup_22.x -o /tmp/nodesource-setup.sh
# Review this script before running it.
sudo -E bash /tmp/nodesource-setup.sh
sudo apt-get install -y nodejs
sudo corepack enable
corepack prepare pnpm@10.11.0 --activate
node --version
pnpm --version
git clone <your-fork-or-upstream-url> datacat
cd datacat
```

Use Node 22.15+ (or Node 24) for the current stack and SDK. Building the agent requires
Go 1.26.11+ (https://go.dev/doc/install).

### Option A: Docker Compose

Install Docker Engine and the Compose plugin using
https://docs.docker.com/engine/install/ubuntu/ (not the obsolete `docker-compose` v1).
The host Node/PostgreSQL installation above is unnecessary when using containers.

```sh
cp .env.example .env
sed -i "s/^POSTGRES_PASSWORD=.*/POSTGRES_PASSWORD=$(openssl rand -hex 24)/" .env
sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=$(openssl rand -hex 32)/" .env
chmod 600 .env
mkdir -p downloads
# Edit PUBLIC_URL in .env if using a domain or a remote host.
docker compose up -d --build
docker compose ps
```

Compose stores PostgreSQL data in `postgres-data`, waits for database readiness, and
binds DataCat to `127.0.0.1:3000` by default. Use a reverse proxy for HTTPS. Only set
`BIND_ADDRESS=0.0.0.0` if you have appropriate firewall rules. Never expose PostgreSQL.
`docker compose down` preserves data; **`down -v` destroys data**.

After setup, create an API key in the UI and add it as `DATACAT_AGENT_API_KEY` in `.env`.
The optional container agent measures its container, not the full host:

```sh
docker compose --profile agent up -d --build
```

For full host visibility, install the host agent in section 4 instead.

### Choosing telemetry storage

DataCat keeps users, organizations, API keys, monitors and dashboards in PostgreSQL either way.
Spans, logs and metrics go to the storage you choose with `DATACAT_STORAGE`:

| | `postgres` (default) | `clickhouse` |
| --- | --- | --- |
| What you run | PostgreSQL only | PostgreSQL + ClickHouse |
| Best for | Small and medium installs; fewest moving parts | Large data volumes and long time ranges |
| Disk for 102M spans (measured) | 63.7 GB | 4.6 GB |
| 7-day aggregations on 102M spans | seconds to minutes; some 7-day pages run out of memory | 9–20× faster |
| Narrow lookups (one service's errors) | fastest (milliseconds) | slower (hundreds of ms) |
| Under overload | slows down, keeps all data | stays fast, may reset a few connections |
| Retention | hourly deletes of expired rows | table TTLs (drops whole days) |
| Replication | standard PostgreSQL replication | ClickHouse replicas with Keeper |


To use ClickHouse with Compose:

```sh
sed -i "s/^DATACAT_STORAGE=.*/DATACAT_STORAGE=clickhouse/" .env
sed -i "s/^CLICKHOUSE_PASSWORD=.*/CLICKHOUSE_PASSWORD=$(openssl rand -hex 24)/" .env
docker compose --profile clickhouse up -d --build
```

From source, run ClickHouse 24.8 or newer yourself and set `DATACAT_STORAGE=clickhouse`
and `DATACAT_CLICKHOUSE_URL` (plus user and password if set). DataCat creates its tables
on startup. Choose before you send data: switching storage on an existing install starts
with empty telemetry and does not move data that is already stored.

### Option B: from source

Create a non-superuser PostgreSQL owner and database. `createuser --pwprompt` asks for
a password without echoing it; choose your own strong password.

```sh
sudo -u postgres createuser --pwprompt datacat
sudo -u postgres createdb --owner=datacat datacat
pnpm install --frozen-lockfile
BASE_PATH=/ pnpm run build:selfhost
cp .env.example .env
chmod 600 .env
```

Edit `.env`: set `DATABASE_URL` using your database password (URL-encode special
characters), `PUBLIC_URL=http://localhost:3000` for initial local testing, and set
`SESSION_SECRET` to at least 32 random characters. This writes a random secret directly:

```sh
sed -i "s/^SESSION_SECRET=.*/SESSION_SECRET=$(openssl rand -hex 32)/" .env
set -a
. ./.env
set +a
NODE_ENV=production pnpm start
```

Do not run as root. The schema is automatically created/upgraded, inside a transaction
with an advisory lock, **before** the listener opens. The DB user needs CREATE/ALTER
permissions on its own schema. Failed migrations abort startup rather than serving a
half-initialized app. `datacat_migrations` records applied versions. Existing databases
receive the nullable password hash column without deleting telemetry. Back up before
every upgrade; do not use development `drizzle-kit push --force` in production.

### Optional systemd service

Create a dedicated `datacat` OS user, put the checkout at `/srv/datacat`, and store the
required environment variables in `/etc/datacat/server.env` owned by root, mode 0600.
Use an absolute path to the installed Node executable. Example
`/etc/systemd/system/datacat.service`:

```ini
[Unit]
Description=DataCat observability server
After=network-online.target postgresql.service
Wants=network-online.target
[Service]
User=datacat
Group=datacat
WorkingDirectory=/srv/datacat
Environment=NODE_ENV=production
EnvironmentFile=/etc/datacat/server.env
ExecStart=/usr/bin/node --enable-source-maps /srv/datacat/artifacts/api-server/dist/index.mjs
Restart=on-failure
NoNewPrivileges=true
PrivateTmp=true
[Install]
WantedBy=multi-user.target
```

Then `sudo systemctl daemon-reload && sudo systemctl enable --now datacat`.
Use `/api/healthz` as a liveness check and `/api/readyz` as a readiness check. Readiness requires PostgreSQL and, when `DATACAT_STORAGE=clickhouse`, ClickHouse to respond to a query; it returns HTTP 503 while either required store is unavailable.

## 2. Configuration reference

All server configuration lives in environment variables. The server does not
automatically load `.env`; Compose does, and source users can source it as above or
use systemd `EnvironmentFile`.

| Variable | Default / purpose |
| --- | --- |
| `DATABASE_URL` | **Required.** PostgreSQL connection URL. |
| `PORT` | `3000`, HTTP listener. In Compose this controls the published host port; the container listens on 3000. |
| `PUBLIC_URL` | Canonical external origin, e.g. `https://observe.example.com`. Used for invite links, installer and in-app documentation. **Required when `NODE_ENV=production`**; in development it falls back to the request origin. No path prefix. |
| `SESSION_SECRET` | **Required in production**, at least 32 random characters. Signs session cookies. Changing it signs browser sessions out. |
| `DATACAT_RETENTION_DAYS` | `15`, positive telemetry retention window. Legacy `RETENTION_DAYS` is accepted with lower priority. With PostgreSQL, cleanup runs hourly; with ClickHouse it is a table TTL. |
| `DATACAT_STORAGE` | `postgres`. Telemetry storage: `postgres` or `clickhouse` (see "Choosing telemetry storage"). App data always stays in PostgreSQL. |
| `DATACAT_CLICKHOUSE_URL` | `http://127.0.0.1:8123`. ClickHouse HTTP endpoint, used when `DATACAT_STORAGE=clickhouse`. |
| `DATACAT_CLICKHOUSE_DB` / `DATACAT_CLICKHOUSE_USER` / `DATACAT_CLICKHOUSE_PASSWORD` | `datacat` / `default` / empty. ClickHouse database (created on startup) and credentials. |
| `DATACAT_CLICKHOUSE_CLUSTER` | Empty. Optional ClickHouse cluster name: tables are created as replicated tables `ON CLUSTER` (needs ClickHouse Keeper). |
| `DATACAT_BACKGROUND_JOBS` | `true`. Set `false` on extra API processes that share one database so monitors are evaluated and notifications sent by exactly one process. |
| `DATACAT_MAX_BODY_MB` | `16`. Maximum intake request body (compressed); larger requests get 413. |
| `DATACAT_MAX_DECOMPRESSED_MB` | `64`. Maximum decompressed intake payload (protects against gzip/zstd bombs); 413 when exceeded. |
| `DATACAT_MAX_ATTRIBUTE_CHARS` / `DATACAT_MAX_LOG_MESSAGE_CHARS` | `25000` / `262144`. Longer span/log attribute values and log messages are truncated before storage (records keep at most 500 attributes). |
| `DATACAT_REDACTION` | `on`. Masks card numbers, bearer tokens, secret key/value pairs, AWS keys, JWTs, private keys and secret-named attributes in logs and spans before storage; `off` disables. See `bench/security/README.md`. |
| `DATACAT_REDACT_EMAILS` / `DATACAT_REDACT_PATTERNS` / `DATACAT_REDACT_KEYS` | `false` / empty / empty. Also mask emails; extra regexes separated by `;;`; extra attribute names to mask (comma-separated). |
| `DATACAT_SETUP_TOKEN` | Empty. Token required to complete first-run setup. When empty, a random token is generated and printed in the log at startup. |
| `DATACAT_CUMULATIVE_STREAMS_MAX` | `500000` (minimum 1000). How many cumulative OTLP metric streams are remembered for delta conversion; the oldest are forgotten past this. |
| `DATACAT_TRUST_PROXY` | Unset (trust no proxy). Set to the number of reverse proxies in front of DataCat (usually `1`), or an Express trust-proxy value, so client addresses and HTTPS are read from `X-Forwarded-*`. Leave unset when DataCat is reached directly. |
| `DATACAT_ALLOW_PRIVATE_WEBHOOKS` | `false`. Webhook and Slack channels may not target loopback, private, link-local or metadata addresses, and redirects are not followed. Set `true` for receivers on your own network. |
| `DATACAT_CLICKHOUSE_ASYNC_INSERT` | `1`. ClickHouse async inserts; each request still waits for the insert to be acknowledged. |
| `DATACAT_STATS_FLUSH_MS` | `10000`. How often APM rollups are written (PostgreSQL storage). |
| `NODE_ENV` | Set to `production`; development enables pretty logging. |
| `LOG_LEVEL` | `info`. |
| `DATACAT_UI_DIR` | Absolute built UI directory; defaults to `artifacts/web/dist` relative to the API bundle. |
| `DATACAT_DOWNLOADS_DIR` | Absolute release asset directory; defaults to `artifacts/api-server/downloads`. Compose uses `/app/downloads`. |
| `DATACAT_DOWNLOAD_URL` | Optional base URL containing agent binaries and `SHA256SUMS`; defaults to `${PUBLIC_URL}/downloads`. Can also be set when running the installer. |
| `API_PROXY` | UI development only: API origin for Vite's `/api` proxy. |
| `BASE_PATH` | UI build base, `/` for supported single-origin deployments. |

Compose-only settings: `POSTGRES_PASSWORD` (required), `CLICKHOUSE_PASSWORD` (with the `clickhouse` profile), `BIND_ADDRESS` (127.0.0.1),
`DATACAT_AGENT_API_KEY` (optional agent profile).

There are **no required webhook/SMTP environment variables**. Configure webhook and
Slack incoming-webhook channels per organization in the UI. Email delivery is not
implemented; monitor mentions without a configured channel are recorded in-app.
Webhook destination URLs and optional headers are sensitive database contents.

## 3. Create the administrator and invite members

1. Visit `PUBLIC_URL`. With zero users, DataCat shows **Create your admin account +
   organization**. Enter the organization, email, and a password of 12–256 characters.
   Setup also asks for the **setup token**: `DATACAT_SETUP_TOKEN` if you set it, otherwise a random
   token the server prints in its log at startup (`docker compose logs datacat | grep "setup token"`).
2. The first account is an administrator; setup is locked thereafter.
3. Under **Organization Settings → API Keys**, create a key for agents and SDKs. Only admins can
   create, view or revoke keys and notification channels. Application keys are shown once, when created.
4. Under **Users**, invite an email and copy its link. Share it using a private channel.
   Opening the link lets a new member set their password. Links expire in 30 days and
   are consumed once; they are not permanent bearer-login URLs.
5. Members log in with email/password at `/login`. Sign out using the account menu.

Passwords use randomly salted scrypt, never plaintext. Opaque sessions live in
PostgreSQL, expire in seven days, and use HTTP-only SameSite=Lax cookies. HTTPS
`PUBLIC_URL` enables Secure cookies; explicit HTTP URLs support local deployments.
Local login is throttled per IP (set `DATACAT_TRUST_PROXY` behind a reverse proxy so the
real client address is used). Cookie-authenticated changes must come from DataCat's own origin.
There is currently no email/password-reset service; keep administrator credentials
safe and follow your organization's controlled account recovery procedures.

### HTTPS

Terminate TLS with Caddy/nginx/your load balancer and proxy to `127.0.0.1:3000`.
Set `PUBLIC_URL=https://observe.example.com` and forward the original scheme and host.
The API trusts proxy headers, so restrict direct network access to trusted proxies.
Example Caddyfile:

```caddyfile
observe.example.com {
    reverse_proxy 127.0.0.1:3000
}
```

## 4. Release assets and host agent

Download the matching release assets and `SHA256SUMS` from your project's GitHub
release into `downloads/` (Compose) or `artifacts/api-server/downloads/` (source).
To build your own releases with Go 1.26.11+:

```sh
DESTDIR="$PWD/dist/downloads" bash agent/release.sh
# Includes linux/amd64, linux/arm64, darwin/arm64 and darwin/amd64.
mkdir -p artifacts/api-server/downloads
cp dist/downloads/* artifacts/api-server/downloads/
# For Compose instead:
mkdir -p downloads
cp dist/downloads/* downloads/
```

`TARGETS=linux/arm64` restricts builds; `DESTDIR` can be outside the repository.
The script runs unit tests and produces SHA-256 checksums. Tag workflow
`.github/workflows/release.yml` also packages the Node SDK and Python sdist/wheel.
Tags should correspond to the versions declared in the agent manifest and SDK metadata.

On the machine you want to observe, put an API key in the environment using a protected
secret store (do not put literal keys in shell history):

```sh
curl -fsSL https://observe.example.com/install.sh -o /tmp/datacat-install.sh
# Review /tmp/datacat-install.sh, then:
DATACAT_API_KEY="$YOUR_API_KEY" sh /tmp/datacat-install.sh
```

The installer detects OS/architecture, verifies the binary, installs under
`/opt/datacat-agent`, writes mode-0600 `/etc/datacat/datacat.yaml`, and starts a service
on systemd Linux. macOS uses the matching Darwin binary but requires manual startup (or
your own launchd service). Existing configuration is preserved.

Verification: the server computes the SHA-256 of each agent binary it hosts and writes it
into the installer, so the checksum does not come from the same download as the binary.
With `DATACAT_DOWNLOAD_URL` pointing elsewhere, the installer uses that source's
`SHA256SUMS` and refuses plain-HTTP downloads from another host unless you pin
`DATACAT_AGENT_SHA256`. Releases built by this project's workflow carry a signed build
attestation; with the GitHub CLI installed, `DATACAT_VERIFY_REPO=<owner>/<repo>` makes
the installer check it (`gh attestation verify`). Serve the installer over HTTPS.

Host metrics appear within a minute. Add log paths/services under `logs` in the YAML
and restart **only your own installed agent**. OTLP ports 4317/4318 and compatible
tracer/StatsD ports bind locally by default; never expose them to untrusted networks.
See [agent configuration](../agent/datacat.example.yaml).

## 5. Instrument a Node.js app

Node 22.15+ is required by the current library. SDKs need not be published to npm:

```sh
# On the DataCat build machine; put the resulting .tgz in the served downloads directory.
cd sdks/node
npm pack --pack-destination ../../artifacts/api-server/downloads
# In your application directory:
npm install https://observe.example.com/downloads/datacat-trace-0.1.0.tgz
DATACAT_SERVICE=checkout node -r @datacat/trace/init app.js
```

Initialize before importing frameworks and loggers. With a local agent, export goes
to `http://localhost:4318`. For agentless use:

```sh
DATACAT_SERVICE=checkout DATACAT_URL=https://observe.example.com \
  DATACAT_API_KEY="$YOUR_API_KEY" node -r @datacat/trace/init app.js
```

`DATACAT_URL` is the origin **without** `/otlp`. Structured Pino/Winston/Bunyan logs
ship with trace correlation; `console.log` is not automatically shipped. See the
[Node SDK guide](../sdks/node/README.md).

## 6. Instrument a Python app

Use Python 3.10+ and a virtual environment. Installing directly from source does not
require a public package registry release:

```sh
python3 -m venv .venv
. .venv/bin/activate
pip install '/path/to/datacat/sdks/python[instrumentation]'
DATACAT_SERVICE=checkout datacat-run python app.py
```

Or build a wheel (`pip install build && python -m build sdks/python`) and serve it
alongside the agent, then `pip install` that wheel URL. Install instrumentation
extras/framework dependencies appropriate for your app. For agentless use:

```sh
DATACAT_SERVICE=checkout DATACAT_URL=https://observe.example.com \
  DATACAT_API_KEY="$YOUR_API_KEY" datacat-run python app.py
```

Set your root logger to INFO to include INFO messages. See the
[Python SDK guide](../sdks/python/README.md). Confirm services in **APM**, records in
**Logs**, and metrics in **Metrics Explorer**.

## 7. Create a monitor with a webhook

1. In **Organization Settings → Notification Channels**, create a **webhook** named
   `oncall` with your HTTPS receiver URL. Optional headers support receiver credentials.
2. In **Monitors → New Monitor**, choose a metric query such as
   `avg(last_5m):avg:system.cpu.user{*} > 80` (CPU metrics are percentages; pick a metric
   your agent actually emits in Metrics Explorer). Set warning/critical thresholds.
3. Add `@webhook-oncall` to the message and save. Slack channels use `@slack-name`.
4. Trigger the condition in a test environment. The evaluator checks every 30 seconds,
   records events and sends JSON containing monitor/state/value/tags. Check notification
   history and Events for delivery failures.

## 8. Operations, backup and upgrades

- Back up with `pg_dump` and test `pg_restore` into a separate DB. Backups include
  session tokens, API keys, invite tokens and webhook credentials: encrypt them.
- Persist PostgreSQL and release downloads. Do not rebuild database state from logs.
- Before upgrades, back up; rebuild UI/API together, restart the DataCat service, and
  verify `/api/healthz` and `/api/readyz`. Migrations are additive; do not assume binary downgrades are safe.
- Retention deletes metrics, logs and spans hourly; use PostgreSQL vacuum/monitoring and
  disk alerts. Events and configuration are not currently automatically expired.
- No cron or SMTP service is required.
- Never run test tooling against a production database. `scripts/e2e.sh` requires an
  empty, separately deployed test instance.
