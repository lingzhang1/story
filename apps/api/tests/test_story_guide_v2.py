"""story_guide/2 (AI shooting script) — additive, feature-flagged backend tests.

Covers: feature-gate (404 when STORY_GUIDE_V2 off), scene-based output when on, v1 UNCHANGED,
server-minted canonical ids, and that the model can never inject image ids/urls/attribution.
Mock engine only (STORY_GUIDE_MOCK=1) — no real Bedrock call, no cost.
"""
from __future__ import annotations

import os
import uuid

import pytest
from fastapi.testclient import TestClient

from app.main import create_app
from story_guide import RealStoryGuideV2Engine
from contracts.schemas.ai_contracts import StoryGuideV2Contract


@pytest.fixture(autouse=True)
def _mock_guide(monkeypatch):
    monkeypatch.setenv("STORY_GUIDE_MOCK", "1")
    yield


def _client(v2_enabled: bool, monkeypatch) -> TestClient:
    if v2_enabled:
        monkeypatch.setenv("STORY_GUIDE_V2", "1")
    else:
        monkeypatch.delenv("STORY_GUIDE_V2", raising=False)
    return TestClient(create_app())


def _body() -> dict:
    return {"story_id": str(uuid.uuid4()), "creative_intent": {"summary": "Three days in New York"}, "scope": {}}


def test_v2_route_404_when_flag_off(monkeypatch):
    c = _client(False, monkeypatch)
    r = c.post("/v1/story-guide-v2", json=_body())
    assert r.status_code == 404


def test_v2_returns_scene_shooting_script_when_flag_on(monkeypatch):
    c = _client(True, monkeypatch)
    r = c.post("/v1/story-guide-v2", json=_body())
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["schema_version"] == "story_guide/2"
    assert b["scenes"], "expected at least one scene"
    s0 = b["scenes"][0]
    assert s0["id"] == "scene_01"
    for key in ("title", "what_to_capture", "how_to_shoot", "why_it_matters"):
        assert key in s0
    # the model output path never carries image provider metadata
    assert "image_id" not in s0 and "source_url" not in s0 and "attribution" not in s0


def test_v1_story_guide_unchanged_with_v2_enabled(monkeypatch):
    c = _client(True, monkeypatch)
    r = c.post("/v1/story-guide", json=_body())
    assert r.status_code == 200, r.text
    assert r.json()["schema_version"] == "story_guide/1"
    assert "dimensions" in r.json() and "scenes" not in r.json()


def test_mint_ids_canonicalizes_and_strips_fabricated_image_fields():
    raw = {
        "framing_summary": "x",
        "scenes": [{
            "id": "s9", "title": "T", "what_to_capture": "w", "how_to_shoot": "h", "why_it_matters": "y",
            "visual_reference_query": "wide shot city skyline",
            # an LLM trying to fabricate provider metadata — must be dropped by minting + extra=forbid
            "image_id": "HACK", "source_url": "http://evil", "attribution": "fake",
            "capture_possibilities": [{"id": "s9p1", "label": "L", "semantic_purpose": "p"}],
        }],
    }
    minted = RealStoryGuideV2Engine.mint_ids(raw)
    scene = minted["scenes"][0]
    assert scene["id"] == "scene_01"
    assert scene["capture_possibilities"][0]["id"] == "scene_01_cp_01"
    assert scene["visual_reference_query"] == "wide shot city skyline"  # generic query preserved
    assert "image_id" not in scene and "source_url" not in scene and "attribution" not in scene
    # and the canonical contract validates
    minted["story_id"] = str(uuid.uuid4())
    StoryGuideV2Contract.model_validate(minted)


def test_empty_visual_query_is_omitted_not_blank():
    minted = RealStoryGuideV2Engine.mint_ids({
        "framing_summary": "x",
        "scenes": [{"id": "s1", "title": "T", "what_to_capture": "w", "how_to_shoot": "h",
                    "why_it_matters": "y", "visual_reference_query": "   "}],
    })
    assert "visual_reference_query" not in minted["scenes"][0]
