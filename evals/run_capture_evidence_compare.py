"""C4A.2 — Capture Evidence transport experiment runner.

Compares THREE temporal-evidence transports feeding the SAME Sonnet 4.6 model,
SAME shot-validation prompt, SAME fixtures, SAME expected labels:

  A. uniform-4   — 4 evenly-spaced ordered frames (current C4A frontier)
  B. uniform-6   — 6 evenly-spaced ordered frames
  C. capevidence — forward-only CaptureEvidenceV1 selector (~4-6 ordered points)

The ONLY thing that varies between arms is which frames reach the validator; the
model, prompt, schema, derivation and scoring are identical and come from the
C4A runner (imported, not reimplemented). Results are banded by clip duration:
  <=10s (DIRECT-like, PRIMARY) / 10-30s / >30s (robustness).

Intent-independence check: for shared-source fixtures (A05<->S02_G, A01<->A06)
CaptureEvidence must be identical for the same physical file regardless of the
requested Shot/Beat context (only the downstream judgment may differ).

LIVE Bedrock only with --run (bills). Default dry = selector + wiring only.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import time
from typing import Any

import run_shot_validation as R
from shot_validation import ShotValidationJudgment, derive

REPO = R.REPO
EV_SRC = REPO / "evals/shot_validation/tools/capture_evidence.swift"
EV_BIN = pathlib.Path("/tmp/capture_evidence")
MODEL = "us.anthropic.claude-sonnet-4-6"


def ensure_ev() -> None:
    if EV_BIN.exists():
        return
    subprocess.run(["swiftc", "-O", str(EV_SRC), "-o", str(EV_BIN)],
                   capture_output=True, text=True)
    if not EV_BIN.exists():
        raise RuntimeError("failed to build capture_evidence selector")


def band_of(duration_s: float) -> str:
    return "le10s" if duration_s <= 10 else "10to30s" if duration_s <= 30 else "gt30s"


def capture_evidence(video: pathlib.Path, out_dir: pathlib.Path,
                     obs_fps: float = 3.0) -> dict:
    ensure_ev()
    out_dir.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(EV_BIN), str(video), str(out_dir), str(obs_fps), "4", "6"],
                       capture_output=True, text=True)
    line = next((ln for ln in r.stdout.splitlines() if ln.strip().startswith("{")), None)
    if not line:
        raise RuntimeError(f"capture_evidence no manifest for {video.name}: {r.stderr[:300]}")
    return json.loads(line)


def ev_to_frames(man: dict) -> list[dict]:
    """Adapt CaptureEvidenceV1 evidence_points to the runner's frame list shape
    ({index, t_ms, path}), preserving temporal order."""
    pts = sorted(man["evidence_points"], key=lambda p: p["timestamp_ms"])
    return [{"index": i, "t_ms": p["timestamp_ms"], "path": p["frame_ref"], "role": p["role"]}
            for i, p in enumerate(pts) if p.get("frame_ref")]


def build_user_content(c: R.FixtureCase, frames: list[dict]) -> str:
    # Same content shape as the base runner; include roles when present so the
    # model knows these are ordered temporal anchors (still intent-independent).
    def label(f):
        role = f.get("role")
        return f"frame {f['index']}@{f['t_ms']}ms" + (f"[{role}]" if role else "")
    stamps = ", ".join(label(f) for f in frames)
    return json.dumps({
        "ordered_frames": stamps,
        "shot": c.shot, "beat": c.beat, "concept_summary": c.concept_summary,
        "instructions": "Judge against the shot PURPOSE using the ordered frames. "
                        "Return only the four axes.",
    }, ensure_ascii=False)


def one_call(gw, system, schema, c: R.FixtureCase, frames: list[dict]) -> dict:
    from model_gateway import ImageInput, StructuredRequest
    imgs = [ImageInput(data=pathlib.Path(f["path"]).read_bytes(), media_type="image/jpeg")
            for f in frames]
    req = StructuredRequest(
        task="shot_validation.judge", schema=schema, prompt_version="shot_validation/v1",
        system=system, user_content=build_user_content(c, frames), images=imgs,
        max_tokens=600, temperature=0.0, max_repair_attempts=1,
    )
    t0 = time.monotonic()
    res = gw.generate_structured(req)
    dt = time.monotonic() - t0
    payload = res.data
    if isinstance(payload, dict) and set(payload) == {"judgment"} and isinstance(payload["judgment"], dict):
        payload = payload["judgment"]
    allowed = set(ShotValidationJudgment.model_fields)
    payload = {k: v for k, v in payload.items() if k in allowed}
    row: dict[str, Any] = {"fixture_id": c.fixture_id, "latency_s": round(dt, 3)}
    if res.usage:
        row["in_tok"] = res.usage.input_tokens or 0
        row["out_tok"] = res.usage.output_tokens or 0
    try:
        j = ShotValidationJudgment.model_validate(payload)
    except Exception as e:
        row["parse_error"] = str(e)[:200]
        return row
    d = derive(j)
    row["pred"] = {**j.model_dump(mode="json"),
                   "clip_disposition": d.clip_disposition.value,
                   "requested_shot_status": d.requested_shot_status.value,
                   "user_state": d.user_state.value}
    row["exp"] = c.expectations
    row["tags"] = c.tags
    return row


def run_arm(arm: str, cases: list[R.FixtureCase], meta: dict, live: bool) -> dict:
    """arm in {uniform4, uniform6, capevidence}."""
    from model_gateway import BedrockModelGateway
    mm = json.loads(R.MEDIA_MAP.read_text())
    media_root = REPO / mm["media_root"]
    schema = R._judgment_schema()
    system = R.PROMPT.read_text()
    gw = BedrockModelGateway(model_id=MODEL) if live else None

    rows, lat, ev_counts, cpu_ms = [], [], [], []
    for c in cases:
        video = media_root / c.media_rel
        out_dir = R.FRAMES_ROOT / f"c4a2_{arm}" / c.fixture_id
        if arm == "capevidence":
            man = capture_evidence(video, out_dir)
            frames = ev_to_frames(man)
            ev_counts.append(man["evidence_count"])
            cpu_ms.append(man["selector_cpu_ms_total"])
            meta.setdefault("evidence", {})[c.fixture_id] = {
                "count": man["evidence_count"],
                "points": [{"t": p["timestamp_ms"], "role": p["role"],
                            "chg": p["change_score"], "sharp": p["sharpness_score"]}
                           for p in sorted(man["evidence_points"], key=lambda x: x["timestamp_ms"])],
                "duration_ms": man["duration_ms"],
            }
        else:
            n = 4 if arm == "uniform4" else 6
            frames = R.sample_frames(video, out_dir, n)
            ev_counts.append(len(frames))
        if not live:
            rows.append({"fixture_id": c.fixture_id, "band": meta["band"][c.fixture_id],
                         "frames": len(frames)})
            continue
        row = one_call(gw, system, schema, c, frames)
        row["band"] = meta["band"][c.fixture_id]
        lat.append(row["latency_s"])
        rows.append(row)

    return {
        "arm": arm, "model": MODEL, "live": live, "rows": rows,
        "latency": R._latency_stats(lat),
        "evidence_count": {"n": len(ev_counts),
                           "mean": round(statistics.mean(ev_counts), 2) if ev_counts else None,
                           "min": min(ev_counts) if ev_counts else None,
                           "max": max(ev_counts) if ev_counts else None},
        "selector_cpu_ms": ({"mean": round(statistics.mean(cpu_ms), 1),
                             "p50": round(statistics.median(cpu_ms), 1),
                             "max": round(max(cpu_ms), 1)} if cpu_ms else None),
    }


def score_banded(rows: list[dict]) -> dict:
    """Score the required metrics overall AND per duration band."""
    out = {"overall": R.score_rows(rows)}
    for b in ("le10s", "10to30s", "gt30s"):
        sub = [r for r in rows if r.get("band") == b]
        out[b] = R.score_rows(sub) if sub else None
    return out


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true", help="LIVE Bedrock (bills). Default dry.")
    ap.add_argument("--arms", nargs="*", default=["uniform4", "uniform6", "capevidence"])
    ap.add_argument("--only", nargs="*", default=[])
    ap.add_argument("--out", default=str(REPO / "evals/results"))
    args = ap.parse_args()

    cases = R.load_cases()
    if args.only:
        cases = [c for c in cases if c.fixture_id in set(args.only)]

    # Band every fixture by its real duration (one sampler manifest read).
    R.ensure_sampler()
    band = {}
    for c in cases:
        video = (REPO / json.loads(R.MEDIA_MAP.read_text())["media_root"]) / c.media_rel
        # cheap duration probe: sample 1 frame, read manifest duration
        man = subprocess.run([str(R.SAMPLER_BIN), str(video), "/tmp/_band", "1"],
                             capture_output=True, text=True)
        dur = json.loads(next(ln for ln in man.stdout.splitlines()
                              if ln.strip().startswith("{")))["duration_s"]
        band[c.fixture_id] = band_of(dur)
    meta = {"band": band}
    print(f"{len(cases)} fixtures | bands:",
          {b: sum(1 for v in band.values() if v == b) for b in ("le10s", "10to30s", "gt30s")})

    arms = []
    for a in args.arms:
        print(f"=== arm {a} (live={args.run}) ===")
        res = run_arm(a, cases, meta, live=args.run)
        if args.run:
            res["scores"] = score_banded(res["rows"])
        arms.append(res)

    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = pathlib.Path(args.out) / f"c4a2_capture_evidence_{stamp}.json"
    out.write_text(json.dumps({"arms": arms, "meta_evidence": meta.get("evidence", {}),
                               "bands": band}, indent=2))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
