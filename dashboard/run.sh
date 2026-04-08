#!/usr/bin/env bash
#
# NEURAL-CLINICS cockpit-calm dashboard launcher.
#
# - Creates an isolated venv at dashboard/venv/ (first run only).
# - Installs FastAPI + uvicorn inside it (no system pollution).
# - Launches uvicorn in the foreground on 127.0.0.1:7734.
# - Ctrl-C cleanly tears down uvicorn.
#
# Usage:
#     bash /Users/blucid/.claude/orchestrator/dashboard/run.sh

set -euo pipefail

DASHBOARD_DIR="/Users/blucid/.claude/orchestrator/dashboard"
VENV_DIR="${DASHBOARD_DIR}/venv"
PYTHON_BIN="/usr/local/bin/python3"
HOST="127.0.0.1"
PORT="7734"

if [[ ! -d "${DASHBOARD_DIR}" ]]; then
  echo "[run.sh] dashboard dir missing: ${DASHBOARD_DIR}" >&2
  exit 1
fi

# Prefer the pinned system python3, but fall back to whatever python3 is on PATH.
if [[ ! -x "${PYTHON_BIN}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    PYTHON_BIN="$(command -v python3)"
  else
    echo "[run.sh] python3 not found" >&2
    exit 1
  fi
fi

# Create venv on first run.
if [[ ! -x "${VENV_DIR}/bin/python" ]]; then
  echo "[run.sh] creating venv at ${VENV_DIR}"
  "${PYTHON_BIN}" -m venv "${VENV_DIR}"
fi

# shellcheck disable=SC1091
source "${VENV_DIR}/bin/activate"

# Install deps if fastapi is missing. We pin nothing here — this is a
# throwaway local venv and the packages are stable APIs.
if ! python -c "import fastapi, uvicorn" >/dev/null 2>&1; then
  echo "[run.sh] installing fastapi + uvicorn into venv"
  python -m pip install --quiet --upgrade pip
  python -m pip install --quiet fastapi "uvicorn[standard]"
fi

cd "${DASHBOARD_DIR}"

echo "[run.sh] cockpit listening on http://${HOST}:${PORT}"
echo "[run.sh] press Ctrl-C to stop"

# Ctrl-C goes to uvicorn (foreground process) — nothing else to clean up.
exec python -m uvicorn server:app \
  --host "${HOST}" \
  --port "${PORT}" \
  --log-level info \
  --no-access-log
