#!/usr/bin/env bash
# verify_beta_archive.sh — TestFlight Option A pre-archive safety gate.
#
# Inspects a BUILT app's embedded Info.plist and FAILS CLOSED unless it carries a fully-consistent BETA
# environment. This verifies the ARCHIVE ITSELF (baked metadata), not just source — the thing that actually
# ships. Run it against a Beta-configured build product (an .app or Info.plist), e.g. as a post-archive /
# pre-upload check:
#
#   scripts/verify_beta_archive.sh /path/to/Story.app
#   scripts/verify_beta_archive.sh /path/to/Info.plist
#
# Exit 0 = the archive's baked environment is beta and internally consistent (safe to upload).
# Exit non-zero = labelled beta but resolves to dev / missing values / mixed env (DO NOT upload).
#
# Expected beta identifiers (VERIFIED LIVE 2026-10-27, beta account 224033508028):
set -euo pipefail

EXPECT_ENV="beta"
EXPECT_API="https://asxtxgjiis.us-east-1.awsapprunner.com"
EXPECT_POOL="us-east-1_3cPNfbrUl"
EXPECT_CLIENT="4f3dtn9d0nk5uq1hcvbdc7m73c"
EXPECT_DOMAIN="story-beta-auth"
# Dev tripwires that must NEVER appear in a beta archive:
DEV_API="https://ydmju5wdps.us-east-1.awsapprunner.com"
DEV_POOL="us-east-1_AzfHOEdA5"
DEV_CLIENT="5rnvp7oq6d7crbt01ldpe89tkh"

target="${1:-}"
[ -n "$target" ] || { echo "usage: $0 <Story.app | Info.plist>" >&2; exit 2; }

if [ -d "$target" ]; then
  PLIST="$target/Info.plist"
elif [ -f "$target" ]; then
  PLIST="$target"
else
  echo "FAIL: not found: $target" >&2; exit 2
fi
[ -f "$PLIST" ] || { echo "FAIL: no Info.plist at $PLIST" >&2; exit 2; }

read_key() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$PLIST" 2>/dev/null || echo ""
}

ENV_VAL="$(read_key StoryBuildEnv)"
API="$(read_key StoryEnvApiBaseURL)"
REGION="$(read_key StoryEnvCognitoRegion)"
POOL="$(read_key StoryEnvUserPoolId)"
CLIENT="$(read_key StoryEnvAppClientId)"
DOMAIN="$(read_key StoryEnvDomainPrefix)"
REDIRECT="$(read_key StoryEnvRedirectURI)"

fail() { echo "FAIL: $1" >&2; exit 1; }

# 1) Must be LABELLED beta.
[ "$ENV_VAL" = "$EXPECT_ENV" ] || fail "StoryBuildEnv='$ENV_VAL' (expected '$EXPECT_ENV'). A beta archive must be labelled beta."

# 2) No unresolved build tokens / empties.
for kv in "StoryEnvApiBaseURL=$API" "StoryEnvCognitoRegion=$REGION" "StoryEnvUserPoolId=$POOL" \
          "StoryEnvAppClientId=$CLIENT" "StoryEnvDomainPrefix=$DOMAIN" "StoryEnvRedirectURI=$REDIRECT"; do
  v="${kv#*=}"
  [ -n "$v" ] || fail "missing baked value: ${kv%%=*}"
  case "$v" in '$('*) fail "unresolved build token in ${kv%%=*}: $v";; esac
done

# 3) Must MATCH the expected beta identifiers.
[ "$API" = "$EXPECT_API" ]       || fail "StoryEnvApiBaseURL='$API' != beta '$EXPECT_API'"
[ "$POOL" = "$EXPECT_POOL" ]     || fail "StoryEnvUserPoolId='$POOL' != beta '$EXPECT_POOL'"
[ "$CLIENT" = "$EXPECT_CLIENT" ] || fail "StoryEnvAppClientId='$CLIENT' != beta '$EXPECT_CLIENT'"
[ "$DOMAIN" = "$EXPECT_DOMAIN" ] || fail "StoryEnvDomainPrefix='$DOMAIN' != beta '$EXPECT_DOMAIN'"

# 4) Dev tripwires must be ABSENT (catches a half-dev/half-beta mix).
for devv in "$DEV_API" "$DEV_POOL" "$DEV_CLIENT"; do
  for got in "$API" "$POOL" "$CLIENT"; do
    [ "$got" = "$devv" ] && fail "development identifier leaked into beta archive: $devv"
  done
done

echo "OK: beta archive verified — env=$ENV_VAL api=$API pool=$POOL client=$CLIENT domain=$DOMAIN redirect=$REDIRECT"
echo "    (no development identifiers present; no unresolved tokens)"
