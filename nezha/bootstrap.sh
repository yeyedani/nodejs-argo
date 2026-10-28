#!/usr/bin/env bash
# One-shot bootstrap after a sandbox restart/suspend: clears stale locks,
# then (idempotently) starts the scheduler and the agent supervisor.
set -u

BASE="/workspace/nezha"
cd "$BASE" || exit 1

pid_alive() {
    local p="${1:-}" st
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(sed -n 's/^State:[[:space:]]*\([A-Za-z]\).*/\1/p' "/proc/${p}/status" 2>/dev/null)
    [ -n "$st" ] && [ "$st" != "Z" ]
}

echo "== bootstrap $(date '+%Y-%m-%d %H:%M:%S') =="

# 1. stale state from a previous sandbox lifetime
for lock in .supervisor.lock .cron.lock; do
    if [ -d "$lock" ]; then
        p=$(cat "${lock}/pid" 2>/dev/null || true)
        if pid_alive "${p}"; then
            echo "[skip] ${lock} alive (pid ${p})"
        else
            echo "[clean] stale ${lock}"
            rm -rf "$lock"
        fi
    fi
done

# 2. scheduler (20-minute keepalive)
if [ -x "${BASE}/start-cron.sh" ]; then
    "${BASE}/start-cron.sh" || echo "[warn] start-cron.sh returned non-zero"
else
    echo "[error] ${BASE}/start-cron.sh missing"
fi

# 3. supervisor (owns the agent process)
sup_pid=$(cat "${BASE}/.supervisor.lock/pid" 2>/dev/null || true)
if pid_alive "${sup_pid}"; then
    echo "[skip] supervisor already running (pid ${sup_pid})"
else
    setsid nohup "${BASE}/supervisor.sh" >>"${BASE}/supervisor-console.log" 2>&1 </dev/null &
    sleep 6
fi

# 4. report
agent_pid=$(cat "${BASE}/agent.pid" 2>/dev/null || true)
echo "-- status --"
echo "supercronic: $(cat "${BASE}/.cron.lock/pid" 2>/dev/null || echo none)"
echo "supervisor : $(cat "${BASE}/.supervisor.lock/pid" 2>/dev/null || echo none)"
echo "agent      : ${agent_pid:-none}"
pid_alive "${agent_pid}" && echo "result     : agent UP" || { echo "result     : agent DOWN"; exit 1; }
