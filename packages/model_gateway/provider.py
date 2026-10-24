"""Provider router — builds a ModelGateway for a given AI capability from configurable routing.

ONE chokepoint so deps.py / worker.py never construct a vendor gateway directly. A route maps a capability
to {primary_provider, fallback_provider}; providers resolve to concrete adapters (bedrock | openai | gemini)
with config-driven model ids. Primary+fallback are wrapped in the EXISTING FallbackModelGateway, so the
fallback policy (recoverable -> fail over; ProviderPolicyError -> never) is unchanged and shared.

CONSTRAINTS enforced here:
  * No capability routes to a RESTRICTED Anthropic model. `anthropic`/`bedrock-anthropic` is NOT a valid
    provider token; `bedrock` is allowed only for non-Anthropic Bedrock model ids and a model id that
    looks like an Anthropic id is refused (defense in depth against an accidental Anthropic default).
  * Everything is env-configurable: provider per capability, model id per provider, and whether a
    capability even has a fallback.

Default routing (approved Phase A table):
  Gemini primary / OpenAI fallback : asset_understanding, scene_understanding
  OpenAI primary / Gemini fallback : creative_intent, story_guide, story_coverage, edit_plan, music,
                                     story_director, duration
"""
from __future__ import annotations

import os
from typing import Any

from . import ModelGateway, FallbackModelGateway

# Capability -> (primary_provider, fallback_provider). Overridable per capability via
# STORY_ROUTE_<CAP>="primary:fallback" (e.g. STORY_ROUTE_ASSET_UNDERSTANDING="openai:gemini").
_DEFAULT_ROUTES: dict[str, tuple[str, str | None]] = {
    "asset_understanding": ("gemini", "openai"),
    "scene_understanding": ("gemini", "openai"),
    "creative_intent":     ("openai", "gemini"),
    "story_guide":         ("openai", "gemini"),
    "story_coverage":      ("openai", "gemini"),
    "edit_plan":           ("openai", "gemini"),
    "music":               ("openai", "gemini"),
    "story_director":      ("openai", "gemini"),
    "duration":            ("openai", "gemini"),
}

# Per-provider default model id env knobs. Values intentionally UNSET here — resolved from env with a
# documented placeholder; the real GA id is confirmed in Phase D against the provider catalog. A missing
# id raises so we never silently call a wrong/empty model.
_MODEL_ENV = {
    "openai": "STORY_OPENAI_MODEL",
    "gemini": "STORY_GEMINI_MODEL",
    "bedrock": "STORY_BEDROCK_ROUTED_MODEL",
}
# Phase-A placeholders (documented as provisional; override via env). Chosen as capable GA vision +
# structured-output families; EXACT ids verified in Phase D.
_MODEL_DEFAULT = {
    "openai": "gpt-4o",
    "gemini": "gemini-1.5-pro",
}

_ANTHROPIC_MARKERS = ("anthropic", "claude")


def _looks_anthropic(model_id: str) -> bool:
    m = (model_id or "").lower()
    return any(k in m for k in _ANTHROPIC_MARKERS)


def _route_for(capability: str) -> tuple[str, str | None]:
    override = os.environ.get(f"STORY_ROUTE_{capability.upper()}")
    if override:
        parts = override.split(":", 1)
        primary = parts[0].strip()
        fallback = parts[1].strip() if len(parts) > 1 and parts[1].strip() else None
        return primary, fallback
    return _DEFAULT_ROUTES.get(capability, ("openai", "gemini"))


def _model_for(provider: str) -> str:
    env = _MODEL_ENV.get(provider)
    model = (os.environ.get(env) if env else None) or _MODEL_DEFAULT.get(provider)
    if not model:
        raise ValueError(f"no model id configured for provider '{provider}' (set {env})")
    return model


def _make_adapter(provider: str, **kw: Any) -> ModelGateway:
    provider = (provider or "").lower()
    if provider in ("anthropic", "bedrock-anthropic"):
        raise ValueError("Anthropic routing is disabled (access restricted); no capability may target it")
    model = _model_for(provider)
    if provider == "openai":
        from .openai_gateway import OpenAIModelGateway
        return OpenAIModelGateway(model_id=model, **kw)
    if provider == "gemini":
        from .gemini_gateway import GeminiModelGateway
        return GeminiModelGateway(model_id=model, **kw)
    if provider == "bedrock":
        if _looks_anthropic(model):
            raise ValueError(f"refusing Bedrock route to an Anthropic model id '{model}' (restricted)")
        from . import BedrockModelGateway
        return BedrockModelGateway(model_id=model)
    raise ValueError(f"unknown provider '{provider}'")


def make_gateway(capability: str, **adapter_kwargs: Any) -> ModelGateway:
    """Return a ModelGateway for a capability, honoring the configured primary/fallback route. Fallback
    (when present and distinct) is wrapped in FallbackModelGateway. `adapter_kwargs` are passed to the
    HTTP adapters (e.g. secrets_client/http_post for tests)."""
    primary_name, fallback_name = _route_for(capability)
    primary = _make_adapter(primary_name, **adapter_kwargs)
    if not fallback_name or fallback_name == primary_name:
        return primary
    fallback = _make_adapter(fallback_name, **adapter_kwargs)
    return FallbackModelGateway(primary, fallback)


def active_routes() -> dict[str, dict[str, str | None]]:
    """Resolved routing + model ids, for diagnostics/logging (no secrets). Used by a /diag or a log line."""
    out: dict[str, dict[str, str | None]] = {}
    for cap in _DEFAULT_ROUTES:
        p, f = _route_for(cap)
        try:
            pm = _model_for(p)
        except ValueError:
            pm = None
        fm: str | None = None
        if f and f != p:
            try:
                fm = _model_for(f)
            except ValueError:
                fm = None
        out[cap] = {"primary": p, "primary_model": pm, "fallback": f, "fallback_model": fm}
    return out
