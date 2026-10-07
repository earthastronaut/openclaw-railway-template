#!/bin/bash
# Two-way sync between the OpenClaw workspace and a Cloudflare R2 bucket
# (rclone bisync), with git snapshots of the workspace for rollback.
#
# Watchdog mode: triggers on file changes under /data/.openclaw/workspace,
# with a quiet period to batch rapid changes.
#
# Opt-in: does nothing unless R2_BUCKET is set.
#
# Env:
#   R2_BUCKET             bucket name (required to enable)
#   R2_ACCESS_KEY_ID      R2 API token access key (required)
#   R2_SECRET_ACCESS_KEY  R2 API token secret (required)
#   R2_ACCOUNT_ID         Cloudflare account id (required unless R2_ENDPOINT set)
#   R2_ENDPOINT           override endpoint URL
#   R2_PREFIX             optional key prefix inside the bucket
#   R2_DEBOUNCE_SECS      quiet period after last file change before syncing (default 5)
#   R2_GIT_REMOTE         optional private git remote URL; snapshots are pushed to it
#
# Pause: `touch /data/.r2-sync-paused` (remove the file to resume).

set -u

if [ -z "${R2_BUCKET:-}" ]; then
  exit 0
fi

DATA_DIR="${R2_DATA_DIR:-/data}"
STATE_DIR="${OPENCLAW_STATE_DIR:-$DATA_DIR/.openclaw}"
WORKSPACE_DIR="${OPENCLAW_WORKSPACE_DIR:-$STATE_DIR/workspace}"
DEBOUNCE_SECS="${R2_DEBOUNCE_SECS:-5}"
PREFIX="${R2_PREFIX:-}"
PREFIX="${PREFIX#/}"
PREFIX="${PREFIX%/}"
PAUSE_FLAG="$DATA_DIR/.r2-sync-paused"
WORKDIR="$DATA_DIR/.rclone-bisync"
LOG_FILE="$STATE_DIR/r2-sync.log"
FILTERS_FILE="$WORKDIR/filters.txt"
LAST_CHANGE_FILE="/tmp/r2-sync-last-change"

mkdir -p "$STATE_DIR" "$WORKSPACE_DIR" "$WORKDIR"

log() {
  local line
  line="[r2-sync] $(date -u +%FT%TZ) $*"
  echo "$line"
  echo "$line" >> "$LOG_FILE" 2>/dev/null || true
}

# Keep the log from growing without bound (~1MB).
rotate_log() {
  if [ -f "$LOG_FILE" ] && [ "$(wc -c < "$LOG_FILE")" -gt 1048576 ]; then
    tail -n 2000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
}

if [ -z "${R2_ACCESS_KEY_ID:-}" ] || [ -z "${R2_SECRET_ACCESS_KEY:-}" ]; then
  log "R2_BUCKET is set but R2_ACCESS_KEY_ID / R2_SECRET_ACCESS_KEY are missing; sync disabled"
  exit 0
fi

ENDPOINT="${R2_ENDPOINT:-}"
if [ -z "$ENDPOINT" ]; then
  if [ -z "${R2_ACCOUNT_ID:-}" ]; then
    log "Set R2_ACCOUNT_ID (or R2_ENDPOINT); sync disabled"
    exit 0
  fi
  ENDPOINT="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
fi

# rclone remote "r2" configured purely from env (no config file).
export RCLONE_CONFIG_R2_TYPE=s3
export RCLONE_CONFIG_R2_PROVIDER=Cloudflare
export RCLONE_CONFIG_R2_ACCESS_KEY_ID="$R2_ACCESS_KEY_ID"
export RCLONE_CONFIG_R2_SECRET_ACCESS_KEY="$R2_SECRET_ACCESS_KEY"
export RCLONE_CONFIG_R2_ENDPOINT="$ENDPOINT"
export RCLONE_CONFIG_R2_REGION=auto
export RCLONE_CONFIG_R2_NO_CHECK_BUCKET=true
export RCLONE_CONFIG_R2_ACL=private

REMOTE="r2:${R2_BUCKET}"
[ -n "$PREFIX" ] && REMOTE="${REMOTE}/${PREFIX}"

cat > "$FILTERS_FILE" <<'EOF'
- .git/**
- node_modules/**
- .obsidian/**
- .trash/**
- _remotely-save-metadata-on-remote.json
- .DS_Store
- *.tmp
EOF

# --- git snapshots ----------------------------------------------------------

GIT=(git -C "$WORKSPACE_DIR" -c user.name="openclaw-r2-sync" -c user.email="r2-sync@localhost")

git_init() {
  if [ ! -d "$WORKSPACE_DIR/.git" ]; then
    "${GIT[@]}" init -q -b main >/dev/null 2>&1 || "${GIT[@]}" init -q >/dev/null 2>&1
    log "initialised git repo in $WORKSPACE_DIR"
  fi
  # Local-only ignores: kept out of the synced tree.
  mkdir -p "$WORKSPACE_DIR/.git/info"
  for pat in 'node_modules/' '*.tmp' '.obsidian/' '.trash/' '.DS_Store'; do
    grep -qxF "$pat" "$WORKSPACE_DIR/.git/info/exclude" 2>/dev/null \
      || echo "$pat" >> "$WORKSPACE_DIR/.git/info/exclude"
  done
  if [ -n "${R2_GIT_REMOTE:-}" ]; then
    if "${GIT[@]}" remote get-url r2backup >/dev/null 2>&1; then
      "${GIT[@]}" remote set-url r2backup "$R2_GIT_REMOTE"
    else
      "${GIT[@]}" remote add r2backup "$R2_GIT_REMOTE"
    fi
  fi
}

git_snapshot() {
  local label="$1"
  "${GIT[@]}" add -A >/dev/null 2>&1 || return 0
  if ! "${GIT[@]}" diff --cached --quiet 2>/dev/null; then
    if "${GIT[@]}" commit -q -m "$label $(date -u +%FT%TZ)" >/dev/null 2>&1; then
      log "git snapshot: $label"
      if [ -n "${R2_GIT_REMOTE:-}" ]; then
        # Output suppressed: the remote URL may contain a token.
        "${GIT[@]}" push -q r2backup HEAD:refs/heads/main >/dev/null 2>&1 \
          || log "git push to R2_GIT_REMOTE failed (will retry on next snapshot)"
      fi
    fi
  fi
  "${GIT[@]}" gc --auto -q >/dev/null 2>&1 || true
}

# --- bisync -----------------------------------------------------------------

BISYNC_COMMON=(
  --workdir "$WORKDIR"
  --filters-file "$FILTERS_FILE"
  --conflict-resolve newer
  --conflict-loser num
  --resilient
  --recover
  --max-delete 25
  --create-empty-src-dirs
  --fast-list
)

have_listings() {
  ls "$WORKDIR"/*.lst >/dev/null 2>&1
}

run_bisync() {
  local mode="${1:-normal}" out rc
  if [ "$mode" = "resync" ]; then
    log "running initial resync (merging local and R2, newest wins)"
    out=$(rclone bisync "$WORKSPACE_DIR" "$REMOTE" "${BISYNC_COMMON[@]}" --resync --resync-mode newer 2>&1)
    rc=$?
  else
    out=$(rclone bisync "$WORKSPACE_DIR" "$REMOTE" "${BISYNC_COMMON[@]}" 2>&1)
    rc=$?
  fi
  if [ $rc -ne 0 ]; then
    log "bisync exited $rc: $(echo "$out" | tail -n 8 | tr '\n' ' ')"
  fi
  return $rc
}

sync_cycle() {
  if [ -e "$PAUSE_FLAG" ]; then
    log "paused ($PAUSE_FLAG exists); skipping"
    return 0
  fi

  git_snapshot "pre-sync"

  if ! have_listings; then
    run_bisync resync
  else
    run_bisync normal
    local rc=$?
    # 7 = critical error requiring --resync (lost state, filter change, ...)
    if [ $rc -eq 7 ]; then
      run_bisync resync
    fi
  fi

  git_snapshot "post-sync"
}

# --- watchdog: inotifywait loop --------------------------------------------------

STOP=0
DEBOUNCE_PID=""
on_stop() {
  STOP=1
  [ -n "$DEBOUNCE_PID" ] && kill "$DEBOUNCE_PID" 2>/dev/null
}
trap on_stop TERM INT

log "starting: remote=$REMOTE debounce=${DEBOUNCE_SECS}s workspace=$WORKSPACE_DIR"
git_init

# Check for inotifywait; fall back to interval mode if not available.
if ! command -v inotifywait &>/dev/null; then
  log "warning: inotifywait not found; falling back to interval mode (60s)"
  while [ "$STOP" -eq 0 ]; do
    rotate_log
    sync_cycle
    [ "$STOP" -eq 1 ] && break
    sleep 60 &
    DEBOUNCE_PID=$!
    wait "$DEBOUNCE_PID" 2>/dev/null
    DEBOUNCE_PID=""
  done
else
  # Watchdog mode: trigger sync on file changes, debounced.
  on_change() {
    rm -f "$LAST_CHANGE_FILE"
    touch "$LAST_CHANGE_FILE"
    # Debounce: wait for quiet period before syncing.
    if [ -n "$DEBOUNCE_PID" ]; then
      kill "$DEBOUNCE_PID" 2>/dev/null || true
    fi
    sleep "$DEBOUNCE_SECS" &
    DEBOUNCE_PID=$!
    wait "$DEBOUNCE_PID" 2>/dev/null || true
    DEBOUNCE_PID=""
    if [ "$STOP" -eq 0 ]; then
      rotate_log
      sync_cycle
    fi
  }
  
  export -f on_change rotate_log sync_cycle log git_snapshot run_bisync git_init have_listings
  export STOP DEBOUNCE_PID DATA_DIR STATE_DIR WORKSPACE_DIR WORKDIR LOG_FILE FILTERS_FILE
  export PAUSE_FLAG ENDPOINT REMOTE WORKDIR BISYNC_COMMON GIT
  export WORKSPACE_DIR REMOTE WORKDIR FILTERS_FILE PAUSE_FLAG LOG_FILE STATE_DIR
  export R2_GIT_REMOTE
  
  # Watch workspace for changes: ignore .git and common noise.
  # Trigger on: create, write, delete, moved_to (catching file moves).
  inotifywait -m -r \
    --exclude '(\\.git|node_modules|__pycache__|.obsidian|.trash|.DS_Store|.*\\.tmp)' \
    -e create,write,delete,moved_to,attrib \
    "$WORKSPACE_DIR" 2>/dev/null | while read -r dir action file; do
    if [ "$STOP" -eq 0 ]; then
      on_change
    else
      break
    fi
  done
fi

log "stop requested; running final sync"
# Ignore further signals so the final sync can finish.
trap '' TERM INT
sync_cycle
log "exiting"
