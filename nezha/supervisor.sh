#!/usr/bin/env bash
# Nezha agent supervisor for the sandbox (no systemd / no cron available).
# - restarts the agent immediately whenever it exits
# - performs an explicit liveness check every CHECK_INTERVAL (600s) as a heartbeat
# - single instance guaranteed by a lock directory
set -u

BASE="/workspace/nezha"
AGENT="${BASE}/nezha-agent"
CONFIG="${BASE}/config.yml"
AGENT_LOG="${BASE}/agent.log"
SUP_LOG="${BASE}/supervisor.log"
LOCK="${BASE}/.supervisor.lock"
CHECK_INTERVAL=600
RESTART_BACKOFF=10

log() { printf '%s [supervisor] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$SUP_LOG"; }

if ! mkdir "$LOCK" 2>/dev/null; then
    if [ -f "${LOCK}/pid" ] && kill -0 "$(cat "${LOCK}/pid" 2>/dev/null)" 2>/dev/null; then
        echo "supervisor already running (pid $(cat "${LOCK}/pid"))"
        exit 0
    fi
    log "stale lock found, taking over"
fi
echo $$ >"${LOCK}/pid"
trap 'rm -rf "$LOCK"; log "supervisor exiting"' EXIT INT TERM

[ -x "$AGENT" ] || { log "ERROR: agent binary missing at $AGENT"; exit 1; }
[ -f "$CONFIG" ] || { log "ERROR: config missing at $CONFIG"; exit 1; }

log "supervisor started (pid $$), check interval ${CHECK_INTERVAL}s"

restarts=0
while true; do
    log "starting agent"
    nohup "$AGENT" -c "$CONFIG" >>"$AGENT_LOG" 2>&1 &
    pid=$!
    log "agent pid=$pid"
    echo "$pid" >"${BASE}/agent.pid"

    next_check=$(( $(date +%s) + CHECK_INTERVAL ))
    while kill -0 "$pid" 2>/dev/null; do
        sleep 5
        if [ "$(date +%s)" -ge "$next_check" ]; then
            log "heartbeat: agent pid=$pid alive (restarts so far: $restarts)"
            next_check=$(( $(date +%s) + CHECK_INTERVAL ))
        fi
    done

    restarts=$((restarts + 1))
    log "agent pid=$pid is down, restart #$restarts in ${RESTART_BACKOFF}s"
    sleep "$RESTART_BACKOFF"
done
