"""Story Director offline eval + model comparison (Milestone C3A).

Runs INITIALIZE across the contrast cases (same-intent x scenes, same-scene x
intents, TMB-home anchor, safety) through a chosen model, applies the engine's
integrity + safety guards, and prints concept/beats/shots/decision for manual
rubric review. Model via arg.

Usage: TMPDIR=/tmp .venv/bin/python evals/run_story_director.py <model_id>
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

from story_director import RealStoryDirectorEngine  # noqa: E402
from model_gateway import BedrockModelGateway, ProviderError, StructuredOutputError  # noqa: E402

TMB = {"summary": "8-day Tour du Mont Blanc hike; peaceful and adventurous 60s video; human, mountain, beautiful views.",
       "desired_feeling": ["peaceful", "adventurous"], "emphasis": ["person", "environment", "journey"],
       "pace": "slow", "target_duration_seconds": 60, "raw_user_description": "8 days hiking in TMB..."}
ENERGETIC = {"summary": "fun, fast, high-energy clip", "desired_feeling": ["energetic", "playful"], "pace": "fast"}
ORDINARY = {"summary": "one ordinary day of my life", "desired_feeling": ["calm"], "emphasis": ["everyday"]}

HOME = {"summary": "A room with a hiking backpack on a chair, wooden floor, a window and a bookshelf.",
        "environment_tags": ["indoor", "room"], "operator_space": "moderate", "lighting": "bright daylight",
        "subjects": [{"label": "red backpack", "prominence": "high"}, {"label": "chair", "prominence": "medium"},
                     {"label": "window", "prominence": "medium"}, {"label": "bookshelf", "prominence": "medium"}],
        "composition_opportunities": ["the window provides a natural frame", "the bookshelf is a strong vertical line"]}
TRAIL = {"summary": "Open alpine trail leading toward a large mountain, strong depth, one hiker.",
         "environment_tags": ["mountain", "trail"], "operator_space": "open", "lighting": "bright daylight",
         "subjects": [{"label": "hiker", "prominence": "low"}, {"label": "mountain", "prominence": "high"}],
         "composition_opportunities": ["trail creates a strong line toward the mountain", "scale contrast"]}
EDGE = {"summary": "Narrow ridge trail with a steep drop on one side.",
        "environment_tags": ["ridge", "cliff"], "operator_space": "limited",
        "subjects": [{"label": "hiker", "prominence": "medium"}],
        "constraints": ["steep drop nearby", "narrow operator space"]}

CASES = [
    ("TMB x home (anchor)", TMB, HOME),
    ("TMB x trail", TMB, TRAIL),
    ("ordinary-day x home (intent axis)", ORDINARY, HOME),
    ("energetic x edge (safety)", ENERGETIC, EDGE),
]


def main() -> None:
    model = sys.argv[1] if len(sys.argv) > 1 else "us.anthropic.claude-sonnet-4-5-20250929-v1:0"
    eng = RealStoryDirectorEngine(BedrockModelGateway(model_id=model))
    print(f"Story Director — model {model}\n")
    for name, ci, su in CASES:
        t = time.monotonic()
        try:
            out = eng.initialize(ci, su, {"target_duration_seconds": ci.get("target_duration_seconds", 15)})
            dt = (time.monotonic() - t) * 1000
            print(f"=== {name}  ({dt:.0f}ms) ===")
            print(f"  CONCEPT: {out.concept.title} — {out.concept.summary}")
            print(f"  BEATS: " + " | ".join(f"{b.id}:{b.purpose}" for b in out.plan.beats))
            for s in out.plan.shots:
                print(f"  SHOT[{s.beat_id}] purpose={s.purpose!r}")
                print(f"       instruction={s.instruction!r}")
            print(f"  DECISION: {out.decision.action.value}" + (f" -> {out.decision.shot.instruction!r}" if out.decision.shot else ""))
        except (StructuredOutputError, ProviderError) as e:
            print(f"=== {name} ===\n  FAIL: {type(e).__name__}: {str(e)[:200]}")
        print()


if __name__ == "__main__":
    main()
