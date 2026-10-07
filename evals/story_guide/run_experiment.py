"""E2-a StoryGuide experiment — Sonnet 4.6 vs Opus 4.6, identical prompt/schema/fixtures.

CreativeIntent -> StoryGuide (long-horizon creative map). Text-only Converse tool-use,
temperature 0. The model returns ORDINAL ids (d1, d1p1); the engine would mint canonical
ids — here we just record what the model produced + validate the shape.

Usage:
  TMPDIR=/tmp .venv/bin/python evals/story_guide/run_experiment.py --run
  TMPDIR=/tmp .venv/bin/python evals/story_guide/run_experiment.py --run --only A_tmb_hiking
Outputs: evals/results/story_guide_e2a_<model>.json  (+ a combined side_by_side.json)
"""
from __future__ import annotations
import argparse, json, pathlib, sys, time

REPO = pathlib.Path(__file__).resolve().parents[2]
sys.path[:0] = [str(REPO), str(REPO / "packages")]
from model_gateway import BedrockModelGateway, StructuredRequest, StructuredOutputError, ProviderError

FIX = json.loads((REPO / "evals/story_guide/fixtures.json").read_text())["fixtures"]
MODELS = {"sonnet": "us.anthropic.claude-sonnet-4-6", "opus": "us.anthropic.claude-opus-4-6-v1"}
RESULTS = REPO / "evals/results"

# --- Experimental StoryGuide schema (the reconciliation's minimum candidate). -----------
# Model emits ORDINAL ids (engine would mint canonical UUIDs later). NO required flags,
# NO weights, NO percentages, NO fixed vocabulary, NO camera direction.
GUIDE_SCHEMA = {
    "type": "object", "additionalProperties": False,
    "properties": {
        "framing_summary": {"type": "string",
            "description": "ONE short human-readable statement of what this Story is trying to capture."},
        "dimensions": {
            "type": "array",
            "description": "A SMALL, scope-sensitive set of Story-specific narrative dimensions.",
            "items": {
                "type": "object", "additionalProperties": False,
                "properties": {
                    "id": {"type": "string", "description": "ordinal handle d1,d2,... (engine mints canonical id)"},
                    "label": {"type": "string"},
                    "purpose": {"type": "string", "description": "what this dimension expresses for the Story"},
                    "capture_possibilities": {
                        "type": "array",
                        "description": "A FEW example ways to express the purpose. EXAMPLES, not requirements.",
                        "items": {
                            "type": "object", "additionalProperties": False,
                            "properties": {
                                "id": {"type": "string", "description": "ordinal d1p1,... (engine mints)"},
                                "label": {"type": "string"},
                                "semantic_purpose": {"type": "string"},
                            },
                            "required": ["id", "label"],
                        },
                    },
                },
                "required": ["id", "label", "purpose", "capture_possibilities"],
            },
        },
    },
    "required": ["framing_summary", "dimensions"],
}

SYSTEM = """You are StoryGuide for a personal Story-video app.

Given the user's CreativeIntent (what they want to make) and its scope (target duration),
produce a LONG-HORIZON CREATIVE MAP: a small set of Story-specific narrative dimensions that
could make THIS Story compelling. You run ONCE at Story creation, BEFORE any footage exists.

You answer: "What kinds of moments / narrative qualities could make the Story the user asked
for compelling?"

The Guide IS:
- Story-specific and grounded in THIS CreativeIntent
- scope-sensitive (a tiny Story gets a tiny map; a long/rich Story may get a richer one)
- advisory, semantic, concise
- a creative map that gives the user confidence you understand the film they want to make

The Guide is NOT:
- a screenplay, a required-shot list, a Director plan, or an itinerary (unless the Story
  itself is fundamentally about chronology)
- a generic filmmaking or travel template
- homework or a checklist

RULES:
- Derive dimensions FROM the intent. Use the Story's own domain vocabulary (a guitar-practice
  Story has 'focus/progress', NOT 'landscape/scale'; a typewriter restoration has
  'disassembly/transformation', NOT 'journey/people').
- SCALE THE MAP TO SCOPE. An 8-second Story should get 1-2 dimensions, NOT six. A rich
  multi-minute Story may justify more — but only if each dimension earns its place.
- Honor explicit constraints. If the user says "no people" or "no narrative arc", DO NOT add
  people/companionship/arc dimensions.
- capture_possibilities are a FEW ILLUSTRATIVE expressions of a dimension's purpose — example
  ways it COULD be realized, never required shots and never camera/framing instructions. A
  dimension may have zero possibilities if examples add nothing. Do not over-plan.
- framing_summary is ONE short sentence, in the app's calm voice (e.g. "For this Story: one
  strong opening, movement through the landscape, the scale of it all - and one big moment.").
- Fewer, sharper dimensions beat more, padded ones. Do NOT invent near-duplicate dimensions
  to look thorough.
- id fields: emit simple ordinals (d1, d2; d1p1, d1p2). They are temporary handles.

Return ONLY the StoryGuide via the tool."""


def build_req(fx: dict) -> StructuredRequest:
    ci = fx["creative_intent"]
    scope = {"target_duration_seconds": ci.get("target_duration_seconds"),
             "target_format": ci.get("target_format")}
    payload = {"creative_intent": ci, "scope": scope}
    user = ("Produce the StoryGuide for THIS Story.\n\nCREATIVE INTENT + SCOPE:\n"
            + json.dumps(payload, indent=2)
            + "\n\nRemember: scale the map to the scope, use this Story's own domain vocabulary, "
              "honor explicit constraints, and keep capture_possibilities as a few examples. "
              "Return ONLY the StoryGuide via the tool.")
    return StructuredRequest(task="story_guide.generate", schema=GUIDE_SCHEMA,
                             prompt_version="story_guide/exp-v1", system=SYSTEM,
                             user_content=user, max_repair_attempts=2,
                             max_tokens=2000, temperature=0.0)


def validate_shape(data: dict) -> list[str]:
    """Lightweight structural + rule checks (the hard 'no required/weights/percent/camera'
    rules are enforced by the schema's additionalProperties=False; this catches value-level
    leaks for the report)."""
    errs = []
    if not data.get("framing_summary"): errs.append("missing framing_summary")
    dims = data.get("dimensions") or []
    if not dims: errs.append("zero dimensions")
    ids = [d.get("id") for d in dims]
    if len(ids) != len(set(ids)): errs.append("duplicate dimension ids")
    for d in dims:
        for p in d.get("capture_possibilities", []):
            if not p.get("label"): errs.append(f"possibility w/o label in {d.get('id')}")
    return errs


def run_model(name: str, model_id: str, only: str | None):
    gw = BedrockModelGateway(model_id=model_id)
    out = {"model": name, "model_id": model_id, "fixtures": {}}
    for key, fx in FIX.items():
        if only and key != only:
            continue
        req = build_req(fx)
        t0 = time.time()
        rec = {"domain": fx["domain"]}
        try:
            r = gw.generate_structured(req)
            dt = time.time() - t0
            rec.update({
                "ok": True, "latency_s": round(dt, 2),
                "attempts": r.attempts, "repaired": r.repaired,
                "in_tok": r.usage.input_tokens, "out_tok": r.usage.output_tokens,
                "total_tok": r.usage.total_tokens,
                "guide": r.data,
                "dim_count": len(r.data.get("dimensions", [])),
                "shape_errors": validate_shape(r.data),
            })
            print(f"[{name}] {key}: {rec['dim_count']} dims, {dt:.1f}s, "
                  f"{rec['total_tok']} tok, errs={rec['shape_errors']}")
        except (StructuredOutputError, ProviderError) as e:
            rec.update({"ok": False, "error": f"{type(e).__name__}: {str(e)[:160]}"})
            print(f"[{name}] {key}: FAIL {rec['error']}")
        out["fixtures"][key] = rec
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", action="store_true")
    ap.add_argument("--only", default=None)
    args = ap.parse_args()
    if not args.run:
        print("dry run; pass --run"); return
    RESULTS.mkdir(parents=True, exist_ok=True)
    combined = {}
    for name, mid in MODELS.items():
        res = run_model(name, mid, args.only)
        (RESULTS / f"story_guide_e2a_{name}.json").write_text(json.dumps(res, indent=2))
        combined[name] = res
    (RESULTS / "story_guide_e2a_side_by_side.json").write_text(json.dumps(combined, indent=2))
    # cost summary
    print("\n=== COST / LATENCY ===")
    for name, res in combined.items():
        fs = [f for f in res["fixtures"].values() if f.get("ok")]
        if not fs: continue
        tot = sum(f["total_tok"] for f in fs)
        lat = sorted(f["latency_s"] for f in fs)
        p50 = lat[len(lat)//2]; p95 = lat[min(len(lat)-1, int(len(lat)*0.95))]
        print(f"{name}: {len(fs)} ok, total {tot} tok, p50 {p50}s p95 {p95}s")


if __name__ == "__main__":
    main()
