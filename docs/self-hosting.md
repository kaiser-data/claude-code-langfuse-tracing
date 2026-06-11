# Self-hosting Langfuse (prepared migration)

A prepared plan for moving tracing off Langfuse Cloud onto your own box — a
small VPS or a Raspberry Pi — when Cloud's free tier stops being enough. Until
then, nothing here needs to run; the hook is already wired so the cutover is
three config values.

---

## When to migrate (how long Cloud can grow)

Langfuse Cloud's free **Hobby** tier is metered per ingested unit (every
generation and tool span counts) and limits data retention/history. Check your
burn rate before deciding:

- **Langfuse UI → Settings → Usage** shows units used this billing month.
- This hook emits roughly *one trace per turn*, containing one generation plus
  one span per tool call — a busy coding session can easily produce hundreds of
  units. With tracing enabled globally across all projects, expect tens of
  thousands of units per month.

Rules of thumb:

| Signal | Action |
|---|---|
| Usage consistently < 50% of the monthly quota | Stay on Cloud, revisit monthly |
| Hitting the quota or wanting > 30-day history | Migrate (this doc) or pay for Core |
| Tracing sensitive/client work | Migrate regardless of quota |

Old traces do **not** migrate automatically. The clean approach: treat the
cutover as a new epoch — Cloud keeps the history until it expires, the
self-hosted box owns everything after. (Bulk export via the Langfuse API is
possible but rarely worth it for hobby data.)

---

## Hardware: Pi vs VPS

Langfuse v3 is a five-service stack: **web + worker + Postgres + ClickHouse +
Redis + MinIO** (S3-compatible blob store). ClickHouse is the heavy one. All
images ship multi-arch (amd64 + arm64), so both options work.

| | Raspberry Pi 4/5 with SSD | Small VPS (e.g. Hetzner CAX21/CX32, 4 vCPU / 8 GB) |
|---|---|---|
| Cost | hardware you may already own | ~€7–12 / month |
| RAM headroom | the stack idles at ~3–4 GB → needs the **8 GB** model, ideally dedicated | comfortable |
| Disk | SSD over USB3/NVMe is fine; **never** an SD card (ClickHouse will shred it) | included SSD |
| Network | LAN-only by default → expose via Tailscale | reachable from anywhere; still front with Tailscale or a reverse proxy + TLS |
| Backups | yours to script | snapshot button |
| Verdict | workable for one-person volume on an 8 GB board | the boring, recommended choice |

Pi fine print:

- **8 GB board, mostly dedicated**: works. A Pi 4's CPU makes the UI and
  dashboards sluggish but ingestion (what the hook needs) is light.
- **4 GB board, or sharing with other services** (an OpenClaw/Tailscale Pi
  already running something): not recommended as-is. ClickHouse alone wants
  several GB; under memory pressure it OOMs and takes ingestion with it. If
  you must, cap it in `docker-compose.yml`
  (`max_server_memory_usage_to_ram_ratio: 0.4` plus a container `mem_limit`)
  and accept slower queries — but a small VPS is less fragile.

**Minimum spec either way:** 2 vCPU, 8 GB RAM (4 GB works for very light use
with swap, but ClickHouse OOMs are ugly), 40 GB+ disk.

---

## Setting up the server

```bash
# on the Pi / VPS
git clone https://github.com/langfuse/langfuse.git
cd langfuse

# REQUIRED: change every secret in docker-compose.yml / .env before first boot:
#   POSTGRES_PASSWORD, CLICKHOUSE_PASSWORD, REDIS_AUTH,
#   MINIO_ROOT_PASSWORD, NEXTAUTH_SECRET, SALT, ENCRYPTION_KEY
# (generate with: openssl rand -hex 32)

docker compose up -d
```

First boot takes a few minutes (migrations). Then open `http://<host>:3000`,
create an account, an organization, a project, and generate an API key pair
(`pk-lf-…` / `sk-lf-…`).

**Access**: simplest secure option is Tailscale on the box — the UI and the
ingestion endpoint are then reachable at `http://<tailscale-name>:3000` from
every machine in your tailnet, with zero ports exposed to the internet. The
hook's 5-second flush cap tolerates a sleepy WireGuard link fine. If you skip
Tailscale on a public VPS, put Caddy/Traefik with TLS in front and never expose
`:3000` raw.

**Backups**: nightly `docker compose exec postgres pg_dump …` plus a ClickHouse
volume snapshot (or VPS snapshots) is enough at this scale.

---

## The cutover (≈ 3 minutes)

The hook reads everything from the environment, so no code changes — only the
three values set during install change.

1. **Point the hook at the new host** — in `~/.claude/settings.json` (`env`
   block, where tracing is enabled globally):

   ```json
   "TRACE_TO_LANGFUSE": "true",
   "LANGFUSE_PUBLIC_KEY": "pk-lf-<new key from your instance>",
   "LANGFUSE_BASE_URL": "http://<tailscale-name-or-vps-host>:3000"
   ```

2. **Swap the secret in the Keychain** (the wrapper reads it from there on
   every Stop):

   ```bash
   security delete-generic-password -a "$USER" -s LANGFUSE_SECRET_KEY
   security add-generic-password -a "$USER" -s LANGFUSE_SECRET_KEY -w 'sk-lf-<new secret>'
   ```

3. **Restart Claude Code sessions** (running sessions keep the old env), then
   verify:

   ```bash
   ./scripts/verify.sh   # or run any session and check the new UI for a trace
   ```

Rollback is the same three values in reverse — Cloud keys + Cloud URL.

### Gotchas

- `LANGFUSE_BASE_URL` must **not** have a trailing slash.
- If the box is HTTP-only inside the tailnet, that's fine — traffic is
  WireGuard-encrypted end to end. Use HTTPS the moment anything is publicly
  reachable.
- Per-session state in `~/.claude/state/langfuse_state.json` tracks byte
  offsets per transcript, not per backend — sessions that were mid-flight at
  cutover continue seamlessly on the new backend, but their earlier turns stay
  in Cloud.
- If the self-hosted box is down, the hook fails open: the session is never
  blocked, and unsent turns are picked up on a later Stop as long as the
  transcript file still exists.
