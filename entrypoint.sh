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

# Stay as the supervisor so SIGTERM (redeploy) reaches the wrapper and the
# background jobs. update-models watches models.md under the state dir.
# r2-sync, when R2_BUCKET is set, needs the signal so it can run a final sync
# before exit.
gosu openclaw /app/bin/update-models --watch "${OPENCLAW_STATE_DIR:-/data/.openclaw}/workspace/models.md" &
MODELS_PID=$!

SYNC_PID=""
if [ -n "${R2_BUCKET:-}" ]; then
  gosu openclaw /app/bin/r2-sync &
  SYNC_PID=$!
fi

gosu openclaw node src/server.js &
APP_PID=$!

trap 'kill -TERM "$APP_PID" 2>/dev/null || true' TERM INT

APP_CODE=0
while kill -0 "$APP_PID" 2>/dev/null; do
  wait "$APP_PID" && APP_CODE=0 || APP_CODE=$?
done

kill -TERM "$MODELS_PID" 2>/dev/null || true
if [ -n "$SYNC_PID" ]; then
  kill -TERM "$SYNC_PID" 2>/dev/null || true
fi
wait "$MODELS_PID" 2>/dev/null || true
if [ -n "$SYNC_PID" ]; then
  wait "$SYNC_PID" 2>/dev/null || true
fi
exit "$APP_CODE"
