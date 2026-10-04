"""Shot Validation offline eval runner (C4A).

Loads the media-map + fixtures, samples N ordered timestamped frames per clip
(via the Swift sample_frames tool — ffmpeg/pyav unavailable in sandbox), builds a
purpose-conditioned ShotValidationJudgment request, invokes a candidate model
through the GENERIC ModelGateway (no provider coupling here), applies the
deterministic derivation, and scores against the fixture expectations on every
C4A metric:

  four-axis accuracy, shot-purpose accuracy, false-TRY-AGAIN, FALSE-FULFILLMENT,
  alternative-success recognition, contradiction detection, adversarial catch-rate,
  temporal accuracy, technical-failure accuracy, p50/p95 latency, token/image
  usage, approximate cost.

Model adapters are JUST `BedrockModelGateway(model_id=...)` — one generic surface,
three candidate ids. Native-video is a separate optional experiment (not built
unless a candidate shows a material advantage; §7-B).

This runner performs LIVE Bedrock calls when --run is passed; by default (--dry)
it only samples frames and validates wiring so nothing is billed accidentally.
Frames are written under the gitignored private_local/frames/ tree.
"""

from __future__ import annotations

import argparse
import json
import pathlib
import statistics
import subprocess
import time
from dataclasses import dataclass, field
from typing import Any

from shot_validation import ShotValidationJudgment, derive

REPO = pathlib.Path(__file__).resolve().parents[2]
MEDIA_MAP = REPO / "evals/shot_validation/media-map.json"
FIXTURES_DIR = REPO / "evals/shot_validation/scenarios"
FRAMES_ROOT = REPO / "evals/assets/private_local/frames"
SAMPLER_SRC = REPO / "evals/shot_validation/tools/sample_frames.swift"
SAMPLER_BIN = pathlib.Path("/tmp/sample_frames")
PROMPT = REPO / "prompts/shot_validation/v1/system.md"

# Approximate per-1k-token prices (USD) for cost estimation ONLY. Overridable;
# these are illustrative and must be reconciled with the account's actual pricing
# in the C4A report, not treated as authoritative.
_PRICE_PER_1K = {
    "amazon.nova-2-lite-v1:0": (0.00006, 0.00024),
    "amazon.nova-lite-v1:0": (0.00006, 0.00024),
    "amazon.nova-pro-v1:0": (0.0008, 0.0032),
    "anthropic.claude-haiku-4-5-20251001-v1:0": (0.001, 0.005),
    "anthropic.claude-sonnet-4-6": (0.003, 0.015),
}


def _judgment_schema() -> dict:
    """JSON Schema the model MUST satisfy = the 4 axes (+ optional diagnostics).
    Derived fields are NOT in the schema — the model never emits them."""
    s = ShotValidationJudgment.model_json_schema()
    return s


def ensure_sampler() -> None:
    if SAMPLER_BIN.exists():
        return
    r = subprocess.run(["swiftc", "-O", str(SAMPLER_SRC), "-o", str(SAMPLER_BIN)],
                       capture_output=True, text=True)
    if not SAMPLER_BIN.exists():
        raise RuntimeError(f"failed to build sampler: {r.stderr[:400]}")


def sample_frames(video: pathlib.Path, out_dir: pathlib.Path, n: int,
                  window: tuple[float, float] | None = None) -> list[dict]:
    ensure_sampler()
    out_dir.mkdir(parents=True, exist_ok=True)
    cmd = [str(SAMPLER_BIN), str(video), str(out_dir), str(n)]
    if window:
        cmd += [str(window[0]), str(window[1])]
    r = subprocess.run(cmd, capture_output=True, text=True)
    line = next((ln for ln in r.stdout.splitlines() if ln.strip().startswith("{")), None)
    if not line:
        raise RuntimeError(f"sampler produced no manifest for {video.name}: {r.stderr[:300]}")
    return json.loads(line)["frames"]


def long_clip_window(duration_s: float, cap: float = 20.0) -> tuple[float, float] | None:
    """Long clips (S07_A 95s, S08_D 154s) sample a centered window, not the whole
    file (design §7). Returns None for short clips (use full span)."""
    if duration_s <= cap:
        return None
    mid = duration_s / 2
    return (max(0.0, mid - cap / 2), min(duration_s, mid + cap / 2))


@dataclass
class FixtureCase:
    fixture_id: str
    media_rel: str
    shot: dict
    beat: dict
    concept_summary: str | None
    expectations: dict
    tags: list[str] = field(default_factory=list)


def load_cases() -> list[FixtureCase]:
    mm = json.loads(MEDIA_MAP.read_text())
    media_root = REPO / mm["media_root"]
    cases: list[FixtureCase] = []
    for fid, rel in mm["fixtures"].items():
        fdir = FIXTURES_DIR / _set_of(fid) / fid
        req_p, exp_p = fdir / "request.json", fdir / "expectations.json"
        if not req_p.exists() or not exp_p.exists():
            continue  # not yet authored
        req = json.loads(req_p.read_text())
        exp = json.loads(exp_p.read_text())
        cases.append(FixtureCase(
            fixture_id=fid, media_rel=rel, shot=req["shot"], beat=req.get("beat", {}),
            concept_summary=req.get("concept_summary"), expectations=exp,
            tags=exp.get("tags", []),
        ))
    return cases


def _set_of(fid: str) -> str:
    return fid.split("__", 1)[0]


def build_user_content(c: FixtureCase, frames: list[dict]) -> str:
    stamps = ", ".join(f"frame {f['index']}@{f['t_ms']}ms" for f in frames)
    return json.dumps({
        "ordered_frames": stamps,
        "shot": c.shot,
        "beat": c.beat,
        "concept_summary": c.concept_summary,
        "instructions": "Judge against the shot PURPOSE using the ordered frames. "
                        "Return only the four axes.",
    }, ensure_ascii=False)


def run_candidate(model_id: str, n_frames: int, cases: list[FixtureCase],
                  live: bool) -> dict[str, Any]:
    from model_gateway import BedrockModelGateway, ImageInput, StructuredRequest
    mm = json.loads(MEDIA_MAP.read_text())
    media_root = REPO / mm["media_root"]
    schema = _judgment_schema()
    system = PROMPT.read_text()
    gw = BedrockModelGateway(model_id=model_id)

    rows, latencies = [], []
    in_tok = out_tok = 0
    for c in cases:
        video = media_root / c.media_rel
        # duration via sampler manifest (also gives frames)
        out_dir = FRAMES_ROOT / f"{model_id.replace('/', '_')}_{n_frames}" / c.fixture_id
        frames = sample_frames(video, out_dir, n_frames)
        if not live:
            rows.append({"fixture_id": c.fixture_id, "sampled": len(frames)})
            continue
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
        latencies.append(dt)
        if res.usage:
            in_tok += res.usage.input_tokens or 0
            out_tok += res.usage.output_tokens or 0
        judgment = ShotValidationJudgment.model_validate(res.data)
        d = derive(judgment)
        rows.append({
            "fixture_id": c.fixture_id,
            "pred": {**judgment.model_dump(mode="json"),
                     "clip_disposition": d.clip_disposition.value,
                     "requested_shot_status": d.requested_shot_status.value,
                     "user_state": d.user_state.value},
            "exp": c.expectations, "tags": c.tags, "latency_s": round(dt, 3),
        })
    return {
        "model_id": model_id, "n_frames": n_frames, "live": live,
        "rows": rows, "latency": _latency_stats(latencies),
        "tokens": {"input": in_tok, "output": out_tok},
        "approx_cost_usd": _cost(model_id, in_tok, out_tok),
        "scores": score_rows(rows) if live else None,
    }


def _latency_stats(xs: list[float]) -> dict:
    if not xs:
        return {}
    xs = sorted(xs)
    return {"n": len(xs), "p50": round(statistics.median(xs), 3),
            "p95": round(xs[min(len(xs) - 1, int(0.95 * len(xs)))], 3),
            "max": round(xs[-1], 3)}


def _cost(model_id: str, in_tok: int, out_tok: int) -> float | None:
    p = _PRICE_PER_1K.get(model_id)
    if not p:
        return None
    return round(in_tok / 1000 * p[0] + out_tok / 1000 * p[1], 4)


def score_rows(rows: list[dict]) -> dict:
    """Compute every C4A metric from predicted-vs-expected rows."""
    axes = ["technical_usability", "execution_match", "shot_purpose", "story_utility"]
    scored = [r for r in rows if "pred" in r and "exp" in r]
    n = len(scored)
    if not n:
        return {}
    def acc(field_):
        return sum(1 for r in scored if r["pred"].get(field_) == r["exp"].get(field_)) / n
    axis_acc = {a: round(acc(a), 3) for a in axes}
    four_axis = sum(1 for r in scored if all(r["pred"].get(a) == r["exp"].get(a) for a in axes)) / n

    # false TRY AGAIN: predicted try_again but expected kept (got_it/keep+)
    false_try = sum(1 for r in scored
                    if r["pred"].get("user_state") == "try_again"
                    and r["exp"].get("user_state") != "try_again") / n
    # FALSE FULFILLMENT: predicted requested_shot fulfilled but expected not
    false_fulfill = sum(1 for r in scored
                        if r["pred"].get("requested_shot_status") == "fulfilled"
                        and r["exp"].get("requested_shot_status") != "fulfilled") / n

    def subset_acc(tag, field_="user_state"):
        sub = [r for r in scored if tag in r.get("tags", [])]
        if not sub:
            return None
        return round(sum(1 for r in sub if r["pred"].get(field_) == r["exp"].get(field_)) / len(sub), 3)

    return {
        "n": n,
        "four_axis_accuracy": round(four_axis, 3),
        "axis_accuracy": axis_acc,
        "shot_purpose_accuracy": axis_acc["shot_purpose"],
        "false_try_again_rate": round(false_try, 3),
        "false_fulfillment_rate": round(false_fulfill, 3),
        "alternative_success_recognition": subset_acc("alternative_success", "shot_purpose"),
        "contradiction_detection": subset_acc("contradiction", "requested_shot_status"),
        "adversarial_catch_rate": subset_acc("adversarial", "requested_shot_status"),
        "temporal_accuracy": subset_acc("temporal"),
        "technical_failure_accuracy": subset_acc("technical", "technical_usability"),
    }


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--models", nargs="*", default=[
        "amazon.nova-2-lite-v1:0", "amazon.nova-pro-v1:0",
    ])
    ap.add_argument("--frames", nargs="*", type=int, default=[8])
    ap.add_argument("--run", action="store_true", help="LIVE Bedrock calls (bills). Default dry.")
    ap.add_argument("--out", default=str(REPO / "evals/results"))
    args = ap.parse_args()

    cases = load_cases()
    print(f"loaded {len(cases)} authored fixtures")
    results = []
    for m in args.models:
        for nf in args.frames:
            print(f"=== {m} @ {nf} frames (live={args.run}) ===")
            results.append(run_candidate(m, nf, cases, live=args.run))
    stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    out = pathlib.Path(args.out) / f"shot_validation_{stamp}.json"
    out.write_text(json.dumps({"results": results}, indent=2))
    print(f"wrote {out}")


if __name__ == "__main__":
    main()
