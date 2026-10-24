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
for name in "${REQUIRED[@]}"; do
  if aws secretsmanager describe-secret --region "$REGION" --secret-id "$name" >/dev/null 2>&1; then
    echo "  ✓ $name"
  else
    echo "  ✗ MISSING: $name"
    missing+=("$name")
  fi
done

if [ "${#missing[@]}" -ne 0 ]; then
  echo ""
  echo "ABORT: ${#missing[@]} required secret(s) missing in the $ENVIRONMENT account: ${missing[*]}"
  echo "Provision them in Secrets Manager (per-account, out of band) BEFORE deploying."
  echo "Prod/gamma must never deploy with missing keys — failing closed."
  exit 1
fi
echo "All required secrets present. Proceeding."
