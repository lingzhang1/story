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
from contracts.schemas import ai_contracts as _ai  # noqa: E402

OUT_PATH = Path(__file__).resolve().parent / "schemas" / "story.schema.json"
AI_OUT_DIR = Path(__file__).resolve().parent / "schemas"

# The frozen AI structured-output + boundary contracts that need standalone,
# language-neutral JSON Schema files (task §4). Name -> (model, filename).
AI_CONTRACTS: dict[str, tuple[type, str]] = {
    "CreativeIntent": (_ai.CreativeIntentContract, "creative-intent.schema.json"),
    "SceneUnderstanding": (_ai.SceneUnderstandingContract, "scene-understanding.schema.json"),
    "StoryConcept": (_ai.StoryConceptContract, "story-concept.schema.json"),
    "StoryPlan": (_ai.StoryPlanContract, "story-plan.schema.json"),
    "DirectorDecision": (_ai.DirectorDecision, "director-decision.schema.json"),
    "DirectorState": (_ai.DirectorState, "director-state.schema.json"),
    "ValidationResult": (_ai.ValidationResultContract, "validation-result.schema.json"),
    "CaptureSession": (_ai.CaptureSessionContract, "capture-session.schema.json"),
    "MusicDirection": (_ai.MusicDirectionContract, "music-direction.schema.json"),
    "MusicPlan": (_ai.MusicPlanContract, "music-plan.schema.json"),
    "AssetUnderstanding": (_ai.AssetUnderstandingContract, "asset-understanding.schema.json"),
    "MomentUnderstanding": (_ai.MomentUnderstandingContract, "moment-understanding.schema.json"),
    "StoryGuide": (_ai.StoryGuideContract, "story-guide.schema.json"),
    "StoryGuideV2": (_ai.StoryGuideV2Contract, "story-guide-v2.schema.json"),
    "StoryGuideRefinement": (_ai.StoryGuideRefinementResult, "story-guide-refinement.schema.json"),
    "StoryCoverage": (_ai.StoryCoverageContract, "story-coverage.schema.json"),
    "StoryCoverageV2": (_ai.StoryCoverageContractV2, "story-coverage-v2.schema.json"),
    "EditPlan": (_ai.EditPlanContract, "edit-plan.schema.json"),
    "EditPlanV2": (_ai.EditPlanV2Contract, "edit-plan-v2.schema.json"),
    "MusicAnalysisV1": (_ai.MusicAnalysisV1Contract, "music-analysis-v1.schema.json"),
}


def build_schema() -> dict:
    """Return the JSON Schema for the StoryDTO wire model."""
    schema = StoryDTO.model_json_schema()
    schema["title"] = "Story"
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    return schema


def build_ai_schema(title: str, model: type) -> dict:
    """Return the JSON Schema for one frozen AI/boundary contract."""
    schema = model.model_json_schema()
    schema["title"] = title
    schema["$schema"] = "https://json-schema.org/draft/2020-12/schema"
    return schema


def main() -> None:
    schema = build_schema()
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text(json.dumps(schema, indent=2, sort_keys=True) + "\n")
    print(f"wrote {OUT_PATH}")

    for title, (model, filename) in AI_CONTRACTS.items():
        out = AI_OUT_DIR / filename
        out.write_text(
            json.dumps(build_ai_schema(title, model), indent=2, sort_keys=True) + "\n"
        )
        print(f"wrote {out}")


if __name__ == "__main__":
    main()
