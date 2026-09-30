"""Generate contracts/schemas/story.schema.json from the Pydantic DTOs.

The JSON Schema is the language-neutral wire contract (used to generate /
validate Swift + Python DTOs). It is emitted from StoryDTO.model_json_schema()
so the schema can never silently drift from the Python wire model.

Run from the repo root:

    python contracts/generate_schema.py

Writes: contracts/schemas/story.schema.json
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

# Make the repo root importable so `contracts.schemas...` resolves when this
# script is run directly (python contracts/generate_schema.py) without an
# editable install. Mirrors conftest.py.
_ROOT = Path(__file__).resolve().parent.parent
if str(_ROOT) not in sys.path:
    sys.path.insert(0, str(_ROOT))

from contracts.schemas.dto import StoryDTO  # noqa: E402

OUT_PATH = Path(__file__).resolve().parent / "schemas" / "story.schema.json"


def build_schema() -> dict:
    """Return the JSON Schema for the StoryDTO wire model."""
    schema = StoryDTO.model_json_schema()
    schema["title"] = "Story"
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    return schema


def main() -> None:
    schema = build_schema()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUT_PATH}")


if __name__ == "__main__":
    main()
