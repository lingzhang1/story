#!/usr/bin/env bash
# Build the Docker-FREE Lambda worker asset for CDK (sandbox cannot run Docker).
# Assembles: worker code (app/) + engine packages + contracts + prompts + the Linux cp312 pydantic wheels
# (boto3 is preinstalled in the Lambda runtime, so it is NOT bundled). Output: infrastructure/cdk/.worker-asset/
set -euo pipefail
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="$REPO/infrastructure/cdk/.worker-asset"
rm -rf "$OUT"; mkdir -p "$OUT"

# 1. source: the worker + engine packages + contracts + prompts (same layout the planner's prompt resolver needs)
mkdir -p "$OUT/app" "$OUT/packages" "$OUT/contracts"
cp -R "$REPO/apps/api/app/." "$OUT/app/"
cp -R "$REPO/packages/." "$OUT/packages/"
cp -R "$REPO/contracts/." "$OUT/contracts/"
cp -R "$REPO/prompts" "$OUT/prompts"

# 2. deps: Linux cp312 manylinux wheels for pydantic (compiled pydantic-core) — boto3 is in the runtime.
WHEELS="$(mktemp -d /tmp/lw.XXXXXX)"
python3 -m pip download --only-binary=:all: \
  --platform manylinux2014_x86_64 --python-version 3.12 --implementation cp --abi cp312 \
  --dest "$WHEELS" "pydantic>=2" >/dev/null
for whl in "$WHEELS"/*.whl; do
  python3 -m zipfile -e "$whl" "$OUT/"   # extract wheel contents into the asset root (site-packages style)
done
rm -rf "$WHEELS"

# 3. strip caches to keep the zip lean
find "$OUT" -name '__pycache__' -type d -prune -exec rm -rf {} + 2>/dev/null || true
find "$OUT" -name '*.pyc' -delete 2>/dev/null || true

echo "worker asset built at $OUT"
du -sh "$OUT" 2>/dev/null | awk '{print "size:", $1}'
