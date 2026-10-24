"""GeminiModelGateway — direct Google Gemini (Generative Language API) adapter for ModelGateway.

Thin, dependency-free HTTP client (urllib). Forces schema-valid structured output via a SINGLE required
function call whose parameters are the request schema DOWN-CONVERTED to Gemini's schema dialect (a subset
of JSON Schema), with `tool_config.function_calling_config.mode=ANY` + an allowed-name pin. Ordered
multimodal frames are sent as inline_data parts, in order, each preceded by its position text;
`system_instruction` carries the system prompt.

Schema down-conversion is CONSERVATIVE and NON-SILENT: it maps JSON-Schema -> Gemini Schema, dropping only
keywords Gemini does not support (e.g. additionalProperties, $defs/$ref are not expressible) while
PRESERVING type/properties/required/enum/items. It NEVER drops a `required` field or changes a type to make
a request accept — if a schema cannot be faithfully represented (e.g. it relies on $ref), it raises
SchemaTranslationError so the caller can report the incompatibility (req 3) rather than weaken semantics.
Upstream validation still enforces the ORIGINAL JSON Schema on the returned object, so a looser provider
schema cannot let an invalid object through.

Error classification matches the OpenAI adapter: 429/5xx/transport -> ProviderError; 400/401/403/policy
-> ProviderPolicyError; schema-invalid-after-repair -> StructuredOutputError. Never logs key/prompt/bytes.
"""
from __future__ import annotations

import base64
import json
import time
import urllib.error
import urllib.request
from typing import Any

from . import (
    ProviderError,
    ProviderPolicyError,
    StructuredOutputError,
    StructuredRequest,
    StructuredResult,
    Usage,
)
from ._secret import load_provider_key

DEFAULT_GEMINI_BASE = "https://generativelanguage.googleapis.com/v1beta"
_TOOL_NAME = "emit_structured"


class SchemaTranslationError(StructuredOutputError):
    """A request JSON Schema cannot be faithfully represented in Gemini's schema dialect (e.g. $ref/$defs).
    Raised instead of silently weakening the contract — the caller reports the incompatibility."""


# Gemini Schema supports a subset of OpenAPI/JSON-Schema. These keys translate; others are dropped
# (structural only) or, when load-bearing ($ref), rejected.
_SUPPORTED = {"type", "format", "description", "nullable", "enum", "items", "properties", "required",
              "minItems", "maxItems", "minimum", "maximum"}
_REJECT_IF_PRESENT = {"$ref", "$defs", "definitions", "allOf", "anyOf", "oneOf", "not"}


def translate_schema(schema: dict[str, Any]) -> dict[str, Any]:
    """Down-convert a JSON Schema to Gemini's Schema dialect. Conservative + non-silent (raises on
    inexpressible constructs). Preserves type/properties/required/enum/items; drops only non-semantic
    structural keywords (additionalProperties). Pure + unit-testable."""
    if not isinstance(schema, dict):
        raise SchemaTranslationError("schema node is not an object")
    present_reject = _REJECT_IF_PRESENT.intersection(schema.keys())
    if present_reject:
        raise SchemaTranslationError(
            f"schema uses constructs Gemini cannot represent faithfully: {sorted(present_reject)}")
    out: dict[str, Any] = {}
    for k, v in schema.items():
        if k == "additionalProperties":
            continue  # Gemini has no equivalent; harmless to drop (upstream validation still forbids extras)
        if k not in _SUPPORTED:
            continue  # drop unknown non-semantic keywords
        if k == "properties" and isinstance(v, dict):
            out["properties"] = {pk: translate_schema(pv) for pk, pv in v.items()}
        elif k == "items" and isinstance(v, dict):
            out["items"] = translate_schema(v)
        else:
            out[k] = v
    return out


class GeminiModelGateway:
    def __init__(
        self,
        model_id: str,
        *,
        secret_id: str = "YoTale-Gemini-API-Key",
        api_key: str | None = None,
        base_url: str = DEFAULT_GEMINI_BASE,
        region: str | None = None,
        timeout_seconds: float = 60.0,
        max_retries: int = 2,
        secrets_client: Any = None,
        http_post: Any = None,
    ):
        self.model_id = model_id
        self._secret_id = secret_id
        self._api_key = api_key
        self._base = base_url.rstrip("/")
        self._region = region
        self._timeout = timeout_seconds
        self._max_retries = max(0, max_retries)
        self._secrets_client = secrets_client
        self._http_post = http_post

    def _key(self) -> str:
        if self._api_key is None:
            self._api_key = load_provider_key(
                self._secret_id, region=self._region, client=self._secrets_client,
                expected_key_hint=self._secret_id)
        return self._api_key

    def _build_body(self, req: StructuredRequest) -> dict[str, Any]:
        parts: list[dict[str, Any]] = [{"text": req.user_content}]
        for i, img in enumerate(req.images):
            parts.append({"text": f"[frame {i + 1}]"})
            parts.append({"inline_data": {
                "mime_type": img.media_type,
                "data": base64.b64encode(img.data).decode("ascii"),
            }})
        return {
            "system_instruction": {"parts": [{"text": req.system}]},
            "contents": [{"role": "user", "parts": parts}],
            "tools": [{"function_declarations": [{
                "name": _TOOL_NAME,
                "description": "Emit the single structured result for this task.",
                "parameters": translate_schema(req.schema),
            }]}],
            "tool_config": {"function_calling_config": {"mode": "ANY", "allowed_function_names": [_TOOL_NAME]}},
            "generationConfig": {"maxOutputTokens": req.max_tokens, "temperature": req.temperature},
        }

    def generate_structured(self, req: StructuredRequest) -> StructuredResult:
        body = self._build_body(req)  # may raise SchemaTranslationError (reported, not swallowed)
        last_err: Exception | None = None
        for attempt in range(1 + max(0, req.max_repair_attempts)):
            status, payload, headers = self._post(
                f"/models/{self.model_id}:generateContent", body)
            tool_input = self._extract_function_args(payload)
            if tool_input is not None:
                um = payload.get("usageMetadata") or {}
                return StructuredResult(
                    data=tool_input,
                    usage=Usage(
                        input_tokens=um.get("promptTokenCount"),
                        output_tokens=um.get("candidatesTokenCount"),
                        total_tokens=um.get("totalTokenCount"),
                    ),
                    attempts=attempt + 1,
                    repaired=attempt > 0,
                    model=self.model_id,
                    provider="gemini",
                    stop_reason=(payload.get("candidates") or [{}])[0].get("finishReason"),
                )
            finish = (payload.get("candidates") or [{}])[0].get("finishReason")
            if finish in ("SAFETY", "PROHIBITED_CONTENT", "BLOCKLIST"):
                # Gemini content-policy block -> never fail over.
                raise ProviderPolicyError(f"gemini content blocked (finishReason={finish})")
            if finish == "MAX_TOKENS":
                last_err = StructuredOutputError("output truncated at maxOutputTokens (increase max_tokens)")
            else:
                last_err = StructuredOutputError(f"model did not return a function call (finishReason={finish})")
            body["contents"].append({"role": "user", "parts": [{"text": f"You must call {_TOOL_NAME} with valid JSON."}]})
        raise last_err or StructuredOutputError("no structured output")

    def _post(self, path: str, body: dict[str, Any]) -> tuple[int, dict[str, Any], dict[str, str]]:
        # API key as a query param (x-goog-api-key header also works; query avoids a custom header in urllib)
        url = f"{self._base}{path}?key={self._key()}"
        data = json.dumps(body).encode("utf-8")
        headers = {"Content-Type": "application/json"}
        attempt = 0
        while True:
            try:
                if self._http_post is not None:
                    status, raw, resp_headers = self._http_post(url, headers, data, self._timeout)
                else:
                    reqo = urllib.request.Request(url, data=data, headers=headers, method="POST")
                    with urllib.request.urlopen(reqo, timeout=self._timeout) as r:
                        status, raw, resp_headers = r.status, r.read(), dict(r.headers)
            except urllib.error.HTTPError as he:  # pragma: no cover
                status = he.code
                raw = he.read() if hasattr(he, "read") else b""
                resp_headers = dict(getattr(he, "headers", {}) or {})
            except (urllib.error.URLError, TimeoutError, OSError) as te:
                if attempt < self._max_retries:
                    time.sleep(min(2 ** attempt, 8)); attempt += 1; continue
                raise ProviderError(f"gemini transport error: {type(te).__name__}") from te

            if status == 200:
                try:
                    return status, json.loads(raw.decode("utf-8")), resp_headers
                except (json.JSONDecodeError, UnicodeDecodeError) as e:
                    raise StructuredOutputError(f"gemini returned non-JSON body: {type(e).__name__}") from e
            if status in (400, 401, 403):
                raise ProviderPolicyError(f"gemini {status} (policy/auth/bad-request)")
            if status == 429:
                if attempt < self._max_retries:
                    ra = resp_headers.get("Retry-After") or resp_headers.get("retry-after")
                    delay = float(ra) if (ra and str(ra).replace(".", "", 1).isdigit()) else min(2 ** attempt, 8)
                    time.sleep(min(delay, 30)); attempt += 1; continue
                raise ProviderError("gemini 429 rate limited (retries exhausted)")
            if 500 <= status < 600:
                if attempt < self._max_retries:
                    time.sleep(min(2 ** attempt, 8)); attempt += 1; continue
                raise ProviderError(f"gemini {status} server error (retries exhausted)")
            raise ProviderError(f"gemini unexpected status {status}")

    @staticmethod
    def _extract_function_args(payload: dict[str, Any]) -> dict[str, Any] | None:
        try:
            parts = payload["candidates"][0]["content"]["parts"]
        except (KeyError, IndexError, TypeError):
            return None
        for p in parts or []:
            fc = p.get("functionCall")
            if fc and fc.get("name") == _TOOL_NAME:
                args = fc.get("args")
                return args if isinstance(args, dict) else None
        return None
