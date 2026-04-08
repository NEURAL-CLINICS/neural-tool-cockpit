# NEURAL-CLINICS Cockpit Dashboard

Local web app that shows live state for every active `nrl-claude` session:
roles, Linear issues, current pipeline stage, and a v1 burndown stub.

Cockpit-calm by construction — no animation except a single 240ms reveal
fade, no toasts, no auto-scroll, no popovers. Designed for neurodivergent
operators running multiple terminals at once.

## Quick start

```bash
bash /Users/blucid/.claude/orchestrator/dashboard/run.sh
```

Then open:

```
http://127.0.0.1:7734/
```

Or launch as a Chrome app window (recommended — no tabs, no URL bar):

```bash
open -a "Google Chrome" --args --app=http://127.0.0.1:7734
```

## Files

| Path | Purpose |
| --- | --- |
| `server.py` | FastAPI app: `/`, `/api/state`, `/events` (SSE), `/api/font/{face}` |
| `static/index.html` | Single-file dashboard (HTML + inline vanilla JS) |
| `static/style.css` | NC cockpit-calm tokens, B612 Mono, ring/bar signature patterns |
| `run.sh` | Creates venv, installs fastapi + uvicorn, launches on `127.0.0.1:7734` |
| `com.neuralclinics.cockpit-dashboard.plist` | Optional launchd agent for auto-start at login |
| `venv/` | Isolated Python virtualenv (created on first run) |

## Data source

The dashboard reads `/Users/blucid/.claude/orchestrator/sessions.json` on
every `/api/state` call. The SSE endpoint (`/events`) polls that file's
mtime once per second and pushes a fresh snapshot to the browser whenever
it changes. A heartbeat comment is emitted every 10 seconds to keep the
connection warm.

Schema: see `/Users/blucid/.claude/orchestrator/README.md`.

Missing, empty, or malformed `sessions.json` is handled gracefully — the
dashboard renders the empty state with a small amber banner explaining
what went wrong, but never 5xx's.

## Hero rings

| Ring | Hue | Counts |
| --- | --- | --- |
| Active Sessions | sage `#708C69` | total sessions in the registry |
| In Progress | celeste `#BDD3CE` | sessions with a non-idle, non-waiting `current_stage` |
| Waiting / Handoff | marigold `#F4A258` | sessions parked waiting for resume (e.g., `handoff_complete`) |

Each ring uses the diagonal BL→TR gradient signature: stopOpacity
`1.0 → 0.12`, 9px stroke, `stroke-linecap: round`, 74px diameter.

## Pipeline view

Ten-stage NEURAL-CLINICS pipeline as a row of slotted bars:

```
plan → impl → qgap·m → qgap·c → sgap·m → sgap·c → comply → docs → regress → merge
```

Each slot is colored by aggregate state across all active sessions:

- **idle** (grey) — no session touched this stage yet
- **touched** (sage) — at least one session has moved past this stage
- **active** (celeste) — at least one session is currently in this stage

The `blocked` (marigold) state is reserved but not yet wired up — it will
engage when a session reports a `blocked` label in a future iteration.

## v1 Burndown (stub)

Reads merged PR count for the last 7 days across the `NEURAL-CLINICS` org
via `gh search prs` if `gh` is available. Otherwise hardcoded to 0. The
section is visibly tagged **STUB · PHASE 2** so the operator is never
misled.

## Design constraints

- **Fonts:** B612 Mono only (the Airbus cockpit typeface). Served from
  the system font directory at `/Users/blucid/Library/Fonts/B612Mono-*.ttf`
  via the `/api/font/{face}` endpoint with a strict whitelist. Falls back
  to `SF Mono` → `Menlo` if the font fails to load.
- **3-hue discipline:** sage `#708C69`, celeste `#BDD3CE`,
  marigold `#F4A258`. Grey (`#A8A8A8`) is neutral, not a 4th hue.
- **1px borders only**, never 2px+. Border-bottom glows are the exception.
- **18px card radius**, 9999px pills, hex-only gradient stops.
- **Slotted bars** use the vertical 180deg `${hex}44 → ${hex}88` gradient.
- **Transitions** only on interaction: 160ms with
  `cubic-bezier(0.2, 0, 0, 1)`. Reveal is 240ms with
  `cubic-bezier(0, 0, 0.2, 1)`. Nothing else moves.
- **Hover a session card** swaps its border to sage (no size change, no
  layout shift, no shadow).
- **Focus a card and press Enter** to copy its handoff id to the
  clipboard. The border briefly swaps to celeste as confirmation — no
  toast, no sound.

## Auto-start at login (optional)

```bash
cp /Users/blucid/.claude/orchestrator/dashboard/com.neuralclinics.cockpit-dashboard.plist \
   /Users/blucid/Library/LaunchAgents/com.neuralclinics.cockpit-dashboard.plist
launchctl load  /Users/blucid/Library/LaunchAgents/com.neuralclinics.cockpit-dashboard.plist
launchctl start com.neuralclinics.cockpit-dashboard
```

Logs go to `/Users/blucid/.claude/orchestrator/logs/cockpit-dashboard.{out,err}.log`.

To uninstall:

```bash
launchctl unload /Users/blucid/Library/LaunchAgents/com.neuralclinics.cockpit-dashboard.plist
rm /Users/blucid/Library/LaunchAgents/com.neuralclinics.cockpit-dashboard.plist
```

## Troubleshooting

**Port 7734 already in use.** Edit `run.sh` and change `PORT=` to a
free port. Also update the Chrome command above.

**Fonts look fallback-ish in Chrome.** Open DevTools → Network and check
that `/api/font/Regular` returned 200 with `content-type: font/ttf`. If
not, confirm the files exist at
`/Users/blucid/Library/Fonts/B612Mono-Regular.ttf`.

**Empty dashboard even though sessions are running.** Inspect
`sessions.json` directly — the `nrl-claude` wrapper is responsible for
populating it, not the dashboard.
