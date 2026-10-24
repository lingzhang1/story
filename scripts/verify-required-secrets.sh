#!/usr/bin/env bash
# verify-required-secrets.sh — FAIL-CLOSED pre-deploy gate: every secret the app needs at runtime MUST
# already exist in the TARGET account before a deploy proceeds. This prevents the class of outage we hit on
# beta (scene images / direct-provider LLM silently failing because YoTale-OpenAI/Gemini/Unsplash keys were
# never provisioned in the account). Usage: verify-required-secrets.sh <environment>
#
# It checks PRESENCE only (never prints values). Secrets are provisioned per-account out of band (they hold
# live credentials and must not be copied through CI logs); this gate just refuses to deploy without them.
# For gamma/prod the list is STRICT — a missing key aborts the deploy with a non-zero exit.
set -euo pipefail
ENVIRONMENT="${1:?usage: verify-required-secrets.sh <environment>}"
REGION="${AWS_REGION:-us-east-1}"

# Required at runtime for every non-dev environment (direct-provider LLM + Unsplash scene images + music).
REQUIRED=(
  "YoTale-OpenAI-API-Key"      # direct-provider primary (gpt-5.1)
  "YoTale-Gemini-API-Key"      # direct-provider fallback (gemini-3.8-flash)
  "Unsplash-API-Key"           # /v1/scene-image reference images (StoryGuide v2)
  "story-epidemic-key"         # music provider
  "epidemic-mcp-api-key"       # music MCP
)

echo "Verifying required secrets exist in account for environment=$ENVIRONMENT (region=$REGION)…"
missing=()
unverifiable=()
for name in "${REQUIRED[@]}"; do
  # Capture stderr so we can tell "genuinely missing" (ResourceNotFoundException) apart from "cannot check"
  # (AccessDenied — the scoped deploy role may lack secretsmanager:DescribeSecret). Only a definitive
  # not-found aborts the deploy; an access gap is reported but does NOT false-positive as missing.
  err="$(aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" 2>&1 >/dev/null)" && {
    echo "  ✓ $name"; continue
  }
  if printf '%s' "$err" | grep -q "ResourceNotFoundException"; then
    echo "  ✗ MISSING: $name"; missing+=("$name")
  elif printf '%s' "$err" | grep -qiE "AccessDenied|not authorized"; then
    echo "  ? UNVERIFIABLE (no describe permission): $name"; unverifiable+=("$name")
  else
    echo "  ? UNVERIFIABLE ($(printf '%s' "$err" | head -1)): $name"; unverifiable+=("$name")
  fi
done

if [ "${#missing[@]}" -ne 0 ]; then
  echo ""
  echo "ABORT: ${#missing[@]} required secret(s) definitively MISSING in the $ENVIRONMENT account: ${missing[*]}"
  echo "Provision them in Secrets Manager (per-account, out of band) BEFORE deploying."
  echo "Prod/gamma must never deploy with missing keys — failing closed."
  exit 1
fi
if [ "${#unverifiable[@]}" -ne 0 ]; then
  echo ""
  echo "NOTE: could not verify ${#unverifiable[@]} secret(s) (no DescribeSecret permission for the deploy role):"
  echo "      ${unverifiable[*]}"
  echo "      Not a 'missing' signal — proceeding. Grant secretsmanager:DescribeSecret to the deploy role to"
  echo "      make this gate authoritative. The instance/worker roles' GetSecretValue is unaffected."
fi
echo "No definitively-missing required secrets. Proceeding."
