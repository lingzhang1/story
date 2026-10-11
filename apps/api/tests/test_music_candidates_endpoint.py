"""Music provider ENDPOINT tests (R-d Batch B) — the enriched /v1/music/candidates and the new
/v1/music/analysis + /v1/music/soundtrack. The Epidemic client is STUBBED (no network, no real key) and the
prototyping flag is toggled via monkeypatch. Verifies preview + analysis enrichment, selected-track analysis,
the authorized-soundtrack link (prototyping, commercial export OFF), and the flag-off 404 for all three.
"""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient

import app.main as main_mod
from app.main import create_app
import music_provider as _mp


class _FakeClient:
    def __init__(self, *a, **k): pass
    def search(self, term, *, vocal_type=None, bpm_min=None, limit=5):
        return [
            {"id": "t1", "title": "Alpine Journey", "length": 62, "bpm": 90,
             "moods": ["cinematic", "emotional"], "vocalType": "NONE"},
            {"id": "t2", "title": "Into the Mountains", "length": 58, "bpm": 120,
             "moods": ["epic"], "vocalType": "NONE"},
        ]
    def preview_url(self, track_id): return f"https://preview.example/{track_id}.mp3"
    def beats(self, track_id): return [{"start": 0}, {"start": 500}, {"start": 1000}]
    def highlights(self, track_id, duration=15): return {"start": 10000, "end": 25000}
    def metadata(self, track_id): return {"length": 62, "bpm": 90, "vocalType": "NONE"}
    def download_link(self, track_id, *, quality="normal"): return f"https://dl.example/{track_id}.mp3?sig=abc"
    def waveform_for_track(self, track_id): return None
    def search_page(self, term, *, page_size=10, cursor=None):
        # /v1/music/search tests use query 'mountain' -> paged s0.. / s_last.
        # /v1/music/candidates builds the term from mood_tags (e.g. 'cinematic emotional') -> t1/t2 page 1,
        #   then a second page of different tracks when a cursor is supplied.
        if "mountain" in term:
            if cursor is None:
                return ([{"id": f"s{i}", "title": f"Search {i}", "length": 50 + i, "vocalType": "NONE"}
                         for i in range(page_size)], "p2")
            return ([{"id": "s_last", "title": "Last", "length": 70, "vocalType": "LEAD"}], None)
        # candidates path
        if cursor is None:
            return ([
                {"id": "t1", "title": "Alpine Journey", "length": 62, "bpm": 90,
                 "moods": ["cinematic", "emotional"], "vocalType": "NONE"},
                {"id": "t2", "title": "Into the Mountains", "length": 58, "bpm": 120,
                 "moods": ["epic"], "vocalType": "NONE"},
            ], "cand_p2")
        return ([
            {"id": "t3", "title": "Second Page Track", "length": 60, "bpm": 100,
             "moods": ["cinematic"], "vocalType": "NONE"},
        ], None)


@pytest.fixture
def proto_client(monkeypatch):
    monkeypatch.setattr(_mp, "prototyping_enabled", lambda: True)
    monkeypatch.setattr(main_mod._mp, "prototyping_enabled", lambda: True)
    monkeypatch.setattr(main_mod._mp, "EpidemicClient", _FakeClient)
    return TestClient(create_app())


def _plan():
    return {"character": {"mood_tags": ["cinematic", "emotional"], "energy": "dynamic"},
            "audio_strategy": {"soundtrack_role": "continuous", "native_audio_priority": "selective"}}


def test_candidates_enriched_with_preview_and_top_analysis(proto_client):
    r = proto_client.post("/v1/music/candidates",
                          json={"music_plan": _plan(), "target_duration_seconds": 60.0, "limit": 5})
    assert r.status_code == 200, r.text
    body = r.json()
    assert len(body["candidates"]) == 2
    assert all(c.get("preview_url", "").startswith("https://preview.example/") for c in body["candidates"])
    # top pick is the instrumental mood-matching track; analysis is normalized music_analysis/1
    assert body["top_track_id"] in ("t1", "t2")
    assert body["top_music_analysis"] is not None
    assert body["top_music_analysis"]["duration_seconds"] == 62.0
    assert "beats" in body["top_music_analysis"] and "energy_curve" in body["top_music_analysis"]


def test_analysis_for_chosen_track(proto_client):
    r = proto_client.post("/v1/music/analysis", json={"track_id": "t2"})
    assert r.status_code == 200, r.text
    a = r.json()
    assert a["duration_seconds"] == 62.0
    assert "tempo_reliable" in a


def test_candidates_next_page_returns_different_options(proto_client):
    plan = _plan()
    r1 = proto_client.post("/v1/music/candidates",
                           json={"music_plan": plan, "target_duration_seconds": 60.0, "limit": 5})
    assert r1.status_code == 200, r1.text
    b1 = r1.json()
    assert b1["next_cursor"] == "cand_p2"                 # page 1 offers a next page
    assert b1["top_music_analysis"] is not None            # page 1 carries the top-pick analysis
    assert {c["track_id"] for c in b1["candidates"]} == {"t1", "t2"}
    r2 = proto_client.post("/v1/music/candidates",
                           json={"music_plan": plan, "target_duration_seconds": 60.0, "limit": 5,
                                 "cursor": b1["next_cursor"]})
    assert r2.status_code == 200, r2.text
    b2 = r2.json()
    assert {c["track_id"] for c in b2["candidates"]} == {"t3"}   # DIFFERENT tracks on page 2
    assert b2["top_music_analysis"] is None                      # analysis is page-1 only
    assert b2["top_track_id"] is None
    assert b2["next_cursor"] is None


def test_search_page1_has_more_and_previews(proto_client):
    r = proto_client.post("/v1/music/search", json={"query": "mountain", "page_size": 4})
    assert r.status_code == 200, r.text
    b = r.json()
    assert len(b["candidates"]) == 4
    assert b["next_cursor"] == "p2"          # more pages available
    assert all(c["preview_url"].startswith("https://preview.example/") for c in b["candidates"])
    assert all(c["score"] == 0.0 for c in b["candidates"])  # search results unranked


def test_search_page2_ends(proto_client):
    r = proto_client.post("/v1/music/search", json={"query": "mountain", "page_size": 4, "cursor": "p2"})
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["next_cursor"] is None          # last page
    assert b["candidates"][0]["track_id"] == "s_last"


def test_search_404_when_flag_off(monkeypatch):
    monkeypatch.setattr(main_mod._mp, "prototyping_enabled", lambda: False)
    c = TestClient(create_app())
    assert c.post("/v1/music/search", json={"query": "x"}).status_code == 404


def test_soundtrack_link_is_prototyping_and_export_off(proto_client):
    r = proto_client.post("/v1/music/soundtrack", json={"track_id": "t1"})
    assert r.status_code == 200, r.text
    b = r.json()
    assert b["download_url"].startswith("https://dl.example/t1")
    assert b["usage"] == "prototyping_test"
    assert b["commercial_export_enabled"] is False


def test_all_music_provider_endpoints_404_when_flag_off(monkeypatch):
    monkeypatch.setattr(main_mod._mp, "prototyping_enabled", lambda: False)
    c = TestClient(create_app())
    assert c.post("/v1/music/candidates",
                  json={"music_plan": _plan(), "target_duration_seconds": 60.0}).status_code == 404
    assert c.post("/v1/music/analysis", json={"track_id": "t1"}).status_code == 404
    assert c.post("/v1/music/soundtrack", json={"track_id": "t1"}).status_code == 404
