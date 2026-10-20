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

is_alive() {
    local p="${1:-}" st
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(sed -n 's/^State:[[:space:]]*\([A-Za-z]\).*/\1/p' "/proc/${p}/status" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != "Z" ]
}

while true; do
    log "starting agent"
    nohup "$AGENT" -c "$CONFIG" >>"$AGENT_LOG" 2>&1 &
    pid=$!
    log "agent pid=$pid"
    echo "$pid" >"${BASE}/agent.pid"

    next_check=$(( $(date +%s) + CHECK_INTERVAL ))
    while is_alive "$pid"; do
        sleep 5
        if [ "$(date +%s)" -ge "$next_check" ]; then
            log "heartbeat: agent pid=$pid alive (restarts so far: $restarts)"
            # make sure the 20-minute keepalive scheduler is still alive too
            cron_pid=$(cat "${BASE}/.cron.lock/pid" 2>/dev/null || true)
            if [ -n "${cron_pid}" ] && ! kill -0 "${cron_pid}" 2>/dev/null; then
                log "supercronic is down, restarting it"
                "${BASE}/start-cron.sh" >>"$SUP_LOG" 2>&1
            fi
            next_check=$(( $(date +%s) + CHECK_INTERVAL ))
        fi
    done

    restarts=$((restarts + 1))
    log "agent pid=$pid is down, restart #$restarts in ${RESTART_BACKOFF}s"
    sleep "$RESTART_BACKOFF"
done
