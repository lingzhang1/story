"""Music Provider adapter — Epidemic Partner API (Milestone M-d, PROTOTYPING ONLY).

Backend-only. The API key is read from AWS Secrets Manager (secret id, default 'story-epidemic-key') IN-PROCESS;
it is never printed, logged, embedded in iOS, or committed. ALL functionality is gated behind a PROTOTYPING_ONLY
feature flag (env STORY_EPIDEMIC_MODE must == 'prototyping') — there is no production export/sublicense/safelist
path here.

Owns:
  - the Epidemic client (search, metadata, preview, beats, highlights, waveform, vocal, download-link) using the
    LIVE-VERIFIED response shapes (milestone-md-epidemic-live-validation-results.md);
  - normalization of provider responses into the FROZEN music_analysis/1 contract (bpm<=0 -> null;
    downbeats = beats value==1; highlights ms -> s; waveform -> coarse normalized energy_curve);
  - a deterministic MusicPlan -> track matcher (NO extra LLM, NO embeddings, NO vector DB).

Does NOT: build a local catalog mirror; persist provider collections/metadata or copyrighted audio; render; mix.
"""
from __future__ import annotations

import json
import os
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from typing import Any

from contracts.schemas.ai_contracts import HighlightWindow, MusicAnalysisV1Contract

BASE = "https://api.epidemicsound.com"
FLAG_ENV = "STORY_EPIDEMIC_MODE"            # must == "prototyping" to enable
SECRET_ENV = "STORY_EPIDEMIC_SECRET_ID"     # Secrets Manager id; default below
DEFAULT_SECRET_ID = "story-epidemic-key"
ENERGY_RESOLUTION = 16                      # coarse energy_curve samples (bounded, no false precision)


class EpidemicDisabledError(RuntimeError):
    """The adapter is not in prototyping mode (feature flag off)."""


class EpidemicAuthError(RuntimeError):
    pass


class EpidemicProviderError(RuntimeError):
    pass


def prototyping_enabled() -> bool:
    return os.environ.get(FLAG_ENV, "").strip().lower() == "prototyping"


def _require_flag() -> None:
    if not prototyping_enabled():
        raise EpidemicDisabledError(
            f"Epidemic adapter is PROTOTYPING_ONLY; set {FLAG_ENV}=prototyping to enable. "
            "No production export/sublicense/safelist path exists.")


def load_key(secret_id: str | None = None) -> str:
    """Read the API key from Secrets Manager in-process. Never logged/returned to callers other than the client."""
    import boto3  # noqa
    from botocore.exceptions import BotoCoreError, ClientError  # noqa
    sid = secret_id or os.environ.get(SECRET_ENV, DEFAULT_SECRET_ID)
    sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    try:
        s = (sm.get_secret_value(SecretId=sid).get("SecretString") or "").strip()
    except (ClientError, BotoCoreError) as e:
        # Missing secret, denied access (instance role lacks secretsmanager:GetSecretValue), region/network
        # fault — all surface as a clean auth failure the endpoint maps to 503, never an unhandled 500.
        raise EpidemicAuthError(f"could not read Epidemic key secret '{sid}': {type(e).__name__}") from e
    if s.startswith("{"):
        d = json.loads(s)
        for k in ("EPIDEMIC_API_KEY", "api_key", "apiKey", "key", "value"):
            if d.get(k):
                return str(d[k]).strip()
        if len(d) == 1:
            return str(next(iter(d.values()))).strip()
        raise EpidemicAuthError("secret JSON has no recognizable key field")
    if not s:
        raise EpidemicAuthError("empty secret")
    return s


# ---------------------------------------------------------------------------
# Normalization: provider response -> frozen music_analysis/1
# ---------------------------------------------------------------------------
def normalize_bpm(raw_bpm: Any) -> tuple[float | None, bool]:
    """Provider 0/absent/implausible -> (None, False). Returns (bpm, tempo_reliable).
    A beat grid alone does NOT make a track beat-synchronizable (ambient returns bpm=0)."""
    try:
        bpm = float(raw_bpm)
    except (TypeError, ValueError):
        return None, False
    if bpm <= 0:
        return None, False
    # plausibility band for music; outside it we keep the value but flag tempo UNreliable
    reliable = 40.0 <= bpm <= 220.0
    return bpm, reliable


def normalize_beats(raw_beats: list[dict] | None) -> tuple[list[float], list[float]]:
    """Return (beats_s, downbeats_s). Downbeats where value==1. Dedup + sort + nonneg."""
    beats, downs = [], []
    for b in raw_beats or []:
        if not isinstance(b, dict):
            continue
        t = b.get("time")
        if t is None or t < 0:
            continue
        beats.append(float(t))
        if b.get("value") == 1:
            downs.append(float(t))
    beats = sorted(set(beats))
    downs = sorted(set(downs))
    return beats, downs


def normalize_highlight(raw: Any) -> HighlightWindow | None:
    """Provider /highlights returns {highlights:[{from,to,duration}]} in MILLISECONDS -> seconds."""
    hs = raw.get("highlights") if isinstance(raw, dict) else raw
    if not hs:
        return None
    h = hs[0]
    frm, to = h.get("from"), h.get("to")
    if frm is None or to is None:
        return None
    start, end = frm / 1000.0, to / 1000.0
    if end <= start:
        return None
    return HighlightWindow(start_seconds=round(start, 3), end_seconds=round(end, 3))


def normalize_energy(waveform: dict | None, resolution: int = ENERGY_RESOLUTION) -> list[float]:
    """Coarse 0..1 amplitude envelope from BBC-format waveform JSON. Measures SIGNAL AMPLITUDE, not emotion."""
    data = (waveform or {}).get("data") or []
    if not data:
        return []
    mags = [abs(float(x)) for x in data]
    peak = max(mags) or 1.0
    n = len(mags)
    buckets = []
    step = max(1, n // resolution)
    for i in range(0, n, step):
        chunk = mags[i:i + step]
        buckets.append(round((sum(chunk) / len(chunk)) / peak, 3))
    return buckets[:resolution]


def to_music_analysis_v1(*, duration_seconds: float, raw_bpm: Any, raw_beats: list[dict] | None,
                         raw_highlights: Any, waveform: dict | None, vocal_type: str | None) -> MusicAnalysisV1Contract:
    bpm, reliable = normalize_bpm(raw_bpm)
    beats, downs = normalize_beats(raw_beats)
    # clamp any beats that marginally exceed duration (provider rounding)
    beats = [t for t in beats if t <= duration_seconds + 0.1]
    downs = [t for t in downs if t <= duration_seconds + 0.1]
    hw = normalize_highlight(raw_highlights)
    if hw and hw.end_seconds > duration_seconds:
        hw = HighlightWindow(start_seconds=min(hw.start_seconds, duration_seconds),
                             end_seconds=duration_seconds)
    return MusicAnalysisV1Contract(
        duration_seconds=duration_seconds, bpm=bpm, tempo_reliable=reliable,
        beats=beats, downbeats=downs, highlight_window=hw,
        energy_curve=normalize_energy(waveform), vocal_type=vocal_type)


# ---------------------------------------------------------------------------
# Deterministic MusicPlan -> track matcher (NO LLM / embeddings / vector DB)
# ---------------------------------------------------------------------------
@dataclass
class Candidate:
    track_id: str
    title: str
    duration_seconds: float
    bpm: float | None
    mood_tags: list[str]
    vocal_type: str | None  # NONE | PRESENCE | LEAD
    score: float = 0.0
    factors: dict = field(default_factory=dict)


def rank_candidates(music_plan: dict, candidates: list[Candidate], *, target_duration: float) -> list[Candidate]:
    """Explainable weighted score. Prefers mood fit, duration adequacy, energy/structure compatibility, vocal
    compatibility, and native-audio preservation. Does NOT prefer highest BPM or 'most dramatic'."""
    char = (music_plan or {}).get("character", {})
    plan_moods = {m.lower() for m in char.get("mood_tags", [])}
    strat = (music_plan or {}).get("audio_strategy", {})
    native_priority = strat.get("native_audio_priority", "low")
    for c in candidates:
        f = {}
        # mood overlap (0..1) — coerce provider mood objects {id,name} to strings
        cm = set()
        for m in c.mood_tags:
            s = (m.get("name") or m.get("id")) if isinstance(m, dict) else m
            if s:
                cm.add(str(s).lower())
        f["mood"] = (len(plan_moods & cm) / len(plan_moods)) if plan_moods else 0.0
        # duration adequacy: the track must COVER the target (short tracks penalized); over-length is fine (cut downstream)
        f["duration"] = 1.0 if c.duration_seconds >= target_duration else max(0.0, c.duration_seconds / target_duration)
        # vocal compatibility: when native audio matters, prefer instrumental (NONE); LEAD vocals penalized
        if native_priority in ("important", "selective"):
            f["vocal"] = {"NONE": 1.0, "PRESENCE": 0.5, "LEAD": 0.0}.get((c.vocal_type or "NONE"), 0.5)
        else:
            f["vocal"] = {"NONE": 0.8, "PRESENCE": 0.9, "LEAD": 1.0}.get((c.vocal_type or "NONE"), 0.8)
        # weighted sum (mood dominant, then vocal/native, then duration)
        c.factors = {k: round(v, 3) for k, v in f.items()}
        c.score = round(0.5 * f["mood"] + 0.3 * f["vocal"] + 0.2 * f["duration"], 4)
    return sorted(candidates, key=lambda c: c.score, reverse=True)


# ---------------------------------------------------------------------------
# Epidemic client (prototyping-gated)
# ---------------------------------------------------------------------------
class EpidemicClient:
    def __init__(self, key: str | None = None, *, secret_id: str | None = None):
        _require_flag()
        self._key = key or load_key(secret_id)
        if not self._key.startswith("epidemic_"):
            raise EpidemicAuthError("unexpected key format")

    def _call(self, path: str, params: dict | None = None, *, external_url: str | None = None):
        url = external_url or (BASE + path)
        if params and not external_url:
            url += "?" + urllib.parse.urlencode(params, doseq=True)
        req = urllib.request.Request(url, method="GET")
        if not external_url:
            req.add_header("Authorization", f"Bearer {self._key}")
        req.add_header("accept", "application/json")
        try:
            with urllib.request.urlopen(req, timeout=30) as r:
                return r.status, json.loads(r.read().decode())
        except urllib.error.HTTPError as e:
            if e.code in (401, 403):
                raise EpidemicAuthError(f"auth {e.code}")
            if e.code == 429:
                raise EpidemicProviderError("rate_limited")
            raise EpidemicProviderError(f"http_{e.code}")
        except Exception as e:  # noqa
            raise EpidemicProviderError(type(e).__name__)

    def search(self, term: str, *, vocal_type: str | None = None, bpm_min: int | None = None, limit: int = 5):
        p: dict[str, Any] = {"term": term, "limit": limit}
        if vocal_type:
            p["vocalType"] = vocal_type
        if bpm_min:
            p["bpmMin"] = bpm_min
        _, body = self._call("/v0/tracks/search", p)
        return body.get("tracks") or body.get("items") or body.get("data") or []

    def search_page(self, term: str, *, page_size: int = 10, cursor: str | None = None):
        """Paginated free-text search, offset-based (the Partner REST API has no opaque cursor). ``cursor`` is a
        stringified integer offset ('0' / None for the first page); ``next_cursor`` is the next offset as a
        string, or None when the page came back short (no further results). Mirrors the MCP client's
        (tracks, next_cursor) shape so the endpoint is provider-agnostic."""
        try:
            offset = int(cursor) if cursor else 0
        except (TypeError, ValueError):
            offset = 0
        p: dict[str, Any] = {"term": term, "limit": page_size, "offset": offset}
        _, body = self._call("/v0/tracks/search", p)
        tracks = body.get("tracks") or body.get("items") or body.get("data") or []
        next_cursor = str(offset + page_size) if len(tracks) >= page_size else None
        return tracks, next_cursor

    def metadata(self, track_id: str):
        _, body = self._call("/v0/tracks/metadata", {"trackId": track_id})
        arr = body if isinstance(body, list) else body.get("tracks")
        return (arr[0] if isinstance(arr, list) and arr else (body if isinstance(body, dict) else {}))

    def beats(self, track_id: str):
        _, body = self._call(f"/v0/tracks/{track_id}/beats")
        return body.get("beats") if isinstance(body, dict) else body

    def highlights(self, track_id: str, duration: int = 15):
        _, body = self._call(f"/v0/tracks/{track_id}/highlights", {"duration": duration})
        return body

    def waveform(self, waveform_url: str):
        _, body = self._call("", external_url=waveform_url)
        return body

    def preview_url(self, track_id: str):
        _, body = self._call(f"/v0/tracks/{track_id}/stream")
        return body

    def download_link(self, track_id: str, *, quality: str = "normal"):
        """Prototype testing only (counts vs free-tier 50). Returns the link+expiry; does NOT fetch audio."""
        _, body = self._call(f"/v0/tracks/{track_id}/download", {"format": "mp3", "quality": quality})
        return body

    def waveform_for_track(self, track_id: str) -> dict | None:
        """Provider-agnostic hook used by the music endpoints to source an energy_curve waveform by track id.
        The REST (production) path intentionally returns None here — its MusicAnalysis/1 is driven by the
        dedicated /beats + /highlights endpoints, and energy_curve stays empty exactly as before this change.
        (The separate waveform(waveform_url) method above is unchanged and still used by evals.)"""
        return None


# ---------------------------------------------------------------------------
# Provider selector — REST (production) vs MCP (internal testing). ADDITIVE.
# ---------------------------------------------------------------------------
def get_music_client(key: str | None = None, *, secret_id: str | None = None):
    """Return the active music provider client, honoring the feature flag.

    STORY_MUSIC_PROVIDER=mcp selects the Epidemic MCP (Beta) client (business-subscription key in
    'epidemic-mcp-api-key'), used for INTERNAL TESTING. Any other value (or unset) returns the Partner REST
    client, which stays the PRODUCTION provider. Both are still gated by STORY_EPIDEMIC_MODE=prototyping.
    Endpoints call this instead of constructing a client directly, so switching providers is a one-env change
    with no code edits and no change to the REST path.
    """
    provider = os.environ.get("STORY_MUSIC_PROVIDER", "").strip().lower()
    if provider == "mcp":
        from .mcp_client import EpidemicMCPClient  # local import: MCP transport confined to its module
        return EpidemicMCPClient(key=key, secret_id=secret_id)
    return EpidemicClient(key=key, secret_id=secret_id)


__all__ = [
    "BASE", "FLAG_ENV", "DEFAULT_SECRET_ID", "prototyping_enabled",
    "EpidemicDisabledError", "EpidemicAuthError", "EpidemicProviderError",
    "load_key", "normalize_bpm", "normalize_beats", "normalize_highlight", "normalize_energy",
    "to_music_analysis_v1", "Candidate", "rank_candidates", "EpidemicClient", "get_music_client",
]
