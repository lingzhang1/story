"""Asset Understanding INTELLIGENCE/TRANSPORT experiment (bounded, report-only).

Compares evidence representations × models for whole-Moment Story understanding:
  A. frame-timeline  — low-rate ORDERED timestamped frames (duration-scaled budget,
                       NOT C4's 4-frame cap), image-capable models.
  B. native-video    — whole clip to a video-capable model (Converse bytes for short,
                       Converse S3-source for medium/long; TwelveLabs Pegasus via
                       InvokeModel S3-source).
Experimental AU schema (NOT a canonical contract). No production code, no permanent
storage. Temp S3 bucket is private + 1-day lifecycle. Discovered facts recorded in the
result JSON for the report.

Usage: TMPDIR=/tmp .venv/bin/python evals/run_asset_understanding.py --run [--limit N]
"""
from __future__ import annotations
import argparse, base64, json, pathlib, subprocess, sys, time
from statistics import median

REPO = pathlib.Path(__file__).resolve().parents[1]
for rel in (".", "packages", "apps/api"):
    p = str((REPO / rel).resolve())
    if p not in sys.path: sys.path.insert(0, p)

MEDIA_MAP = json.loads((REPO / "evals/shot_validation/media-map.json").read_text())
MEDIA_ROOT = REPO / MEDIA_MAP["media_root"]
SUBSET = json.loads((REPO / "evals/asset_understanding/subset.json").read_text())["clips"]
FIXTURES = REPO / "evals/shot_validation/scenarios"
SAMPLER = pathlib.Path("/tmp/sample_frames")
FRAMES = REPO / "evals/assets/private_local/frames/au"
BUCKET = "story-assetunderstanding-exp-989088054552-us-east-1"
ACCT = "989088054552"

# Experimental AU output schema (NOT canonical). The model fills observed material;
# Story-contribution fields are judged against capture_context when present.
AU_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "summary": {"type": "string"},
        "subjects": {"type": "array", "items": {"type": "string"}},
        "environment": {"type": "string"},
        "events": {"type": "array", "items": {"type": "object", "additionalProperties": False,
            "properties": {"t_start_s": {"type": "number"}, "t_end_s": {"type": "number"},
                           "description": {"type": "string"}},
            "required": ["t_start_s", "description"]}},
        "temporal_order_note": {"type": "string"},
        "useful_segments": {"type": "array", "items": {"type": "object", "additionalProperties": False,
            "properties": {"t_start_s": {"type": "number"}, "t_end_s": {"type": "number"},
                           "why_useful": {"type": "string"}},
            "required": ["t_start_s", "t_end_s", "why_useful"]}},
        "dead_or_setup_segments": {"type": "array", "items": {"type": "object", "additionalProperties": False,
            "properties": {"t_start_s": {"type": "number"}, "t_end_s": {"type": "number"}, "note": {"type": "string"}},
            "required": ["t_start_s", "t_end_s"]}},
        "story_utility": {"type": "string", "enum": ["none", "useful_elsewhere", "strong_elsewhere"]},
        "requested_shot_contribution": {"type": "string"},
        "requested_beat_contribution": {"type": "string"}
    },
    "required": ["summary", "subjects", "environment", "events", "temporal_order_note",
                 "useful_segments", "story_utility"]
}

PROMPT = (
 "You are analyzing ONE captured video Moment for a personal Story app. Produce a STRUCTURED "
 "understanding of what useful Story material exists in this Moment — NOT a caption, and NOT "
 "final edit decisions. Observe the WHOLE clip over time. Fill the schema: a concise summary; "
 "subjects; environment; an ORDERED list of events with timestamps (seconds); a note on the "
 "temporal order (what happens first/then/last — note departures vs arrivals, reveal "
 "direction, progression, or any contradiction); meaningful useful_segments (start/end + why) "
 "that a later editor could actually use; dead_or_setup_segments (camera lowering, nothing "
 "happening); and story_utility. When a requested Shot/Beat context is given, also judge "
 "requested_shot_contribution and requested_beat_contribution HONESTLY — observed events stay "
 "grounded in the video regardless of the request. Keep timestamps within the clip duration."
)


def dur_of(path):
    r = subprocess.run([str(SAMPLER), str(path), "/tmp/_aud", "1"], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["duration_s"]


def frame_budget(dur):
    # duration-scaled ordered-frame policy (NOT C4's 4): ~1 frame / 2.5s, clamped 6..24.
    return max(6, min(24, round(dur / 2.5)))


def sample(path, n, out):
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(SAMPLER), str(path), str(out), str(n)], capture_output=True, text=True)
    return json.loads(next(l for l in r.stdout.splitlines() if l.strip().startswith("{")))["frames"]


def context_for(fx):
    fid = fx["fixture"]; sset = fid.split("__", 1)[0]
    reqp = FIXTURES / sset / fid / "request.json"
    if reqp.exists():
        req = json.loads(reqp.read_text())
        return {"shot": req.get("shot"), "beat": req.get("beat")}
    return None


def frame_timeline(model, path, dur, ctx):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    n = frame_budget(dur)
    frames = sample(path, n, FRAMES / f"{model.replace('/','_')}" / path.stem)
    content = []
    for f in frames:
        content.append({"image": {"format": "jpeg", "source": {"bytes": pathlib.Path(f["path"]).read_bytes()}}})
    stamps = ", ".join(f"frame{f['index']}@{f['t_ms']}ms" for f in frames)
    content.append({"text": PROMPT + f"\n\nOrdered frames: {stamps}\nclip_duration_s={dur:.1f}\n"
                    + (f"capture_context={json.dumps(ctx)}\n" if ctx else "")
                    + "Return ONLY JSON matching this schema:\n" + json.dumps(AU_SCHEMA)})
    t = time.time()
    r = br.converse(modelId=model, messages=[{"role": "user", "content": content}],
                    inferenceConfig={"maxTokens": 1500, "temperature": 0})
    dt = time.time() - t
    return _parse(r["output"]["message"]["content"][0]["text"]), dt, r.get("usage", {}), n


def native_nova(model, s3key, dur, ctx):
    import boto3
    br = boto3.client("bedrock-runtime", region_name="us-east-1")
    txt = (PROMPT + f"\nclip_duration_s={dur:.1f}\n" + (f"capture_context={json.dumps(ctx)}\n" if ctx else "")
           + "Return ONLY JSON matching this schema:\n" + json.dumps(AU_SCHEMA))
    msg = [{"role": "user", "content": [
        {"video": {"format": "mov", "source": {"s3Location": {"uri": f"s3://{BUCKET}/{s3key}", "bucketOwner": ACCT}}}},
        {"text": txt}]}]
    t = time.time()
    r = br.converse(modelId=model, messages=msg, inferenceConfig={"maxTokens": 1500, "temperature": 0})
    dt = time.time() - t
    return _parse(r["output"]["message"]["content"][0]["text"]), dt, r.get("usage", {}), None


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
    return _parse(out.get("message", "")), dt, {}, None


def _parse(text):
    s = text.find("{"); e = text.rfind("}")
    if s < 0 or e < 0: return {"_parse_error": text[:200]}
    try: return json.loads(text[s:e+1])
    except Exception as ex: return {"_parse_error": f"{ex}: {text[s:s+160]}"}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--limit", type=int, default=0)
    ap.add_argument("--arms", nargs="*",
                    default=["ft_nova_pro", "ft_sonnet", "nv_nova_pro", "nv_nova_lite", "nv_pegasus"])
    args = ap.parse_args()
    import boto3
    s3 = boto3.client("s3", region_name="us-east-1")
    clips = SUBSET[: args.limit] if args.limit else SUBSET
    FT = {"ft_nova_pro": "amazon.nova-pro-v1:0", "ft_sonnet": "us.anthropic.claude-sonnet-4-6"}
    NV = {"nv_nova_pro": "amazon.nova-pro-v1:0", "nv_nova_lite": "amazon.nova-lite-v1:0"}
    rows = []
    for c in clips:
        fid = c["fixture"]; rel = MEDIA_MAP["fixtures"][fid]; path = MEDIA_ROOT / rel
        dur = dur_of(path); ctx = context_for(c)
        s3key = None
        rec = {"fixture": fid, "band": c["band"], "tags": c["tags"], "dur_s": round(dur, 1),
               "frame_budget": frame_budget(dur), "arms": {}}
        print(f"\n== {fid[:46]} {c['band']} {dur:.1f}s fb={frame_budget(dur)} ==")
        if not args.run:
            rows.append(rec); continue
        # upload once for native arms
        need_native = any(a.startswith("nv_") for a in args.arms)
        if need_native:
            s3key = f"au/{fid}.mov"
            s3.upload_file(str(path), BUCKET, s3key)
        for a in args.arms:
            try:
                if a in FT:
                    data, dt, u, n = frame_timeline(FT[a], path, dur, ctx)
                elif a in NV:
                    data, dt, u, n = native_nova(NV[a], s3key, dur, ctx)
                elif a == "nv_pegasus":
                    data, dt, u, n = native_pegasus(s3key, dur, ctx)
                else: continue
                ok = "_parse_error" not in data
                rec["arms"][a] = {"ok": ok, "latency_s": round(dt, 1),
                                  "in_tok": u.get("inputTokens"), "out_tok": u.get("outputTokens"),
                                  "n_events": len(data.get("events", [])) if ok else None,
                                  "n_useful": len(data.get("useful_segments", [])) if ok else None,
                                  "story_utility": data.get("story_utility") if ok else None,
                                  "data": data}
                print(f"  {a:14s} {'OK ' if ok else 'ERR'} {dt:5.1f}s events={rec['arms'][a].get('n_events')} "
                      f"useful={rec['arms'][a].get('n_useful')} util={rec['arms'][a].get('story_utility')}")
            except Exception as e:
                rec["arms"][a] = {"ok": False, "error": f"{type(e).__name__}: {str(e)[:160]}"}
                print(f"  {a:14s} EXC {str(e)[:120]}")
        if s3key:
            try: s3.delete_object(Bucket=BUCKET, Key=s3key)   # shortest retention: delete now
            except Exception: pass
        rows.append(rec)
    out = REPO / "evals/results/asset_understanding_exp.json"
    out.write_text(json.dumps({"rows": rows}, indent=2))
    print("\nwrote", out)


if __name__ == "__main__":
    main()
