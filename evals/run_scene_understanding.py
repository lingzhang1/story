"""Scene Understanding model comparison + Layer-0 eval (Milestone C2).

Runs representative scene frames through candidate vision models via the real
engine, applies Layer-0 (schema + semantic-guard) checks, and reports grounding/
hallucination-relevant output for manual review. Uses synthetic scenes for the
headless comparison; real device scans are added as fixtures during the iPhone
dogfooding gate (frames preserved under evals/scene_understanding/<id>/).

Usage: TMPDIR=/tmp .venv/bin/python evals/run_scene_understanding.py <model_id>
"""

from __future__ import annotations

import io
import json
import sys
import time
from pathlib import Path

_ROOT = Path(__file__).resolve().parent.parent
for rel in (".", "packages", "apps/api"):
    p = str((_ROOT / rel).resolve())
    if p not in sys.path:
        sys.path.insert(0, p)

from PIL import Image, ImageDraw  # noqa: E402

from scene_understanding import PROMPT_VERSION, SCHEMA_VERSION, RealSceneUnderstandingEngine  # noqa: E402
from model_gateway import BedrockModelGateway, ProviderError, StructuredOutputError  # noqa: E402
from evals.harness.deterministic import check_schema_valid  # noqa: E402
from evals.harness.runner import FixtureResult, new_run  # noqa: E402


def _jpeg(img: Image.Image, q: int = 65) -> bytes:
    b = io.BytesIO(); img.save(b, format="JPEG", quality=q); return b.getvalue()


def _scene_mountain_trail() -> list[bytes]:
    frames = []
    for shift in (0, 40):
        img = Image.new("RGB", (768, 512), (150, 180, 215))
        d = ImageDraw.Draw(img)
        d.polygon([(0, 512), (380 + shift, 170), (768, 512)], fill=(95, 110, 92))
        d.polygon([(300, 512), (520 + shift, 300), (768, 512)], fill=(120, 130, 110))
        d.rectangle([0, 430, 768, 512], fill=(130, 110, 80))
        d.ellipse([360 + shift, 395, 378 + shift, 435], fill=(25, 25, 30))  # tiny figure
        frames.append(_jpeg(img))
    return frames


def _scene_indoor_room() -> list[bytes]:
    frames = []
    for shift in (0, 30):
        img = Image.new("RGB", (768, 512), (205, 200, 190))
        d = ImageDraw.Draw(img)
        d.rectangle([0, 360, 768, 512], fill=(150, 120, 95))         # floor
        d.rectangle([120 + shift, 150, 360 + shift, 360], fill=(70, 70, 80))  # tv/furniture
        d.rectangle([560, 120, 720, 320], fill=(230, 225, 210))      # window
        frames.append(_jpeg(img))
    return frames


def _scene_crowded_street() -> list[bytes]:
    frames = []
    for shift in (0, 25):
        img = Image.new("RGB", (768, 512), (60, 55, 70))
        d = ImageDraw.Draw(img)
        d.rectangle([0, 380, 768, 512], fill=(45, 45, 55))
        for i in range(14):
            x = (i * 55 + shift) % 760
            d.ellipse([x, 330, x + 24, 390], fill=(20, 20, 25))      # crowd
        d.rectangle([40, 60, 160, 300], fill=(220, 180, 60))         # neon sign
        frames.append(_jpeg(img))
    return frames


def _scene_blank_wall() -> list[bytes]:
    # weak/boring scene — must report limited opportunities, not invent features
    return [_jpeg(Image.new("RGB", (768, 512), (210, 208, 205))) for _ in range(2)]


SCENES = {
    "mountain_trail_scale": _scene_mountain_trail,
    "indoor_room_window": _scene_indoor_room,
    "crowded_street_night": _scene_crowded_street,
    "blank_wall_weak": _scene_blank_wall,
}


def main() -> None:
    model = sys.argv[1] if len(sys.argv) > 1 else "amazon.nova-pro-v1:0"
    gateway = BedrockModelGateway(model_id=model)
    engine = RealSceneUnderstandingEngine(gateway)
    print(f"Scene Understanding — model {gateway.model_id}\n")

    results, latencies = [], []
    total_in = total_out = total_bytes = 0
    for name, builder in SCENES.items():
        frames = builder()
        total_bytes += sum(len(f) for f in frames)
        t = time.monotonic()
        status, checks, payload = "OK", [], {}
        try:
            req = engine.build_request(frames)
            sr = gateway.generate_structured(req)
            if sr.usage:
                total_in += sr.usage.input_tokens or 0
                total_out += sr.usage.output_tokens or 0
            scene = engine._to_contract(sr)  # noqa: SLF001 (eval driver)
            payload = scene.model_dump(mode="json")
            checks = [check_schema_valid("scene_understanding", payload)]
        except (StructuredOutputError, ProviderError) as e:
            status = f"FAIL:{type(e).__name__}:{str(e)[:80]}"
        dt = (time.monotonic() - t) * 1000
        latencies.append(dt)
        passed = status == "OK" and all(c.passed for c in checks)
        results.append(FixtureResult(name, "scene_understanding", passed,
                                     [{"name": c.name, "passed": c.passed, "detail": c.detail} for c in checks]))
        print(f"[{'OK ' if passed else 'XX '}] {name}  {dt:.0f}ms  ({sum(len(f) for f in frames)} B, {len(frames)} frames)")
        if payload:
            slim = {k: payload[k] for k in ("summary", "environment_tags", "subjects",
                    "operator_space", "lighting", "motion_opportunities",
                    "composition_opportunities", "constraints") if payload.get(k)}
            print("   " + json.dumps(slim, ensure_ascii=False))
        else:
            print("   " + status)
        print()

    run = new_run(results, model=gateway.model_id, provider="bedrock",
                  prompt_version=PROMPT_VERSION, schema_version=SCHEMA_VERSION,
                  fixture_set_version="su-synth-v1")
    out = run.save()
    ok = sum(1 for r in results if r.passed)
    ls = sorted(latencies)
    print("=" * 60)
    print(f"model: {gateway.model_id}  schema-pass: {ok}/{len(results)}")
    print(f"latency ms: min={min(latencies):.0f} p50={ls[len(ls)//2]:.0f} max={max(latencies):.0f}")
    print(f"tokens in/out: {total_in}/{total_out}  payload bytes: {total_bytes}")
    print(f"RunRecord: {out}")


if __name__ == "__main__":
    main()
