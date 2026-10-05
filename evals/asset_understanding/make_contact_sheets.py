"""Contact-sheet generator for AU ground-truth annotation + owner review.

For each annotation-subset clip, sample timestamped frames (density scaled by duration,
denser for long/multi-event clips so events are reviewable without blind scrubbing) and
tile them into a labelled grid PNG. Review-infra only; no model calls, no media duplication
into git (sheets land under the gitignored private_local/ tree).

Usage: TMPDIR=/tmp .venv/bin/python evals/asset_understanding/make_contact_sheets.py
"""
from __future__ import annotations
import json, pathlib, subprocess, sys
from PIL import Image, ImageDraw, ImageFont

REPO = pathlib.Path(__file__).resolve().parents[2]
MEDIA_MAP = json.loads((REPO / "evals/shot_validation/media-map.json").read_text())
MEDIA_ROOT = REPO / MEDIA_MAP["media_root"]
SAMPLER = pathlib.Path("/tmp/sample_frames")
OUT = REPO / "evals/assets/private_local/frames/au_annotation"
SHEETS = REPO / "evals/assets/private_local/frames/au_contact_sheets"

# 18-clip annotation subset (fixture ids). Chosen for full §1 coverage.
SUBSET = [
    "T01_technical_controls__A_clean_4s",
    "T01_technical_controls__I_camera_points_away",
    "S01_backpack_static__A_exact_good",
    "S01_backpack_static__F_alternative_good",
    "S02_departure__A_exact_good",
    "S02_departure__D_walk_away_through_door",
    "S02_departure__G_contradictory_action",
    "S03_scenic_reveal__D_reverse_reveal__take1",
    "S05_trail_progression__A_follow_behind",
    "A01_semantic_adversarial__A03_backpack_but_arrival_not_departure",
    "S04_human_scale__A_exact_small_person_landscape__take1",
    "S06_difficulty__E_cross_river",
    "S07_companionship__A_natural_conversation",
    "S07_companionship__E_wrong_people",
    "S08_end_of_day__D_cooking_dinner",
    "S08_end_of_day__F_nice_dinner_window_view",
    "A01_semantic_adversarial__A01_hiking_but_not_difficulty",
    "A01_semantic_adversarial__A06_beautiful_but_wrong_beat",
]


def sample(path, n, out):
    out.mkdir(parents=True, exist_ok=True)
    r = subprocess.run([str(SAMPLER), str(path), str(out), str(n)], capture_output=True, text=True)
    line = next(l for l in r.stdout.splitlines() if l.strip().startswith("{"))
    return json.loads(line)


def budget(dur):
    # Denser than the 24-frame model budget: review needs to SEE events. ~1 frame / 2s,
    # clamped 8..40 so a 154s clip gets 40 review frames (~1 / 4s), a 4s clip gets 8.
    return max(8, min(40, round(dur / 2.0)))


def make_sheet(fid, meta, frames, cols=6, cell=240):
    imgs = [Image.open(f["path"]).convert("RGB") for f in frames]
    # scale each to cell width, preserve aspect
    scaled = []
    for im, f in zip(imgs, frames):
        w, h = im.size
        nh = int(h * cell / w)
        scaled.append((im.resize((cell, nh)), f))
    maxh = max(im.size[1] for im, _ in scaled)
    rows = (len(scaled) + cols - 1) // cols
    label_h = 22
    sheet_w = cols * cell
    sheet_h = rows * (maxh + label_h) + 40
    sheet = Image.new("RGB", (sheet_w, sheet_h), (18, 18, 20))
    draw = ImageDraw.Draw(sheet)
    try:
        font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial.ttf", 14)
        hfont = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Bold.ttf", 16)
    except Exception:
        font = hfont = ImageFont.load_default()
    draw.text((8, 8), f"{fid}   dur={meta['duration_s']:.1f}s   {len(frames)} review frames",
              fill=(240, 240, 240), font=hfont)
    y0 = 36
    for i, (im, f) in enumerate(scaled):
        r, c = divmod(i, cols)
        x = c * cell
        y = y0 + r * (maxh + label_h)
        sheet.paste(im, (x, y))
        draw.text((x + 4, y + im.size[1] + 2), f"{f['t_ms']/1000:.1f}s", fill=(120, 220, 255), font=font)
    SHEETS.mkdir(parents=True, exist_ok=True)
    out = SHEETS / f"{fid}.png"
    sheet.save(out, "PNG")
    return out


def main():
    index = []
    for fid in SUBSET:
        rel = MEDIA_MAP["fixtures"][fid]
        path = MEDIA_ROOT / rel
        meta = sample(path, 1, OUT / fid)   # cheap duration probe
        dur = meta["duration_s"]
        n = budget(dur)
        meta = sample(path, n, OUT / fid)
        out = make_sheet(fid, meta, meta["frames"])
        index.append({"fixture": fid, "duration_s": round(dur, 1), "review_frames": n, "sheet": str(out)})
        print(f"  {fid[:50]:50} {dur:6.1f}s {n:2}fr -> {out.name}")
    (SHEETS / "index.json").write_text(json.dumps(index, indent=2))
    print(f"\nwrote {len(index)} sheets to {SHEETS}")


if __name__ == "__main__":
    main()
