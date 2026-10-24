"""Shared Secrets Manager key reader for direct-provider adapters (OpenAI / Gemini).

Reads an API key from AWS Secrets Manager IN-PROCESS and NEVER logs, returns to a client, or embeds it.
Generalizes the proven `scene_image.load_key` extractor: a secret may be a BARE STRING or a JSON object
with a single value (e.g. {"YoTale-OpenAI-API-Key": "sk-..."}). Matching is separator/case-insensitive and
explicitly avoids obvious non-key fields ('secret', 'application id', 'app id') before a lone-value fallback.

boto3 is imported lazily so the package imports cleanly where boto3 is absent (unit tests inject a fake
client via `client=`). Raises ProviderAuthError on missing/denied/empty/unparseable — the caller surfaces
that as a non-fallback error (an auth failure must NOT fail over to the other provider).
"""
from __future__ import annotations

import json
import os
from typing import Any


class ProviderAuthError(RuntimeError):
    """The provider API key could not be read from Secrets Manager, or was empty/unrecognizable.

    This is an AUTH failure: callers must surface it and must NOT fail over to another provider."""


def _norm(x: str) -> str:
    return "".join(ch for ch in str(x).lower() if ch.isalnum())


def extract_key(secret_string: str, *, expected_key_hint: str | None = None) -> str:
    """Pull the API key out of a Secrets Manager SecretString value. Pure (no I/O) — unit-testable.

    Order: a bare non-'{' string is the key; else a JSON object -> the field matching `expected_key_hint`
    (normalized), then a lone non-secret field, then a lone field. Never returns an empty string."""
    s = (secret_string or "").strip()
    if not s:
        raise ProviderAuthError("empty secret")
    if not s.startswith("{"):
        return s
    try:
        d: dict[str, Any] = json.loads(s)
    except json.JSONDecodeError as e:
        raise ProviderAuthError(f"secret is not valid JSON: {type(e).__name__}") from e
    if not isinstance(d, dict) or not d:
        raise ProviderAuthError("secret JSON is not a non-empty object")
    norm_map = {_norm(k): v for k, v in d.items()}
    # Prefer the self-named field (e.g. "YoTale-OpenAI-API-Key"), then generic key-ish fields.
    candidates: list[str] = []
    if expected_key_hint:
        candidates.append(_norm(expected_key_hint))
    candidates += ["apikey", "api_key", "key", "value", "token", "secretkey"]
    for want in candidates:
        v = norm_map.get(want)
        if v and str(v).strip():
            return str(v).strip()
    # Avoid obvious non-key fields, then fall back to a lone value.
    non_secret = {
        k: v for k, v in d.items()
        if "applicationid" not in _norm(k) and "appid" not in _norm(k)
    }
    if len(non_secret) == 1:
        v = str(next(iter(non_secret.values()))).strip()
        if v:
            return v
    if len(d) == 1:
        v = str(next(iter(d.values()))).strip()
        if v:
            return v
    raise ProviderAuthError("secret JSON has no recognizable key field")


def load_provider_key(secret_id: str, *, region: str | None = None, client: Any = None,
                      expected_key_hint: str | None = None) -> str:
    """Read + extract a provider API key from Secrets Manager. `client` is injectable for tests
    (anything with .get_secret_value(SecretId=...) -> {"SecretString": ...}). Raises ProviderAuthError."""
    sm = client
    if sm is None:
        try:
            import boto3  # lazy
        except ImportError as e:  # pragma: no cover
            raise ProviderAuthError("boto3 not available to read provider key") from e
        sm = boto3.client("secretsmanager", region_name=region or os.environ.get("AWS_REGION", "us-east-1"))
    try:
        raw = sm.get_secret_value(SecretId=secret_id).get("SecretString") or ""
    except Exception as e:  # botocore ClientError / BotoCoreError
        raise ProviderAuthError(f"could not read secret '{secret_id}': {type(e).__name__}") from e
    return extract_key(raw, expected_key_hint=expected_key_hint or secret_id)
