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
