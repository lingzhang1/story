"""Offline tests for Rich Editorial Asset Understanding v2 (moment_understanding/2).

No live model. Exercises the canonical v2 contract, the editorial candidate schema
and validation, the engine's server-minted v2 provenance, and v1 read-only
backward compatibility. Editorial Pipeline v2 — P1-B §13.
"""

from __future__ import annotations

import io
import json
from uuid import uuid4

import pytest
from fastapi.testclient import TestClient
from PIL import Image

from app.deps import get_asset_understanding_engine
from app.main import create_app
from asset_engine import (
    DEFAULT_AU_MODEL,
    PROMPT_VERSION,
    SCHEMA_VERSION,
    RealAssetUnderstandingEngine,
)
from contracts.schemas.ai_contracts import (
    MomentEditorial,
    MomentUnderstandingContract,
    NarrativeCandidate,
    VisualCandidate,
)
from model_gateway import FakeModelGateway

# ----------------------------------------------------------------------------- fixtures


def _jpeg() -> bytes:
    b = io.BytesIO()
    Image.new("RGB", (24, 24), (90, 110, 130)).save(b, format="JPEG")
    return b.getvalue()


def _frames(n=24, step=100):
    files = [("frames", (f"f{i}.jpg", _jpeg(), "image/jpeg")) for i in range(n)]
    fmeta = json.dumps([{"t_ms": i * step} for i in range(n)])
    return files, fmeta


def _meta(**kw):
    base = {"moment_id": "11111111-1111-1111-1111-111111111111"}
    base.update(kw)
    return json.dumps(base)


def _client(engine):
    app = create_app()
    app.dependency_overrides[get_asset_understanding_engine] = lambda: engine
    return TestClient(app)


_OBSERVED = {
    "summary": "A girl twirls in a dress in a yard.",
    "subjects": ["girl", "dress"],
    "events": [{"start_time": 0.0, "end_time": 8.0, "description": "child plays and twirls"}],
    "temporal_order_note": "walks in, then twirls, then stops",
    "useful_segments": [{"start_time": 0.0, "end_time": 8.0, "why_useful": "complete play sequence"}],
}
_STORY_CTX = {"story_utility": "strong_elsewhere"}


def _v2_model_output(visual=None, narrative=None):
    """A v2-shaped model payload (server mints provenance; editorial is model-produced)."""
    out = {"observed": _OBSERVED, "story_context": _STORY_CTX}
    editorial = {}
    if visual is not None:
        editorial["visual_candidates"] = visual
    if narrative is not None:
        editorial["narrative_candidates"] = narrative
    if editorial:
        out["editorial"] = editorial
    return out


# ----------------------------------------------------------------------------- contract


def test_v2_is_canonical_default_version():
    c = MomentUnderstandingContract(
        moment_id=uuid4(),
        observed={"summary": "s"},
        story_context={"story_utility": "none"},
    )
    assert c.schema_version == "moment_understanding/2"
    assert c.prompt_version == "au_prompt/2"
    assert c.editorial is None  # a record with no editorial is valid (and not v2-enriched)
    assert c.is_v2 is False


def test_v1_record_decodes_read_only():
    """An existing dev v1 record (no editorial, old versions) still validates — no re-analysis."""
    v1 = {
        "moment_id": str(uuid4()),
        "schema_version": "moment_understanding/1",
        "prompt_version": "au_prompt/1",
        "observed": _OBSERVED,
        "story_context": _STORY_CTX,
    }
    r = MomentUnderstandingContract.model_validate(v1)
    assert r.schema_version == "moment_understanding/1"
    assert r.editorial is None
    assert r.is_v2 is False  # recognized as needing v2 enrichment


def test_multiple_visual_and_narrative_candidates():
    ed = MomentEditorial(
        visual_candidates=[
            VisualCandidate(start_time=1.0, end_time=3.0, peak_time=2.0, visual_value="twirl apex"),
            VisualCandidate(start_time=5.0, end_time=12.0, visual_value="long expressive run"),  # not short
        ],
        narrative_candidates=[
            NarrativeCandidate(start_time=0.0, end_time=8.0, what_happens="play sequence", why_matters="context"),
            NarrativeCandidate(start_time=8.0, end_time=30.0, what_happens="longer scene", why_matters="progression"),
        ],
    )
    assert len(ed.visual_candidates) == 2
    assert len(ed.narrative_candidates) == 2
    # a visual candidate may be longer than 5s — not a contract limit
    assert ed.visual_candidates[1].end_time - ed.visual_candidates[1].start_time == pytest.approx(7.0)


def test_zero_candidates_is_valid():
    ed = MomentEditorial()
    assert ed.visual_candidates == []
    assert ed.narrative_candidates == []


def test_missing_peak_is_allowed():
    vc = VisualCandidate(start_time=1.0, end_time=3.0, visual_value="uncertain peak")
    assert vc.peak_time is None  # uncertainty retained, not invented


def test_invalid_interval_rejected():
    with pytest.raises(Exception):
        VisualCandidate(start_time=3.0, end_time=1.0, visual_value="x")
    with pytest.raises(Exception):
        NarrativeCandidate(start_time=5.0, end_time=5.0, what_happens="x", why_matters="y")


def test_peak_out_of_bounds_rejected():
    with pytest.raises(Exception):
        VisualCandidate(start_time=1.0, end_time=3.0, peak_time=9.0, visual_value="x")


def test_no_beauty_score_field():
    with pytest.raises(Exception):
        VisualCandidate.model_validate(
            {"start_time": 1.0, "end_time": 3.0, "visual_value": "x", "beauty_score": 0.9}
        )


def test_spoken_meaning_defaults_unknown():
    nc = NarrativeCandidate(start_time=0.0, end_time=4.0, what_happens="people talk", why_matters="interaction")
    assert nc.spoken_meaning == "unknown"  # dialogue never invented from frames


# ----------------------------------------------------------------------------- engine/endpoint


def test_engine_mints_v2_provenance_with_editorial():
    visual = [{"start_time": 1.0, "end_time": 3.0, "peak_time": 2.0, "visual_value": "twirl apex", "confidence": 0.7}]
    narrative = [{"start_time": 0.0, "end_time": 8.0, "what_happens": "play", "why_matters": "context"}]
    engine = RealAssetUnderstandingEngine(
        FakeModelGateway(response=_v2_model_output(visual, narrative)), model_id=DEFAULT_AU_MODEL
    )
    client = _client(engine)
    files, fmeta = _frames()
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": fmeta}, files=files)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["schema_version"] == SCHEMA_VERSION == "moment_understanding/2"
    assert body["prompt_version"] == PROMPT_VERSION == "au_prompt/3"
    assert len(body["editorial"]["visual_candidates"]) == 1
    assert len(body["editorial"]["narrative_candidates"]) == 1
    assert body["editorial"]["visual_candidates"][0]["peak_time"] == 2.0
    assert body["editorial"]["narrative_candidates"][0]["spoken_meaning"] == "unknown"
    assert body["editorial"]["analysis_version"] == "au_editorial/1"


def test_engine_accepts_model_output_without_editorial():
    """A model that returns no editorial block still resolves (editorial optional); the
    server marks it v2 by provenance but editorial is None — a legitimate no-candidate result."""
    engine = RealAssetUnderstandingEngine(
        FakeModelGateway(response=_v2_model_output()), model_id=DEFAULT_AU_MODEL
    )
    client = _client(engine)
    files, fmeta = _frames()
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": fmeta}, files=files)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["schema_version"] == "moment_understanding/2"
    assert body.get("editorial") is None


def test_observed_block_unchanged_from_v1_shape():
    """v2 preserves the v1 observed block byte-for-byte (same consumers: useful_segments, events)."""
    engine = RealAssetUnderstandingEngine(
        FakeModelGateway(response=_v2_model_output()), model_id=DEFAULT_AU_MODEL
    )
    client = _client(engine)
    files, fmeta = _frames()
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": fmeta}, files=files)
    body = resp.json()
    assert body["observed"]["useful_segments"] == _OBSERVED["useful_segments"]
    assert body["observed"]["events"] == _OBSERVED["events"]


# ----------------------------------------------------------------------------- fallback diagnostics (§7)

def test_au_result_reports_fallback_diagnostics():
    """When the primary provider raises ProviderError, FallbackModelGateway serves on the fallback and
    AUResult records requested(primary)/served-provider/used_fallback — privacy-safe, no keys/prompt/bytes."""
    from model_gateway import FallbackModelGateway, ProviderError, StructuredResult, Usage
    from asset_engine import RealAssetUnderstandingEngine, AUFrame, AURequestMeta
    from uuid import uuid4

    class _PrimaryBoom:
        model_id = "gemini-x"
        def generate_structured(self, req): raise ProviderError("gemini transport error: TimeoutError")
    class _FallbackOK:
        model_id = "openai-y"
        def generate_structured(self, req):
            return StructuredResult(data={"observed": _OBSERVED, "story_context": _STORY_CTX},
                                    usage=Usage(input_tokens=10, output_tokens=5, total_tokens=15),
                                    attempts=1, repaired=False, model="openai-y", provider="openai",
                                    stop_reason="stop")
    gw = FallbackModelGateway(_PrimaryBoom(), _FallbackOK())
    eng = RealAssetUnderstandingEngine(gw, model_id="gemini-x")
    r = eng.analyze([AUFrame(b"x", 0)], AURequestMeta(moment_id=uuid4()))
    assert r.used_fallback is True
    assert r.requested_model == "gemini-x"    # the configured primary
    assert r.served_provider == "openai"      # what actually served
    assert r.model == "openai-y"

def test_au_result_no_fallback_on_primary_success():
    from model_gateway import FallbackModelGateway, StructuredResult, Usage
    from asset_engine import RealAssetUnderstandingEngine, AUFrame, AURequestMeta
    from uuid import uuid4
    class _PrimaryOK:
        model_id = "gemini-x"
        def generate_structured(self, req):
            return StructuredResult(data={"observed": _OBSERVED, "story_context": _STORY_CTX},
                                    usage=Usage(input_tokens=10, output_tokens=5, total_tokens=15),
                                    attempts=1, repaired=False, model="gemini-x", provider="gemini",
                                    stop_reason="stop")
    class _Fb:
        model_id = "openai-y"
        def generate_structured(self, req): raise AssertionError("fallback must not be called")
    gw = FallbackModelGateway(_PrimaryOK(), _Fb())
    eng = RealAssetUnderstandingEngine(gw, model_id="gemini-x")
    r = eng.analyze([AUFrame(b"x", 0)], AURequestMeta(moment_id=uuid4()))
    assert r.used_fallback is False
    assert r.served_provider == "gemini"
