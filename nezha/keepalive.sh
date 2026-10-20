#!/usr/bin/env bash
# 20-minute keepalive for the Nezha agent (runs under supercronic).
# Checks: supervisor alive / agent alive / panel TCP reachable.
# Actions: restore the agent, or restart the supervisor if it is wedged.
set -u

BASE="/workspace/nezha"
LOG="${BASE}/keepalive.log"
STATE="${BASE}/.keepalive.state"
SERVER="nzooo.zdk.pp.ua"
PORT=443
FAIL_THRESHOLD=3

log() { printf '%s [keepalive] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >>"$LOG"; }

alive() {
    local p="${1:-}" st
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    # PID 1 here does not reap children, so a SIGKILLed process stays as a
    # zombie forever and `kill -0` still succeeds -> exclude state Z.
    st=$(sed -n 's/^State:[[:space:]]*\([A-Za-z]\).*/\1/p' "/proc/${p}/status" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != "Z" ]
}

# guard against PID reuse: the pid must actually belong to the expected program
is_agent()      { alive "${1:-}" && tr '\0' ' ' <"/proc/${1}/cmdline" 2>/dev/null | grep -q 'nezha-agent'; }
is_supervisor() { alive "${1:-}" && tr '\0' ' ' <"/proc/${1}/cmdline" 2>/dev/null | grep -q 'supervisor\.sh'; }

sup_pid=$(cat "${BASE}/.supervisor.lock/pid" 2>/dev/null || true)
agent_pid=$(cat "${BASE}/agent.pid" 2>/dev/null || true)

sup_state=down
agent_state=down
is_supervisor "${sup_pid}" && sup_state=up
is_agent "${agent_pid}" && agent_state=up

if timeout 8 bash -c "</dev/tcp/${SERVER}/${PORT}" 2>/dev/null; then net=ok; else net=down; fi

action="none"

start_supervisor() {
    setsid nohup "${BASE}/supervisor.sh" >>"${BASE}/supervisor-console.log" 2>&1 </dev/null &
    sleep 6
    agent_pid=$(cat "${BASE}/agent.pid" 2>/dev/null || true)
    if is_agent "${agent_pid}"; then
        agent_state=up
    else
        agent_state=down
    fi
}

if [ "$agent_state" = down ] && [ "$sup_state" = up ]; then
    # supervisor restarts within ~15s; give it a chance before intervening
    sleep 15
    agent_pid=$(cat "${BASE}/agent.pid" 2>/dev/null || true)
    if is_agent "${agent_pid}"; then
        agent_state=up
        action="supervisor restored agent (pid=${agent_pid})"
    else
        action="supervisor wedged, agent still down -> restarting supervisor"
        kill "${sup_pid}" 2>/dev/null
        sleep 2
        start_supervisor
        sup_pid=$(cat "${BASE}/.supervisor.lock/pid" 2>/dev/null || true)
        is_supervisor "${sup_pid}" && sup_state=up
    fi
elif [ "$agent_state" = down ] && [ "$sup_state" = down ]; then
    action="supervisor and agent both down -> starting supervisor"
    start_supervisor
    sup_pid=$(cat "${BASE}/.supervisor.lock/pid" 2>/dev/null || true)
    is_supervisor "${sup_pid}" && sup_state=up
fi

# consecutive panel-unreachable counter
fails=$(cat "$STATE" 2>/dev/null || echo 0)
case "$fails" in ''|*[!0-9]*) fails=0 ;; esac
if [ "$net" = ok ]; then
    fails=0
else
    fails=$((fails + 1))
fi
echo "$fails" >"$STATE"

if [ "$net" = down ] && [ "$agent_state" = up ] && [ "$fails" -ge "$FAIL_THRESHOLD" ]; then
    log "panel ${SERVER}:${PORT} unreachable on ${fails} consecutive runs -> restarting agent pid=${agent_pid}"
    kill "${agent_pid}" 2>/dev/null
    sleep 3
    agent_pid=$(cat "${BASE}/agent.pid" 2>/dev/null || true)
    if is_agent "${agent_pid}"; then
        agent_state=up
    else
        agent_state=down
    fi
    action="${action}; force-restarted agent after ${fails} failed checks"
    fails=0
    echo "$fails" >"$STATE"
fi

last_log=$(date -r "${BASE}/agent.log" '+%Y-%m-%d %H:%M:%S' 2>/dev/null || echo 'n/a')
log "supervisor=${sup_state}(pid=${sup_pid:-none}) agent=${agent_state}(pid=${agent_pid:-none}) panel=${net} net_fails=${fails} agent_log_mtime=${last_log} action=${action}"

# non-zero exit only when the agent ends up down, so supercronic marks the run failed
[ "$agent_state" = up ] || exit 1
exit 0
