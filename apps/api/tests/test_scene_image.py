"""scene-image (Unsplash reference-image proxy) — backend tests.

Covers req 11: security (key never leaks, SSRF-bounded track, flag gate), bounded+sanitized query
(no URLs/emails/overlong/control chars), metadata-only caching (bounds provider calls), provider-error
and auth fail-soft (never 5xx / never blocks the UI), and Unsplash compliance of the returned metadata
(hotlinked urls.*, attribution text + utm links, download_location present but NOT auto-fired).

No network and no real key: the Unsplash client is a fake injected via the module factory seam.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import app.main as main_mod
from app.main import create_app
import scene_image as si


_SAMPLE = si.SceneImage(
    photo_id="abc123",
    image_url="https://images.unsplash.com/photo-abc?ixid=xyz&w=1080",
    thumb_url="https://images.unsplash.com/photo-abc?ixid=xyz&w=200",
    attribution_text="Photo by Jane Doe on Unsplash",
    photographer_name="Jane Doe",
    photographer_url="https://unsplash.com/@jane?utm_source=yotale&utm_medium=referral",
    source_url="https://unsplash.com/photos/abc123?utm_source=yotale&utm_medium=referral",
    download_location="https://api.unsplash.com/photos/abc123/download?ixid=xyz",
    width=1080, height=720, color="#223344", alt_description="city skyline at dusk",
)


class _FakeClient:
    def __init__(self, *, result=_SAMPLE, raise_exc=None):
        self.result = result
        self.raise_exc = raise_exc
        self.search_calls = 0
        self.track_calls = []

    def search_one(self, query):
        self.search_calls += 1
        if self.raise_exc:
            raise self.raise_exc
        return self.result

    def trigger_download(self, loc):
        self.track_calls.append(loc)


@pytest.fixture(autouse=True)
def _reset(monkeypatch):
    monkeypatch.setenv("STORY_SCENE_IMAGES", "1")
    main_mod._SCENE_IMAGE_CACHE = None
    main_mod._SCENE_IMAGE_CLIENT = None
    main_mod._SCENE_IMAGE_CLIENT_FACTORY = None
    yield
    main_mod._SCENE_IMAGE_CLIENT_FACTORY = None


def _client(fake=None):
    if fake is not None:
        main_mod._SCENE_IMAGE_CLIENT_FACTORY = lambda: fake
    return TestClient(create_app())


def test_flag_off_returns_404(monkeypatch):
    monkeypatch.delenv("STORY_SCENE_IMAGES", raising=False)
    c = TestClient(create_app())
    r = c.post("/v1/scene-image", json={"query": "city skyline"})
    assert r.status_code == 404


def test_returns_metadata_only_with_attribution_and_hotlink():
    fake = _FakeClient()
    c = _client(fake)
    r = c.post("/v1/scene-image", json={"query": "wide shot city skyline at dusk"})
    assert r.status_code == 200
    img = r.json()["image"]
    assert img["provider"] == "unsplash"
    assert img["image_url"].startswith("https://images.unsplash.com/")
    assert img["attribution_text"] == "Photo by Jane Doe on Unsplash"
    assert "utm_source=yotale" in img["source_url"] and "utm_medium=referral" in img["source_url"]
    assert "utm_source=yotale" in img["photographer_url"]
    assert img["download_location"].startswith("https://api.unsplash.com/")
    assert "bytes" not in img and "data" not in img


def test_display_does_not_fire_download_tracking():
    fake = _FakeClient()
    c = _client(fake)
    c.post("/v1/scene-image", json={"query": "candid group laughing at dinner"})
    assert fake.track_calls == []


@pytest.mark.parametrize("bad", [
    "",
    "   ",
    "x" * 200,
    "see http://evil.example/leak",
    "contact me jane@example.com",
])
def test_bounded_query_rejected_as_text_only_fallback(bad):
    fake = _FakeClient()
    c = _client(fake)
    r = c.post("/v1/scene-image", json={"query": bad})
    assert r.status_code == 200
    assert r.json()["image"] is None
    assert r.json()["status"] == "invalid_query"
    assert fake.search_calls == 0


def test_sanitize_query_unit():
    assert si.sanitize_query("  wide   shot\tskyline  ") == "wide shot skyline"
    with pytest.raises(si.SceneImageQueryError):
        si.sanitize_query("http://x")
    with pytest.raises(si.SceneImageQueryError):
        si.sanitize_query("a" * 500)


def test_metadata_cache_bounds_provider_calls():
    fake = _FakeClient()
    c = _client(fake)
    for _ in range(3):
        r = c.post("/v1/scene-image", json={"query": "same scene phrase"})
        assert r.status_code == 200 and r.json()["status"] == "ok"
    assert fake.search_calls == 1
    assert c.post("/v1/scene-image", json={"query": "same scene phrase"}).json()["cached"] is True


def test_no_match_is_cached_and_text_only():
    fake = _FakeClient(result=None)
    c = _client(fake)
    r = c.post("/v1/scene-image", json={"query": "an impossible scene"})
    assert r.json()["image"] is None and r.json()["status"] == "no_match"
    c.post("/v1/scene-image", json={"query": "an impossible scene"})
    assert fake.search_calls == 1


def test_provider_error_is_graceful_text_only():
    fake = _FakeClient(raise_exc=si.SceneImageProviderError("unsplash rate limited (429)"))
    c = _client(fake)
    r = c.post("/v1/scene-image", json={"query": "street food after dark"})
    assert r.status_code == 200
    assert r.json()["image"] is None and r.json()["status"] == "provider_error"


def test_auth_error_is_graceful_text_only():
    fake = _FakeClient(raise_exc=si.SceneImageAuthError("bad key"))
    c = _client(fake)
    r = c.post("/v1/scene-image", json={"query": "temple at sunrise"})
    assert r.status_code == 200
    assert r.json()["image"] is None and r.json()["status"] == "unavailable"


def test_track_fires_only_for_unsplash_host():
    fake = _FakeClient()
    c = _client(fake)
    r = c.post("/v1/scene-image/track",
               json={"download_location": "https://api.unsplash.com/photos/abc/download?ixid=z"})
    assert r.status_code == 204
    assert fake.track_calls == ["https://api.unsplash.com/photos/abc/download?ixid=z"]
    r = c.post("/v1/scene-image/track", json={"download_location": "https://evil.example/internal"})
    assert r.status_code == 204
    assert len(fake.track_calls) == 1


def test_track_flag_off_404(monkeypatch):
    monkeypatch.delenv("STORY_SCENE_IMAGES", raising=False)
    c = TestClient(create_app())
    r = c.post("/v1/scene-image/track", json={"download_location": "https://api.unsplash.com/x"})
    assert r.status_code == 404
