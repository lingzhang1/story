"""AU FINALIST ground-truth evaluation (controlled, report-only).

FOUR finalists on the owner-approved 18-clip ground truth:
  A ft_nova_pro   amazon.nova-pro-v1:0            — 24 fixed frames
  B ft_sonnet     us.anthropic.claude-sonnet-4-6  — EXACT SAME 24 frames
  C ft_opus       us.anthropic.claude-opus-4-6-v1 — EXACT SAME 24 frames (strongest INVOCABLE opus;
                                                     opus-5-5 is listed but AccessDenied)
  D nv_pegasus    us.twelvelabs.pegasus-1-2-v1:0  — native whole video (S3 source)

Controlled: A/B/C get IDENTICAL frames/timestamps/resolution/compression/prompt/schema — a pure
MODEL comparison. No density sweep. Pegasus answers the native-video question separately.
Persists every raw output + exact usage/latency keyed to fixture+arm for ground-truth scoring and
cost accounting. Temp S3 is private; each native upload is deleted immediately (shortest retention)
with a 1-day lifecycle backstop. NOT a canonical contract; no production code; no infra built.

Usage: TMPDIR=/tmp .venv/bin/python evals/run_au_finalists.py --run [--arms ...] [--limit N]
"""
from __future__ import annotations
import argparse, json, pathlib, subprocess, sys, time

REPO = pathlib.Path(__file__).resolve().parents[1]
MEDIA_MAP = json.loads((REPO / "evals/shot_validation/media-map.json").read_text())
MEDIA_ROOT = REPO / MEDIA_MAP["media_root"]
GT = json.loads((REPO / "evals/asset_understanding/ground_truth.json").read_text())
FIXTURES = REPO / "evals/shot_validation/scenarios"
SAMPLER = pathlib.Path("/tmp/sample_frames")
FRAMES = REPO / "evals/assets/private_local/frames/au_finalists"
BUCKET = "story-assetunderstanding-exp-989088054552-us-east-1"
ACCT = "989088054552"
FIXED_FRAMES = 24   # §4: fixed 24 frames for ALL frame-timeline finalists (NO density sweep)

# Reuse the EXACT experimental AU schema + prompt from run_asset_understanding.py (import to stay identical)
sys.path.insert(0, str((REPO / "evals").resolve()))
from run_asset_understanding import AU_SCHEMA, PROMPT, _parse, dur_of, context_for  # noqa: E402

MODELS = {
    "ft_nova_pro": "amazon.nova-pro-v1:0",
    "ft_sonnet":   "us.anthropic.claude-sonnet-4-6",
    "ft_opus":     "us.anthropic.claude-opus-4-6-v1",
}


def sample24(path, out):
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(SAMPLER), str(path), str(out), str(FIXED_FRAMES)], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["frames"]


def frame_timeline(model, frames, dur, ctx):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    content = [{"image": {"format": "jpeg", "source": {"bytes": pathlib.Path(f["path"]).read_bytes()}}} for f in frames]
    stamps = ", ".join(f"frame{f['index']}@{f['t_ms']}ms" for f in frames)
    content.append({"text": PROMPT + f"\n\nOrdered frames: {stamps}\nclip_duration_s={dur:.1f}\n"
                    + (f"capture_context={json.dumps(ctx)}\n" if ctx else "")
                    + "Return ONLY JSON matching this schema:\n" + json.dumps(AU_SCHEMA)})
    t = time.time()
    r = br.converse(modelId=model, messages=[{"role": "user", "content": content}],
                    inferenceConfig={"maxTokens": 1800, "temperature": 0})
    dt = time.time() - t
    return _parse(r["output"]["message"]["content"][0]["text"]), dt, r.get("usage", {})


def native_pegasus(s3key, dur, ctx):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    prompt = (PROMPT + f"\nclip_duration_s={dur:.1f}\n" + (f"capture_context={json.dumps(ctx)}\n" if ctx else "")
              + "Return ONLY JSON matching this schema:\n" + json.dumps(AU_SCHEMA))
    body = {"inputPrompt": prompt, "mediaSource": {"s3Location": {"uri": f"s3://{BUCKET}/{s3key}", "bucketOwner": ACCT}}}
    t = time.time()
    r = br.invoke_model(modelId="us.twelvelabs.pegasus-1-2-v1:0", body=json.dumps(body))
    dt = time.time() - t
    out = json.loads(r["body"].read())
    return _parse(out.get("message", "")), dt, {"pegasus_raw_keys": list(out.keys())}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--arms", nargs="*", default=["ft_nova_pro", "ft_sonnet", "ft_opus", "nv_pegasus"])
    args = ap.parse_args()
    import boto3
    s3 = boto3.client("s3", region_name="us-east-1")
    clips = GT["clips"][: args.limit] if args.limit else GT["clips"]
    rows = []
    for c in clips:
        fid = c["fixture"]; rel = MEDIA_MAP["fixtures"][fid]; path = MEDIA_ROOT / rel
        dur = dur_of(path); ctx = context_for(c)
        rec = {"fixture": fid, "band": c["band"], "dur_s": round(dur, 1), "arms": {}}
        print(f"\n== {fid[:46]} {c['band']} {dur:.1f}s ==")
        if not args.run:
            rows.append(rec); continue
        frames = sample24(path, FRAMES / path.stem) if any(a in MODELS for a in args.arms) else []
        s3key = None
        if any(a == "nv_pegasus" for a in args.arms):
            s3key = f"au_fin/{fid}.mov"; s3.upload_file(str(path), BUCKET, s3key)
        for a in args.arms:
            try:
                if a in MODELS:
                    data, dt, u = frame_timeline(MODELS[a], frames, dur, ctx)
                elif a == "nv_pegasus":
                    data, dt, u = native_pegasus(s3key, dur, ctx)
                else:
                    continue
                ok = "_parse_error" not in data
                rec["arms"][a] = {"ok": ok, "latency_s": round(dt, 1),
                                  "in_tok": u.get("inputTokens"), "out_tok": u.get("outputTokens"),
                                  "n_frames": FIXED_FRAMES if a in MODELS else None,
                                  "data": data}
                print(f"  {a:12s} {'OK ' if ok else 'ERR'} {dt:5.1f}s "
                      f"in={u.get('inputTokens')} out={u.get('outputTokens')} "
                      f"events={len(data.get('events', [])) if ok else '-'}")
            except Exception as e:
                rec["arms"][a] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:160]}"}
                print(f"  {a:12s} EXC {str(e)[:120]}")
        if s3key:
            try: s3.delete_object(Bucket=BUCKET, Key=s3key)
            except Exception: pass
        rows.append(rec)
    out = REPO / "evals/results/au_finalists.json"
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(json.dumps({"fixed_frames": FIXED_FRAMES, "models": MODELS, "rows": rows}, indent=2))
    print("\nwrote", out)


if __name__ == "__main__":
    main()
