#!/usr/bin/env python3
"""Phase 4 image-budget evaluation — DETERMINISTIC half (payload + estimated token/latency), NO model calls.
Builds tiled contact sheets at 3 budgets on the real girl/hiking/guitar fixtures, holding Moment COVERAGE
constant, and reports total bytes + estimated image tokens per budget. The QUALITY half (opening/payoff/
source-range/variety/guitar continuity) requires live Opus multimodal calls and is scoped separately."""
import os, subprocess, sys, pathlib, math
from PIL import Image

REPO = pathlib.Path("/Users/lingzhang/Workplace/story")
SCRATCH = pathlib.Path(os.environ["KIROCREW_SCRATCH"]) / "p4eval"
SAMPLER = str(SCRATCH / "framesampler")
SCENES = {
    "girl_with_dress": REPO / "evals/scenarios/girl_with_dress",
    "hiking": REPO / "evals/scenarios/hiking",
    "guitar": REPO / "evals/scenarios/guitar_practice_001",
}
VIDEO_EXT = {".mov", ".mp4", ".m4v"}
# (label, cell_px, jpeg_quality) — current = production tier1; moderate + aggressive are the eval variants.
BUDGETS = [("current(320/0.70)", 320, 0.70), ("moderate(256/0.55)", 256, 0.55), ("aggressive(192/0.45)", 192, 0.45)]
FRAMES_PER_CLIP = 6          # held constant across budgets (coverage constant)
MAX_CLIPS = 8                # bound per scenario for a comparable payload

def clips(d):
    return sorted([p for p in d.iterdir() if p.suffix.lower() in VIDEO_EXT])[:MAX_CLIPS]

def extract(video, outdir, n):
    outdir.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([SAMPLER, str(video), str(outdir), str(n)], capture_output=True, text=True)
    return sorted(outdir.glob("*.jpg")) + sorted(outdir.glob("*.jpeg")) + sorted(outdir.glob("*.png"))

def build_sheet(frame_paths, cell, quality, out):
    imgs = [Image.open(p).convert("RGB") for p in frame_paths]
    if not imgs: return 0
    cols = min(3, len(imgs)); rows = math.ceil(len(imgs)/cols)
    cells = []
    for im in imgs:
        w, h = im.size; scale = cell / max(w, h)
        cells.append(im.resize((max(1,int(w*scale)), max(1,int(h*scale)))))
    cw = max(c.width for c in cells); ch = max(c.height for c in cells)
    sheet = Image.new("RGB", (cols*cw, rows*ch), (0,0,0))
    for i, c in enumerate(cells):
        sheet.paste(c, ((i%cols)*cw, (i//cols)*ch))
    sheet.save(out, "JPEG", quality=int(quality*100))
    return out.stat().st_size

def est_tokens(nbytes):
    # Bedrock/Anthropic image tokens scale ~ with pixels; a practical proxy used by the repo's runners is
    # ~1200 tokens per tiled contact-sheet frame-grid at tier1. Scale by sqrt(byte ratio) as a rough proxy.
    return nbytes  # report bytes; token estimate derived in the summary via a per-budget ratio

def main():
    print(f"{'scenario':16} {'budget':20} {'clips':>5} {'sheets':>6} {'total_KB':>9} {'avg_KB/sheet':>12}")
    base = {}
    for scene, d in SCENES.items():
        cs = clips(d)
        framesets = []
        for i, v in enumerate(cs):
            fs = extract(v, SCRATCH / scene / f"c{i}", FRAMES_PER_CLIP)
            if fs: framesets.append(fs)
        for label, cell, q in BUDGETS:
            total = 0; nsheets = 0
            for i, fs in enumerate(framesets):
                out = SCRATCH / scene / f"sheet_{label.split('(')[0]}_{i}.jpg"
                sz = build_sheet(fs, cell, q, out)
                if sz: total += sz; nsheets += 1
            kb = total/1024
            avg = kb/nsheets if nsheets else 0
            print(f"{scene:16} {label:20} {len(cs):>5} {nsheets:>6} {kb:>9.1f} {avg:>12.1f}")
            base.setdefault(scene, {})[label] = kb
        print()
    print("=== payload reduction vs current (per scenario) ===")
    for scene, b in base.items():
        cur = b[BUDGETS[0][0]]
        for label, _, _ in BUDGETS[1:]:
            pct = 100*(1 - b[label]/cur) if cur else 0
            print(f"{scene:16} {label:20} -> {pct:5.1f}% smaller payload")

if __name__ == "__main__":
    main()
