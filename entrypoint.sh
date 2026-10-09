#!/bin/bash
set -e

# /proc/1/environ is root-only. Login shells source
# /etc/profile.d/container-env.sh, which reads this copy.
mkdir -p /run
cat /proc/self/environ > /run/container.env
chmod 644 /run/container.env

mkdir -p /data/.openclaw
chown -R openclaw:openclaw /data
chmod 700 /data

if [ ! -d /data/.linuxbrew ]; then
  cp -a /home/linuxbrew/.linuxbrew /data/.linuxbrew
fi

rm -rf /home/linuxbrew/.linuxbrew
ln -sfn /data/.linuxbrew /home/linuxbrew/.linuxbrew

# Optional R2 workspace sync. When enabled we keep this shell alive so that a
# SIGTERM (redeploy) can be forwarded to both processes and the sync script
# gets to run its final sync before the container exits.
if [ -n "${R2_BUCKET:-}" ]; then
  gosu openclaw /app/bin/r2-sync &
  SYNC_PID=$!
  gosu openclaw node src/server.js &
  APP_PID=$!

  trap 'kill -TERM "$APP_PID" 2>/dev/null || true' TERM INT

  APP_CODE=0
  while kill -0 "$APP_PID" 2>/dev/null; do
    wait "$APP_PID" && APP_CODE=0 || APP_CODE=$?
  done

  # App is gone: tell the sync script to do its final sync, then wait for it.
  kill -TERM "$SYNC_PID" 2>/dev/null || true
  wait "$SYNC_PID" 2>/dev/null || true
  exit "$APP_CODE"
fi

exec gosu openclaw node src/server.js
