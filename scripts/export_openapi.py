"""Export the FastAPI OpenAPI document to contracts/openapi/openapi.json.

Imports the app and dumps app.openapi(). Run from the repo root:

    python scripts/export_openapi.py

Adds the monorepo package directories to sys.path (mirrors conftest.py)
so it runs without editable installs.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = (_ROOT / rel).resolve()
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))

from app.main import create_app  # noqa: E402

OUT_PATH = _ROOT / "contracts" / "openapi" / "openapi.json"


def main() -> None:
    app = create_app()
    spec = app.openapi()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
