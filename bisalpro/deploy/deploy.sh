#!/usr/bin/env bash
# bisalpro one-at-a-time, rollback-safe deploy helper.
# Run as root on the VPS. Edit the CONFIG block if your paths differ.
set -euo pipefail

# ── CONFIG ───────────────────────────────────────────────────────────────────
REPO_URL="https://github.com/tk22kalal/bisalpro.git"
BRANCH="main"
INST_A_DIR="/opt/bisalpro"
INST_B_DIR="/opt/bisalprox"
SVC_A="bisalpro-8080"
SVC_B="bisalpro-8081"
PORT_A=8080
PORT_B=8081
BACKUP_ROOT="/opt/bisalpro-backups"
LOG_DIR="/var/log/bisalpro"
# ─────────────────────────────────────────────────────────────────────────────

STAMP="$(date +%Y%m%d-%H%M%S)"
log() { echo -e "\033[1;36m[$(date +%H:%M:%S)]\033[0m $*"; }
die() { echo -e "\033[1;31mERROR:\033[0m $*" >&2; exit 1; }

backup_instance() {
  local dir="$1" name="$2"
  local dest="$BACKUP_ROOT/$name-$STAMP"
  log "Backing up $dir -> $dest"
  mkdir -p "$BACKUP_ROOT"
  # Snapshot code + current commit + env (env kept 0600)
  cp -a "$dir" "$dest"
  ( cd "$dir" && git rev-parse HEAD 2>/dev/null || echo "no-git" ) > "$dest.commit"
  log "Backup commit: $(cat "$dest.commit")"
  echo "$dest"
}

health_check() {
  local port="$1" tries="${2:-30}"
  log "Health check on 127.0.0.1:$port ..."
  for i in $(seq 1 "$tries"); do
    if curl -fsS "http://127.0.0.1:$port/" >/dev/null 2>&1; then
      log "  OK: :$port answered on attempt $i"
      return 0
    fi
    sleep 2
  done
  return 1
}

update_repo() {
  local dir="$1"
  log "Updating repo in $dir to origin/$BRANCH"
  if [ ! -d "$dir/.git" ]; then
    die "$dir is not a git checkout. Clone first: git clone $REPO_URL $dir"
  fi
  ( cd "$dir"
    git fetch --all --prune
    git checkout "$BRANCH"
    git reset --hard "origin/$BRANCH"
  )
}

install_deps() {
  local dir="$1"
  log "Installing pinned deps in $dir venv"
  [ -d "$dir/venv" ] || python3 -m venv "$dir/venv"
  # Pinned install only — never pip install -U here.
  "$dir/venv/bin/pip" install --upgrade pip >/dev/null
  "$dir/venv/bin/pip" install -r "$dir/requirements.txt"
}

deploy_one() {
  local dir="$1" svc="$2" port="$3" name="$4"
  log "=== Deploying $name ($svc, :$port) ==="
  local backup; backup="$(backup_instance "$dir" "$name")"
  update_repo "$dir"
  install_deps "$dir"
  log "Restarting $svc"
  systemctl restart "$svc"
  if health_check "$port"; then
    log "$name healthy after deploy."
    journalctl -u "$svc" -n 20 --no-pager || true
  else
    log "!! $name FAILED health check — ROLLING BACK to $backup"
    systemctl stop "$svc" || true
    rm -rf "$dir"
    cp -a "$backup" "$dir"
    systemctl start "$svc"
    health_check "$port" 15 && log "Rollback of $name succeeded." \
      || die "Rollback of $name ALSO failed — investigate: journalctl -u $svc -n 100"
    die "Deploy of $name failed and was rolled back."
  fi
}

main() {
  mkdir -p "$LOG_DIR" "$BACKUP_ROOT"
  case "${1:-both}" in
    a)     deploy_one "$INST_A_DIR" "$SVC_A" "$PORT_A" "bisalpro" ;;
    b)     deploy_one "$INST_B_DIR" "$SVC_B" "$PORT_B" "bisalprox" ;;
    both)
      # One node at a time: A first, validate, then B. Traffic stays served by
      # the other node via Nginx during each restart.
      deploy_one "$INST_A_DIR" "$SVC_A" "$PORT_A" "bisalpro"
      log "Instance A confirmed. Proceeding to Instance B..."
      deploy_one "$INST_B_DIR" "$SVC_B" "$PORT_B" "bisalprox"
      ;;
    *) die "Usage: $0 [a|b|both]" ;;
  esac
  log "Done. Nginx upstream state:"
  echo "  curl -s http://127.0.0.1:$PORT_A/ | head -c 200"
  echo "  curl -s http://127.0.0.1:$PORT_B/ | head -c 200"
}

main "$@"
