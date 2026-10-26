"""Endpoint tests for POST /v1/asset-understanding (multipart, no network).

Exercises the real multipart handler + frame/timestamp validation + the frozen
retryable-failure path, with the engine dependency overridden by a FakeModelGateway-
backed engine. No model is invoked.
"""

from __future__ import annotations

import io
import json

from fastapi.testclient import TestClient
from PIL import Image

from app.deps import get_asset_understanding_engine
from app.main import create_app
from asset_engine import RealAssetUnderstandingEngine, DEFAULT_AU_MODEL
from model_gateway import FakeModelGateway, ProviderError


def _jpeg(n: int = 24) -> bytes:
    b = io.BytesIO()
    Image.new("RGB", (n, n), (90, 110, 130)).save(b, format="JPEG")
    return b.getvalue()


_GOOD = {
    "observed": {
        "summary": "A quiet end-of-day meal outdoors.",
        "subjects": ["two people", "meal"],
        "events": [{"start_time": 0.0, "end_time": 20.0, "description": "eating a pouch meal together"}],
        "temporal_order_note": "sustained eating from start toward an end selfie",
        "useful_segments": [{"start_time": 0.0, "end_time": 20.0, "why_useful": "quiet eating-together"}],
    },
    "story_context": {
        "story_utility": "strong_elsewhere",
        "requested_shot_contribution": "fulfilled",
        "requested_beat_contribution": "serves beat_endofday",
    },
}


def _client(engine):
    app = create_app()
    app.dependency_overrides[get_asset_understanding_engine] = lambda: engine
    return TestClient(app)


def _meta(**kw):
    base = {"moment_id": "11111111-1111-1111-1111-111111111111"}
    base.update(kw)
    return json.dumps(base)


def _frames(n=24, start=0, step=100):
    files = [("frames", (f"f{i}.jpg", _jpeg(), "image/jpeg")) for i in range(n)]
    fmeta = json.dumps([{"t_ms": start + i * step} for i in range(n)])
    return files, fmeta


def test_asset_understanding_success():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD), model_id=DEFAULT_AU_MODEL))
    files, fmeta = _frames(24)
    resp = client.post(
        "/v1/asset-understanding",
        data={"meta": _meta(capture_context=json.dumps({"shot": {"id": "s1"}, "beat": {"id": "b1"}})) if False else _meta(),
              "frames_meta": fmeta},
        files=files,
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["schema_version"] == "moment_understanding/2"
    assert body["prompt_version"] == "au_prompt/2"
    assert body["n_frames"] == 24
    assert body["story_context"]["story_utility"] == "strong_elsewhere"
    assert len(body["observed"]["events"]) == 1


def test_capture_context_in_meta_object():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD), model_id=DEFAULT_AU_MODEL))
    files, fmeta = _frames(24)
    meta = json.dumps({
        "moment_id": "22222222-2222-2222-2222-222222222222",
        "source_capture_id": "33333333-3333-3333-3333-333333333333",
        "capture_context": {"shot": {"id": "s1", "purpose": "end of day"}, "beat": {"id": "beat_endofday"}},
    })
    resp = client.post("/v1/asset-understanding", data={"meta": meta, "frames_meta": fmeta}, files=files)
    assert resp.status_code == 200, resp.text
    # with context, requested contributions are preserved
    assert resp.json()["story_context"]["requested_shot_contribution"] == "fulfilled"


def test_rejects_wrong_frame_count():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    files, fmeta = _frames(12)
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": fmeta}, files=files)
    assert resp.status_code == 422
    assert "exactly 24" in resp.json()["detail"]


def test_rejects_nonmonotonic_timestamps():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    files, _ = _frames(24)
    bad = json.dumps([{"t_ms": 0} for _ in range(24)])  # all equal -> not increasing
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": bad}, files=files)
    assert resp.status_code == 422
    assert "monotonically increasing" in resp.json()["detail"]


def test_rejects_meta_frames_length_mismatch():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    files, _ = _frames(24)
    short = json.dumps([{"t_ms": i * 100} for i in range(23)])
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": short}, files=files)
    assert resp.status_code == 422


def test_rejects_unsupported_frame_type():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    files = [("frames", (f"f{i}.png", _jpeg(), "image/png")) for i in range(24)]
    fmeta = json.dumps([{"t_ms": i * 100} for i in range(24)])
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": fmeta}, files=files)
    assert resp.status_code == 415


def test_rejects_invalid_meta():
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(response=_GOOD)))
    files, fmeta = _frames(24)
    resp = client.post("/v1/asset-understanding", data={"meta": "{bad", "frames_meta": fmeta}, files=files)
    assert resp.status_code == 422


def test_retryable_failure_returns_503_not_fabrication():
    # gateway always fails -> engine exhausts its one retry -> AURetryableError -> 503
    client = _client(RealAssetUnderstandingEngine(FakeModelGateway(error=ProviderError("bedrock down"))))
    files, fmeta = _frames(24)
    resp = client.post("/v1/asset-understanding", data={"meta": _meta(), "frames_meta": fmeta}, files=files)
    assert resp.status_code == 503
    assert "asset_understanding_unavailable" in resp.json()["detail"]
