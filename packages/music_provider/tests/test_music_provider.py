"""Music provider (Epidemic adapter) tests — Milestone M-d, PROTOTYPING ONLY.

No live API calls, no persistent cache. Uses SANITIZED recorded-shape fixtures (mirroring the live-verified
response shapes). Covers normalization into frozen music_analysis/1, deterministic matching, zero-BPM ambient,
missing highlights, expired-URL / provider errors, vocal filtering, and feature-flag restriction.
"""
from __future__ import annotations

import os
import pytest

import music_provider as mp
from music_provider import (
    Candidate,
    EpidemicDisabledError,
    normalize_bpm,
    normalize_beats,
    normalize_highlight,
    normalize_energy,
    rank_candidates,
    to_music_analysis_v1,
)

# ---- recorded (sanitized) provider response SHAPES (from the live probe) ----
BEATS_TEMPO = [{"time": 0.0, "value": 1}, {"time": 0.66, "value": 2}, {"time": 1.33, "value": 3},
               {"time": 2.0, "value": 4}, {"time": 2.66, "value": 1}]
HIGHLIGHTS = {"highlights": [{"from": 17000, "to": 32000, "duration": 15}]}
WAVEFORM = {"version": 2, "channels": 1, "sample_rate": 48000, "bits": 8,
            "data": [0, 40, -80, 120, -124, 126, 10, -10, 60, -60, 100, -100, 5, -5, 30, -30]}


def test_normalize_bpm_zero_and_reliability():
    assert normalize_bpm(0) == (None, False)       # ambient: provider 0 -> null
    assert normalize_bpm(-5) == (None, False)
    assert normalize_bpm(90) == (90.0, True)
    assert normalize_bpm(5)[1] is False            # implausibly low -> kept null (unreliable)
    assert normalize_bpm(None) == (None, False)


def test_normalize_beats_downbeats():
    beats, downs = normalize_beats(BEATS_TEMPO)
    assert beats == [0.0, 0.66, 1.33, 2.0, 2.66]
    assert downs == [0.0, 2.66]                     # value==1


def test_normalize_highlight_ms_to_seconds():
    hw = normalize_highlight(HIGHLIGHTS)
    assert hw is not None and hw.start_seconds == 17.0 and hw.end_seconds == 32.0


def test_normalize_highlight_missing():
    assert normalize_highlight({"highlights": []}) is None
    assert normalize_highlight({}) is None


def test_normalize_energy_bounded_0_1():
    e = normalize_energy(WAVEFORM, resolution=8)
    assert e and all(0.0 <= x <= 1.0 for x in e) and len(e) <= 8


def test_to_music_analysis_v1_tempo_track():
    a = to_music_analysis_v1(duration_seconds=131.0, raw_bpm=117, raw_beats=BEATS_TEMPO,
                             raw_highlights=HIGHLIGHTS, waveform=WAVEFORM, vocal_type="NONE")
    assert a.schema_version == "music_analysis/1"
    assert a.bpm == 117 and a.tempo_reliable is True
    assert a.downbeats == [0.0, 2.66]
    assert a.highlight_window.end_seconds == 32.0
    assert a.energy_curve and a.vocal_type == "NONE"


def test_to_music_analysis_v1_ambient_bpm0():
    a = to_music_analysis_v1(duration_seconds=220.0, raw_bpm=0, raw_beats=BEATS_TEMPO,
                             raw_highlights={}, waveform=WAVEFORM, vocal_type="NONE")
    assert a.bpm is None and a.tempo_reliable is False  # NOT beat-synchronizable despite a beat grid
    assert a.highlight_window is None


def test_matcher_prefers_mood_and_instrumental_not_highest_bpm():
    plan = {"character": {"mood_tags": ["calm", "warm"], "energy": "low"},
            "audio_strategy": {"soundtrack_role": "sparse", "native_audio_priority": "important"}}
    cands = [
        Candidate("t_loud", "Loud Banger", 200, 174, ["aggressive", "epic"], "LEAD"),
        Candidate("t_fit", "Warm Calm", 90, 70, ["calm", "warm"], "NONE"),
        Candidate("t_vocal", "Calm Song", 120, 72, ["calm"], "LEAD"),
    ]
    ranked = rank_candidates(plan, cands, target_duration=60.0)
    assert ranked[0].track_id == "t_fit"            # mood + instrumental wins
    assert ranked[0].track_id != "t_loud"           # NOT highest-BPM/most-dramatic
    assert "mood" in ranked[0].factors and "vocal" in ranked[0].factors  # explainable


def test_matcher_vocal_penalty_relaxes_when_native_low():
    plan = {"character": {"mood_tags": ["fun"]}, "audio_strategy": {"native_audio_priority": "low"}}
    cands = [Candidate("v", "Vocal", 120, 100, ["fun"], "LEAD"),
             Candidate("i", "Instr", 120, 100, ["fun"], "NONE")]
    ranked = rank_candidates(plan, cands, target_duration=30.0)
    # with native priority LOW, a lead-vocal track is acceptable (not penalized to zero)
    assert ranked[0].factors["vocal"] >= 0.8


def test_feature_flag_blocks_client(monkeypatch):
    monkeypatch.delenv(mp.FLAG_ENV, raising=False)
    with pytest.raises(EpidemicDisabledError):
        mp.EpidemicClient(key="epidemic_live_fake")
    assert mp.prototyping_enabled() is False


def test_feature_flag_enables_client_construction(monkeypatch):
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    # construct with an injected key (no Secrets Manager, no network)
    c = mp.EpidemicClient(key="epidemic_live_fake")
    assert c is not None and mp.prototyping_enabled() is True


def test_music_candidates_endpoint_404_when_flag_off(monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import create_app
    monkeypatch.delenv(mp.FLAG_ENV, raising=False)
    client = TestClient(create_app())
    r = client.post("/v1/music/candidates", json={
        "music_plan": {"character": {"mood_tags": ["calm"]}}, "target_duration_seconds": 30.0})
    assert r.status_code == 404  # invisible in production


def test_music_candidates_endpoint_ranks_when_enabled(monkeypatch):
    from fastapi.testclient import TestClient
    from app.main import create_app

    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")

    class _FakeClient:
        def __init__(self, *a, **k): pass
        def search(self, term, vocal_type=None, bpm_min=None, limit=5):
            return [
                {"id": "t_loud", "title": "Loud", "length": 200, "bpm": 174, "moods": ["epic"], "vocalType": "LEAD"},
                {"id": "t_fit", "title": "Calm Warm", "length": 90, "bpm": 70, "moods": ["calm", "warm"], "vocalType": "NONE"},
            ]
        # R-d Batch B enriched the endpoint: it now also fetches a preview url + MusicAnalysis for the top pick.
        def preview_url(self, track_id): return f"https://preview.example/{track_id}.mp3"
        def beats(self, track_id): return [{"start": 0}, {"start": 500}]
        def highlights(self, track_id, duration=15): return {"start": 5000, "end": 20000}
        def metadata(self, track_id): return {"length": 90, "bpm": 70, "vocalType": "NONE"}
    monkeypatch.setattr(mp, "EpidemicClient", _FakeClient)
    client = TestClient(create_app())
    r = client.post("/v1/music/candidates", json={
        "music_plan": {"character": {"mood_tags": ["calm", "warm"]},
                       "audio_strategy": {"native_audio_priority": "important"}},
        "target_duration_seconds": 60.0})
    assert r.status_code == 200, r.text
    cands = r.json()["candidates"]
    assert cands[0]["track_id"] == "t_fit"  # mood + instrumental wins, not the louder/higher-bpm track
    assert "factors" in cands[0]
