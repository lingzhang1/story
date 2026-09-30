#!/usr/bin/env bash
# Run the Story API locally with the repo root on PYTHONPATH so
# `contracts` and `packages` resolve (mirrors the container's PYTHONPATH).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/apps/api"
export PYTHONPATH="$ROOT:$ROOT/packages"
exec .venv/bin/python -m uvicorn app.main:app --host 127.0.0.1 --port 8080 --reload
