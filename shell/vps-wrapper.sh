#!/bin/bash
# ────────────────────────────────────────────────────────────────
# nrl-cockpit VPS wrapper for claude
#
# Usage: nrl-claude-vps [args]
#
# Same auto-resume semantics as the Mac wrapper. Install on VPS at:
#   ~/.config/nrl-cockpit/wrapper.sh
# Then agents should be launched via this wrapper instead of `claude` directly.
# ────────────────────────────────────────────────────────────────

set -u

export NRL_ORCH_DIR="$HOME/.claude/orchestrator"
export NRL_ORCH_SESSIONS="$NRL_ORCH_DIR/sessions.json"
export NRL_ORCH_RESUME_QUEUE="$NRL_ORCH_DIR/resume-queue"
export NRL_ORCH_HANDOFFS="$HOME/.claude/handoffs"

mkdir -p "$NRL_ORCH_RESUME_QUEUE" "$NRL_ORCH_DIR/state" "$NRL_ORCH_DIR/logs" "$NRL_ORCH_HANDOFFS"

nrl_vps_register() {
    local shell_pid="$$"
    local tty_dev="$(tty 2>/dev/null || echo unknown)"
    local cwd="$PWD"
    local now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

    if command -v python3 >/dev/null 2>&1; then
        python3 - "$NRL_ORCH_SESSIONS" "$shell_pid" "$tty_dev" "$cwd" "$now" <<'PYEOF' 2>/dev/null || true
import json, sys, os
path, shell_pid, tty, cwd, now = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
try:
    with open(path) as f:
        data = json.load(f)
except Exception:
    data = {"schema_version": 1, "updated_at": None, "sessions": []}
sid = f"NRL-vps-{os.path.basename(tty)}-{shell_pid}"
data["updated_at"] = now
found = False
for s in data.get("sessions", []):
    if s.get("id") == sid:
        s["last_seen"] = now
        s["cwd"] = cwd
        found = True
        break
if not found:
    data.setdefault("sessions", []).append({
        "id": sid,
        "shell_pid": int(shell_pid),
        "tty": tty,
        "cwd": cwd,
        "host": "vps",
        "launched_at": now,
        "last_seen": now,
        "role": "orchestrator",
        "linear_issue": None,
        "current_stage": "idle",
    })
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
    fi
}

nrl_vps_deregister() {
    local shell_pid="$$"
    local tty_dev="$(tty 2>/dev/null || echo unknown)"
    if command -v python3 >/dev/null 2>&1; then
        python3 - "$NRL_ORCH_SESSIONS" "$shell_pid" "$tty_dev" <<'PYEOF' 2>/dev/null || true
import json, sys, os
path, shell_pid, tty = sys.argv[1:]
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
sid = f"NRL-vps-{os.path.basename(tty)}-{shell_pid}"
d["sessions"] = [s for s in d.get("sessions", []) if s.get("id") != sid]
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
    fi
}

SHELL_PID=$$
RESUME_FLAG="$NRL_ORCH_RESUME_QUEUE/$SHELL_PID"

export NRL_COCKPIT_SHELL_PID="$SHELL_PID"
export NRL_COCKPIT_RESUME_FLAG="$RESUME_FLAG"
export NRL_COCKPIT_SESSIONS="$NRL_ORCH_SESSIONS"
export NRL_COCKPIT_HANDOFFS_DIR="$NRL_ORCH_HANDOFFS"

CLAUDE_BIN="${CLAUDE_BIN:-$(command -v claude || echo claude)}"

nrl_vps_register

"$CLAUDE_BIN" "$@"
exit_code=$?

loops=0
while [[ -f "$RESUME_FLAG" && $loops -lt 10 ]]; do
    resume_id="$(cat "$RESUME_FLAG" 2>/dev/null || true)"
    rm -f "$RESUME_FLAG"
    [[ -z "$resume_id" ]] && break

    echo ""
    echo "  ↻  Auto-resuming: $resume_id"
    echo ""
    sleep 0.3

    nrl_vps_register
    "$CLAUDE_BIN" "/resume $resume_id"
    exit_code=$?
    loops=$((loops + 1))
done

nrl_vps_deregister
exit $exit_code
