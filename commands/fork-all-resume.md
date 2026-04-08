# Fork · Handoff · Auto-Resume (ALL sessions on Mac + VPS)

This is the broadcast variant. It instructs EVERY claude session — on the Mac (iTerm2) AND on the VPS (tmux) — to fork, handoff, and auto-resume. You run it ONCE from any single terminal and every other claude session handles itself.

The mechanism:
1. Enumerate all Mac iTerm2 sessions running `claude`
2. Enumerate all VPS tmux panes running `claude` (via SSH)
3. Type `/fork-resume` into each via AppleScript (Mac) or `tmux send-keys` (VPS)
4. Each session runs `/fork-resume`, which saves state and self-terminates via SIGTERM
5. Shell wrapper (`nrl-claude`) on Mac auto-relaunches each session with `/resume {id}`
6. VPS wrapper (installed on first run of this command) does the same for VPS panes
7. This command FINALLY forks the current session last

Execute the steps in order. Do NOT skip any.

## Step 1: Ensure VPS wrapper is deployed (first run only)

Check if the VPS has the wrapper installed:

```bash
ssh -i ~/.ssh/oci_sandbox02 -o ConnectTimeout=5 ubuntu@100.92.11.118 \
    'test -f ~/.config/nrl-cockpit/wrapper.sh && echo INSTALLED || echo MISSING' 2>/dev/null \
  || ssh -i ~/.ssh/oci_sandbox02 -o ConnectTimeout=5 ubuntu@144.24.251.125 \
    'test -f ~/.config/nrl-cockpit/wrapper.sh && echo INSTALLED || echo MISSING' 2>/dev/null
```

If `MISSING`, deploy the wrapper:

```bash
ssh -i ~/.ssh/oci_sandbox02 ubuntu@100.92.11.118 'mkdir -p ~/.config/nrl-cockpit ~/.claude/orchestrator/resume-queue ~/.claude/handoffs'

scp -i ~/.ssh/oci_sandbox02 ~/.claude/orchestrator/vps-wrapper.sh ubuntu@100.92.11.118:~/.config/nrl-cockpit/wrapper.sh
ssh -i ~/.ssh/oci_sandbox02 ubuntu@100.92.11.118 'chmod +x ~/.config/nrl-cockpit/wrapper.sh'
```

(The file `~/.claude/orchestrator/vps-wrapper.sh` is installed alongside this command. See `~/.claude/orchestrator/README.md`.)

If the VPS is unreachable, skip VPS broadcast and proceed with Mac-only. Print a warning.

## Step 2: Enumerate Mac iTerm2 claude sessions

Run this AppleScript via Bash tool to find every iTerm2 session whose tty has a running `claude` process:

```bash
osascript <<'APPLESCRIPT'
tell application "iTerm2"
    set out to ""
    set ws to windows
    repeat with w in ws
        set wid to id of w
        set tabIdx to 0
        repeat with t in tabs of w
            set tabIdx to tabIdx + 1
            set sessIdx to 0
            repeat with s in sessions of t
                set sessIdx to sessIdx + 1
                try
                    set ttyPath to tty of s
                    set ttyName to do shell script "basename " & ttyPath
                    set pidFound to do shell script "ps -t " & ttyName & " -o pid,comm= 2>/dev/null | awk '/claude$/ {print $1; exit}'"
                    if pidFound is not "" then
                        set out to out & (wid as string) & "|" & tabIdx & "|" & sessIdx & "|" & ttyPath & "|" & pidFound & linefeed
                    end if
                end try
            end repeat
        end repeat
    end repeat
    return out
end tell
APPLESCRIPT
```

Save output as `MAC_SESSIONS` (pipe-separated lines of `wid|tabIdx|sessIdx|tty|pid`).

Filter out the CURRENT session (the tty running this command — compare against `$(tty)`). Call the filtered list `MAC_TARGETS`.

## Step 3: Enumerate VPS tmux claude panes

```bash
VPS_HOST="100.92.11.118"
VPS_KEY="$HOME/.ssh/oci_sandbox02"

ssh -i "$VPS_KEY" -o ConnectTimeout=5 ubuntu@$VPS_HOST \
    'tmux list-sessions -F "#{session_name}" 2>/dev/null' \
  | while read -r sess; do
      ssh -i "$VPS_KEY" ubuntu@$VPS_HOST \
        "tmux list-panes -s -t $sess -F '#{session_name}|#{window_index}|#{pane_index}|#{pane_pid}|#{pane_current_command}' 2>/dev/null" \
        | awk -F'|' '$5 ~ /claude|node/ {print}'
    done
```

Save output as `VPS_TARGETS` (lines of `session|window|pane|pid|cmd`). A pane is a claude pane if either:
- `pane_current_command` contains `claude`, OR
- `pane_current_command` is `node`/`zsh`/`bash` AND that pane's child process tree contains `claude`

For a more robust check, use this on the VPS:
```bash
for pane in $(tmux list-panes -s -t agents -F "#{pane_id}:#{pane_pid}"); do
    pid="${pane##*:}"
    id="${pane%%:*}"
    if pgrep -P "$pid" -f claude >/dev/null 2>&1 || ps -p "$pid" -o comm= | grep -q claude; then
        echo "$id"
    fi
done
```

If VPS is unreachable, set `VPS_TARGETS=""` and print a warning.

## Step 4: Type `/fork-resume` into each Mac target

For each entry in `MAC_TARGETS`:

```bash
while IFS='|' read -r wid tidx sidx tty pid; do
    [[ -z "$wid" ]] && continue
    osascript <<APPLESCRIPT
tell application "iTerm2"
    tell (first window whose id is $wid)
        tell tab $tidx
            tell session $sidx
                write text "/fork-resume"
            end tell
        end tell
    end tell
end tell
APPLESCRIPT
    echo "  → Mac: sent /fork-resume to window $wid tab $tidx session $sidx (pid $pid)"
done <<< "$MAC_TARGETS"
```

## Step 5: Send `/fork-resume` to each VPS pane

For each pane id in `VPS_TARGETS`:

```bash
while IFS='|' read -r sess win pane pid cmd; do
    [[ -z "$sess" ]] && continue
    ssh -i "$VPS_KEY" ubuntu@$VPS_HOST \
        "tmux send-keys -t ${sess}:${win}.${pane} '/fork-resume' Enter"
    echo "  → VPS: sent /fork-resume to ${sess}:${win}.${pane} (pid $pid)"
done <<< "$VPS_TARGETS"
```

## Step 6: Wait for broadcast completion

Each target session now runs `/fork-resume` which takes ~10-20 seconds (handoff file + Pieces save + SIGTERM). Sleep for 25 seconds to let them all complete.

```bash
echo ""
echo "  Waiting 25s for all sessions to save state and self-terminate..."
sleep 25
```

## Step 7: Collect all new handoff IDs

Find handoff files created in the last minute:

```bash
find ~/.claude/handoffs -name "NRL-*.md" -mmin -1 -type f 2>/dev/null | sort
```

Also check VPS handoffs (they're on the VPS filesystem):
```bash
ssh -i "$VPS_KEY" ubuntu@$VPS_HOST 'find ~/.claude/handoffs -name "NRL-*.md" -mmin -1 -type f' 2>/dev/null
```

Read each handoff file's frontmatter to extract:
- handoff_id
- current_role
- next_role
- linear_issue
- session_topic

## Step 8: Build the routing summary

Print a clear summary of what just happened and what each forked session will resume into:

```
╭─────────────────────────────────────────────────────────────────╮
│  BROADCAST FORK COMPLETE                                        │
├─────────────────────────────────────────────────────────────────┤
│  Mac sessions forked:  {MAC_COUNT}                              │
│  VPS panes forked:     {VPS_COUNT}                              │
│  Total:                {TOTAL}                                  │
├─────────────────────────────────────────────────────────────────┤
│  ROUTING                                                        │
│                                                                 │
│   → plan      NRL-a7f3b2  NRL-123  auth-system spec             │
│   → impl      NRL-c8d1e4  NRL-124  auth middleware              │
│   → qgap-m    NRL-e5f6a9  NRL-125  api endpoints review         │
│   → merge     NRL-d1b2c3  NRL-126  dashboard PR                 │
│   ...                                                           │
├─────────────────────────────────────────────────────────────────┤
│  All handoffs saved: ~/.claude/handoffs/ + Pieces               │
│  All sessions will auto-resume with fresh context               │
│  via their shell wrappers (Mac: nrl-claude, VPS: nrl-wrapper)   │
╰─────────────────────────────────────────────────────────────────╯
```

## Step 9: Fork the CURRENT session last

Now run the same flow as `/fork-resume` for THIS session:
1. Generate HANDOFF_ID
2. Infer CURRENT_ROLE = `orchestrator` (since this session coordinated the broadcast)
3. Write handoff file, copy to latest.md
4. Save to Pieces
5. Update Linear if applicable
6. Update session registry
7. Write resume flag
8. Print announcement
9. `sleep 1 && kill -TERM $PPID` to self-exit

The wrapper picks up the flag and auto-resumes this session last.

## Important

- This command does NOT rely on a daemon or polling loop. Coordination is via: AppleScript typing (Mac), `tmux send-keys` over SSH (VPS), and filesystem flags for resume.
- If AppleScript permission is denied for iTerm2, Mac broadcast fails silently. Check System Settings → Privacy & Security → Automation.
- If SSH to VPS fails (Tailscale down, keys missing), VPS broadcast is skipped — Mac still works.
- If a target session is mid-tool-call, the typed `/fork-resume` will queue and execute after the current tool finishes — that's fine.
- Sessions that don't actually have claude running (empty iTerm2 tabs, idle shells) are filtered out by the enumeration in Steps 2 and 3.
- The 25-second wait in Step 6 is conservative. Sessions with very large context or slow MCP calls may need more time. If verifying later shows missing handoffs, increase the wait.
