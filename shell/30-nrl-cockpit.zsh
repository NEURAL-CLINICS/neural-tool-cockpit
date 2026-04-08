# ────────────────────────────────────────────────────────────────
# 30-nrl-cockpit.zsh — NEURAL-CLINICS cockpit integration
#
# Provides:
#   - `claude` wrapper that auto-resumes on exit if handoff flag set
#   - Session registration in ~/.claude/orchestrator/sessions.json
#   - Broadcast listener for /fork-all-resume-all
#
# Loaded from ~/.zshrc via the zshrc.d loop.
# ────────────────────────────────────────────────────────────────

export NRL_ORCH_DIR="$HOME/.claude/orchestrator"
export NRL_ORCH_SESSIONS="$NRL_ORCH_DIR/sessions.json"
export NRL_ORCH_RESUME_QUEUE="$NRL_ORCH_DIR/resume-queue"
export NRL_ORCH_BROADCAST="$NRL_ORCH_DIR/broadcast.json"
export NRL_ORCH_HANDOFFS="$HOME/.claude/handoffs"

mkdir -p "$NRL_ORCH_RESUME_QUEUE" "$NRL_ORCH_DIR/state" "$NRL_ORCH_DIR/logs" "$NRL_ORCH_HANDOFFS"

# ── Session registration helper ────────────────────────────────
# Writes (or updates) an entry in sessions.json for the current shell.
# Uses Python for safe JSON mutation.
nrl_session_register() {
  local shell_pid="$$"
  local tty_dev="${TTY:-$(tty 2>/dev/null)}"
  local cwd="$PWD"
  local iterm_window="${ITERM_SESSION_ID:-unknown}"
  local role="${NRL_COCKPIT_ROLE:-orchestrator}"
  local launched_at
  launched_at="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  python3 - "$NRL_ORCH_SESSIONS" "$shell_pid" "$tty_dev" "$cwd" "$iterm_window" "$launched_at" "$role" <<'PYEOF' 2>/dev/null
import json, sys, os, time, fcntl
path, shell_pid, tty, cwd, iterm, launched, role = sys.argv[1:]
os.makedirs(os.path.dirname(path), exist_ok=True)
if not os.path.exists(path):
    data = {"schema_version": 1, "updated_at": None, "sessions": []}
else:
    try:
        with open(path, "r") as f:
            data = json.load(f)
    except Exception:
        data = {"schema_version": 1, "updated_at": None, "sessions": []}

sid = f"NRL-{os.path.basename(tty)}-{shell_pid}"
now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
data["updated_at"] = now

found = False
for s in data["sessions"]:
    if s.get("id") == sid:
        s["last_seen"] = now
        s["cwd"] = cwd
        s["role"] = role
        found = True
        break
if not found:
    data["sessions"].append({
        "id": sid,
        "shell_pid": int(shell_pid),
        "claude_pid": None,
        "tty": tty,
        "iterm_session_id": iterm,
        "cwd": cwd,
        "launched_at": launched,
        "last_seen": now,
        "role": role,
        "linear_issue": None,
        "current_stage": "idle",
    })

with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

nrl_session_deregister() {
  local shell_pid="$$"
  local tty_dev="${TTY:-$(tty 2>/dev/null)}"
  python3 - "$NRL_ORCH_SESSIONS" "$shell_pid" "$tty_dev" <<'PYEOF' 2>/dev/null
import json, sys, os, time
path, shell_pid, tty = sys.argv[1:]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path, "r") as f:
        data = json.load(f)
except Exception:
    sys.exit(0)
sid = f"NRL-{os.path.basename(tty)}-{shell_pid}"
data["sessions"] = [s for s in data.get("sessions", []) if s.get("id") != sid]
data["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
with open(path, "w") as f:
    json.dump(data, f, indent=2)
PYEOF
}

# ── Claude session UUID detector ──────────────────────────────
# Background helper: after `claude` starts, watch ~/.claude/projects/-Users-blucid/
# for a NEW UUID directory and write it into sessions.json so the
# dashboard can read the per-session task list at ~/.claude/tasks/<uuid>/.
nrl_claude_uuid_watch() {
  local shell_pid="$1"
  local tty_dev="$2"
  local before_snapshot="$3"
  local projects_dir="$HOME/.claude/projects/-Users-blucid"
  local i=0
  local found_uuid=""

  while (( i < 30 )); do
    sleep 0.5
    i=$((i + 1))
    [[ ! -d "$projects_dir" ]] && continue
    # Find a new UUID-shaped dir that wasn't in before_snapshot
    while IFS= read -r d; do
      local base="${d##*/}"
      if [[ "$base" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]]; then
        if ! grep -qxF "$base" "$before_snapshot" 2>/dev/null; then
          found_uuid="$base"
          break 2
        fi
      fi
    done < <(find "$projects_dir" -maxdepth 1 -type d 2>/dev/null)
  done

  rm -f "$before_snapshot"

  if [[ -n "$found_uuid" ]]; then
    python3 - "$NRL_ORCH_SESSIONS" "$shell_pid" "$tty_dev" "$found_uuid" <<'PYEOF' 2>/dev/null
import json, sys, os, time
path, shell_pid, tty, uuid = sys.argv[1:]
if not os.path.exists(path):
    sys.exit(0)
try:
    with open(path) as f:
        d = json.load(f)
except Exception:
    sys.exit(0)
sid = f"NRL-{os.path.basename(tty)}-{shell_pid}"
for s in d.get("sessions", []):
    if s.get("id") == sid or s.get("shell_pid") == int(shell_pid):
        s["claude_session_uuid"] = uuid
        s["last_seen"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        break
d["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
  fi
}

# ── claude wrapper ─────────────────────────────────────────────
# Exports env for the running claude process so /fork-all-resume
# knows where to write the resume flag.
claude() {
  local shell_pid="$$"
  local tty_dev="${TTY:-$(tty 2>/dev/null)}"
  local resume_flag="$NRL_ORCH_RESUME_QUEUE/$shell_pid"
  local max_loops=10
  local loops=0

  export NRL_COCKPIT_SHELL_PID="$shell_pid"
  export NRL_COCKPIT_RESUME_FLAG="$resume_flag"
  export NRL_COCKPIT_SESSIONS="$NRL_ORCH_SESSIONS"
  export NRL_COCKPIT_BROADCAST="$NRL_ORCH_BROADCAST"
  export NRL_COCKPIT_HANDOFFS_DIR="$NRL_ORCH_HANDOFFS"

  nrl_session_register

  # Snapshot existing claude session UUIDs so we can detect the new one
  local before_snapshot
  before_snapshot="$(mktemp -t nrl-cockpit-before.XXXXXX)"
  find "$HOME/.claude/projects/-Users-blucid" -maxdepth 1 -type d 2>/dev/null \
    | while read -r d; do
        local base="${d##*/}"
        [[ "$base" =~ ^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$ ]] && echo "$base"
      done > "$before_snapshot"

  # Background watcher that finds the new UUID and writes it to sessions.json
  nrl_claude_uuid_watch "$shell_pid" "$tty_dev" "$before_snapshot" &
  disown 2>/dev/null

  # Initial launch
  command claude "$@"
  local exit_code=$?

  # Auto-resume loop
  while [[ -f "$resume_flag" && $loops -lt $max_loops ]]; do
    local resume_id
    resume_id="$(cat "$resume_flag" 2>/dev/null)"
    rm -f "$resume_flag"
    [[ -z "$resume_id" ]] && break

    print ""
    print "\033[38;5;215m  ↻  Auto-resuming:\033[0m $resume_id"
    print ""
    sleep 0.3

    nrl_session_register
    command claude "/resume $resume_id"
    exit_code=$?
    loops=$((loops + 1))
  done

  nrl_session_deregister
  unset NRL_COCKPIT_SHELL_PID NRL_COCKPIT_RESUME_FLAG NRL_COCKPIT_SESSIONS NRL_COCKPIT_BROADCAST NRL_COCKPIT_HANDOFFS_DIR
  return $exit_code
}

# ── Convenience: check cockpit state ───────────────────────────
nrl-cockpit-status() {
  if [[ ! -f "$NRL_ORCH_SESSIONS" ]]; then
    print "No cockpit sessions registered."
    return 0
  fi
  python3 - "$NRL_ORCH_SESSIONS" <<'PYEOF'
import json, sys
with open(sys.argv[1]) as f:
    d = json.load(f)
print(f"Updated: {d.get('updated_at', 'never')}")
print(f"Sessions: {len(d.get('sessions', []))}")
for s in d.get("sessions", []):
    role = s.get("role", "?")
    issue = s.get("linear_issue") or "-"
    cwd = s.get("cwd", "?").replace("/Users/blucid", "~")
    print(f"  [{role:12}] {issue:8} {s['id']}  {cwd}")
PYEOF
}
