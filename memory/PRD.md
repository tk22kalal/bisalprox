# PRD — Harden bisalpro Telegram Streamer

## Problem statement
Harden the two-instance bisalpro Telegram file-streaming setup (repo:
github.com/tk22kalal/bisalpro) against slow Telegram responses, null media
lookups, and inconsistent two-deployment state. App: Pyrogram + aiohttp behind
Nginx on Ubuntu/systemd VPS. Instances at /opt/bisalpro (8080) and
/opt/bisalprox (8081).

## Constraints
- Cannot run/verify live here: needs real Telegram API creds + VPS/systemd/Nginx.
- Verified statically: `python -m py_compile` (all 4 files) + `bash -n` (deploy.sh).

## Implemented (2026-06)
- Phase 2.1 `stream_routes.py`: file-properties timeout 15s → `Var.FILE_PROPERTIES_TIMEOUT` (60s).
- Phase 2.2 `custom_dl.py`: per-chunk GetFile retry (TG_CHUNK_RETRY) with linear
  TG_CHUNK_BACKOFF, logs offset/client/retry, no silent None on first transient error.
- Phase 2.3 `vars.py`: FILE_PROPERTIES_TIMEOUT=60, TG_CHUNK_RETRY=3,
  TG_CHUNK_BACKOFF=2, PREPARE_REQUEST_TIMEOUT_MS=90000 (env-driven).
- Phase 3 `file_properties.py`: null guards (message/media/file_id) raise FIleNotFound
  before metadata access.
- Phase 4 `prepare.html`: 45000ms aborts → configurable PREPARE_TIMEOUT_MS (default 90000,
  injected from backend).
- Phase 1/5/6 ops artifacts in `/app/bisalpro/deploy/`: two systemd units, Nginx
  least_conn upstream config, identical env templates (differ only by PORT/SERVE_DOMAIN),
  rollback-safe one-node-at-a-time deploy.sh, README with exact commands,
  harden-code.patch (git apply).

## Backlog / open
- P1: Decide routing — shipped least_conn balancing; sticky-by-host documented as alt.
- P2: Latent bug (not changed): `/root-tree` route registered after catch-all `/{path:.+}`
  → unreachable; move above catch-all if that admin page is needed.
- P2: Confirm both /opt checkouts are on same commit before first cutover.
