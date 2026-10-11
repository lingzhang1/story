"""Epidemic MCP client tests — ADDITIVE provider (internal-testing only). No live MCP calls.

Covers: surface parity with EpidemicClient (search/preview_url/download_link/metadata/beats/highlights),
MCP recording-node -> REST-shape normalization (duration ms->s, mood/vocal tags), inline lqmp3 preview
(no 402, no extra call), signed-download expiry parse, graceful degradation of beats/highlights, provider
selector (get_music_client), feature-flag gating, and SSE/GraphQL envelope parsing.
"""
from __future__ import annotations

import json

import pytest

import music_provider as mp
from music_provider.mcp_client import EpidemicMCPClient

# ---- a sanitized SearchRecordings node (mirrors the live probe shape) -------
_REC = {
    "id": "6ad53d76-31f3-423b-b5d2-a7d51f339021",
    "title": "All I Know",
    "bpm": 102,
    "audioFile": {
        "durationInMilliseconds": 190360,
        "waveformUrl": "https://audiocdn.epidemicsound.com/waveform/x.json",
        "lqmp3Url": "https://audiocdn.epidemicsound.com/lqmp3/x.mp3",
    },
    "tags": [
        {"displayName": "hopeful", "dimension": {"name": "mood"}},
        {"displayName": "restless", "dimension": {"name": "mood"}},
        {"displayName": "lead vocals", "dimension": {"name": "vocal type"}},
        {"displayName": "pop", "dimension": {"name": "genre"}},
    ],
}


def _client(monkeypatch, tool_impl):
    """Build a client with the flag on, a fake key, and _tool stubbed (no network/secrets)."""
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    c = EpidemicMCPClient(key="epidemic_live_fake")
    monkeypatch.setattr(c, "_tool", tool_impl)
    return c


def test_feature_flag_blocks_mcp_client(monkeypatch):
    monkeypatch.delenv(mp.FLAG_ENV, raising=False)
    with pytest.raises(mp.EpidemicDisabledError):
        EpidemicMCPClient(key="epidemic_live_fake")


def test_rejects_bad_key_format(monkeypatch):
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    with pytest.raises(mp.EpidemicAuthError):
        EpidemicMCPClient(key="not_an_epidemic_key")


def test_search_maps_node_to_rest_track_shape(monkeypatch):
    def fake_tool(name, args, _id=2):
        assert name == "SearchRecordings"
        assert args["query"]["term"] == "calm warm"
        assert args["first"] == 3
        return {"recordings": {"nodes": [{"recording": _REC}]}}
    c = _client(monkeypatch, fake_tool)
    tracks = c.search("calm warm", limit=3)
    assert len(tracks) == 1
    t = tracks[0]
    assert t["id"] == _REC["id"]
    assert t["title"] == "All I Know"
    assert t["length"] == pytest.approx(190.36, abs=0.01)   # ms -> s
    assert t["bpm"] == 102
    assert set(t["moods"]) == {"hopeful", "restless"}        # only mood-dimension tags
    assert t["vocalType"] == "LEAD"                          # 'lead vocals' -> LEAD


def test_search_passes_bpm_min_filter(monkeypatch):
    seen = {}
    def fake_tool(name, args, _id=2):
        seen.update(args)
        return {"recordings": {"nodes": []}}
    c = _client(monkeypatch, fake_tool)
    c.search("x", bpm_min=120, limit=2)
    assert seen["filter"]["bpm"]["min"] == 120


def test_preview_url_uses_inline_lqmp3_no_extra_call(monkeypatch):
    """After search, preview_url must return the cached lqmp3 WITHOUT calling any tool (no 402 path)."""
    calls = []
    def fake_tool(name, args, _id=2):
        calls.append(name)
        return {"recordings": {"nodes": [{"recording": _REC}]}}
    c = _client(monkeypatch, fake_tool)
    c.search("calm", limit=1)
    calls.clear()
    pv = c.preview_url(_REC["id"])
    assert pv["url"] == _REC["audioFile"]["lqmp3Url"]
    assert calls == []    # no second round-trip, no DownloadRecording, no 402


def test_preview_url_falls_back_to_download_when_uncached(monkeypatch):
    def fake_tool(name, args, _id=2):
        if name == "DownloadRecording":
            return {"recordingDownload": {"assetUrl": "https://cdn/x.mp3?exp=1791703979.0&key_id=K"}}
        return {}
    c = _client(monkeypatch, fake_tool)
    pv = c.preview_url("never-searched-id")   # not in cache -> download link
    assert pv["url"].startswith("https://cdn/x.mp3")
    assert pv["expires"] == pytest.approx(1791703979.0)


def test_download_link_returns_signed_url_and_expiry(monkeypatch):
    def fake_tool(name, args, _id=3):
        assert name == "DownloadRecording"
        assert args["options"] == {"fileType": "MP3", "stemType": "FULL"}
        return {"recordingDownload": {"assetUrl": "https://cdn/y.mp3?exp=1800000000.5&signature=z"}}
    c = _client(monkeypatch, fake_tool)
    dl = c.download_link("tid")
    assert dl["url"].startswith("https://cdn/y.mp3")
    assert dl["expires"] == pytest.approx(1800000000.5)


def test_download_link_missing_url_raises(monkeypatch):
    c = _client(monkeypatch, lambda *a, **k: {"recordingDownload": {}})
    with pytest.raises(mp.EpidemicProviderError):
        c.download_link("tid")


def test_metadata_via_similar_lookup(monkeypatch):
    def fake_tool(name, args, _id=4):
        assert name == "SearchSimilarToRecording"
        # real shape: data.recording.similarRecordings.nodes[] with FLAT recording objects
        return {"recording": {"similarRecordings": {"nodes": [_REC]}}}
    c = _client(monkeypatch, fake_tool)
    m = c.metadata(_REC["id"])
    assert m["length"] == pytest.approx(190.36, abs=0.01)
    assert m["bpm"] == 102 and m["vocalType"] == "LEAD"


def test_beats_and_highlights_degrade_gracefully(monkeypatch):
    c = _client(monkeypatch, lambda *a, **k: {})
    assert c.beats("tid") == []        # no beat grid on MCP -> empty, not an error
    assert c.highlights("tid") == {}   # no highlight tool -> empty -> normalize returns None


def test_get_music_client_selects_mcp(monkeypatch):
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    monkeypatch.setenv("STORY_MUSIC_PROVIDER", "mcp")
    c = mp.get_music_client(key="epidemic_live_fake")
    assert isinstance(c, EpidemicMCPClient)


def test_get_music_client_defaults_to_rest(monkeypatch):
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    monkeypatch.delenv("STORY_MUSIC_PROVIDER", raising=False)
    c = mp.get_music_client(key="epidemic_live_fake")
    assert isinstance(c, mp.EpidemicClient) and not isinstance(c, EpidemicMCPClient)


def test_tool_surfaces_graphql_error(monkeypatch):
    """A GraphQL `errors` payload inside the tool text must become EpidemicProviderError, not a silent pass."""
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    c = EpidemicMCPClient(key="epidemic_live_fake")
    monkeypatch.setattr(c, "_ensure_session", lambda: None)

    def fake_post(msg, notif=False):
        body = ("data: " + json.dumps({
            "jsonrpc": "2.0", "id": 2,
            "result": {"content": [{"type": "text",
                                    "text": json.dumps({"errors": [{"message": "RETRY_LATER"}]})}]}}) + "\n")
        return 200, "sid", body
    monkeypatch.setattr(c, "_post", fake_post)
    with pytest.raises(mp.EpidemicProviderError):
        c._tool("SearchRecordings", {"query": {"term": "x"}})


def test_parse_sse_extracts_json_rpc_envelope():
    body = "event: message\ndata: {\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"ok\":true}}\n\n"
    env = EpidemicMCPClient._parse_sse(body)
    assert env["result"]["ok"] is True


# ----------------------------- energy_curve / waveform ---------------------------
import io
import urllib.error

# a real BBC-format waveform payload shape (signed int8 samples), matching the live Epidemic format
_WAVEFORM_JSON = {
    "version": 2, "channels": 1, "sample_rate": 48000, "bits": 8, "samples_per_pixel": 256,
    "length": 8, "data": [0, 40, -80, 120, -124, 126, 10, -10, 60, -60, 100, -100, 5, -5, 30, -30],
}


class _Resp(io.BytesIO):
    """Minimal urlopen() context-manager stand-in."""
    def __enter__(self): return self
    def __exit__(self, *a): return False


def _wf_client(monkeypatch, urlopen_impl, *, cache_url="https://cdn/wf.json", tid="tid"):
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    c = EpidemicMCPClient(key="epidemic_live_fake")
    c._wf_cache[tid] = cache_url
    monkeypatch.setattr("music_provider.mcp_client.urllib.request.urlopen", urlopen_impl)
    return c


def test_waveform_valid_feeds_energy_curve(monkeypatch):
    def urlopen(req, timeout=None):
        return _Resp(json.dumps(_WAVEFORM_JSON).encode())
    c = _wf_client(monkeypatch, urlopen)
    wf = c.waveform_for_track("tid")
    assert isinstance(wf, dict) and wf["data"]
    # end to end: it produces a bounded 0..1 energy_curve through the frozen normalizer
    an = mp.to_music_analysis_v1(duration_seconds=120.0, raw_bpm=100, raw_beats=[], raw_highlights={},
                                 waveform=wf, vocal_type="NONE")
    assert an.energy_curve and all(0.0 <= x <= 1.0 for x in an.energy_curve)


def test_waveform_uncached_track_returns_none(monkeypatch):
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    c = EpidemicMCPClient(key="epidemic_live_fake")  # no cache entry
    assert c.waveform_for_track("never-searched") is None


def test_waveform_empty_body_returns_none(monkeypatch):
    c = _wf_client(monkeypatch, lambda req, timeout=None: _Resp(b""))
    assert c.waveform_for_track("tid") is None


def test_waveform_malformed_json_returns_none(monkeypatch):
    c = _wf_client(monkeypatch, lambda req, timeout=None: _Resp(b"{not json"))
    assert c.waveform_for_track("tid") is None


def test_waveform_wrong_shape_returns_none(monkeypatch):
    # valid JSON but not the BBC waveform shape (no non-empty data list)
    c = _wf_client(monkeypatch, lambda req, timeout=None: _Resp(json.dumps({"data": []}).encode()))
    assert c.waveform_for_track("tid") is None


def test_waveform_expired_url_returns_none(monkeypatch):
    def urlopen(req, timeout=None):
        raise urllib.error.HTTPError(req.full_url if hasattr(req, "full_url") else "u", 403, "Forbidden", {}, None)
    c = _wf_client(monkeypatch, urlopen)
    assert c.waveform_for_track("tid") is None


def test_waveform_timeout_returns_none(monkeypatch):
    def urlopen(req, timeout=None):
        raise TimeoutError("read timed out")
    c = _wf_client(monkeypatch, urlopen)
    assert c.waveform_for_track("tid") is None


def test_waveform_oversize_body_returns_none(monkeypatch):
    big = b"x" * (EpidemicMCPClient._WAVEFORM_MAX_BYTES + 10)
    c = _wf_client(monkeypatch, lambda req, timeout=None: _Resp(big))
    assert c.waveform_for_track("tid") is None


def test_waveform_does_not_invent_beats_or_highlights(monkeypatch):
    """energy_curve populated, but beats/downbeats/highlight stay honestly empty — NOT derived from bpm."""
    c = _wf_client(monkeypatch, lambda req, timeout=None: _Resp(json.dumps(_WAVEFORM_JSON).encode()))
    wf = c.waveform_for_track("tid")
    an = mp.to_music_analysis_v1(duration_seconds=120.0, raw_bpm=128, raw_beats=c.beats("tid"),
                                 raw_highlights=c.highlights("tid"), waveform=wf, vocal_type="NONE")
    assert an.energy_curve                      # present
    assert an.beats == [] and an.downbeats == []  # NOT invented from bpm=128
    assert an.highlight_window is None


def test_rest_waveform_for_track_returns_none(monkeypatch):
    """REST adapter preserves prior behavior: energy_curve stays empty (waveform None)."""
    monkeypatch.setenv(mp.FLAG_ENV, "prototyping")
    rest = mp.EpidemicClient(key="epidemic_live_fake")
    assert rest.waveform_for_track("tid") is None
