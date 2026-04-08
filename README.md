# · И E U R A L · neural-tool-cockpit

Cockpit orchestration layer for managing multiple claude code sessions across
Mac iTerm2 and the OCI VPS tmux. Replaces the legacy tmux-based `nrl-agents`
dashboard with a neurodivergent-friendly, cockpit-calm control plane: a
session registry, two slash commands, a shell wrapper, a macOS Spaces
launcher, and a live web dashboard.

Built for an operator who runs many parallel claude instances simultaneously
and needs a single place to see what everything is doing, broadcast a
save-state command across all of them at once, and have every session
automatically resume after a fork without manual steps.

## Architecture

```
                                   +-----------------------------+
                                   |  session registry            |
                                   |  ~/.claude/orchestrator/     |
                                   |   sessions.json              |
                                   +--------------^---------------+
                                                  |
                    +-------------+  register +---+---+ poll  +-----------+
                    |  nrl-claude +---------->|  fs    |<------| dashboard |
                    |  wrapper    |           | state  |       | FastAPI   |
                    |  (shell)    |<----------+--------+       | 127:7734  |
                    +------+------+    resume flag              +-----------+
                           ^
                           |  exec claude
                           |
           +---------------+---------------+
           |               |               |
    +------+-----+  +------+-----+  +------+------+
    | iTerm2 tab |  | iTerm2 tab |  | VPS tmux     |
    | orch       |  | plan/impl  |  | pane         |
    +------+-----+  +------+-----+  +------+------+
           |               |               |
           | /fork-resume  |               | /fork-resume
           |               |               |
           +-------+-------+---------------+
                   |
                   | one session only
                   |
           /fork-all-resume
                   |
                   v  broadcast to every Mac + VPS session
```

The slash commands write structured handoffs; the shell wrapper intercepts
claude exit and auto-relaunches with `/resume {handoff_id}`; the dashboard
renders live state via SSE.

## Layout

| Path                                   | Role                                          |
| -------------------------------------- | --------------------------------------------- |
| `commands/fork-resume.md`              | Single-session fork and auto-resume           |
| `commands/fork-all-resume.md`          | Broadcast fork to all Mac + VPS sessions      |
| `shell/30-nrl-cockpit.zsh`             | zsh wrapper for `claude` with auto-resume     |
| `shell/vps-wrapper.sh`                 | VPS variant of the wrapper                    |
| `launcher/nrl-cockpit`                 | macOS Spaces / iTerm2 launcher                |
| `dashboard/server.py`                  | FastAPI dashboard + SSE                       |
| `dashboard/static/index.html`          | Dashboard frontend                            |
| `dashboard/static/style.css`           | Cockpit-calm tokens                           |
| `dashboard/run.sh`                     | venv launcher                                 |
| `dashboard/com.neuralclinics.cockpit-dashboard.plist` | launchd plist for auto-start   |
| `docs/ARCHITECTURE.md`                 | How the pieces fit                            |
| `docs/INSTALL.md`                      | Fresh Mac install guide                       |
| `Makefile`                             | `install` / `uninstall` / `update` targets    |

## Installation

One command:

```
make install
```

This copies every artifact from the repo into its production location on
the Mac:

| Artifact                               | Destination                                                        |
| -------------------------------------- | ------------------------------------------------------------------ |
| `commands/fork-resume.md`              | `/Users/blucid/.claude/commands/fork-resume.md`                    |
| `commands/fork-all-resume.md`          | `/Users/blucid/.claude/commands/fork-all-resume.md`                |
| `shell/30-nrl-cockpit.zsh`             | `/Users/blucid/.zshrc.d/30-nrl-cockpit.zsh`                        |
| `shell/vps-wrapper.sh`                 | `/Users/blucid/.claude/orchestrator/vps-wrapper.sh`                |
| `launcher/nrl-cockpit`                 | `/Users/blucid/.local/bin/nrl-cockpit`                             |
| `dashboard/*`                          | `/Users/blucid/.claude/orchestrator/dashboard/`                    |

For a dry run:

```
make install DRY_RUN=1
```

To remove everything:

```
make uninstall
```

To update from GitHub:

```
make update
```

For a step-by-step fresh-Mac walkthrough see `docs/INSTALL.md`.

## Usage

### Start the cockpit

```
nrl-cockpit              # full 6-window layout
nrl-cockpit --minimal    # single orchestrator window
nrl-cockpit --role plan  # single window pre-tagged with a role
```

The launcher opens iTerm2 windows in a dedicated macOS Space using the
`NC-COCKPIT-CALM-001` profile (B612 Mono 14pt, cockpit dark surface,
marigold cursor).

### Fork the current session

```
/fork-resume
```

Saves handoff to Pieces, writes `/Users/blucid/.claude/handoffs/latest.md`,
updates the Linear issue comment thread, flags the resume queue, and exits.
The wrapper relaunches claude immediately with `/resume {handoff_id}`.

### Fork every session at once

```
/fork-all-resume
```

Broadcasts the same flow across every Mac iTerm2 tab AND every VPS tmux
pane running claude. Useful before a deep architectural review or a
context refresh.

### Open the dashboard

```
http://127.0.0.1:7734
```

Or as a Chrome app window with no chrome:

```
open -a "Google Chrome" --args --app=http://127.0.0.1:7734
```

Shows:

- Hero rings: active sessions, in-progress sessions, waiting/handoff sessions
- Session cards: one per running claude, with role, Linear issue, last-seen
- Pipeline strip: the 10-stage NRL pipeline with live stage highlighting
- v1 Burndown (stub, Phase 2)

## Configuration

The shell wrapper honours these environment variables:

| Variable                | Default                                  | Purpose                                    |
| ----------------------- | ---------------------------------------- | ------------------------------------------ |
| `NRL_COCKPIT_ROLE`      | inferred from cwd                        | Pre-tag the session with a role            |
| `NRL_ORCH_DIR`          | `/Users/blucid/.claude/orchestrator`     | Root of the orchestrator runtime state     |
| `NRL_ORCH_SESSIONS`     | `${NRL_ORCH_DIR}/sessions.json`          | Session registry file                      |
| `NRL_ORCH_RESUME_QUEUE` | `${NRL_ORCH_DIR}/resume-queue`           | Per-shell resume flags                     |
| `NRL_ORCH_BROADCAST`    | `${NRL_ORCH_DIR}/broadcast.json`         | Pending broadcast command                  |
| `NRL_ORCH_HANDOFFS`     | `/Users/blucid/.claude/handoffs`         | Handoff file directory                     |
| `NRL_COCKPIT_LINEAR`    | unset                                    | Linear issue to pre-associate on launch    |

## Session schema

Every session registered in `sessions.json` looks like:

```json
{
  "id": "NRL-<tty>-<pid>",
  "shell_pid": 12345,
  "claude_pid": 12346,
  "tty": "/dev/ttys004",
  "iterm_window_id": "51968",
  "iterm_tab_id": "t3",
  "cwd": "/Users/blucid/NEURAL-CLINICS/...",
  "launched_at": "2026-04-08T14:00:00Z",
  "last_seen": "2026-04-08T14:15:22Z",
  "role": "impl",
  "linear_issue": "NRL-123",
  "current_stage": "writing_code",
  "last_handoff": "NRL-a7f3b2"
}
```

Role is inferred from cwd, active Linear issue, and recent file edits.
Fallback is `orchestrator`.

## Troubleshooting

**Dashboard empty even though claude is running.** Inspect
`/Users/blucid/.claude/orchestrator/sessions.json`. If it's empty, the
shell wrapper is not sourced — check `/Users/blucid/.zshrc.d/30-nrl-cockpit.zsh`
exists and is loaded from `~/.zshrc`.

**Fonts look wrong in Chrome.** DevTools → Network → confirm
`/api/font/Regular` returned 200 `content-type: font/ttf`. B612 Mono must
be at `/Users/blucid/Library/Fonts/B612Mono-*.ttf`.

**Port 7734 already in use.** Edit `dashboard/run.sh`, change `PORT=`,
re-run `make install`.

**Nothing happens on `/fork-resume`.** The wrapper reads the resume queue
on claude exit. If the queue file is missing, the wrapper does not relaunch.
Check `/Users/blucid/.claude/orchestrator/resume-queue/` exists and is
writable.

**VPS sessions don't receive broadcasts.** Ensure `~/.config/nrl-cockpit/wrapper.sh`
is installed on the VPS and every tmux pane runs the wrapper, not raw claude.

## Roadmap

Phase 2 (parked):

- **yabai install** — tiled window management for the macOS Space
- **VPS auto-resume full loop** — mirror the Mac auto-resume on tmux panes
- **v1 burndown live data** — pull merged PR count from `gh search prs`
- **Light mode dashboard** — parity with the cockpit-calm light palette
- **Per-session task list** — mirror `/Users/blucid/.claude/tasks/<uuid>/` into the dashboard
- **Blocked-state wiring** — marigold highlight on the pipeline strip

Tracked in the NEURAL-CLINICS Linear workspace under the cockpit initiative.

## License

Internal NEURAL-CLINICS tool. Not for external redistribution.
