#!/usr/bin/env python3
"""Verify the enhancement layer (EL) of a Dolby Vision "pulse test" Profile 7 FEL clip.

CLIP is either the muxed .mp4 (HEVC track = BL + EL + RPU) or an EL-only .hevc elementary stream.
For .mp4 the track is copied to Annex-B (ffmpeg), split with `dovi_tool demux` and the EL is used.
The EL is decoded with ffmpeg to raw yuv420p10le (no range conversion) and, per checked frame:
  * phase A (gen_pulse.phase_of): the median luma code in the inset (20%) of every EL patch box must
    be 512 (+-1); the fraction of EL luma pixels != 512 must be 0.
  * phase B: every patch median must equal its el_design() code (+-1); the non-512 pixel fraction
    is printed and compared with the patch area fraction.
The expected composed 10-bit luma delta (delta10, delta_pct) per patch is printed alongside.
For .mp4 the RPU payloads (dovi_tool extract-rpu) are also hashed to confirm they are constant.

Usage: check_el.py CLIP [--frames N] [--json OUT]
  --frames N  check at most N frames per phase segment (evenly spread, default: all frames)
Exit status 0 = PASS, 1 = FAIL, 2 = tool/usage error.
"""
import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import tempfile
import time

import numpy as np

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import gen_pulse as G  # noqa: E402

TOL = 1
INSET = 0.20


def die(msg):
    print("error: " + msg, file=sys.stderr)
    sys.exit(2)


def run(cmd, **kw):
    try:
        r = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, **kw)
    except FileNotFoundError:
        die(f"{cmd[0]} not found in PATH")
    if r.returncode != 0:
        die(f"{' '.join(cmd[:3])}... failed (rc {r.returncode}): {r.stderr.decode(errors='replace')[-400:]}")
    return r


def rpu_payloads(path):
    """Split a dovi_tool RPU.bin (start-code separated) into payloads."""
    data = open(path, "rb").read()
    parts = data.split(b"\x00\x00\x00\x01")
    return [p for p in parts if p]


def prepare_el(clip, tmp):
    """Return (el_hevc_path, rpu_info dict or None)."""
    if not os.path.isfile(clip):
        die(f"no such file: {clip}")
    if not clip.lower().endswith(".mp4"):
        return clip, None
    annexb = os.path.join(tmp, "stream.hevc")
    run(["ffmpeg", "-v", "error", "-y", "-i", clip, "-map", "0:v:0", "-c:v", "copy",
         "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", annexb])
    run(["dovi_tool", "demux", "-i", annexb, "--bl-out", os.path.join(tmp, "BL.hevc"),
         "--el-out", os.path.join(tmp, "EL.hevc")], cwd=tmp)
    el = os.path.join(tmp, "EL.hevc")
    if not os.path.isfile(el) or os.path.getsize(el) == 0:
        die("dovi_tool demux produced no EL (is this a dual-layer Profile 7 clip?)")
    rpu = None
    rb = os.path.join(tmp, "RPU.bin")
    r = subprocess.run(["dovi_tool", "extract-rpu", "-i", annexb, "-o", rb],
                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, cwd=tmp)
    if r.returncode == 0 and os.path.isfile(rb):
        pl = rpu_payloads(rb)
        hashes = [hashlib.sha1(p).hexdigest() for p in pl]
        rpu = {"count": len(pl), "distinct": len(set(hashes)), "constant": len(set(hashes)) == 1}
    return el, rpu


def pick_frames(n_frames, per_seg):
    """Frames to check: every frame, or `per_seg` evenly spread (>=3) in every phase segment."""
    bounds = [0, G.PREROLL] + [G.PREROLL + G.PHASE_LEN * k for k in range(1, G.N_PHASES + 1)]
    bounds = [b for b in bounds if b < n_frames] + [n_frames]
    segs = [(bounds[k], bounds[k + 1]) for k in range(len(bounds) - 1)]
    sel = set()
    for a, b in segs:
        idx = list(range(a, b))
        if per_seg and len(idx) > per_seg:
            idx = sorted({int(round(x)) for x in np.linspace(a, b - 1, max(per_seg, 3))})
        sel.update(idx)
    return sel


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("clip")
    ap.add_argument("--frames", type=int, default=0,
                    help="max frames checked per phase segment (default: all, minimum 3)")
    ap.add_argument("--json", metavar="OUT")
    a = ap.parse_args()
    t0 = time.time()
    design = G.el_design()
    W, H = G.EL_W, G.EL_H
    rois, areas = [], 0
    for d in design:
        x0, y0, x1, y1 = (v // 2 for v in d["box"])
        ix, iy = int((x1 - x0) * INSET), int((y1 - y0) * INSET)
        rois.append((y0 + iy, y1 - iy, x0 + ix, x1 - ix))
        areas += (x1 - x0) * (y1 - y0)
    area_frac = areas / (W * H)

    tmp = tempfile.mkdtemp(prefix="check_el_")
    try:
        el, rpu = prepare_el(a.clip, tmp)
        want_all = a.frames <= 0
        fsize = W * H * 3 // 2 * 2
        p = subprocess.Popen(["ffmpeg", "-v", "error", "-i", el, "-f", "rawvideo", "-pix_fmt", "yuv420p10le", "-"],
                             stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sel = None
        if not want_all:
            r = subprocess.run(["ffprobe", "-v", "error", "-count_packets", "-select_streams", "v:0",
                                "-show_entries", "stream=nb_read_packets", "-of", "csv=p=0", el],
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                sel = pick_frames(int(r.stdout.decode().strip().split(",")[0]), a.frames)
            except ValueError:
                sel = None
        stats = {"A": {"n": 0, "nz": 0.0, "bad": 0, "med": [[] for _ in design]},
                 "B": {"n": 0, "nz": 0.0, "bad": 0, "med": [[] for _ in design]}}
        i = 0
        while True:
            buf = p.stdout.read(fsize)
            if len(buf) < fsize:
                break
            if sel is None or i in sel:
                ph = G.phase_of(i)
                y = np.frombuffer(buf, dtype=np.uint16, count=W * H).reshape(H, W)
                s = stats[ph]
                s["n"] += 1
                s["nz"] += float(np.count_nonzero(y != G.EL_FLAT)) / (W * H)
                bad = False
                for k, (ya, yb, xa, xb) in enumerate(rois):
                    m = int(np.median(y[ya:yb, xa:xb]))
                    s["med"][k].append(m)
                    want = design[k]["el_code"] if ph == "B" else G.EL_FLAT
                    if abs(m - want) > TOL:
                        bad = True
                s["bad"] += bad
            i += 1
        p.stdout.close()
        err = p.stderr.read().decode(errors="replace")
        if p.wait() != 0:
            die("ffmpeg decode failed: " + err[-400:])
        if i == 0:
            die("decoded 0 frames from the EL" + (": " + err[-200:] if err else ""))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    ok_all = True
    print(f"{a.clip}: {i} EL frames decoded, checked A={stats['A']['n']} B={stats['B']['n']}, "
          f"EL {W}x{H}, inset {int(INSET*100)}%, tol +-{TOL}")
    print(f"{'patch':8} {'BL Y10':>6} {'dY10':>5} {'dY%':>6} | {'A want':>6} {'A med(min..max)':>16} {'':4} "
          f"| {'B want':>6} {'B med(min..max)':>16}")
    rows = []
    for k, d in enumerate(design):
        row = {"patch": d["name"], "bl_y10": d["bl_y10"], "delta10": d["delta10"], "delta_pct": d["delta_pct"],
               "el_code_expected": d["el_code"]}
        cells = []
        for ph, want in (("A", G.EL_FLAT), ("B", d["el_code"])):
            m = stats[ph]["med"][k]
            if not m:
                cells.append("n/a")
                row[ph] = {"ok": None}
                continue
            lo, hi = min(m), max(m)
            ok = abs(lo - want) <= TOL and abs(hi - want) <= TOL
            ok_all &= ok
            row[ph] = {"min": lo, "max": hi, "ok": ok}
            cells.append(f"{lo}..{hi} {'PASS' if ok else 'FAIL'}")
        print(f"{d['name']:8} {d['bl_y10']:6d} {d['delta10']:5d} {d['delta_pct']:6.2f} | {G.EL_FLAT:6d} "
              f"{cells[0]:>21} | {d['el_code']:6d} {cells[1]:>21}")
        rows.append(row)
    res = {"clip": a.clip, "frames_decoded": i, "patches": rows, "area_fraction": area_frac}
    for ph in "AB":
        s = stats[ph]
        if not s["n"]:
            print(f"phase {ph}: no frames checked -> FAIL")
            ok_all = False
            continue
        frac = s["nz"] / s["n"]
        if ph == "A":
            ok = frac == 0.0
        else:
            ok = abs(frac - area_frac) <= 0.15 * area_frac
        ok_all &= ok and s["bad"] == 0
        res["phase_" + ph] = {"frames": s["n"], "frames_failing": s["bad"], "nonflat_fraction": frac, "ok": ok}
        extra = f" (patch area {100*area_frac:.2f}%)" if ph == "B" else ""
        print(f"phase {ph}: {s['n']} frames, {s['bad']} failing, EL luma != 512: {100*frac:.3f}%{extra} "
              f"-> {'PASS' if ok and s['bad'] == 0 else 'FAIL'}")
    if stats["B"]["n"] and stats["B"]["nz"] == 0:
        print("FAIL: phase B EL is flat 512 everywhere (no residual carried; null/flat-EL clip?)")
    if rpu is None:
        print("RPU constancy: skipped (EL-only input or extract-rpu failed)")
    elif rpu["count"] == 0:
        print("RPU constancy: no RPUs found -> skipped")
    else:
        ok = rpu["constant"]
        ok_all &= ok
        print(f"RPU constancy: {rpu['count']} RPUs, {rpu['distinct']} distinct payload(s) -> "
              f"{'PASS' if ok else 'FAIL'}")
    res["rpu"] = rpu
    res["pass"] = bool(ok_all)
    print(f"RESULT: {'PASS' if ok_all else 'FAIL'}  ({time.time()-t0:.1f}s)")
    if a.json:
        with open(a.json, "w") as f:
            json.dump(res, f, indent=1)
    sys.exit(0 if ok_all else 1)


if __name__ == "__main__":
    main()
