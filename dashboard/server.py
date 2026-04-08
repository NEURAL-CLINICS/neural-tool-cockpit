"""
NEURAL-CLINICS cockpit-calm dashboard — FastAPI backend.

Serves a local web app at 127.0.0.1:7734 that reads live session state from
/Users/blucid/.claude/orchestrator/sessions.json and exposes:

    GET /              -> static/index.html
    GET /api/state     -> JSON snapshot of sessions + pipeline + burndown stub
    GET /events        -> Server-Sent Events stream, emits on sessions.json mtime
                          change and every 10s heartbeat
    GET /api/font/<n>  -> serves B612 Mono ttf from system font directory
                          (whitelisted filenames only — no path traversal)

Design contract:
    - Dependencies: fastapi, uvicorn. No database. No ORM. No build step.
    - sessions.json may be missing, empty, or malformed — backend must degrade
      to an empty-state response without 5xx.
    - Burndown uses `gh pr list` against the NEURAL-CLINICS org if gh is
      available; otherwise it stubs to zero. The frontend labels this STUB.
"""

from __future__ import annotations

import asyncio
import json
import os
import shutil
import subprocess
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import (
    FileResponse,
    JSONResponse,
    Response,
    StreamingResponse,
)
from fastapi.staticfiles import StaticFiles


# ---------------------------------------------------------------------------
# Absolute paths (per CLAUDE.md: never use ~/)
# ---------------------------------------------------------------------------

DASHBOARD_DIR = Path("/Users/blucid/.claude/orchestrator/dashboard")
STATIC_DIR = DASHBOARD_DIR / "static"
SESSIONS_JSON = Path("/Users/blucid/.claude/orchestrator/sessions.json")
FONT_DIR = Path("/Users/blucid/Library/Fonts")
CLAUDE_TASKS_DIR = Path("/Users/blucid/.claude/tasks")
CLAUDE_PROJECTS_DIR = Path("/Users/blucid/.claude/projects/-Users-blucid")

# Whitelisted B612 Mono filenames (prevents path traversal via /api/font/<n>)
ALLOWED_FONT_FACES = {
    "Regular": "B612Mono-Regular.ttf",
    "Italic": "B612Mono-Italic.ttf",
    "Bold": "B612Mono-Bold.ttf",
    "BoldItalic": "B612Mono-BoldItalic.ttf",
}

# 10-stage NEURAL-CLINICS pipeline, in order
PIPELINE_STAGES: list[str] = [
    "plan",
    "impl",
    "qgap-m",
    "qgap-c",
    "sgap-m",
    "sgap-c",
    "comply",
    "docs",
    "regress",
    "merge",
]

# Map session.current_stage values -> canonical pipeline stage key.
# Sessions emit free-form stages; we normalize them here so the pipeline
# view stays honest even when wrappers label stages slightly differently.
STAGE_ALIASES: dict[str, str] = {
    # plan
    "plan": "plan",
    "planning": "plan",
    "nrl-plan": "plan",
    "gp-plan": "plan",
    # impl
    "impl": "impl",
    "implement": "impl",
    "writing_code": "impl",
    "nrl-impl": "impl",
    "gp-impl": "impl",
    # quality gap measure
    "qgap-m": "qgap-m",
    "quality-gap-measure": "qgap-m",
    "nrl-qgap-m": "qgap-m",
    "gp-qgap-m": "qgap-m",
    # quality gap close
    "qgap-c": "qgap-c",
    "quality-gap-close": "qgap-c",
    "nrl-qgap-c": "qgap-c",
    "gp-qgap-c": "qgap-c",
    # security gap measure
    "sgap-m": "sgap-m",
    "security-gap-measure": "sgap-m",
    "nrl-sgap-m": "sgap-m",
    "gp-sgap-m": "sgap-m",
    # security gap close
    "sgap-c": "sgap-c",
    "security-gap-close": "sgap-c",
    "nrl-sgap-c": "sgap-c",
    "gp-sgap-c": "sgap-c",
    # compliance
    "comply": "comply",
    "compliance": "comply",
    "nrl-comply": "comply",
    "gp-comply": "comply",
    # docs
    "docs": "docs",
    "documentation": "docs",
    "nrl-docs": "docs",
    "gp-docs": "docs",
    # regression
    "regress": "regress",
    "regression": "regress",
    "nrl-regress": "regress",
    "gp-regress": "regress",
    # merge
    "merge": "merge",
    "merging": "merge",
    "nrl-merge": "merge",
    "gp-merge": "merge",
}

# Any of these stage labels indicate a session parked waiting for human
# resume (i.e., after /fork-all-resume). The hero ring uses this count.
WAITING_STAGES: set[str] = {
    "handoff_complete",
    "awaiting_resume",
    "waiting",
    "idle_after_handoff",
}

# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(title="NEURAL-CLINICS Cockpit Dashboard", version="1.0.0")

# Static assets (style.css, index.html fallback)
app.mount("/static", StaticFiles(directory=str(STATIC_DIR)), name="static")


# ---------------------------------------------------------------------------
# State readers
# ---------------------------------------------------------------------------


def _iso_now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def read_sessions() -> dict[str, Any]:
    """Read sessions.json. Return a safe empty shape if missing/malformed."""
    empty = {
        "schema_version": 1,
        "updated_at": None,
        "sessions": [],
        "_read_error": None,
    }
    try:
        if not SESSIONS_JSON.exists():
            empty["_read_error"] = "sessions.json does not exist"
            return empty
        raw = SESSIONS_JSON.read_text(encoding="utf-8")
        if not raw.strip():
            empty["_read_error"] = "sessions.json is empty"
            return empty
        data = json.loads(raw)
        if not isinstance(data, dict):
            empty["_read_error"] = "sessions.json root is not an object"
            return empty
        sessions = data.get("sessions", [])
        if not isinstance(sessions, list):
            sessions = []
        data["sessions"] = sessions
        data.setdefault("schema_version", 1)
        data.setdefault("updated_at", None)
        return data
    except json.JSONDecodeError as exc:
        empty["_read_error"] = f"JSON decode error: {exc}"
        return empty
    except OSError as exc:
        empty["_read_error"] = f"I/O error: {exc}"
        return empty


def normalize_stage(raw_stage: Any) -> str | None:
    """Map a session's current_stage to a canonical pipeline stage."""
    if not raw_stage or not isinstance(raw_stage, str):
        return None
    key = raw_stage.strip().lower()
    if key in STAGE_ALIASES:
        return STAGE_ALIASES[key]
    # Try substring match for safety (e.g. "nrl-impl-writing")
    for alias, canonical in STAGE_ALIASES.items():
        if alias in key:
            return canonical
    return None


def compute_pipeline_state(sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """
    For each of the 10 canonical pipeline stages, return its aggregate state
    AND the list of Linear issues currently parked in that stage.

    A stage is:
        - "active"    if any session is currently IN this stage
        - "touched"   if at least one session's index >= this stage's index
                      (i.e., work has moved past it)
        - "idle"      otherwise

    Each stage carries an `issues` list:
        [{"key": "NRL-142", "session_id": "...", "role": "plan", "cwd": "..."}]

    The frontend renders each stage as a quadrant (cell) with the issue pills
    inside. When a session's current_stage changes, its issue moves to the
    new quadrant on the next SSE tick.

    Sessions WITHOUT a recognised stage are bucketed by their `role` field
    if the role itself is a pipeline stage. This means a session can show up
    in its role's quadrant even if its stage is "idle" or unknown — useful
    when a session has registered but hasn't yet emitted a stage label.

    The frontend colors these: active=celeste, touched=sage, idle=grey.
    """
    stage_to_index = {s: i for i, s in enumerate(PIPELINE_STAGES)}
    active_set: set[str] = set()
    max_reached = -1

    # stage_key -> list of issue dicts in deterministic order
    issues_by_stage: dict[str, list[dict[str, Any]]] = {s: [] for s in PIPELINE_STAGES}
    seen_keys_per_stage: dict[str, set[str]] = {s: set() for s in PIPELINE_STAGES}

    def _push(stage_key: str, sess: dict[str, Any]) -> None:
        # Issue key is preferred; fall back to a synthetic id from the
        # session id so the quadrant still shows something representative
        # for sessions that haven't been linked to a Linear issue yet.
        raw_issue = sess.get("linear_issue")
        issue_key = raw_issue.strip() if isinstance(raw_issue, str) and raw_issue.strip() else None
        synthetic = f"~{sess.get('id') or sess.get('shell_pid') or 'session'}"
        key = issue_key or synthetic
        # Deduplicate by key within a stage so two sessions on the same
        # issue don't render two pills.
        if key in seen_keys_per_stage[stage_key]:
            return
        seen_keys_per_stage[stage_key].add(key)
        issues_by_stage[stage_key].append({
            "key": key,
            "is_synthetic": issue_key is None,
            "session_id": sess.get("id"),
            "role": sess.get("role"),
            "cwd": sess.get("cwd"),
            "current_stage": sess.get("current_stage"),
        })

    for sess in sessions:
        canonical = normalize_stage(sess.get("current_stage"))
        if canonical is None:
            # Fall back to role-as-stage if the role itself is a pipeline
            # stage. This catches sessions registered with role=plan and
            # current_stage=idle (e.g., just-launched cockpit windows).
            role = sess.get("role")
            if isinstance(role, str):
                role_norm = normalize_stage(role)
                if role_norm in stage_to_index:
                    canonical = role_norm

        if canonical is None or canonical not in stage_to_index:
            continue

        active_set.add(canonical)
        idx = stage_to_index[canonical]
        if idx > max_reached:
            max_reached = idx
        _push(canonical, sess)

    out: list[dict[str, Any]] = []
    for idx, stage in enumerate(PIPELINE_STAGES):
        if stage in active_set:
            state = "active"
        elif idx <= max_reached:
            state = "touched"
        else:
            state = "idle"
        out.append({
            "stage": stage,
            "index": idx,
            "state": state,
            "issues": issues_by_stage[stage],
            "issue_count": len(issues_by_stage[stage]),
        })
    return out


def compute_burndown_stub() -> dict[str, Any]:
    """
    Count merged PRs to main across the NEURAL-CLINICS org for the past 7
    days. Returns the raw count plus the v1 target (100). If `gh` is not
    available or the call fails, we silently fall back to 0 — the frontend
    always labels this section as a STUB regardless.
    """
    stub = {
        "label": "v1 Target: 100 merged PRs to main across NC org",
        "target": 100,
        "current": 0,
        "window_days": 7,
        "source": "stub",
        "is_stub": True,
    }
    gh_path = shutil.which("gh")
    if not gh_path:
        return stub
    try:
        # Search for PRs merged in the last 7 days across the whole org.
        # We use `gh search prs` because it works across repos in one call,
        # whereas `gh pr list --repo` requires a repo argument each time.
        result = subprocess.run(
            [
                gh_path,
                "search",
                "prs",
                "--owner",
                "NEURAL-CLINICS",
                "--state",
                "closed",
                "--merged-at",
                ">2026-03-24",  # approx 7 days ago from today (2026-03-31)
                "--limit",
                "200",
                "--json",
                "number,repository,mergedAt",
            ],
            capture_output=True,
            text=True,
            timeout=5,
        )
        if result.returncode == 0:
            data = json.loads(result.stdout or "[]")
            stub["current"] = len(data) if isinstance(data, list) else 0
            stub["source"] = "gh search prs"
    except (subprocess.TimeoutExpired, json.JSONDecodeError, OSError):
        # Silent fallback — we already have a safe default.
        pass
    return stub


def read_tasks_for_uuid(uuid: str | None) -> list[dict[str, Any]]:
    """
    Read all task JSON files for a given claude code session UUID.

    Tasks live at /Users/blucid/.claude/tasks/<uuid>/<id>.json with this shape:
        {
            "id": "1",
            "subject": "...",
            "description": "...",
            "activeForm": "...",
            "owner": "...",
            "status": "pending|in_progress|completed",
            "blocks": [],
            "blockedBy": []
        }

    Returns the tasks sorted by integer id ascending. Filters out deleted
    tasks. Returns an empty list if uuid is None or the directory doesn't
    exist (e.g., no tasks created yet).
    """
    if not uuid:
        return []
    task_dir = CLAUDE_TASKS_DIR / uuid
    if not task_dir.exists() or not task_dir.is_dir():
        return []

    tasks: list[dict[str, Any]] = []
    try:
        for entry in task_dir.iterdir():
            if not entry.is_file() or not entry.name.endswith(".json"):
                continue
            # Skip hidden state files (.lock, .highwatermark, etc.)
            if entry.name.startswith("."):
                continue
            try:
                with entry.open("r", encoding="utf-8") as f:
                    task = json.load(f)
            except (OSError, json.JSONDecodeError):
                continue
            if not isinstance(task, dict):
                continue
            status = task.get("status")
            if status == "deleted":
                continue
            # Coerce id to int for sort if possible, else fall back to filename
            try:
                task["_sort_key"] = int(task.get("id", entry.stem))
            except (TypeError, ValueError):
                task["_sort_key"] = 0
            tasks.append(task)
    except OSError:
        return []

    tasks.sort(key=lambda t: t.get("_sort_key", 0))
    for t in tasks:
        t.pop("_sort_key", None)
    return tasks


def find_uuid_for_session(sess: dict[str, Any]) -> str | None:
    """
    Resolve a session entry to its claude code session UUID.

    Strategy:
        1. If the session entry already has `claude_session_uuid`, use it.
        2. Otherwise, find the most recently modified UUID directory under
           ~/.claude/projects/-Users-blucid/ whose mtime is within the
           session's lifetime. This is a best-effort heuristic for sessions
           that started before the wrapper was updated to capture UUID.

    Returns None if no candidate is found.
    """
    explicit = sess.get("claude_session_uuid")
    if isinstance(explicit, str) and explicit:
        return explicit

    if not CLAUDE_PROJECTS_DIR.exists():
        return None

    launched_at = sess.get("launched_at")
    last_seen = sess.get("last_seen")
    try:
        launched_ts = (
            datetime.fromisoformat(launched_at.replace("Z", "+00:00")).timestamp()
            if isinstance(launched_at, str)
            else None
        )
        last_seen_ts = (
            datetime.fromisoformat(last_seen.replace("Z", "+00:00")).timestamp()
            if isinstance(last_seen, str)
            else None
        )
    except (ValueError, AttributeError):
        launched_ts = None
        last_seen_ts = None

    candidates: list[tuple[float, str]] = []
    try:
        for entry in CLAUDE_PROJECTS_DIR.iterdir():
            if not entry.is_dir():
                continue
            name = entry.name
            # UUID-shape filter
            if len(name) != 36 or name.count("-") != 4:
                continue
            try:
                mt = entry.stat().st_mtime
            except OSError:
                continue
            # If we have a launched_ts, prefer dirs created after it
            if launched_ts is not None and mt < launched_ts - 60:
                continue
            candidates.append((mt, name))
    except OSError:
        return None

    if not candidates:
        return None
    candidates.sort(reverse=True)
    # Return the most recently modified candidate
    return candidates[0][1]


def enrich_sessions_with_tasks(sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """
    Mutate the sessions list in-place by adding two fields:
        - `tasks`: list of task dicts (id, subject, status, ...)
        - `task_summary`: {pending, in_progress, completed, total}
    """
    for sess in sessions:
        uuid = find_uuid_for_session(sess)
        if uuid and not sess.get("claude_session_uuid"):
            # Cache the resolved uuid back into the session for the frontend
            sess["claude_session_uuid"] = uuid
        tasks = read_tasks_for_uuid(uuid)
        sess["tasks"] = tasks
        summary = {"pending": 0, "in_progress": 0, "completed": 0, "total": len(tasks)}
        for t in tasks:
            status = t.get("status")
            if status in summary:
                summary[status] += 1
        sess["task_summary"] = summary
    return sessions


def build_state() -> dict[str, Any]:
    """Build a single snapshot of dashboard state."""
    data = read_sessions()
    sessions = data.get("sessions", [])
    sessions = enrich_sessions_with_tasks(sessions)
    pipeline_state = compute_pipeline_state(sessions)

    # Pre-compute totals so the frontend doesn't have to re-derive them.
    total = len(sessions)
    in_progress = 0
    waiting = 0
    for sess in sessions:
        stage = sess.get("current_stage") or ""
        if not isinstance(stage, str):
            continue
        stage_key = stage.strip().lower()
        if stage_key in WAITING_STAGES:
            waiting += 1
            continue
        if stage_key and stage_key not in ("idle", "done", "complete"):
            in_progress += 1

    return {
        "updated_at": _iso_now(),
        "sessions_file_updated_at": data.get("updated_at"),
        "read_error": data.get("_read_error"),
        "sessions": sessions,
        "pipeline_state": pipeline_state,
        "burndown_stub": compute_burndown_stub(),
        "totals": {
            "active": total,
            "in_progress": in_progress,
            "waiting": waiting,
        },
        "stages": PIPELINE_STAGES,
    }


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------


@app.get("/")
def serve_index() -> FileResponse:
    index = STATIC_DIR / "index.html"
    if not index.exists():
        raise HTTPException(status_code=500, detail="index.html missing")
    return FileResponse(str(index), media_type="text/html; charset=utf-8")


@app.get("/api/state")
def api_state() -> JSONResponse:
    return JSONResponse(build_state())


@app.get("/api/font/{face}")
def api_font(face: str) -> Response:
    """Serve a whitelisted B612 Mono ttf from the system font directory."""
    if face not in ALLOWED_FONT_FACES:
        raise HTTPException(status_code=404, detail="unknown font face")
    path = FONT_DIR / ALLOWED_FONT_FACES[face]
    if not path.exists():
        raise HTTPException(status_code=404, detail="font file missing")
    return FileResponse(
        str(path),
        media_type="font/ttf",
        headers={"Cache-Control": "public, max-age=604800"},
    )


@app.get("/events")
async def events(request: Request) -> StreamingResponse:
    """
    SSE stream. Emits the full dashboard state whenever sessions.json's
    mtime changes. Also emits a heartbeat comment every 10 seconds so the
    connection doesn't silently die behind a proxy and so the browser's
    EventSource reconnect timer doesn't fire.
    """

    async def event_gen():
        last_mtime: float = -1.0
        last_heartbeat: float = 0.0
        # Always emit the current state immediately on connect — the
        # frontend relies on this so it doesn't have to make a separate
        # /api/state call at startup.
        try:
            initial = build_state()
            yield f"event: state\ndata: {json.dumps(initial)}\n\n"
        except Exception as exc:  # pragma: no cover - defensive
            yield f"event: error\ndata: {json.dumps({'error': str(exc)})}\n\n"

        while True:
            if await request.is_disconnected():
                break

            try:
                mtime = (
                    SESSIONS_JSON.stat().st_mtime
                    if SESSIONS_JSON.exists()
                    else 0.0
                )
            except OSError:
                mtime = 0.0

            if mtime != last_mtime:
                last_mtime = mtime
                try:
                    state = build_state()
                    yield f"event: state\ndata: {json.dumps(state)}\n\n"
                except Exception as exc:  # pragma: no cover - defensive
                    yield f"event: error\ndata: {json.dumps({'error': str(exc)})}\n\n"

            now = time.monotonic()
            if now - last_heartbeat >= 10.0:
                last_heartbeat = now
                # SSE comment line — keeps the connection warm without
                # triggering an onmessage on the client.
                yield ": heartbeat\n\n"

            await asyncio.sleep(1.0)

    return StreamingResponse(
        event_gen(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache, no-transform",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


# ---------------------------------------------------------------------------
# Entry point (used by run.sh via uvicorn CLI — this block is a fallback)
# ---------------------------------------------------------------------------

if __name__ == "__main__":  # pragma: no cover
    import uvicorn

    uvicorn.run(
        "server:app",
        host="127.0.0.1",
        port=7734,
        log_level="info",
        reload=False,
    )
