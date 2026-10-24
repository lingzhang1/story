"""OpenAIModelGateway — direct OpenAI API adapter for the ModelGateway Protocol.

Thin, dependency-free HTTP client (urllib). Forces schema-valid structured output via a SINGLE required
tool/function call whose parameters ARE the request's JSON Schema (`tool_choice` pins it), mirroring how
BedrockModelGateway uses Converse tool-use — so the output is always a schema-valid JSON object mapped to
StructuredResult.data. Ordered multimodal frames are sent as image_url data-URIs in the user message, in
order, each preceded by its position text; system prompt -> a system message.

Error classification (req 5/8):
  * 429 / 5xx / transport / timeout  -> ProviderError      (recoverable: bounded retry, then fallback)
  * 400 / 401 / 403 / content-policy -> ProviderPolicyError (NEVER fail over; surface + record)
  * schema-invalid-after-repair      -> StructuredOutputError (model answered, output never validated)

NEVER logs the key, prompts, or image bytes. The key is read once (injected or via load_provider_key).
No official SDK — keeps the Lambda bundle small and the supply-chain surface minimal.
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

DEFAULT_OPENAI_BASE = "https://api.openai.com/v1"
_TOOL_NAME = "emit_structured"


class OpenAIModelGateway:
    """Direct OpenAI Chat Completions adapter. `model_id` is config-driven (never hardcoded upstream)."""

    def __init__(
        self,
        model_id: str,
        *,
        secret_id: str = "YoTale-OpenAI-API-Key",
        api_key: str | None = None,
        base_url: str = DEFAULT_OPENAI_BASE,
        region: str | None = None,
        timeout_seconds: float = 60.0,
        max_retries: int = 2,
        secrets_client: Any = None,
        http_post: Any = None,  # injectable transport for tests: (url, headers, body_bytes, timeout) -> (status, bytes, resp_headers)
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

    # -- key (read once, lazily) --
    def _key(self) -> str:
        if self._api_key is None:
            self._api_key = load_provider_key(
                self._secret_id, region=self._region, client=self._secrets_client,
                expected_key_hint=self._secret_id)
        return self._api_key

    # -- request translation --
    def _build_body(self, req: StructuredRequest) -> dict[str, Any]:
        user_content: list[dict[str, Any]] = [{"type": "text", "text": req.user_content}]
        for i, img in enumerate(req.images):
            b64 = base64.b64encode(img.data).decode("ascii")
            user_content.append({"type": "text", "text": f"[frame {i + 1}]"})
            user_content.append({
                "type": "image_url",
                "image_url": {"url": f"data:{img.media_type};base64,{b64}"},
            })
        return {
            "model": self.model_id,
            "messages": [
                {"role": "system", "content": req.system},
                {"role": "user", "content": user_content},
            ],
            "tools": [{
                "type": "function",
                "function": {
                    "name": _TOOL_NAME,
                    "description": "Emit the single structured result for this task.",
                    "parameters": req.schema,
                    "strict": False,  # our schemas use JSON-Schema features OpenAI strict mode rejects; we validate upstream
                },
            }],
            "tool_choice": {"type": "function", "function": {"name": _TOOL_NAME}},
            # GPT-5-era models require `max_completion_tokens` and reject the legacy `max_tokens`
            # (unsupported_parameter 400). Older models accept it too, so use it unconditionally.
            "max_completion_tokens": req.max_tokens,
            "temperature": req.temperature,
        }

    def generate_structured(self, req: StructuredRequest) -> StructuredResult:
        body = self._build_body(req)
        last_err: Exception | None = None
        for attempt in range(1 + max(0, req.max_repair_attempts)):
            try:
                status, payload, headers = self._post("/chat/completions", body)
            except ProviderError as e:
                last_err = e
                raise  # transport/classified errors already typed by _post
            tool_input = self._extract_tool_input(payload)
            if tool_input is not None:
                usage = payload.get("usage") or {}
                return StructuredResult(
                    data=tool_input,
                    usage=Usage(
                        input_tokens=usage.get("prompt_tokens"),
                        output_tokens=usage.get("completion_tokens"),
                        total_tokens=usage.get("total_tokens"),
                    ),
                    attempts=attempt + 1,
                    repaired=attempt > 0,
                    model=self.model_id,
                    provider="openai",
                    stop_reason=(payload.get("choices") or [{}])[0].get("finish_reason"),
                )
            finish = (payload.get("choices") or [{}])[0].get("finish_reason")
            if finish == "length":
                last_err = StructuredOutputError("output truncated at max_tokens (increase max_tokens)")
            else:
                last_err = StructuredOutputError(f"model did not return a tool call (finish_reason={finish})")
            # nudge once more
            body["messages"] = body["messages"][:2] + [
                {"role": "user", "content": f"You must call {_TOOL_NAME} with valid JSON."}]
        raise last_err or StructuredOutputError("no structured output")

    # -- HTTP with bounded retry + classification --
    def _post(self, path: str, body: dict[str, Any]) -> tuple[int, dict[str, Any], dict[str, str]]:
        url = self._base + path
        data = json.dumps(body).encode("utf-8")
        headers = {"Authorization": f"Bearer {self._key()}", "Content-Type": "application/json"}
        attempt = 0
        while True:
            try:
                if self._http_post is not None:
                    status, raw, resp_headers = self._http_post(url, headers, data, self._timeout)
                else:
                    reqo = urllib.request.Request(url, data=data, headers=headers, method="POST")
                    with urllib.request.urlopen(reqo, timeout=self._timeout) as r:
                        status, raw, resp_headers = r.status, r.read(), dict(r.headers)
            except urllib.error.HTTPError as he:  # pragma: no cover - exercised via injected transport in tests
                status = he.code
                raw = he.read() if hasattr(he, "read") else b""
                resp_headers = dict(getattr(he, "headers", {}) or {})
            except (urllib.error.URLError, TimeoutError, OSError) as te:
                # transport / timeout -> recoverable
                if attempt < self._max_retries:
                    time.sleep(min(2 ** attempt, 8))
                    attempt += 1
                    continue
                raise ProviderError(f"openai transport error: {type(te).__name__}") from te

            if status == 200:
                try:
                    return status, json.loads(raw.decode("utf-8")), resp_headers
                except (json.JSONDecodeError, UnicodeDecodeError) as e:
                    raise StructuredOutputError(f"openai returned non-JSON body: {type(e).__name__}") from e
            self._raise_for_status(status, raw, resp_headers, attempt)
            # if _raise_for_status chose to retry, loop again
            attempt += 1

    def _raise_for_status(self, status: int, raw: bytes, headers: dict[str, str], attempt: int) -> None:
        # Policy / access / auth / bad-request -> NEVER fail over.
        if status in (400, 401, 403):
            raise ProviderPolicyError(f"openai {status} (policy/auth/bad-request)")
        # Rate limit -> honor Retry-After, bounded.
        if status == 429:
            if attempt < self._max_retries:
                ra = headers.get("Retry-After") or headers.get("retry-after")
                delay = float(ra) if (ra and str(ra).replace(".", "", 1).isdigit()) else min(2 ** attempt, 8)
                time.sleep(min(delay, 30))
                return  # caller loops
            raise ProviderError("openai 429 rate limited (retries exhausted)")
        if 500 <= status < 600:
            if attempt < self._max_retries:
                time.sleep(min(2 ** attempt, 8))
                return
            raise ProviderError(f"openai {status} server error (retries exhausted)")
        raise ProviderError(f"openai unexpected status {status}")

    @staticmethod
    def _extract_tool_input(payload: dict[str, Any]) -> dict[str, Any] | None:
        try:
            calls = payload["choices"][0]["message"]["tool_calls"]
        except (KeyError, IndexError, TypeError):
            return None
        for c in calls or []:
            fn = c.get("function") or {}
            if fn.get("name") == _TOOL_NAME:
                args = fn.get("arguments")
                if isinstance(args, str):
                    try:
                        parsed = json.loads(args)
                    except json.JSONDecodeError:
                        return None
                    return parsed if isinstance(parsed, dict) else None
                if isinstance(args, dict):
                    return args
        return None
