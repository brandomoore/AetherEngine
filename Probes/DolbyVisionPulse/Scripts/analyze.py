#!/usr/bin/env python3
"""Analyse a phone recording of the pulse clips (see gen_pulse.py and the README).

For every camera frame: find the four corner fiducials, map the clip layout onto the camera image,
read the frame-counter strip (which clip frame is on screen, so which RPU phase), and sample every
patch. Frames whose counter does not decode (slates, mode-switch black, motion) are dropped.

A run is a stretch where the decoded clip frame keeps increasing; it restarts when the counter jumps
back. Label runs in order with --arms (e.g. --arms P,V1,V2,T,N,S,P).

Per run and patch the metadata effect is d_k = B_k - (A_before + A_after)/2 over the k-th B phase
(so slow drift cancels), reported as mean relative change, t statistic, and the frame lag at which
the response crosses half its size after a switch.

Usage: analyze.py recording.mov [--arms P,T,...] [--csv out.csv] [--png out.png] [--scale 1280]
"""
import argparse
import json
import os
import subprocess
import sys

import numpy as np

import gen_pulse as G

HERE = os.path.dirname(os.path.abspath(__file__))
SETTLE = 12  # clip frames ignored after each phase switch (~0.5 s)


def probe(path):
    out = subprocess.check_output(["ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
                                   "stream=width,height,r_frame_rate:stream_side_data=rotation",
                                   "-of", "json", path])
    s = json.loads(out)["streams"][0]
    num, den = (int(x) for x in s["r_frame_rate"].split("/"))
    return s["width"], s["height"], num / den


def frames(path, scale):
    """Yield luma frames as float32 [0,1], scaled to `scale` px wide (ffmpeg applies rotation)."""
    w, h, fps = probe(path)
    cmd = ["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={scale}:-2", "-pix_fmt", "gray16le",
           "-f", "rawvideo", "-"]
    # Output size: decode one frame to PGM and read its header (ffmpeg applies display rotation).
    pgm = subprocess.check_output(["ffmpeg", "-v", "error", "-i", path, "-vf", f"scale={scale}:-2",
                                   "-frames:v", "1", "-pix_fmt", "gray", "-f", "image2pipe", "-c:v", "pgm", "-"])
    ow, oh = (int(x) for x in pgm.split(b"\n")[1].split())
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE)
    n = ow * oh * 2
    t = 0
    while True:
        buf = p.stdout.read(n)
        if len(buf) < n:
            break
        yield t, np.frombuffer(buf, dtype="<u2").reshape(oh, ow).astype(np.float32) / 65535.0
        t += 1
    p.wait()


def find_corners(Y):
    """Outer corners of the four fiducials: extreme bright pixels along the diagonals.

    On a real phone image the TV sits on a bright wall, so the search is restricted to the dark
    screen region (found from row/column projections of dark pixels)."""
    oh, ow = Y.shape
    x_lo, x_hi, y_lo, y_hi = 0, ow, 0, oh
    dark = Y < 0.3
    xs_d = np.nonzero(dark.mean(0) > 0.4)[0]
    ys_d = np.nonzero(dark.mean(1) > 0.4)[0]
    if len(xs_d) and len(ys_d):
        x_lo, x_hi, y_lo, y_hi = xs_d.min(), xs_d.max() + 1, ys_d.min(), ys_d.max() + 1
        # bright wall/bezel pokes into the bbox at curved screen corners; fiducials never touch its edge
        m = int(0.013 * (x_hi - x_lo))
        if x_hi - x_lo < ow or y_hi - y_lo < oh:
            x_lo, x_hi, y_lo, y_hi = x_lo + m, x_hi - m, y_lo + m, y_hi - m
    Z = Y[y_lo:y_hi, x_lo:x_hi]
    lo, hi = np.percentile(Z, 5), np.percentile(Z, 99.5)  # percentile, not max: glare/reflections
    if hi - lo < 0.08:
        return None
    M = Z > lo + 0.35 * (hi - lo)
    # keep only pixels inside a solid 7x7 bright block (fiducials are big squares; specks and thin
    # reflection streaks are not)
    c = np.pad(M.astype(np.int32).cumsum(0).cumsum(1), ((1, 0), (1, 0)))
    k = 7
    solid = (c[k:, k:] - c[:-k, k:] - c[k:, :-k] + c[:-k, :-k]) == k * k
    M = np.zeros_like(M)
    M[k // 2:k // 2 + solid.shape[0], k // 2:k // 2 + solid.shape[1]] = solid
    ys, xs = np.nonzero(M)
    if len(xs) < 200:
        return None
    xs, ys = xs + x_lo, ys + y_lo
    s, d = xs + ys, xs - ys
    tl = (xs[s.argmin()], ys[s.argmin()])
    br = (xs[s.argmax()], ys[s.argmax()])
    tr = (xs[d.argmax()], ys[d.argmax()])
    bl = (xs[d.argmin()], ys[d.argmin()])
    o = k // 2  # the solid-block test insets each corner pixel by k//2
    return np.array([tl, tr, bl, br], dtype=np.float64) + np.array([[-o, -o], [o, -o], [-o, o], [o, o]])


def homography(src, dst):
    A = []
    for (x, y), (u, v) in zip(src, dst):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    _, _, vt = np.linalg.svd(np.array(A))
    Hm = vt[-1].reshape(3, 3)
    return Hm / Hm[2, 2]


def sampler(L, Hm, Y_shape, inset=0.2, n=7):
    """Precompute camera pixel coordinates for an n x n grid inside every box (inset fraction trimmed)."""
    oh, ow = Y_shape

    def grid(box):
        x0, y0, x1, y1 = box
        dx, dy = (x1 - x0) * inset, (y1 - y0) * inset
        gx, gy = np.meshgrid(np.linspace(x0 + dx, x1 - dx, n), np.linspace(y0 + dy, y1 - dy, n))
        P = np.stack([gx.ravel(), gy.ravel(), np.ones(gx.size)])
        Q = Hm @ P
        u = np.clip(np.round(Q[0] / Q[2]).astype(int), 0, ow - 1)
        v = np.clip(np.round(Q[1] / Q[2]).astype(int), 0, oh - 1)
        return v, u

    names = [p["name"] for p in L["patches"]]
    boxes = [p["box"] for p in L["patches"]]
    # Ramp: 8 equal slices.
    x0, y0, x1, y1 = L["ramp"]["box"]
    for k in range(8):
        a = x0 + (x1 - x0) * k // 8
        b = x0 + (x1 - x0) * (k + 1) // 8
        names.append(f"ramp{k}")
        boxes.append([a, y0, b, y1])
    names.append("black")
    boxes.append([1700, 1950, 2140, 2100])  # surround below the code strip
    names.append("fid")
    boxes.append(L["fiducials"][0])
    return names, [grid(b) for b in boxes], [grid(c) for c in L["code_cells"]]


def analyse(path, arms, scale):
    L = G.layout()
    W, H = L["width"], L["height"]
    m, s = 80, 200
    src_corners = np.array([[m, m], [W - m, m], [m, H - m], [W - m, H - m]], dtype=np.float64)
    _, _, cam_fps = probe(path)

    rows = []  # (cam_frame, clip_frame, values...)
    names = None
    cache = None  # (corners, names, patch grids, cell grids)
    bad = 0
    def decode(Y, c):
        nonlocal cache
        if cache is None or np.abs(cache[0] - c).max() > 3:
            names, pg, cg = sampler(L, homography(src_corners, c), Y.shape)
            cache = (c, names, pg, cg)
        _, names, pg, cg = cache
        vals = np.array([Y[v, u].mean() for v, u in pg])
        black, fid = vals[-2], vals[-1]
        if fid - black < 0.05:
            return None
        cells = [Y[v, u].mean() for v, u in cg]
        # cells 0 and 15 are always lit: use them as the 'on' reference (the fiducial's level can differ
        # from the strip's when the RPU darkens the picture unevenly)
        thr = black + 0.5 * (min(cells[0], cells[-1]) - black)
        idx = G.decode_bits([int(x > thr) for x in cells])
        if idx is None or idx >= L["n_frames"]:
            return None
        return idx, vals

    good = None  # corners of the last frame that decoded: the phone is on a tripod, so they stay valid
    for t, Y in frames(path, scale):
        out = None
        c = find_corners(Y)
        if c is not None:
            out = decode(Y, c)
        if out is not None:
            good = c
        elif good is not None:
            # dim frames (the RPU can darken the whole picture) can fool the fiducial search
            out = decode(Y, good)
        if out is None:
            bad += 1
            continue
        rows.append((t, out[0], out[1]))
    names = cache[1] if cache else None
    if not rows:
        sys.exit(f"no decodable frames ({bad} rejected): check framing, exposure, fiducials in view")

    # The 2 parity bits let some misreads through (more often in the dim phases). A real counter
    # advances 23.976 clip frames per second, so drop decodes that disagree with the median of what
    # their neighbours (+-2 s, at least 4 of them) predict for this instant.
    T = np.array([r[0] for r in rows], dtype=np.float64)
    I = np.array([r[1] for r in rows], dtype=np.float64)
    rate = 24000 / 1001 / cam_fps
    ok = np.zeros(len(rows), dtype=bool)
    for i in range(len(rows)):
        lo, hi = np.searchsorted(T, [T[i] - 2 * cam_fps, T[i] + 2 * cam_fps])
        sel = np.arange(lo, hi) != i
        pred = (I[lo:hi] + rate * (T[i] - T[lo:hi]))[sel]
        ok[i] = len(pred) >= 4 and abs(I[i] - np.median(pred)) <= 6
    print(f"  counter consistency filter dropped {int((~ok).sum())} of {len(rows)} decodes")
    bad += int((~ok).sum())
    rows = [r for r, k in zip(rows, ok) if k]

    # Split into runs where the clip frame index restarts.
    runs, cur = [], [rows[0]]
    for r in rows[1:]:
        if r[1] + 48 < cur[-1][1]:
            runs.append(cur)
            cur = [r]
        else:
            cur.append(r)
    runs.append(cur)
    for r in runs:
        print(f"  segment {r[0][0] / cam_fps:6.1f}-{r[-1][0] / cam_fps:6.1f} s: {len(r):5d} decoded frames, "
              f"clip frames {r[0][1]}..{r[-1][1]}" + ("" if len(r) > 10 * cam_fps else "  (too short, dropped)"))
    runs = [r for r in runs if len(r) > 10 * cam_fps]
    labels = (arms or [])
    print(f"{path}: camera {cam_fps:.2f} fps, {len(rows)} decoded frames, {bad} rejected, {len(runs)} runs")
    if labels and len(labels) != len(runs):
        print(f"  warning: {len(labels)} arm labels for {len(runs)} runs; labels applied in order")

    results = []
    for k, run in enumerate(runs):
        label = labels[k] if k < len(labels) else f"run{k + 1}"
        idx = np.array([r[1] for r in run])
        V = np.array([r[2] for r in run])
        V = V[:, :-2]  # drop black, fid
        pnames = names[:-2]
        phase_no = np.where(idx < G.PREROLL, -1, (idx - G.PREROLL) // G.PHASE_LEN)
        pos = np.where(idx < G.PREROLL, idx, (idx - G.PREROLL) % G.PHASE_LEN)
        keep = (pos >= SETTLE) & (phase_no >= -1)
        means = {}
        for ph in np.unique(phase_no[keep]):
            sel = keep & (phase_no == ph)
            if sel.sum() >= 5:
                means[int(ph)] = V[sel].mean(axis=0)
        # B phases are even phase numbers; A neighbours are odd (or the pre-roll, -1).
        d = []
        for ph in sorted(means):
            if ph >= 0 and ph % 2 == 0 and (ph - 1) in means and (ph + 1) in means:
                d.append(means[ph] - 0.5 * (means[ph - 1] + means[ph + 1]))
        d = np.array(d)
        base = np.mean([v for p, v in means.items() if p == -1 or p % 2 == 1], axis=0)
        if len(d) < 2:
            print(f"  {label}: only {len(d)} complete B phases, skipped")
            continue
        mean_d = d.mean(axis=0)
        sd = d.std(axis=0, ddof=1)
        tstat = mean_d / np.maximum(sd / np.sqrt(len(d)), 1e-6)
        rel = mean_d / np.maximum(base, 1e-3)
        # Response lag: average trace around A->B switches of the most responsive patch.
        j = int(np.argmax(np.abs(tstat)))
        lag = step_lag(idx, V[:, j], phase_no, pos)
        span = (run[0][0] / cam_fps, run[-1][0] / cam_fps)
        n_sig = int((np.abs(tstat) > 5).sum())
        verdict = "PULSE" if n_sig >= 3 else ("weak" if n_sig >= 1 else "steady")
        print(f"\n  [{label}] camera {span[0]:.1f}-{span[1]:.1f} s, clip frames {idx.min()}-{idx.max()}, "
              f"{len(d)} B phases -> {verdict} ({n_sig} patches |t|>5), lag {lag}")
        order = np.argsort(-np.abs(tstat))
        for i in order[:8]:
            print(f"    {pnames[i]:>8}: level {base[i]:.3f}  B-A {mean_d[i]:+.4f} ({100 * rel[i]:+.1f}%)  t={tstat[i]:+.1f}")
        results.append({"arm": label, "span_s": span, "b_phases": len(d), "verdict": verdict,
                        "n_sig": n_sig, "lag_clip_frames": lag,
                        "patches": {pnames[i]: {"level": float(base[i]), "delta": float(mean_d[i]),
                                                "rel": float(rel[i]), "t": float(tstat[i])}
                                    for i in range(len(pnames))},
                        "trace": {"clip_frame": idx.tolist(), "values": V.tolist(), "names": pnames}})
    return results


def step_lag(idx, v, phase_no, pos):
    """Clip frames after an A->B switch until the averaged response passes half its size."""
    win = range(-12, 36)
    acc = {o: [] for o in win}
    for ph in set(phase_no[phase_no >= 0].tolist()):
        if ph % 2:
            continue
        start = G.PREROLL + ph * G.PHASE_LEN
        for o in win:
            sel = idx == start + o
            if sel.any():
                acc[o].append(v[sel].mean())
    tr = np.array([np.mean(acc[o]) if acc[o] else np.nan for o in win])
    pre = np.nanmean(tr[:12])
    post = np.nanmean(tr[-12:])
    if not np.isfinite(pre) or not np.isfinite(post) or abs(post - pre) < 1e-3:
        return None
    half = pre + 0.5 * (post - pre)
    for o, x in zip(win, tr):
        if o >= 0 and np.isfinite(x) and (x - half) * np.sign(post - pre) >= 0:
            return o
    return None


def png(results, out):
    from PIL import Image, ImageDraw
    rows = len(results)
    Wd, Hd = 1600, 260
    img = Image.new("RGB", (Wd, Hd * rows), "white")
    dr = ImageDraw.Draw(img)
    for r, res in enumerate(results):
        tr = res["trace"]
        idx = np.array(tr["clip_frame"])
        V = np.array(tr["values"])
        best = sorted(res["patches"], key=lambda n: -abs(res["patches"][n]["t"]))[:3]
        y0 = r * Hd
        dr.text((10, y0 + 5), f"{res['arm']}: {res['verdict']} ({res['n_sig']} patches |t|>5)", fill="black")
        for f in range(G.PREROLL, G.N_FRAMES, G.PHASE_LEN):
            if G.phase_of(f) == "B":
                x = 10 + (f / G.N_FRAMES) * (Wd - 20)
                x2 = 10 + ((f + G.PHASE_LEN) / G.N_FRAMES) * (Wd - 20)
                dr.rectangle([x, y0 + 25, x2, y0 + Hd - 10], fill=(235, 235, 250))
        for c, name in zip([(200, 0, 0), (0, 120, 0), (0, 0, 200)], best):
            j = tr["names"].index(name)
            v = V[:, j]
            lo, hi = v.min(), v.max()
            pts = [(10 + (i / G.N_FRAMES) * (Wd - 20),
                    y0 + Hd - 15 - (x - lo) / max(hi - lo, 1e-6) * (Hd - 50)) for i, x in zip(idx, v)]
            dr.line(pts, fill=c, width=1)
            dr.text((Wd - 300, y0 + 5 + 14 * best.index(name)), f"{name} t={res['patches'][name]['t']:+.1f}", fill=c)
    img.save(out)


if __name__ == "__main__":
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("recording")
    ap.add_argument("--arms", help="comma-separated labels for the runs, in order")
    ap.add_argument("--scale", type=int, default=1280, help="analysis width in px")
    ap.add_argument("--json", help="write full results (with traces) here")
    ap.add_argument("--png", help="write a trace plot here")
    a = ap.parse_args()
    res = analyse(a.recording, a.arms.split(",") if a.arms else None, a.scale)
    if a.json:
        json.dump(res, open(a.json, "w"))
    if a.png and res:
        png(res, a.png)
