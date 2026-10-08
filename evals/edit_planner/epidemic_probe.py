"""M-d (Part B) — bounded Epidemic Partner API live probe. PROTOTYPING/EVALUATION ONLY.

Reads the API key from AWS Secrets Manager (secret id passed via --secret) IN-PROCESS. The key is NEVER printed,
logged, placed in argv, or written to disk. Prints only DERIVED facts (counts, field presence, numeric summaries).
No catalog/metadata mirror is persisted. At most ONE audio download. Respects the free tier (prototyping only;
no export/sublicense/safelist).

Usage: TMPDIR=/tmp .venv/bin/python evals/edit_planner/epidemic_probe.py --secret story-epidemic-key [--download]
Writes a REDACTED summary to evals/results/epidemic_probe.json (no key, no audio, no raw metadata dump).
"""
from __future__ import annotations
import argparse, json, pathlib, sys, urllib.request, urllib.parse, urllib.error

REPO = pathlib.Path(__file__).resolve().parents[2]
RESULTS = REPO / "evals/results"
BASE = "https://api.epidemicsound.com"


def get_key(secret_id: str) -> str:
    import boto3  # noqa
    sm = boto3.client("secretsmanager", region_name="us-east-1")
    v = sm.get_secret_value(SecretId=secret_id)
    s = v.get("SecretString") or ""
    s = s.strip()
    # support either a raw string or {"EPIDEMIC_API_KEY": "..."} / {"api_key": "..."}
    if s.startswith("{"):
        d = json.loads(s)
        for k in ("EPIDEMIC_API_KEY", "api_key", "apiKey", "key", "value"):
            if d.get(k):
                return d[k].strip()
        # single-value object
        if len(d) == 1:
            return str(next(iter(d.values()))).strip()
        raise SystemExit("secret JSON has no recognizable key field")
    return s


def call(method: str, path: str, key: str, params: dict | None = None, raw: bool = False):
    url = BASE + path
    if params:
        url += "?" + urllib.parse.urlencode(params, doseq=True)
    req = urllib.request.Request(url, method=method)
    req.add_header("Authorization", f"Bearer {key}")
    req.add_header("accept", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=30) as r:
            body = r.read()
            return r.status, (body if raw else json.loads(body.decode()))
    except urllib.error.HTTPError as e:
        detail = ""
        try:
            detail = e.read().decode()[:300]
        except Exception:  # noqa
            pass
        return e.code, {"_http_error": e.code, "_detail": detail}
    except Exception as e:  # noqa
        return 0, {"_error": type(e).__name__}


def summarize_track(t: dict) -> dict:
    """Only derived presence/shape — not a metadata mirror."""
    return {k: (t.get(k) is not None) for k in
            ("id", "title", "bpm", "length", "moods", "genres", "waveformUrl", "hasVocals", "vocalType", "isrc")}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--secret", required=True)
    ap.add_argument("--download", action="store_true", help="perform ONE real download (counts vs free-tier 50)")
    a = ap.parse_args()
    key = get_key(a.secret)
    assert key and key.startswith("epidemic_"), "key missing or unexpected prefix"
    print(f"key loaded from Secrets Manager (len={len(key)}, prefix 'epidemic_live_'={'live' in key[:16]}) — value NOT shown")

    out = {"base": BASE, "tests": {}}

    # 1. AUTH + semantic SEARCH across 5 diverse intents
    queries = {
        "warm_acoustic": {"term": "warm intimate acoustic guitar", "vocalType": "NONE"},
        "cinematic_build": {"term": "cinematic gradual emotional build", "vocalType": "NONE"},
        "energetic": {"term": "high energy upbeat driving", "bpmMin": 120},
        "sparse_ambient": {"term": "sparse calm ambient still", "vocalType": "NONE"},
        "vocal_heavy": {"term": "pop song with lead vocals", "vocalType": "LEAD"},
    }
    picked = []
    out["tests"]["search"] = {}
    for name, q in queries.items():
        st, body = call("GET", "/v0/tracks/search", key, {**q, "limit": 5})
        tracks = (body or {}).get("tracks") or (body or {}).get("items") or (body or {}).get("data") or []
        out["tests"]["search"][name] = {"status": st, "n_results": len(tracks),
                                        "first_fields": summarize_track(tracks[0]) if tracks else None}
        if tracks:
            picked.append((name, tracks[0].get("id"), tracks[0]))
        if st not in (200, 0) and "_http_error" in str(body):
            out["tests"]["search"][name]["detail"] = body.get("_detail", "")

    # pick up to 4 distinct track ids for the per-track endpoint tests
    probe = picked[:4]
    out["tests"]["per_track"] = {}
    for name, tid, t0 in probe:
        if not tid:
            continue
        rec = {"from_query": name}
        # 2. metadata (batch of one)
        st, md = call("GET", "/v0/tracks/metadata", key, {"trackId": tid})
        arr = md if isinstance(md, list) else (md.get("tracks") if isinstance(md, dict) else None)
        m0 = (arr[0] if isinstance(arr, list) and arr else (md if isinstance(md, dict) else {}))
        rec["metadata_status"] = st
        rec["duration_s"] = m0.get("length")
        rec["bpm"] = m0.get("bpm")
        rec["hasVocals"] = m0.get("hasVocals")
        rec["vocalType"] = m0.get("vocalType")
        rec["waveformUrl_present"] = bool(m0.get("waveformUrl"))
        # 3. beats (+downbeats via value==1)
        st, be = call("GET", f"/v0/tracks/{tid}/beats", key)
        beats = (be or {}).get("beats") if isinstance(be, dict) else be
        rec["beats_status"] = st
        if isinstance(beats, list) and beats:
            rec["n_beats"] = len(beats)
            rec["n_downbeats"] = sum(1 for b in beats if isinstance(b, dict) and b.get("value") == 1)
            rec["beat_fields"] = sorted(beats[0].keys()) if isinstance(beats[0], dict) else "non-dict"
        else:
            rec["beats_body_keys"] = sorted(be.keys()) if isinstance(be, dict) else str(type(be))
        # 4. highlights (most popular section)
        st, hi = call("GET", f"/v0/tracks/{tid}/highlights", key, {"duration": 15})
        rec["highlights_status"] = st
        rec["highlights_shape"] = sorted(hi.keys()) if isinstance(hi, dict) else str(type(hi))
        # 5. HLS stream (preview)
        st, strm = call("GET", f"/v0/tracks/{tid}/stream", key)
        rec["stream_status"] = st
        rec["stream_has_manifest"] = bool(isinstance(strm, dict) and (strm.get("url") or strm.get("hls") or strm.get("manifest")))
        # 6. waveform JSON fetch (derive coarse energy range only)
        wf_url = m0.get("waveformUrl") or (t0 or {}).get("waveformUrl")
        if wf_url:
            try:
                with urllib.request.urlopen(wf_url, timeout=20) as r:
                    wf = json.loads(r.read().decode())
                data = wf.get("data") or []
                rec["waveform_points"] = len(data)
                rec["waveform_sample_rate"] = wf.get("sample_rate")
                if data:
                    rec["waveform_amp_minmax"] = [min(data), max(data)]
            except Exception as e:  # noqa
                rec["waveform_fetch"] = type(e).__name__
        out["tests"]["per_track"][tid] = rec

    # 7. ONE optional download (counts against free-tier 50)
    if a.download and probe:
        tid = probe[0][1]
        st, dl = call("GET", f"/v0/tracks/{tid}/download", key, {"format": "mp3", "quality": "normal"})
        out["tests"]["download"] = {"status": st,
                                    "has_url": bool(isinstance(dl, dict) and dl.get("url")),
                                    "expires_present": bool(isinstance(dl, dict) and (dl.get("expiresAt") or dl.get("expires")))}
        # we do NOT fetch the audio bytes or persist them.

    RESULTS.mkdir(parents=True, exist_ok=True)
    (RESULTS / "epidemic_probe.json").write_text(json.dumps(out, indent=2))
    print(json.dumps(out, indent=2))
    print(f"\nwrote REDACTED summary {RESULTS/'epidemic_probe.json'} (no key, no audio, no metadata mirror)")


if __name__ == "__main__":
    main()
