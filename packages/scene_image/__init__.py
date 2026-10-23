"""Scene-image provider — Unsplash reference images for the StoryGuide/2 shooting script.

Backend-only. The Unsplash Access Key is read from AWS Secrets Manager (secret id, default
'Unsplash-API-Key') IN-PROCESS and NEVER logged, returned to callers, or embedded in the iOS app.
This module is a BOUNDED reference-image lookup — NOT an unrestricted public image-search proxy:

  * Query is a GENERIC scene/composition phrase (from the server-stored Guide scene
    `visual_reference_query`, or an explicitly-bounded+sanitized client query). Length-capped,
    control-chars stripped, URLs/emails rejected so no personal data / user media can be smuggled.
  * ONE image per scene. Only metadata is returned (photo id, hotlinked urls.*, attribution text,
    photographer + source links with utm, and the download_location tracking URL). Image BYTES are
    NEVER fetched or re-hosted here — the app hotlinks urls.* directly from images.unsplash.com.
  * Compliance (verified 2026-10-23 against unsplash.com/documentation + API Guidelines + Terms):
      - Hotlinking: callers must use the returned urls.* CDN links (we never re-host).
      - Attribution: "Photo by <name> on Unsplash", both links carrying
        ?utm_source=<app>&utm_medium=referral — returned ready-to-render.
      - Download tracking: we DO NOT fire download_location on mere display. We return the
        download_location URL; the caller triggers it only when a photo is actually USED/selected
        as a scene reference (trigger_download()). This matches Unsplash's documented rule.
      - No ML/vision on bytes (we only surface references for human display).
  * Fail-soft: auth/provider/rate-limit/timeout errors raise typed exceptions the endpoint maps to
    a graceful "no image" (text-only) result — they MUST NEVER block Guide generation or the UI.
"""

from __future__ import annotations

import json
import os
import re
import urllib.parse
import urllib.request
from dataclasses import dataclass

BASE = "https://api.unsplash.com"
SECRET_ENV = "UNSPLASH_SECRET_ID"            # Secrets Manager id; default below
DEFAULT_SECRET_ID = "Unsplash-API-Key"
FLAG_ENV = "STORY_SCENE_IMAGES"              # must == "1" to enable the endpoint
APP_UTM = "yotale"                            # utm_source for attribution links (Unsplash requirement)
QUERY_MAX_LEN = 120                           # bounded — a scene composition phrase, not free search
PROVIDER_TIMEOUT_SECONDS = 4.0                # bounded provider call; never hang the request


class SceneImageDisabledError(RuntimeError):
    """The endpoint is not enabled (STORY_SCENE_IMAGES != '1')."""


class SceneImageAuthError(RuntimeError):
    """The Unsplash key could not be read, or the provider rejected it."""


class SceneImageProviderError(RuntimeError):
    """The provider failed, timed out, or rate-limited (HTTP 429/5xx/transport)."""


class SceneImageQueryError(ValueError):
    """The query was empty, too long, or contained disallowed content (URL/email/control chars)."""


def enabled() -> bool:
    return os.environ.get(FLAG_ENV, "").strip() == "1"


# Reject anything that could carry personal data / user media references into the provider.
_URL_RE = re.compile(r"https?://|www\.", re.IGNORECASE)
_EMAIL_RE = re.compile(r"[^\s@]+@[^\s@]+\.[^\s@]+")
_CONTROL_RE = re.compile(r"[\x00-\x1f\x7f]")


def sanitize_query(raw: str) -> str:
    """Validate + bound a scene/composition query. Raises SceneImageQueryError on anything that is
    not a short, generic phrase. Collapses whitespace; strips control chars; rejects URLs/emails."""
    if raw is None:
        raise SceneImageQueryError("empty query")
    q = _CONTROL_RE.sub(" ", str(raw)).strip()
    q = re.sub(r"\s+", " ", q)
    if not q:
        raise SceneImageQueryError("empty query")
    if len(q) > QUERY_MAX_LEN:
        raise SceneImageQueryError(f"query too long (>{QUERY_MAX_LEN} chars)")
    if _URL_RE.search(q) or _EMAIL_RE.search(q):
        raise SceneImageQueryError("query must be a generic scene description (no URLs or emails)")
    return q


def load_key(secret_id: str | None = None) -> str:
    """Read the Unsplash Access Key from Secrets Manager in-process. Never logged/returned to callers
    other than the client. Mirrors the Epidemic key loader (missing/denied/empty -> SceneImageAuthError)."""
    import boto3  # noqa
    from botocore.exceptions import BotoCoreError, ClientError  # noqa
    sid = secret_id or os.environ.get(SECRET_ENV, DEFAULT_SECRET_ID)
    sm = boto3.client("secretsmanager", region_name=os.environ.get("AWS_REGION", "us-east-1"))
    try:
        s = (sm.get_secret_value(SecretId=sid).get("SecretString") or "").strip()
    except (ClientError, BotoCoreError) as e:
        raise SceneImageAuthError(f"could not read Unsplash key secret '{sid}': {type(e).__name__}") from e
    if s.startswith("{"):
        d = json.loads(s)
        # The Unsplash Access Key is the Client-ID used in `Authorization: Client-ID <key>`. (The Secret Key
        # is only for OAuth write flows we never use.) Match tolerantly across separator/case variants so a
        # console-entered key like "Unsplash-Access-Key" / "access_key" / "accessKey" all resolve.
        def _norm(x: str) -> str:
            return "".join(ch for ch in x.lower() if ch.isalnum())
        # Preference order (normalized): the ACCESS key first, then generic single-value fields.
        preferred = ["unsplashaccesskey", "accesskey", "unsplashkey", "apikey", "key", "value"]
        norm_map = { _norm(k): v for k, v in d.items() }
        for want in preferred:
            v = norm_map.get(want)
            if v and str(v).strip():
                return str(v).strip()
        # Avoid the Secret Key / Application ID if an access-like field is absent; fall back to a lone value.
        non_secret = { k: v for k, v in d.items()
                       if "secret" not in _norm(k) and "applicationid" not in _norm(k) and "appid" not in _norm(k) }
        if len(non_secret) == 1:
            return str(next(iter(non_secret.values()))).strip()
        if len(d) == 1:
            return str(next(iter(d.values()))).strip()
        raise SceneImageAuthError("secret JSON has no recognizable Unsplash access-key field")
    if not s:
        raise SceneImageAuthError("empty secret")
    return s


@dataclass(frozen=True)
class SceneImage:
    """Metadata-only reference-image result. NO image bytes. All fields are safe to cache long-term."""

    photo_id: str
    image_url: str                 # hotlinked urls.regular (images.unsplash.com); app must hotlink this
    thumb_url: str                 # hotlinked urls.small for lazy/low-bandwidth
    attribution_text: str          # "Photo by <name> on Unsplash"
    photographer_name: str
    photographer_url: str          # profile link, utm-tagged
    source_url: str                # photo page link, utm-tagged (Unsplash requirement)
    download_location: str         # Unsplash tracking endpoint; fire ONLY on actual use, not display
    width: int | None = None
    height: int | None = None
    color: str | None = None       # dominant color hex for a tasteful placeholder while lazy-loading
    alt_description: str | None = None

    def to_wire(self) -> dict:
        return {
            "photo_id": self.photo_id,
            "image_url": self.image_url,
            "thumb_url": self.thumb_url,
            "attribution_text": self.attribution_text,
            "photographer_name": self.photographer_name,
            "photographer_url": self.photographer_url,
            "source_url": self.source_url,
            "download_location": self.download_location,
            "width": self.width,
            "height": self.height,
            "color": self.color,
            "alt_description": self.alt_description,
            "provider": "unsplash",
        }


def _utm(url: str) -> str:
    """Append the required Unsplash attribution utm params to a link."""
    if not url:
        return url
    sep = "&" if "?" in url else "?"
    return f"{url}{sep}utm_source={APP_UTM}&utm_medium=referral"


class UnsplashClient:
    """Thin Unsplash REST client. Injectable for tests (no network in CI). Bounded timeout; typed errors."""

    def __init__(self, access_key: str, *, base: str = BASE, timeout: float = PROVIDER_TIMEOUT_SECONDS,
                 opener=None):
        self._key = access_key
        self._base = base.rstrip("/")
        self._timeout = timeout
        self._opener = opener or urllib.request.urlopen

    def _get(self, path: str, params: dict) -> dict:
        qs = urllib.parse.urlencode(params)
        req = urllib.request.Request(
            f"{self._base}{path}?{qs}",
            headers={"Authorization": f"Client-ID {self._key}",
                     "Accept-Version": "v1",
                     "Accept": "application/json"},
        )
        try:
            with self._opener(req, timeout=self._timeout) as resp:
                status = getattr(resp, "status", 200)
                body = resp.read()
        except urllib.error.HTTPError as e:  # type: ignore[attr-defined]
            if e.code in (401, 403):
                raise SceneImageAuthError(f"unsplash auth rejected ({e.code})") from e
            raise SceneImageProviderError(f"unsplash http {e.code}") from e
        except Exception as e:  # timeout / transport / DNS
            raise SceneImageProviderError(f"unsplash transport: {type(e).__name__}") from e
        if status in (401, 403):
            raise SceneImageAuthError(f"unsplash auth rejected ({status})")
        if status == 429:
            raise SceneImageProviderError("unsplash rate limited (429)")
        if status >= 400:
            raise SceneImageProviderError(f"unsplash http {status}")
        try:
            return json.loads(body)
        except Exception as e:
            raise SceneImageProviderError("unsplash returned non-JSON") from e

    def search_one(self, query: str) -> SceneImage | None:
        """Search photos (landscape, 1 result) and map the top hit to SceneImage metadata. Returns None
        when the provider has no match (graceful text-only fallback — NOT an error)."""
        data = self._get("/search/photos", {"query": query, "per_page": 1, "orientation": "landscape",
                                             "content_filter": "high"})
        results = data.get("results") or []
        if not results:
            return None
        return self._map(results[0])

    def trigger_download(self, download_location: str) -> None:
        """Fire the Unsplash download-tracking endpoint. Caller invokes this ONLY when a photo is
        actually USED (selected as a scene reference), per Unsplash's documented rule — never on display.
        Best-effort: tracking failure must never surface to the user."""
        if not download_location:
            return
        # The download_location already points at api.unsplash.com; it still needs the Client-ID.
        try:
            req = urllib.request.Request(
                download_location,
                headers={"Authorization": f"Client-ID {self._key}", "Accept-Version": "v1"})
            with self._opener(req, timeout=self._timeout):
                pass
        except Exception:
            pass  # tracking is fire-and-forget; never raise into the request path

    @staticmethod
    def _map(p: dict) -> SceneImage:
        user = p.get("user") or {}
        urls = p.get("urls") or {}
        links = p.get("links") or {}
        name = (user.get("name") or "Unknown").strip()
        prof = _utm((user.get("links") or {}).get("html", "https://unsplash.com"))
        return SceneImage(
            photo_id=str(p.get("id", "")),
            image_url=urls.get("regular") or urls.get("full") or urls.get("raw") or "",
            thumb_url=urls.get("small") or urls.get("thumb") or urls.get("regular") or "",
            attribution_text=f"Photo by {name} on Unsplash",
            photographer_name=name,
            photographer_url=prof,
            source_url=_utm(links.get("html", "https://unsplash.com")),
            download_location=links.get("download_location", ""),
            width=p.get("width"),
            height=p.get("height"),
            color=p.get("color"),
            alt_description=p.get("alt_description"),
        )


__all__ = [
    "BASE", "SECRET_ENV", "DEFAULT_SECRET_ID", "FLAG_ENV", "APP_UTM",
    "QUERY_MAX_LEN", "PROVIDER_TIMEOUT_SECONDS",
    "SceneImageDisabledError", "SceneImageAuthError", "SceneImageProviderError", "SceneImageQueryError",
    "enabled", "sanitize_query", "load_key", "SceneImage", "UnsplashClient",
    "MetadataCache",
]


class MetadataCache:
    """Bounded, TTL'd, in-process metadata-only cache keyed by sanitized query. Caches the LOOKUP RESULT
    (SceneImage metadata or a negative 'no match' marker) so repeated Guide renders / re-opens never
    re-hit the provider — the #1 way we keep provider calls bounded and costs near-zero. Stores NO image
    bytes. Not shared across processes (App Runner may run multiple); that is fine — it only trims calls,
    correctness never depends on it. Simple size+TTL eviction, no external deps."""

    _MISS = object()

    def __init__(self, max_entries: int = 512, ttl_seconds: float = 86_400.0):
        self._max = max_entries
        self._ttl = ttl_seconds
        self._store: dict[str, tuple[float, object]] = {}

    def get(self, key: str):
        import time as _t
        v = self._store.get(key)
        if v is None:
            return None  # cache miss (not looked up yet)
        ts, payload = v
        if _t.monotonic() - ts > self._ttl:
            self._store.pop(key, None)
            return None
        return payload  # SceneImage, or MetadataCache._MISS for a cached 'no provider match'

    def put(self, key: str, payload) -> None:
        import time as _t
        if len(self._store) >= self._max:
            # evict oldest
            oldest = min(self._store.items(), key=lambda kv: kv[1][0])[0]
            self._store.pop(oldest, None)
        self._store[key] = (_t.monotonic(), payload)
