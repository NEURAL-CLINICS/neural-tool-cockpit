# Fork · Handoff · Auto-Resume (this session only)

You are executing a full context fork with automatic resume for the CURRENT session only. The command:

1. Captures ALL state of this session
2. Persists it to every durable store (handoff file, Pieces, session registry, Linear)
3. Tags the work with an inferred role for orchestration routing
4. Writes a resume flag the shell wrapper picks up
5. Signals claude to exit — the wrapper then auto-relaunches with `/resume {id}` in a fresh process

Execute the steps below in order. Do NOT skip any. Print progress as you go.

## Step 1: Generate handoff ID

```bash
echo "NRL-$(openssl rand -hex 3)"
```
Save as `HANDOFF_ID` (e.g., `NRL-a7f3b2`).

## Step 2: Infer role + next_role + linear issue

Look at the conversation so far and determine:

- `CURRENT_ROLE` — what role best describes the work done in this session (`plan`, `impl`, `ui-designer`, `ux-designer`, `image-designer`, `3d-designer`, `video-designer`, `qgap-m`, `qgap-c`, `sgap-m`, `sgap-c`, `comply`, `docs`, `regress`, `merge`, `orchestrator`)
- `NEXT_ROLE` — what role should pick this up next
- `LINEAR_ISSUE` — the current Linear issue if any (e.g., `NRL-123` or `RGGB-45`), otherwise empty
- `REPO_NAME` — basename of cwd if in a git repo, otherwise empty
- `SESSION_TOPIC` — one-line summary of what this session was about

## Step 3: Write the handoff file

Write to `~/.claude/handoffs/{HANDOFF_ID}.md`:

```markdown
---
handoff_id: {HANDOFF_ID}
created: {ISO 8601 UTC timestamp}
session_topic: {SESSION_TOPIC}
current_role: {CURRENT_ROLE}
next_role: {NEXT_ROLE}
linear_issue: {LINEAR_ISSUE or null}
repo: {REPO_NAME or null}
directory: {cwd}
source_command: /fork-resume
host: mac
---

## Session Goal
{What the user was trying to accomplish}

## Completed Work
{Everything done, with specific file paths and changes}

## Current State
{Where things stand: running services, open PRs, pending steps, last command outputs}

## Pending Tasks
{What still needs to be done, in priority order}

## Suggested Next Role
**{NEXT_ROLE}** — {one-sentence reason why}

## Key Context
{Decisions, preferences, constraints, gotchas}

## Environment State
{Services started, configs changed, env vars, backgrounded processes}

## Files Modified
{Complete list of files created/modified}

## Verification Before Resuming
{Commands the resuming agent should run to confirm state hasn't drifted}
```

Copy to `~/.claude/handoffs/latest.md` as well.

## Step 4: Save to Pieces

Call `mcp__pieces-stdio__create_pieces_memory` with:
- `title`: `"NRL Cockpit Resume: {HANDOFF_ID} [{CURRENT_ROLE} → {NEXT_ROLE}]"`
- `body`: full handoff markdown content

Wait for success before proceeding.

## Step 5: Save compact memory (best effort)

If any mem0 or Graphiti MCP tool is visible, save a 3-sentence summary with the handoff ID, role, and topic. If not, skip silently — Pieces is the primary store.

## Step 6: Update Linear issue (if LINEAR_ISSUE set)

If `LINEAR_ISSUE` is set, call `mcp__claude_ai_Linear__save_comment` with a comment containing:
- Handoff ID
- Current state summary
- Next role assignment

## Step 7: Update session registry

```bash
python3 - "$NRL_COCKPIT_SESSIONS" "$NRL_COCKPIT_SHELL_PID" "{CURRENT_ROLE}" "{LINEAR_ISSUE_OR_EMPTY}" "{HANDOFF_ID}" <<'PYEOF'
import json, sys, os, time
path, shell_pid, role, issue, handoff = sys.argv[1:]
if not os.path.exists(path):
    sys.exit(0)
with open(path) as f:
    d = json.load(f)
for s in d.get("sessions", []):
    if s.get("shell_pid") == int(shell_pid):
        s["role"] = role
        s["linear_issue"] = issue or None
        s["last_handoff"] = handoff
        s["current_stage"] = "handoff_complete"
        s["last_seen"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        break
d["updated_at"] = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
with open(path, "w") as f:
    json.dump(d, f, indent=2)
PYEOF
```

## Step 8: Write the resume flag

```bash
echo "{HANDOFF_ID}" > "$NRL_COCKPIT_RESUME_FLAG"
```

If `$NRL_COCKPIT_RESUME_FLAG` is empty the wrapper is not active. In that case, write to `$HOME/.claude/orchestrator/resume-queue/manual-{HANDOFF_ID}` and warn the user that they need to run `exec zsh` and retry — but still continue.

## Step 9: Announce

Print:

```
╭─────────────────────────────────────────────────────────╮
│  HANDOFF COMPLETE — AUTO-RESUME ENGAGED                 │
├─────────────────────────────────────────────────────────┤
│  ID:        {HANDOFF_ID}                                │
│  Role:      {CURRENT_ROLE} → {NEXT_ROLE}                │
│  Issue:     {LINEAR_ISSUE or "-"}                       │
│  Topic:     {SESSION_TOPIC}                             │
├─────────────────────────────────────────────────────────┤
│  Saved:     handoff file · Pieces · session registry   │
│  Next:      claude will exit now and auto-relaunch      │
│             with /resume {HANDOFF_ID}                   │
╰─────────────────────────────────────────────────────────╯
```

## Step 10: Self-exit

Send SIGTERM to the claude process so the shell wrapper can pick up the resume flag and relaunch with fresh context.

```bash
# The Bash tool runs in a subshell whose parent is claude itself.
# SIGTERM to $PPID = claude process = graceful exit.
# The wrapper then sees the resume flag and auto-resumes.
sleep 1 && kill -TERM $PPID
```

After this command, claude exits within a second. The shell wrapper's loop checks the resume flag and runs `claude "/resume {HANDOFF_ID}"` automatically.

If the wrapper is not installed (no `$NRL_COCKPIT_RESUME_FLAG`), the user must manually run `claude "/resume {HANDOFF_ID}"` after claude exits.

## Important

- Do NOT skip Pieces save — that is the durable store.
- Do NOT forget to write the resume flag — without it, no auto-resume.
- The HANDOFF_ID appears in: the handoff file name, Pieces title, resume flag contents, Linear comment, and user-facing announcement.
- Step 10 must be the LAST thing you do. Everything else must complete before the kill.
