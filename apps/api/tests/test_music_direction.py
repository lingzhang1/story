"""M-c MusicDirection inference — engine + endpoint tests.

Covers: deterministic inference, pace->energy, feeling/style->mood_tags, Guide
framing as context, graceful fallback, endpoint round-trip + 422 on bad intent.
No model call (deterministic engine)."""
from __future__ import annotations

from uuid import uuid4

from fastapi.testclient import TestClient

from contracts.schemas.ai_contracts import CreativeIntentContract, MusicDirectionContract
from music_direction import DeterministicMusicDirectionEngine
from app.main import create_app


def _intent(**kw) -> CreativeIntentContract:
    base = dict(id=uuid4(), summary="A story about learning guitar")
    base.update(kw)
    return CreativeIntentContract(**base)


def test_infer_pace_maps_to_energy():
    eng = DeterministicMusicDirectionEngine()
    assert eng.infer(_intent(pace="slow")).energy.value == "low"
    assert eng.infer(_intent(pace="moderate")).energy.value == "medium"
    assert eng.infer(_intent(pace="fast")).energy.value == "high"
    assert eng.infer(_intent()).energy is None  # no pace -> no fabricated energy


def test_infer_feeling_and_style_to_mood_tags():
    eng = DeterministicMusicDirectionEngine()
    md = eng.infer(_intent(desired_feeling=["warm", "emotional", "hopeful"], style_tags=["intimate"]))
    assert "emotional" in md.mood_tags and "intimate" in md.mood_tags and "uplifting" in md.mood_tags
    assert md.mood_tags == list(dict.fromkeys(md.mood_tags))  # dedup, order-stable


def test_infer_uses_guide_framing_as_context():
    eng = DeterministicMusicDirectionEngine()
    md = eng.infer(_intent(desired_feeling=["cinematic"]),
                   guide_framing_summary="The vast scale of the mountains")
    assert "vast scale of the mountains" in md.summary
    assert isinstance(md, MusicDirectionContract)


def test_infer_graceful_fallback_when_no_signal():
    eng = DeterministicMusicDirectionEngine()
    md = eng.infer(_intent(summary="quiet solitude by the sea"))
    assert md.mood_tags == []  # never invents a generic feel
    assert "quiet solitude by the sea" in md.summary
    assert md.progression is None  # structured arc is MusicPlan's job


def test_infer_is_deterministic():
    eng = DeterministicMusicDirectionEngine()
    i = _intent(desired_feeling=["energetic"], pace="fast")
    assert eng.infer(i).model_dump() == eng.infer(i).model_dump()


def test_endpoint_round_trips():
    client = TestClient(create_app())
    body = {"creative_intent": _intent(desired_feeling=["emotional"], pace="moderate").model_dump(mode="json"),
            "guide_framing_summary": "a first full song"}
    r = client.post("/v1/music-direction", json=body)
    assert r.status_code == 200, r.text
    md = r.json()
    assert md["energy"] == "medium"
    assert "emotional" in md["mood_tags"]


def test_endpoint_rejects_bad_intent():
    client = TestClient(create_app())
    r = client.post("/v1/music-direction", json={"creative_intent": {"not": "valid"}})
    assert r.status_code == 422
