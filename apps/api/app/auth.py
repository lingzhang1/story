"""P0 Beta Auth — Increment 2: backend JWT verification + stable Story identity resolution.

This module is the ONE trusted-identity seam. A protected endpoint depends on `require_user` (or, during the
dev-only optional-auth window, `optional_user`), which:

  1. Verifies a Cognito **access** token: RS256 signature against the pool JWKS (bounded cache + rotation),
     exact issuer, expiry/`iat`, `token_use == "access"`, and the expected app-client id (`client_id`).
     ID tokens, expired/tampered tokens, wrong issuer, and wrong client are REJECTED.
  2. Resolves the verified `cognito_sub` to the IMMUTABLE application-owned `story_user_id` via the
     identity-claims table using an ATOMIC conditional write (concurrent first sign-in is race-safe; one
     Cognito subject maps to exactly one Story account; no GSI-only uniqueness; no email auto-merge).
  3. Enforces `account_status` (a suspended/deleted account is rejected).

Nothing here trusts a client-supplied user id. Verification and identity I/O are injectable via `app.state`
(`_jwt_verifier_override`, `_identity_store_override`) so tests need neither network nor real crypto.

Rollout semantics (owner decision):
  - Environment `development` MAY run in optional-auth mode: a MISSING token falls back to the explicitly
    permitted legacy principal; a PRESENT but INVALID token ALWAYS fails (never downgraded); an authenticated
    user is NEVER downgraded to the legacy identity.
  - `production` FAILS CLOSED: auth is always required; there is no env value that reopens unauthenticated
    access. The optional-auth branch is unreachable when the environment is production.
"""

from __future__ import annotations

import os
import time
import uuid
from dataclasses import dataclass
from typing import Any, Optional

from fastapi import Depends, HTTPException, Request

LEGACY_PRINCIPAL = "dev"  # the pre-auth principal; isolated from every real story_user_id.


# ---------------------------------------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------------------------------------
def _env() -> str:
    return os.environ.get("STORY_ENVIRONMENT", "development").strip().lower()


def _is_production() -> bool:
    return _env() == "production"


def auth_required() -> bool:
    """Whether a verified identity is REQUIRED on protected endpoints.

    Production is ALWAYS fail-closed — no env value can reopen it. In non-prod the DEFAULT is the optional-auth
    window (legacy dev clients keep working): a missing token uses the legacy path, a present token must be
    valid. Set `STORY_REQUIRE_AUTH=1` in dev/staging to require auth there too; production ignores the flag."""
    if _is_production():
        return True
    return os.environ.get("STORY_REQUIRE_AUTH", "0") == "1"


@dataclass
class CognitoConfig:
    region: str = ""
    user_pool_id: str = ""
    app_client_id: str = ""

    @classmethod
    def from_env(cls) -> "CognitoConfig":
        return cls(
            region=os.environ.get("AWS_REGION", "us-east-1"),
            user_pool_id=os.environ.get("STORY_COGNITO_USER_POOL_ID", ""),
            app_client_id=os.environ.get("STORY_COGNITO_APP_CLIENT_ID", ""),
        )

    @property
    def issuer(self) -> str:
        return f"https://cognito-idp.{self.region}.amazonaws.com/{self.user_pool_id}"

    @property
    def jwks_url(self) -> str:
        return f"{self.issuer}/.well-known/jwks.json"


class AuthError(HTTPException):
    def __init__(self, detail: str):
        super().__init__(status_code=401, detail=detail)


@dataclass
class Principal:
    """The resolved request principal handed to a protected handler."""
    story_user_id: str
    cognito_sub: Optional[str] = None  # None for the legacy dev principal
    is_legacy: bool = False

    @property
    def is_authenticated(self) -> bool:
        return not self.is_legacy


# ---------------------------------------------------------------------------------------------------------
# JWT verifier — JWKS cache with rotation
# ---------------------------------------------------------------------------------------------------------
class CognitoJwtVerifier:
    """Verifies a Cognito ACCESS token. JWKS is fetched lazily and cached for `jwks_ttl` seconds; a `kid` not
    in the cache forces a SINGLE refresh (key rotation) before failing, so a rotated signing key is picked up
    without a fixed poll. `_fetch_jwks` is overridable in tests (no network)."""

    def __init__(self, cfg: CognitoConfig, *, jwks_ttl: int = 3600):
        self.cfg = cfg
        self.jwks_ttl = jwks_ttl
        self._jwks: dict[str, Any] = {}
        self._jwks_at: float = 0.0

    # -- JWKS --------------------------------------------------------------------------------------------
    def _fetch_jwks(self) -> dict[str, Any]:
        import json as _json
        import urllib.request
        with urllib.request.urlopen(self.cfg.jwks_url, timeout=5) as r:  # noqa: S310 (fixed AWS host)
            return _json.loads(r.read().decode("utf-8"))

    def _jwks_map(self, *, force: bool = False) -> dict[str, Any]:
        now = time.time()
        if force or not self._jwks or (now - self._jwks_at) > self.jwks_ttl:
            data = self._fetch_jwks()
            self._jwks = {k["kid"]: k for k in data.get("keys", [])}
            self._jwks_at = now
        return self._jwks

    def _key_for(self, kid: str):
        keys = self._jwks_map()
        jwk = keys.get(kid)
        if jwk is None:  # possible rotation — refresh once, then give up
            jwk = self._jwks_map(force=True).get(kid)
        if jwk is None:
            raise AuthError("unknown signing key")
        import jwt  # PyJWT
        return jwt.algorithms.RSAAlgorithm.from_jwk(__import__("json").dumps(jwk))

    # -- verify ------------------------------------------------------------------------------------------
    def verify_access_token(self, token: str) -> dict[str, Any]:
        """Return the verified claims of a Cognito ACCESS token, or raise AuthError."""
        import jwt  # PyJWT
        try:
            header = jwt.get_unverified_header(token)
        except Exception:
            raise AuthError("malformed token")
        kid = header.get("kid")
        if not kid or header.get("alg") != "RS256":
            raise AuthError("unexpected token header")
        key = self._key_for(kid)
        try:
            claims = jwt.decode(
                token,
                key=key,
                algorithms=["RS256"],
                issuer=self.cfg.issuer,
                options={"require": ["exp", "iat", "iss", "token_use"], "verify_aud": False},
            )
        except jwt.ExpiredSignatureError:
            raise AuthError("token expired")
        except jwt.InvalidIssuerError:
            raise AuthError("wrong issuer")
        except Exception:
            raise AuthError("invalid token")
        # Cognito ACCESS tokens carry token_use=access and client_id (NOT aud). Reject ID tokens explicitly.
        if claims.get("token_use") != "access":
            raise AuthError("not an access token")
        if self.cfg.app_client_id and claims.get("client_id") != self.cfg.app_client_id:
            raise AuthError("wrong app client")
        if not claims.get("sub"):
            raise AuthError("missing subject")
        return claims


# ---------------------------------------------------------------------------------------------------------
# Identity resolution — atomic cognito_sub -> story_user_id
# ---------------------------------------------------------------------------------------------------------
class IdentityStore:
    """Maps a verified cognito_sub to the immutable story_user_id, creating the Story account on first
    sign-in with an ATOMIC claim (conditional PutItem on the identity-claims table + the StoryUser row via a
    TransactWriteItems). Concurrent first sign-ins for the same sub resolve to the SAME story_user_id; the
    loser of the race re-reads the winner's claim. No GSI-only uniqueness. No email-based auto-merge."""

    def __init__(self, *, ddb=None,
                 claims_table: str = "", users_table: str = "", region: str = "us-east-1"):
        self._ddb = ddb
        self.claims_table = claims_table or os.environ.get("STORY_IDENTITY_CLAIMS_TABLE", "")
        self.users_table = users_table or os.environ.get("STORY_USERS_TABLE", "")
        self.region = region or os.environ.get("AWS_REGION", "us-east-1")

    def _c(self):
        if self._ddb is None:
            import boto3
            self._ddb = boto3.client("dynamodb", region_name=self.region)
        return self._ddb

    def _read_claim(self, claim_key: str) -> Optional[str]:
        resp = self._c().get_item(TableName=self.claims_table, Key={"claim_key": {"S": claim_key}})
        it = resp.get("Item")
        return it["story_user_id"]["S"] if it else None

    def _account_status(self, story_user_id: str) -> str:
        resp = self._c().get_item(TableName=self.users_table, Key={"story_user_id": {"S": story_user_id}})
        it = resp.get("Item")
        if not it:
            return "active"  # claim without a row shouldn't happen; treat as active (row write is same txn)
        return it.get("account_status", {}).get("S", "active")

    def resolve(self, cognito_sub: str, *, verified_email: Optional[str] = None) -> str:
        """Return the story_user_id for this cognito_sub, creating it atomically on first sign-in."""
        claim_key = f"cognito#{cognito_sub}"
        existing = self._read_claim(claim_key)
        if existing:
            self._enforce_status(existing)
            return existing

        new_id = str(uuid.uuid4())
        now = str(int(time.time()))
        try:
            # Atomic: claim + StoryUser row together; condition makes a concurrent second claim fail.
            self._c().transact_write_items(TransactItems=[
                {"Put": {
                    "TableName": self.claims_table,
                    "Item": {"claim_key": {"S": claim_key}, "story_user_id": {"S": new_id},
                             "provider": {"S": "cognito"}, "created_at": {"N": now}},
                    "ConditionExpression": "attribute_not_exists(claim_key)",
                }},
                {"Put": {
                    "TableName": self.users_table,
                    "Item": {"story_user_id": {"S": new_id}, "cognito_sub": {"S": cognito_sub},
                             "account_status": {"S": "active"}, "beta_access_status": {"S": "invited"},
                             "created_at": {"N": now},
                             **({"verified_email": {"S": verified_email}} if verified_email else {})},
                    "ConditionExpression": "attribute_not_exists(story_user_id)",
                }},
            ])
            return new_id
        except Exception as e:
            # Lost the race (or re-submit): the winner's claim now exists — read it back.
            if "ConditionalCheckFailed" in type(e).__name__ or "ConditionalCheckFailed" in str(e) \
                    or "TransactionCanceled" in type(e).__name__ or "TransactionCanceled" in str(e):
                won = self._read_claim(claim_key)
                if won:
                    self._enforce_status(won)
                    return won
            raise

    def _enforce_status(self, story_user_id: str) -> None:
        st = self._account_status(story_user_id)
        if st not in ("active",):
            raise HTTPException(status_code=403, detail=f"account {st}")


# ---------------------------------------------------------------------------------------------------------
# FastAPI dependencies
# ---------------------------------------------------------------------------------------------------------
def _bearer(request: Request) -> Optional[str]:
    h = request.headers.get("Authorization") or request.headers.get("authorization")
    if not h:
        return None
    parts = h.split(" ", 1)
    if len(parts) != 2 or parts[0].lower() != "bearer" or not parts[1].strip():
        raise AuthError("malformed Authorization header")
    return parts[1].strip()


def _verifier(request: Request) -> CognitoJwtVerifier:
    ov = getattr(request.app.state, "_jwt_verifier_override", None)
    if ov is not None:
        return ov
    return CognitoJwtVerifier(CognitoConfig.from_env())


def _identity(request: Request) -> IdentityStore:
    ov = getattr(request.app.state, "_identity_store_override", None)
    if ov is not None:
        return ov
    return IdentityStore()


def _principal_from_token(request: Request, token: str) -> Principal:
    claims = _verifier(request).verify_access_token(token)  # raises AuthError on any failure
    sub = claims["sub"]
    story_user_id = _identity(request).resolve(sub)
    return Principal(story_user_id=story_user_id, cognito_sub=sub, is_legacy=False)


def require_user(request: Request) -> Principal:
    """Protected-endpoint dependency. Always requires a VALID access token (prod + any endpoint that must
    never run unauthenticated). A present-but-invalid token fails; a missing token fails.

    Reuses the principal already resolved by the central `auth_boundary` middleware for THIS request when
    present (verify-once: no second JWT verification or identity-store lookup). Falls back to resolving
    directly if the middleware did not run (e.g. a unit test calling the dependency in isolation)."""
    cached = getattr(request.state, "principal", None)
    if cached is not None:
        if cached.is_legacy:
            # The boundary admitted a legacy principal only in the dev optional-auth window; a require_user
            # route must still reject it.
            raise AuthError("authentication required")
        return cached
    token = _bearer(request)
    if not token:
        raise AuthError("authentication required")
    return _principal_from_token(request, token)


def optional_user(request: Request) -> Principal:
    """Dev-only optional-auth window. A MISSING token -> legacy principal (only when auth is not required).
    A PRESENT token MUST be valid (invalid never downgrades). An authenticated user is NEVER downgraded. In
    production (or whenever auth_required()), this is identical to require_user — fail closed.

    Reuses the principal resolved by the central `auth_boundary` middleware when present (verify-once)."""
    cached = getattr(request.state, "principal", None)
    if cached is not None:
        return cached
    token = _bearer(request)
    if token:
        # Present token: must verify. Never silently fall back on an invalid token.
        return _principal_from_token(request, token)
    if auth_required():
        raise AuthError("authentication required")
    # No token + optional-auth window: the explicitly permitted legacy path.
    return Principal(story_user_id=LEGACY_PRINCIPAL, cognito_sub=None, is_legacy=True)


# ---------------------------------------------------------------------------------------------------------
# Central deny-by-default authentication boundary (P0 Beta Security Phase 1)
# ---------------------------------------------------------------------------------------------------------
# The ONE place that decides "is this request allowed through unauthenticated?". Every route that is NOT on
# the explicit public allowlist is protected here, so a new endpoint cannot ship unauthenticated by a
# forgotten per-route dependency (req 1, 7, 10). The dependencies above REUSE the principal this resolves,
# so a protected request verifies its JWT and resolves its story_user_id exactly once (req 3, 12).

# Always-public paths (exact match). Health is the only customer-facing public route.
PUBLIC_PATHS_ALWAYS = frozenset({"/health"})
# Interactive API docs — public ONLY in development. Disabled (treated as protected) in beta/gamma/prod
# unless an operator explicitly opts in via STORY_DOCS_PUBLIC=1 (req 4).
DOCS_PATHS = frozenset({"/docs", "/redoc", "/openapi.json", "/docs/oauth2-redirect"})


def _docs_public() -> bool:
    if _env() == "development":
        return True
    return os.environ.get("STORY_DOCS_PUBLIC", "0") == "1"


def is_public_path(path: str) -> bool:
    if path in PUBLIC_PATHS_ALWAYS:
        return True
    if path in DOCS_PATHS:
        return _docs_public()
    return False


def _boundary_auth_required() -> bool:
    """At the central boundary, beta/gamma/production FAIL CLOSED regardless of STORY_REQUIRE_AUTH (req 8).
    Development may run the optional-auth window (req 9); STORY_REQUIRE_AUTH=1 opts dev into fail-closed too."""
    if _env() == "development":
        return os.environ.get("STORY_REQUIRE_AUTH", "0") == "1"
    return True  # every non-development environment is always fail-closed


async def auth_boundary(request: Request, call_next):
    """ASGI middleware: deny-by-default. Public allowlist passes through untouched. For every other path,
    resolve the principal ONCE and stash it on request.state.principal; reject when auth is required and no
    valid principal can be established. Dependencies downstream reuse request.state.principal."""
    path = request.url.path
    if is_public_path(path):
        return await call_next(request)

    try:
        token = _bearer(request)
        if token:
            request.state.principal = _principal_from_token(request, token)
        elif _boundary_auth_required():
            raise AuthError("authentication required")
        else:
            # dev optional-auth window, no token: the explicitly permitted legacy principal
            request.state.principal = Principal(
                story_user_id=LEGACY_PRINCIPAL, cognito_sub=None, is_legacy=True)
    except HTTPException as e:
        from fastapi.responses import JSONResponse
        return JSONResponse(status_code=e.status_code, content={"detail": e.detail})

    return await call_next(request)
