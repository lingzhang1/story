"""Epidemic Sound MCP client — ADDITIVE, INTERNAL-TESTING ONLY (keeps the REST client intact for production).

Why this exists
---------------
The production music path (``EpidemicClient`` in ``__init__``) talks to the Epidemic *Partner REST API*
(``api.epidemicsound.com/v0/...``) and stays the authoritative provider for the production launch. This module
adds a SECOND provider that speaks the Epidemic *MCP Server* (Beta) — a hosted Apollo/GraphQL-backed MCP endpoint
at ``https://www.epidemicsound.com/a/mcp-service/mcp`` — authenticated with a BUSINESS-subscription MCP key, used
ONLY for internal testing. The business plan clears the free-tier 402 preview/download paywall the prototyping
Partner key hits.

Selection
---------
``get_music_client()`` (in ``__init__``) returns this client when ``STORY_MUSIC_PROVIDER=mcp`` and the REST client
otherwise. Both remain gated by ``STORY_EPIDEMIC_MODE=prototyping``. Nothing in the REST path changes.

Surface parity
--------------
This client exposes the SAME methods the endpoints call on the REST client, returning the SAME shapes the
normalizers/endpoints expect:
  - ``search(term, vocal_type, bpm_min, limit)`` -> list[dict] with id/title/length/bpm/moods/vocalType
  - ``preview_url(track_id)``   -> {"url": <lqmp3>, "expires": None}       (inline lqmp3Url — no extra call, no 402)
  - ``download_link(track_id)`` -> {"url": <signed mp3>, "expires": <epoch?>} (DownloadRecording signed assetUrl)
  - ``metadata(track_id)``      -> {"length", "bpm", "vocalType", "title"} (via SearchSimilarToRecording self-lookup)
  - ``beats(track_id)``         -> []   (MCP server exposes no beat grid; analysis degrades gracefully to null)
  - ``highlights(track_id)``    -> {}   (MCP server exposes no highlight window; same graceful degradation)

The key is read from Secrets Manager (default id ``epidemic-mcp-api-key``) IN-PROCESS; never printed, logged,
embedded in iOS, or committed. GraphQL/MCP transport details (SSE framing, session handshake) are confined here.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.request
from typing import Any

from . import (
    EpidemicAuthError,
    EpidemicProviderError,
    _require_flag,
    load_key,
)

MCP_URL = "https://www.epidemicsound.com/a/mcp-service/mcp"
MCP_SECRET_ENV = "STORY_EPIDEMIC_MCP_SECRET_ID"
DEFAULT_MCP_SECRET_ID = "epidemic-mcp-api-key"
PROVIDER_ENV = "STORY_MUSIC_PROVIDER"       # "mcp" selects this client; anything else -> REST client

_PROTOCOL = "2025-03-26"


class EpidemicMCPClient:
    """Mirrors EpidemicClient's method surface over the Epidemic MCP (GraphQL) server."""

    def __init__(self, key: str | None = None, *, secret_id: str | None = None):
        _require_flag()
        sid = secret_id or os.environ.get(MCP_SECRET_ENV, DEFAULT_MCP_SECRET_ID)
        self._key = key or load_key(sid)
        if not self._key.startswith("epidemic_"):
            raise EpidemicAuthError("unexpected key format")
        self._session_id: str | None = None
        # lqmp3 preview urls arrive inline in search results; cache per instance so preview_url is a
        # no-op lookup (no second round-trip, no 402). Per-instance to avoid cross-request leakage.
        self._lq_cache: dict[str, str | None] = {}
        # waveformUrl also arrives inline in search; cache it so waveform() needs no extra MCP round-trip.
        self._wf_cache: dict[str, str | None] = {}

    # ---- MCP transport (JSON-RPC over HTTP, SSE-framed responses) ----------
    def _post(self, msg: dict, *, notif: bool = False) -> tuple[int, str | None, str]:
        req = urllib.request.Request(MCP_URL, data=json.dumps(msg).encode(), method="POST")
        req.add_header("Authorization", f"Bearer {self._key}")
        req.add_header("Content-Type", "application/json")
        req.add_header("Accept", "application/json, text/event-stream")
        if self._session_id:
            req.add_header("Mcp-Session-Id", self._session_id)
        try:
            with urllib.request.urlopen(req, timeout=40) as r:
                return r.status, r.headers.get("mcp-session-id"), r.read().decode()
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise EpidemicAuthError(f"auth {e.code}")
            if e.code == 429:
                raise EpidemicProviderError("rate_limited")
            raise EpidemicProviderError(f"http_{e.code}")
        except Exception as e:  # noqa
            raise EpidemicProviderError(type(e).__name__)

    @staticmethod
    def _parse_sse(body: str) -> dict | None:
        """The server replies as text/event-stream; the JSON-RPC envelope rides in a `data:` line."""
        for line in body.splitlines():
            if line.startswith("data:"):
                d = line[5:].strip()
                if d:
                    try:
                        return json.loads(d)
                    except json.JSONDecodeError:
                        continue
        try:
            return json.loads(body)
        except json.JSONDecodeError:
            return None

    def _ensure_session(self) -> None:
        if self._session_id:
            return
        st, sid, _ = self._post({
            "jsonrpc": "2.0", "id": 1, "method": "initialize",
            "params": {"protocolVersion": _PROTOCOL, "capabilities": {},
                       "clientInfo": {"name": "story-backend", "version": "1"}}})
        if not sid:
            raise EpidemicProviderError("mcp_no_session")
        self._session_id = sid
        # required MCP handshake completion (notification, no id, no response body expected)
        self._post({"jsonrpc": "2.0", "method": "notifications/initialized", "params": {}}, notif=True)

    def _tool(self, name: str, arguments: dict, *, _id: int = 2) -> Any:
        """Call an MCP tool and return the decoded GraphQL `data` payload (tool text is a JSON string)."""
        self._ensure_session()
        _, _, body = self._post({"jsonrpc": "2.0", "id": _id, "method": "tools/call",
                                 "params": {"name": name, "arguments": arguments}})
        env = self._parse_sse(body)
        if not env:
            raise EpidemicProviderError("mcp_unparseable")
        if "error" in env:
            raise EpidemicProviderError(f"mcp_{str(env['error'].get('code', 'error'))[:40]}")
        result = env.get("result") or {}
        if result.get("isError"):
            raise EpidemicProviderError("mcp_tool_error")
        for c in result.get("content", []):
            if c.get("type") == "text":
                try:
                    doc = json.loads(c["text"])
                except json.JSONDecodeError:
                    raise EpidemicProviderError("mcp_bad_tool_json")
                if isinstance(doc, dict) and doc.get("errors"):
                    raise EpidemicProviderError(f"gql_{str(doc['errors'][0].get('message', 'error'))[:40]}")
                return doc.get("data", doc) if isinstance(doc, dict) else doc
        raise EpidemicProviderError("mcp_no_content")

    # ---- normalization of an MCP recording node -> REST-shaped track dict ---
    @staticmethod
    def _tags_of(rec: dict, dimension: str) -> list[str]:
        out = []
        for t in rec.get("tags") or []:
            dim = ((t.get("dimension") or {}).get("name") or "").lower()
            if dim == dimension and t.get("displayName"):
                out.append(str(t["displayName"]))
        return out

    @classmethod
    def _vocal_type(cls, rec: dict) -> str | None:
        """Map the MCP 'vocal type' tag to the REST client's NONE/PRESENCE/LEAD vocabulary."""
        vt = " ".join(cls._tags_of(rec, "vocal type")).lower()
        if not vt:
            return None
        if "no vocal" in vt or "instrumental" in vt:
            return "NONE"
        if "lead" in vt:
            return "LEAD"
        return "PRESENCE"

    @classmethod
    def _to_track(cls, rec: dict) -> dict:
        af = rec.get("audioFile") or {}
        dur_ms = af.get("durationInMilliseconds") or 0
        return {
            "id": rec.get("id"),
            "title": rec.get("title", ""),
            "length": (float(dur_ms) / 1000.0) if dur_ms else 0.0,
            "bpm": rec.get("bpm") or None,
            "moods": cls._tags_of(rec, "mood"),
            "vocalType": cls._vocal_type(rec),
            # carried alongside (not in the REST shape) so preview_url needs no second round-trip
            "_lqmp3Url": af.get("lqmp3Url"),
            "_waveformUrl": af.get("waveformUrl"),
        }

    # ---- surface parity with EpidemicClient --------------------------------
    def search(self, term: str, *, vocal_type: str | None = None, bpm_min: int | None = None, limit: int = 5):
        query: dict[str, Any] = {"term": term}
        filt: dict[str, Any] = {}
        if bpm_min:
            filt["bpm"] = {"min": int(bpm_min)}
        args: dict[str, Any] = {"query": query, "first": int(limit)}
        if filt:
            args["filter"] = filt
        data = self._tool("SearchRecordings", args)
        nodes = (((data or {}).get("recordings") or {}).get("nodes")) or []
        tracks = []
        for n in nodes:
            rec = n.get("recording") if isinstance(n, dict) else None
            if rec and rec.get("id"):
                self._lq_cache[rec["id"]] = (rec.get("audioFile") or {}).get("lqmp3Url")
                self._wf_cache[rec["id"]] = (rec.get("audioFile") or {}).get("waveformUrl")
                tracks.append(self._to_track(rec))
        return tracks

    def preview_url(self, track_id: str):
        url = getattr(self, "_lq_cache", {}).get(track_id)
        if not url:
            # not in a prior search (e.g. direct selection) — do a signed download link instead
            return self.download_link(track_id)
        return {"url": url, "expires": None}

    def download_link(self, track_id: str, *, quality: str = "normal"):
        data = self._tool("DownloadRecording",
                           {"id": track_id, "options": {"fileType": "MP3", "stemType": "FULL"}}, _id=3)
        dl = (data or {}).get("recordingDownload") or {}
        url = dl.get("assetUrl")
        if not url:
            raise EpidemicProviderError("mcp_no_download_url")
        return {"url": url, "expires": _exp_from_signed(url)}

    def metadata(self, track_id: str):
        """The MCP catalog has no single-track metadata tool. SearchSimilarToRecording returns the source
        recording's similar set at data.recording.similarRecordings.nodes[]; the first similar node mirrors the
        source's duration/bpm/vocal fields closely enough for analysis. Degrades to {} on miss (graceful)."""
        try:
            data = self._tool("SearchSimilarToRecording", {"id": track_id, "first": 1}, _id=4)
        except EpidemicProviderError:
            return {}
        rec = (data or {}).get("recording") or {}
        nodes = (rec.get("similarRecordings") or {}).get("nodes") or []
        # similar nodes are FLAT recording objects (id/title/bpm/audioFile/tags), not wrapped in {"recording": ...}
        for node in nodes:
            if isinstance(node, dict) and node.get("audioFile"):
                t = self._to_track(node)
                return {"length": t["length"], "bpm": t["bpm"], "vocalType": t["vocalType"], "title": t["title"]}
        return {}

    def beats(self, track_id: str):
        # The MCP server exposes no beat grid. Returning [] makes to_music_analysis_v1 produce bpm-only /
        # no-beats analysis — a graceful degradation, never a failure.
        return []

    def highlights(self, track_id: str, duration: int = 15):
        # No highlight-window tool on the MCP server; empty -> normalize_highlight returns None (graceful).
        return {}

    # bound the waveform fetch: Epidemic waveform JSON is ~14 KB (BBC format, 3202 int8 samples);
    # 1 MB is a generous ceiling that still refuses a pathological/wrong body.
    _WAVEFORM_MAX_BYTES = 1_048_576
    _WAVEFORM_TIMEOUT_S = 8

    def waveform_for_track(self, track_id: str) -> dict | None:
        """Fetch + parse the track's BBC-format waveform JSON for energy_curve. Returns the parsed dict
        (``{"data": [...], ...}``) on success, or ``None`` on ANY failure (unknown track, expired/forbidden
        signed URL, timeout, empty body, oversize body, malformed JSON). The caller feeds it to
        to_music_analysis_v1(waveform=...); a None simply yields an empty energy_curve — never an error, and
        NEVER an invented value. The payload is used transiently to compute a coarse envelope and is NOT
        persisted or mirrored (Business MCP terms)."""
        url = getattr(self, "_wf_cache", {}).get(track_id)
        if not url:
            return None
        try:
            req = urllib.request.Request(url, method="GET")
            req.add_header("accept", "application/json")
            with urllib.request.urlopen(req, timeout=self._WAVEFORM_TIMEOUT_S) as r:
                raw = r.read(self._WAVEFORM_MAX_BYTES + 1)
            if not raw or len(raw) > self._WAVEFORM_MAX_BYTES:
                return None  # empty, or implausibly large -> treat as unavailable
            doc = json.loads(raw.decode("utf-8", "strict"))
            # must be the BBC waveform shape normalize_energy expects: a dict with a non-empty `data` list
            if not isinstance(doc, dict) or not isinstance(doc.get("data"), list) or not doc["data"]:
                return None
            return doc
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError, OSError,
                json.JSONDecodeError, UnicodeDecodeError, ValueError):
            # expired/forbidden URL (403/410), DNS/connect/read timeout, malformed body -> graceful None
            return None


def _exp_from_signed(url: str) -> float | None:
    """Epidemic signed asset URLs carry an `exp=<epoch>` query param; surface it as `expires` if present."""
    try:
        from urllib.parse import parse_qs, urlparse
        q = parse_qs(urlparse(url).query)
        exp = q.get("exp", [None])[0]
        return float(exp) if exp else None
    except (ValueError, TypeError):
        return None


__all__ = ["EpidemicMCPClient", "MCP_URL", "PROVIDER_ENV", "DEFAULT_MCP_SECRET_ID", "MCP_SECRET_ENV"]
