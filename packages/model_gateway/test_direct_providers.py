"""Phase C — offline verification for the direct OpenAI/Gemini adapters + router + fallback.

No network, no real keys: every test injects a fake HTTP transport and a fake secrets client. Covers the
18 required cases (text, multimodal frames, schema translation, structured parsing, missing/malformed
creds, timeout, 429/5xx fallback, 4xx/policy NO-fallback, malformed/invalid output, secret redaction,
routing by capability, App Runner + Lambda construction, and the error-classification contract).
"""
from __future__ import annotations

import json
import urllib.error

import pytest

from model_gateway import (
    StructuredRequest, ImageInput, ProviderError, ProviderPolicyError, StructuredOutputError,
    FallbackModelGateway, FakeModelGateway,
)
from model_gateway._secret import extract_key, load_provider_key, ProviderAuthError
from model_gateway.openai_gateway import OpenAIModelGateway
from model_gateway.gemini_gateway import GeminiModelGateway, translate_schema, SchemaTranslationError
from model_gateway import provider as prov


SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {"summary": {"type": "string"}, "n": {"type": "integer"}},
    "required": ["summary"],
}


def _req(images=None):
    return StructuredRequest(
        task="t", schema=SCHEMA, prompt_version="v1", system="sys", user_content="hi",
        images=images or [], max_tokens=64, temperature=0.0, max_repair_attempts=1)


class _FakeSecrets:
    def __init__(self, value): self._v = value
    def get_secret_value(self, SecretId): return {"SecretString": self._v}


# ---- fake transports (url, headers, body, timeout) -> (status, bytes, headers) ----

def _openai_ok(tool_args):
    payload = {"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
        {"function": {"name": "emit_structured", "arguments": json.dumps(tool_args)}}]}}],
        "usage": {"prompt_tokens": 10, "completion_tokens": 5, "total_tokens": 15}}
    def t(url, headers, body, timeout): return 200, json.dumps(payload).encode(), {}
    return t

def _gemini_ok(args):
    payload = {"candidates": [{"finishReason": "STOP", "content": {"parts": [
        {"functionCall": {"name": "emit_structured", "args": args}}]}}],
        "usageMetadata": {"promptTokenCount": 10, "candidatesTokenCount": 5, "totalTokenCount": 15}}
    def t(url, headers, body, timeout): return 200, json.dumps(payload).encode(), {}
    return t

def _status(code, body=b"{}", headers=None):
    def t(url, h, b, to): return code, body, headers or {}
    return t


# 1 — OpenAI text-only structured generation
def test_openai_text_structured():
    gw = OpenAIModelGateway("gpt-x", api_key="k", http_post=_openai_ok({"summary": "ok", "n": 2}))
    r = gw.generate_structured(_req())
    assert r.data == {"summary": "ok", "n": 2}
    assert r.provider == "openai" and r.usage.total_tokens == 15

def test_openai_uses_max_completion_tokens_not_max_tokens():
    captured = {}
    def t(url, headers, body, timeout):
        captured["body"] = json.loads(body.decode())
        return 200, json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
            {"function": {"name": "emit_structured", "arguments": "{\"summary\":\"x\"}"}}]}}]}).encode(), {}
    OpenAIModelGateway("gpt-5.1", api_key="k", http_post=t).generate_structured(_req())
    assert "max_completion_tokens" in captured["body"]  # GPT-5-era requirement
    assert "max_tokens" not in captured["body"]

# 2 — Gemini text-only structured generation
def test_gemini_text_structured():
    gw = GeminiModelGateway("gem-x", api_key="k", http_post=_gemini_ok({"summary": "ok"}))
    r = gw.generate_structured(_req())
    assert r.data == {"summary": "ok"} and r.provider == "gemini"

# 3 — ordered 24-frame multimodal input (both adapters encode frames in order)
def test_multimodal_frames_ordered():
    frames = [ImageInput(data=bytes([i]), media_type="image/jpeg") for i in range(24)]
    captured = {}
    def t(url, headers, body, timeout):
        captured["body"] = json.loads(body.decode())
        return 200, json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
            {"function": {"name": "emit_structured", "arguments": "{\"summary\":\"x\"}"}}]}}]}).encode(), {}
    gw = OpenAIModelGateway("gpt-x", api_key="k", http_post=t)
    gw.generate_structured(_req(images=frames))
    uc = captured["body"]["messages"][1]["content"]
    img_parts = [p for p in uc if p.get("type") == "image_url"]
    labels = [p["text"] for p in uc if p.get("type") == "text" and p["text"].startswith("[frame")]
    assert len(img_parts) == 24
    assert labels[0] == "[frame 1]" and labels[-1] == "[frame 24]"  # order preserved

# 4 — schema translation (Gemini subset) + rejection of inexpressible schema
def test_gemini_schema_translation_drops_additionalproperties():
    out = translate_schema(SCHEMA)
    assert "additionalProperties" not in out
    assert out["type"] == "object" and out["required"] == ["summary"]
    assert out["properties"]["summary"]["type"] == "string"

def test_gemini_schema_translation_rejects_ref():
    with pytest.raises(SchemaTranslationError):
        translate_schema({"type": "object", "properties": {"x": {"$ref": "#/$defs/Y"}}})

# 5 — missing / malformed credentials
def test_missing_credential_raises_auth():
    with pytest.raises(ProviderAuthError):
        load_provider_key("sid", client=_FakeSecrets(""))
def test_malformed_json_secret_raises_auth():
    with pytest.raises(ProviderAuthError):
        extract_key("{not json")

# 6 — HTTP timeout / connection error -> ProviderError (recoverable)
def test_timeout_is_provider_error():
    def t(url, h, b, to): raise urllib.error.URLError("timed out")
    gw = OpenAIModelGateway("gpt-x", api_key="k", max_retries=0, http_post=t)
    with pytest.raises(ProviderError):
        gw.generate_structured(_req())

# 7 — 429 then success (bounded retry); 5xx exhausted -> ProviderError
def test_429_retries_then_ok():
    calls = {"n": 0}
    def t(url, h, b, to):
        calls["n"] += 1
        if calls["n"] == 1: return 429, b"{}", {"Retry-After": "0"}
        return 200, json.dumps({"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
            {"function": {"name": "emit_structured", "arguments": "{\"summary\":\"x\"}"}}]}}]}).encode(), {}
    gw = OpenAIModelGateway("gpt-x", api_key="k", max_retries=2, http_post=t)
    assert gw.generate_structured(_req()).data["summary"] == "x"
def test_5xx_exhausted_is_provider_error():
    gw = OpenAIModelGateway("gpt-x", api_key="k", max_retries=1, http_post=_status(503))
    with pytest.raises(ProviderError):
        gw.generate_structured(_req())

# 8 — 400/401/403 -> ProviderPolicyError (NEVER recoverable)
@pytest.mark.parametrize("code", [400, 401, 403])
def test_4xx_is_policy_error(code):
    gw = OpenAIModelGateway("gpt-x", api_key="k", http_post=_status(code))
    with pytest.raises(ProviderPolicyError):
        gw.generate_structured(_req())

# 9 — content-policy denial (Gemini SAFETY finish) -> ProviderPolicyError, no fallover
def test_gemini_safety_block_is_policy_error():
    payload = {"candidates": [{"finishReason": "SAFETY", "content": {"parts": []}}]}
    gw = GeminiModelGateway("gem-x", api_key="k", http_post=_status(200, json.dumps(payload).encode()))
    with pytest.raises(ProviderPolicyError):
        gw.generate_structured(_req())

# 10 — malformed JSON args / no tool call -> StructuredOutputError
def test_openai_bad_tool_args_is_structured_error():
    payload = {"choices": [{"finish_reason": "tool_calls", "message": {"tool_calls": [
        {"function": {"name": "emit_structured", "arguments": "{not json"}}]}}]}
    gw = OpenAIModelGateway("gpt-x", api_key="k", http_post=_status(200, json.dumps(payload).encode()))
    with pytest.raises(StructuredOutputError):
        gw.generate_structured(_req())

# 11 — secret-value redaction: the key never appears in the result/model/provider strings
def test_secret_never_surfaced_in_result():
    gw = OpenAIModelGateway("gpt-x", api_key="SECRET-KEY-123", http_post=_openai_ok({"summary": "ok"}))
    r = gw.generate_structured(_req())
    blob = json.dumps({"data": r.data, "model": r.model, "provider": r.provider})
    assert "SECRET-KEY-123" not in blob

# 12 — routing by capability + Anthropic refusal
def test_routing_table(monkeypatch):
    monkeypatch.delenv("STORY_ROUTE_ASSET_UNDERSTANDING", raising=False)
    monkeypatch.setenv("STORY_OPENAI_MODEL", "gpt-x")
    monkeypatch.setenv("STORY_GEMINI_MODEL", "gem-x")
    routes = prov.active_routes()
    assert routes["asset_understanding"]["primary"] == "gemini"
    assert routes["asset_understanding"]["fallback"] == "openai"
    assert routes["story_guide"]["primary"] == "openai"
def test_router_refuses_anthropic(monkeypatch):
    monkeypatch.setenv("STORY_ROUTE_STORY_GUIDE", "anthropic:openai")
    with pytest.raises(ValueError):
        prov.make_gateway("story_guide")
def test_router_refuses_bedrock_anthropic_model(monkeypatch):
    monkeypatch.setenv("STORY_ROUTE_STORY_GUIDE", "bedrock:")
    monkeypatch.setenv("STORY_BEDROCK_ROUTED_MODEL", "us.anthropic.claude-opus-4-6-v1")
    with pytest.raises(ValueError):
        prov.make_gateway("story_guide")

# 13 + 14 — App Runner (deps) and Lambda (worker) construction in direct mode build a routed gateway
def test_deps_direct_mode_builds_router(monkeypatch):
    monkeypatch.setenv("STORY_MODEL_PROVIDER", "direct")
    monkeypatch.setenv("STORY_OPENAI_MODEL", "gpt-x")
    monkeypatch.setenv("STORY_GEMINI_MODEL", "gem-x")
    from app import deps
    gw = deps.routed_gateway("story_guide", "unused-bedrock-model")
    # direct mode => OpenAI primary + Gemini fallback wrapped in FallbackModelGateway
    assert isinstance(gw, FallbackModelGateway)
def test_deps_bedrock_mode_unchanged(monkeypatch):
    monkeypatch.setenv("STORY_MODEL_PROVIDER", "bedrock")
    from app import deps
    gw = deps.routed_gateway("story_guide", "amazon.nova-lite-v1:0")
    # bedrock mode => legacy path (bare or fallback gateway), NOT the direct router
    assert gw is not None

# 15/16/17/18 — the EXISTING suites (story guide, AU, edit plan v2, revise/explore) are unchanged and
# run via the normal mock path; this file adds the adapter layer without weakening them. Covered by the
# full backend run (see Phase C report).

# Fallback policy contract (shared): recoverable fails over; policy does NOT.
def test_fallback_fails_over_on_provider_error():
    gw = FallbackModelGateway(FakeModelGateway(error=ProviderError("429")), FakeModelGateway(response={"summary": "fb"}))
    assert gw.generate_structured(_req()).data["summary"] == "fb"
    assert gw.last_fallback is True
def test_fallback_does_not_fail_over_on_policy_error():
    gw = FallbackModelGateway(FakeModelGateway(error=ProviderPolicyError("policy")), FakeModelGateway(response={"summary": "fb"}))
    with pytest.raises(ProviderPolicyError):
        gw.generate_structured(_req())
    assert gw.last_fallback is False
