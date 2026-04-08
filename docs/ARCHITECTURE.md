# Architecture

The cockpit is a control plane for running many parallel claude code
sessions with one-command broadcast fork-and-resume semantics. It is built
from six independent pieces that communicate through a single shared file:
`/Users/blucid/.claude/orchestrator/sessions.json`.

## The six pieces

1. **Shell wrapper** (`shell/30-nrl-cockpit.zsh`) — sourced from `~/.zshrc`.
   Replaces the bare `claude` command with a function that registers the
   session in `sessions.json`, sets up a per-shell resume queue, and
   intercepts claude's exit. If the exit is flagged as a handoff, the
   wrapper immediately re-exec's claude with `/resume {handoff_id}`. If not,
   it removes the session from the registry and returns to the prompt.

2. **Slash command — single** (`commands/fork-resume.md`) — runs inside
   claude. Captures the current conversation state, saves to Pieces, writes
   `~/.claude/handoffs/latest.md`, adds a Linear comment, writes a resume
   flag into `~/.claude/orchestrator/resume-queue/<shell_pid>`, and exits.
   The wrapper then picks up the flag and relaunches.

3. **Slash command — broadcast** (`commands/fork-all-resume.md`) — same as
   the single-session variant, but writes a `broadcast.json` file that
   every other running session picks up on its next heartbeat and executes
   the same flow locally.

4. **Session registry** (`~/.claude/orchestrator/sessions.json`) — the
   single source of truth for which sessions exist, where they are, what
   role they serve, and what Linear issue they're working. Every piece
   reads and writes this file through a small Python helper that takes a
   file lock. Schema is versioned (`schema_version: 1`).

5. **Dashboard** (`dashboard/server.py`) — FastAPI app on
   `http://127.0.0.1:7734`. Reads `sessions.json` on every `GET /api/state`
   and watches its mtime for an SSE stream on `/events`. Renders the
   cockpit-calm view: hero rings for session counts, session cards, the
   10-stage pipeline strip, and a Phase 2 v1 burndown stub. Never 5xx's on
   a missing or malformed registry — renders an empty state instead.

6. **Launcher** (`launcher/nrl-cockpit`) — the macOS entry point. Creates a
   dedicated Space, opens iTerm2 windows in the `NC-COCKPIT-CALM-001`
   profile, pre-seeds `NRL_COCKPIT_ROLE` per window, and starts the
   dashboard in a Chrome app window. Replaces the legacy `nrl-agents` tmux
   dashboard. Supports `--minimal` (one window) and `--role <name>`
   (single window with a pre-tagged role).

## Data flow

```
  launcher -> iTerm2 windows -> shell wrapper -> claude process
                                       |
                                       v
                         sessions.json (shared state)
                                       ^
                                       |
  dashboard <- SSE/poll <-------------+
                                       ^
                                       |
  /fork-all-resume -> broadcast.json -+
                                       |
                                       v
  every session picks up and runs /fork-resume locally
```

## Why a file, not a daemon

A file-based registry is simpler to reason about, survives process deaths,
and needs no auth story. Every reader can tolerate a missing or malformed
file. Every writer takes a short file lock. No long-lived daemon means no
systemd, no launchd agent (except the optional dashboard plist), no
management overhead.

## VPS integration

The VPS runs the same wrapper under tmux at
`~/.config/nrl-cockpit/wrapper.sh`. When `/fork-all-resume` broadcasts, an
SSH fan-out writes the same `broadcast.json` into the VPS orchestrator
directory; the VPS wrapper's heartbeat loop picks it up and runs the local
fork flow in each tmux pane. Phase 1 deploys the wrapper but does not yet
close the full auto-resume loop on VPS — that is Phase 2.

## Why cockpit-calm

The user is neurodivergent and runs 6+ simultaneous claude sessions. Every
visual element is optimized to reduce motion, sound, and unexpected layout
shift. B612 Mono is the Airbus cockpit typeface. The 3-hue discipline
(sage, celeste, marigold) is enforced everywhere. No toast, no popover, no
auto-scroll. One reveal fade at 240ms, one hover swap at 160ms, nothing
else moves.
