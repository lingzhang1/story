#!/usr/bin/env bash
# release-manifest.sh — emit the immutable release manifest for a dev deployment (Gate 2 req 4).
#
# Captures EXACTLY what was deployed so a running service can be verified against it and a rollback can
# target a known-good artifact set:
#   - git_sha            the commit being released
#   - api_image_digest   the IMMUTABLE ECR image digest (sha256:...), NOT a mutable :latest tag
#   - worker_sha256      sha256 of the reproducible Lambda worker zip
#   - worker_artifact    retained S3 location of the worker zip
#   - cdk_revision       cdk CLI version + synth hash
#   - prompt_versions    the prompt/model config dirs shipped (edit_plan/*, etc.)
#   - environment        target env (development only in Gate 2)
#
# Usage: release-manifest.sh <environment> <api_image_digest> <worker_zip_path> [worker_s3_uri]
# Writes JSON to stdout AND to release-manifests/<git_sha>.json. No AWS calls here (digests are passed in
# by the deploy workflow, which obtains them from the build/push steps).
set -euo pipefail

ENVIRONMENT="${1:?environment required}"
API_IMAGE_DIGEST="${2:?api image digest required (sha256:...)}"
WORKER_ZIP="${3:?worker zip path required}"
WORKER_S3_URI="${4:-}"

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO"

GIT_SHA="$(git rev-parse HEAD)"
GIT_SHA_SHORT="$(git rev-parse --short HEAD)"
WORKER_SHA256="$(shasum -a 256 "$WORKER_ZIP" | awk '{print $1}')"
CDK_VERSION="$(cd infrastructure/cdk && npx cdk --version 2>/dev/null || echo unknown)"
# Prompt/model config shipped: list the versioned prompt dirs + the active edit-plan default.
PROMPT_DIRS="$(ls -1 prompts/edit_plan 2>/dev/null | paste -sd, - || echo none)"
EDIT_PLAN_DEFAULT="${STORY_EDIT_PLAN_VERSION:-unset}"
BUILT_AT="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

mkdir -p release-manifests
OUT="release-manifests/${GIT_SHA_SHORT}.json"

cat > "$OUT" <<JSON
{
  "git_sha": "${GIT_SHA}",
  "git_sha_short": "${GIT_SHA_SHORT}",
  "environment": "${ENVIRONMENT}",
  "api_image_digest": "${API_IMAGE_DIGEST}",
  "worker_sha256": "${WORKER_SHA256}",
  "worker_artifact": "${WORKER_S3_URI}",
  "cdk_revision": "${CDK_VERSION}",
  "prompt_dirs": "${PROMPT_DIRS}",
  "edit_plan_default": "${EDIT_PLAN_DEFAULT}",
  "built_at": "${BUILT_AT}"
}
JSON

cat "$OUT"
echo "wrote $OUT" >&2
