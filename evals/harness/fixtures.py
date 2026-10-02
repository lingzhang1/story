"""Fixture format + loader for the DIRECT eval harness (13-evaluation.md §23-24).

A fixture is a JSON file with a stable id describing ONE evaluation case. It
does NOT pin expected prose — we evaluate semantic behavior, not strings
(§24). Deterministic checks read `component`, the inputs, and the
`expected_properties` / `forbidden_properties` only where those map to
machine-checkable rules; the rest are for the LLM-judge / human layers.

Fixture shape (component="story_director" example):

    {
      "id": "director_tmb_scale_001",
      "component": "story_director",
      "phase": "initialize",                 # or "next" (loop), "contrastive_scene", ...
      "inputs": {
        "creative_intent": { ... },          # a CreativeIntent contract instance
        "scene_understanding": { ... },      # optional
        "capture_constraints": { ... },      # optional, free-form
        "prior_director_state": { ... },     # for phase="next"
        "latest_validation": { ... }         # for phase="next"
      },
      "expected_properties": [ "uses mountain/person scale contrast", ... ],
      "forbidden_properties": [ "walking backward near edge", ... ],
      "expected_decision_action": "capture_shot",   # optional, loop fixtures
      "failure_labels": [ "GENERIC_DIRECTION" ],     # optional (taxonomy §26)
      "tags": [ "regression", "safety" ]             # optional
    }

Contrastive fixtures (§10-12) are expressed as a `group` of fixtures sharing a
`contrast_group` id and varying exactly one axis (intent OR scene); the runner
compares their outputs for material divergence.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

EVALS_ROOT = Path(__file__).resolve().parent.parent

VALID_COMPONENTS = {
    "creative_intent",
    "scene_understanding",
    "story_director",
    "end_to_end",
}


@dataclass
class Fixture:
    id: str
    component: str
    phase: str | None = None
    inputs: dict[str, Any] = field(default_factory=dict)
    expected_properties: list[str] = field(default_factory=list)
    forbidden_properties: list[str] = field(default_factory=list)
    expected_decision_action: str | None = None
    failure_labels: list[str] = field(default_factory=list)
    tags: list[str] = field(default_factory=list)
    contrast_group: str | None = None
    source_path: Path | None = None

    @classmethod
    def from_dict(cls, data: dict[str, Any], source_path: Path | None = None) -> "Fixture":
        if "id" not in data or "component" not in data:
            raise ValueError(f"fixture missing required id/component: {source_path or data}")
        if data["component"] not in VALID_COMPONENTS:
            raise ValueError(
                f"fixture {data['id']}: unknown component {data['component']!r}; "
                f"expected one of {sorted(VALID_COMPONENTS)}"
            )
        return cls(
            id=data["id"],
            component=data["component"],
            phase=data.get("phase"),
            inputs=data.get("inputs", {}),
            expected_properties=data.get("expected_properties", []),
            forbidden_properties=data.get("forbidden_properties", []),
            expected_decision_action=data.get("expected_decision_action"),
            failure_labels=data.get("failure_labels", []),
            tags=data.get("tags", []),
            contrast_group=data.get("contrast_group"),
            source_path=source_path,
        )


def load_fixture(path: str | Path) -> Fixture:
    p = Path(path)
    return Fixture.from_dict(json.loads(p.read_text()), source_path=p)


def load_fixtures(component: str | None = None, root: Path | None = None) -> list[Fixture]:
    """Load every *.fixture.json under evals/, optionally filtered by component.

    Fixtures live under evals/<component>/**.fixture.json. Ids must be unique.
    """
    base = root or EVALS_ROOT
    fixtures: list[Fixture] = []
    seen: dict[str, Path] = {}
    for p in sorted(base.rglob("*.fixture.json")):
        fx = load_fixture(p)
        if fx.id in seen:
            raise ValueError(f"duplicate fixture id {fx.id!r}: {seen[fx.id]} and {p}")
        seen[fx.id] = p
        if component is None or fx.component == component:
            fixtures.append(fx)
    return fixtures
