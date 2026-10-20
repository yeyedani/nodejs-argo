#!/usr/bin/env bash
# Idempotent start of the userspace cron daemon (supercronic).
set -u

BASE="/workspace/nezha"
LOCK="${BASE}/.cron.lock"
mkdir -p "$LOCK" 2>/dev/null || exit 0

if [ -f "${LOCK}/pid" ] && kill -0 "$(cat "${LOCK}/pid" 2>/dev/null)" 2>/dev/null; then
    exit 0
fi

rm -rf "$LOCK"
mkdir -p "$LOCK"
setsid nohup "${BASE}/bin/supercronic" -passthrough-logs "${BASE}/crontab" \
    >>"${BASE}/supercronic.log" 2>&1 </dev/null &
echo $! >"${LOCK}/pid"
sleep 2
kill -0 "$(cat "${LOCK}/pid")" 2>/dev/null || { echo "failed to start supercronic"; exit 1; }
echo "supercronic started (pid $(cat "${LOCK}/pid"))"
