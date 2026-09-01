# bisalpro — Hardening & HA Deploy Guide

This directory contains the operational artifacts that go with the code
hardening patches applied to `biisal/`. Goal: survive intermittent Telegram
latency, stop premature aborts, and actually run both app instances behind a
real Nginx load balancer.

## What the code patches do

| Phase | File | Change |
|------|------|--------|
| 2.1 | `biisal/server/stream_routes.py` | `get_file_properties` timeout `15` → `Var.FILE_PROPERTIES_TIMEOUT` (default **60s**) |
| 2.2 | `biisal/utils/custom_dl.py` | chunk `GetFile` now retries `TG_CHUNK_RETRY` times on timeout/network errors with linear `TG_CHUNK_BACKOFF` backoff, logging offset + client index + retry count. No more silent `None` on first transient error |
| 2.3 | `biisal/vars.py` | new env-driven vars: `FILE_PROPERTIES_TIMEOUT=60`, `TG_CHUNK_RETRY=3`, `TG_CHUNK_BACKOFF=2`, `PREPARE_REQUEST_TIMEOUT_MS=90000` |
| 3 | `biisal/utils/file_properties.py` | `get_file_ids` raises `FIleNotFound` cleanly when `message.empty`, `media is None`, or `file_id is None` — metadata is only set *after* the guards (fixes `'NoneType' object has no attribute 'file_size'`) |
| 4 | `biisal/template/prepare.html` | both `45000ms` abort timers replaced with a configurable `PREPARE_TIMEOUT_MS` injected from `Var.PREPARE_REQUEST_TIMEOUT_MS` (default **90000ms**). Retry logic kept |

All four Python files pass `python -m py_compile`.

## Files here

- `bisalpro-8080.service` — systemd unit, instance A (`/opt/bisalpro`, PORT 8080)
- `bisalpro-8081.service` — systemd unit, instance B (`/opt/bisalprox`, PORT 8081)
- `nginx-bisalpro.conf` — upstream load balancer for both public domains
- `env.instance-a.example` / `env.instance-b.example` — identical envs except `PORT` (+ optional `SERVE_DOMAIN`)
- `deploy.sh` — backup → update → restart → health-check → auto-rollback, one node at a time

---

## Routing decision (was an open question)

Default shipped config = **`least_conn` balancing across both backends for both
domains** (resilience-first). If one node has a Telegram/flood problem,
`max_fails=3 fail_timeout=30s` pulls it out so **new** requests hit the healthy
node. `least_conn` is used instead of plain round-robin because streams are
long-lived.

> Note: this does **not** migrate an already-running stream between backends —
> it only routes new requests.

**If you prefer sticky-by-host** (`web` → 8080, `webx` → 8081): set
`SERVE_DOMAIN=web` in instance A's `.env` and `SERVE_DOMAIN=webx` in instance B's,
then in `nginx-bisalpro.conf` replace the single `server` block with two
`server` blocks each `proxy_pass`-ing to a fixed `127.0.0.1:8080` / `:8081`.

---

## First-time setup (exact commands, run as root)

```bash
# 0. dirs + logs
mkdir -p /var/log/bisalpro /opt/bisalpro-backups

# 1. two deliberate checkouts on the SAME commit
git clone https://github.com/tk22kalal/bisalpro.git /opt/bisalpro   || true
git clone https://github.com/tk22kalal/bisalpro.git /opt/bisalprox  || true
for d in /opt/bisalpro /opt/bisalprox; do
  ( cd "$d" && git fetch --all && git checkout main && git reset --hard origin/main )
done

# 2. venvs + PINNED deps (no pip install -U)
for d in /opt/bisalpro /opt/bisalprox; do
  python3 -m venv "$d/venv"
  "$d/venv/bin/pip" install --upgrade pip
  "$d/venv/bin/pip" install -r "$d/requirements.txt"
done

# 3. env files — identical except PORT (+ optional SERVE_DOMAIN)
cp /opt/bisalpro/deploy/env.instance-a.example  /opt/bisalpro/.env
cp /opt/bisalpro/deploy/env.instance-b.example  /opt/bisalprox/.env
chmod 600 /opt/bisalpro/.env /opt/bisalprox/.env
# now edit both and fill API_ID / API_HASH / BOT_TOKEN / BIN_CHANNEL / DB_CHANNEL /
# OWNER_ID / DATABASE_URL. Keep everything identical EXCEPT PORT.
diff <(grep -v '^PORT\|^SERVE_DOMAIN' /opt/bisalpro/.env | sort) \
     <(grep -v '^PORT\|^SERVE_DOMAIN' /opt/bisalprox/.env | sort) \
  && echo "envs identical except PORT/SERVE_DOMAIN ✅"

# 4. systemd units
cp /opt/bisalpro/deploy/bisalpro-8080.service /etc/systemd/system/
cp /opt/bisalpro/deploy/bisalpro-8081.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now bisalpro-8080 bisalpro-8081

# 5. confirm BOTH answer locally
curl -s http://127.0.0.1:8080/ | head -c 200; echo
curl -s http://127.0.0.1:8081/ | head -c 200; echo

# 6. Nginx upstream (BACK UP existing config first!)
cp /etc/nginx/sites-available/*.conf /opt/bisalpro-backups/ 2>/dev/null || true
cp /opt/bisalpro/deploy/nginx-bisalpro.conf /etc/nginx/sites-available/bisalpro.conf
ln -sf /etc/nginx/sites-available/bisalpro.conf /etc/nginx/sites-enabled/bisalpro.conf
# fix ssl_certificate paths in the file to match your certbot certs, then:
nginx -t && systemctl reload nginx
```

## Routine updates (rollback-safe, one node at a time)

```bash
chmod +x /opt/bisalpro/deploy/deploy.sh
/opt/bisalpro/deploy/deploy.sh both   # A first, validate, then B
# or: deploy.sh a   |   deploy.sh b
```

`deploy.sh` backs up each instance (code + commit hash) before touching it,
restarts, health-checks `/`, and **auto-rolls-back** that instance if it fails.

## Verifying resilience quickly

```bash
# per-instance load / health
curl -s http://127.0.0.1:8080/ | python3 -m json.tool
curl -s http://127.0.0.1:8081/ | python3 -m json.tool

# take one node down, confirm the domain still serves via the other
systemctl stop bisalpro-8081
curl -sI https://web.afrahtafreeh.site/ | head -1
systemctl start bisalpro-8081

# watch retry/backoff + null-guard logs in action
tail -f /var/log/bisalpro/8080.log | grep -Ei 'retry|timeout|giving up|FIleNotFound'
```

## Tuning knobs (env)

| Var | Default | Effect |
|-----|---------|--------|
| `FILE_PROPERTIES_TIMEOUT` | 60 | seconds before trying next client for metadata |
| `TG_CHUNK_RETRY` | 3 | extra retries per chunk on timeout/network error |
| `TG_CHUNK_BACKOFF` | 2 | base seconds between chunk retries (linear) |
| `PREPARE_REQUEST_TIMEOUT_MS` | 90000 | frontend fetch abort timeout |

---

## ⚠️ Latent bug noticed (not changed — outside this task's scope)

In `biisal/server/stream_routes.py`, the admin route `@routes.get("/root-tree")`
is registered **after** the catch-all `@routes.get(r"/{path:.+}")`, so aiohttp
matches the catch-all first and `/root-tree` is effectively unreachable. If you
want that admin page to work, move its route registration above the catch-all
`path_handler`. Left untouched here to avoid changing production routing behavior
without your say-so.
