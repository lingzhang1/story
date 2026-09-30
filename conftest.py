"""Pytest bootstrap: make the monorepo's Python packages importable.

Simplest working approach for the walking skeleton (no editable installs
required): put the directories that contain the top-level packages onto
sys.path so `import contracts...`, `import story_engine`, `import app...`
all resolve when pytest is run from the repo root.

Layout resolved here:
  <root>/                 -> `contracts` (namespace: contracts.schemas.*)
  <root>/packages         -> `story_engine`, `director_engine`, `edit_engine`,
                             `asset_engine`, `music_engine`, `model_gateway`,
                             `observability`
  <root>/apps/api         -> `app` (the FastAPI application package)
"""

from __future__ import annotations

import sys
from pathlib import Path

_ROOT = Path(__file__).resolve().parent

for rel in (".", "packages", "apps/api"):
    p = (_ROOT / rel).resolve()
    if str(p) not in sys.path:
        sys.path.insert(0, str(p))
