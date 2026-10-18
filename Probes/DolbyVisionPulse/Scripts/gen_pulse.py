#!/usr/bin/env python3
"""Synthetic Dolby Vision pulse clips for the RPU-consumption experiment.

The pixels are identical in every variant and every phase, except for a frame-counter strip that
the analysis reads back from the phone video. Only the RPU changes:

  l2    L1 constant (true stats); L2 trims at 100/600/1000/4000-nit targets switch neutral <-> extreme
  l1    L1 max_pq switches 100 nits <-> 10000 nits; no trims
  null  L1 constant, L2 trims always neutral (same shot boundaries as l2)

Timeline at 24000/1001 fps: 144 frames of phase A (pre-roll, lets the HDMI mode switch settle),
then 20 phases of 72 frames alternating B, A, B, ... (10 cycles of ~6 s). The phase of any frame is
a pure function of its index, see `phase_of`.

Usage: gen_pulse.py layout                  -> layout.json (patch boxes, code cells) on stdout
       gen_pulse.py frames                  -> raw yuv420p10le frames on stdout (feed x265)
       gen_pulse.py rpu-json <variant>      -> dovi_tool generate config on stdout
       gen_pulse.py el-frames               -> raw 1920x1080 yuv420p10le EL frames on stdout (feed x265)
       gen_pulse.py el-design               -> the EL residual design (patches, EL codes) as JSON

el-frames is for the p7fel_el clip: the RPU is constant (as in `null`), the enhancement layer is flat
512 (zero residual) in phase A and carries a positive luma residual on EL_PATCHES in phase B.
"""
import json
import sys

import numpy as np

W, H = 3840, 2160
FPS_NUM, FPS_DEN = 24000, 1001
PREROLL = 144
PHASE_LEN = 72
N_PHASES = 20
N_FRAMES = PREROLL + PHASE_LEN * N_PHASES  # 1584, ~66 s

CODE_BITS = 12  # frame index, Gray-coded
CELL_NITS = 300.0
FID_NITS = 300.0


def phase_of(i):
    """'A' or 'B' for frame index i."""
    if i < PREROLL:
        return "A"
    return "B" if ((i - PREROLL) // PHASE_LEN) % 2 == 0 else "A"


def pq(nits):
    m1 = 2610 / 16384
    m2 = 2523 / 4096 * 128
    c1 = 3424 / 4096
    c2 = 2413 / 4096 * 32
    c3 = 2392 / 4096 * 32
    y = np.power(np.asarray(nits, dtype=np.float64) / 10000.0, m1)
    return np.power((c1 + c2 * y) / (1 + c3 * y), m2)


def pq12(nits):
    return int(round(float(pq(nits)) * 4095))


# ---------------------------------------------------------------- layout
GRAY_NITS = [0.1, 1, 10, 50, 100, 200, 400, 600, 1000, 2000, 4000, 10000]
# Linear-light BT.2020 RGB in nits.
COLORS = {
    "gray150": (150, 150, 150),
    "red": (400, 60, 60),
    "green": (60, 300, 60),
    "blue": (60, 60, 400),
    "yellow": (300, 300, 40),
    "cyan": (40, 300, 300),
    "magenta": (300, 40, 300),
    "skin": (250, 160, 120),
}


def layout():
    boxes = []  # name, x0, y0, x1, y1, rgb nits
    pw, gap, x0 = 240, 40, 260
    for k, n in enumerate(GRAY_NITS):
        x = x0 + k * (pw + gap)
        boxes.append({"name": f"g{n:g}", "box": [x, 400, x + pw, 760], "rgb": [n, n, n]})
    cw, cgap = 380, 40
    cx0 = (W - (len(COLORS) * cw + (len(COLORS) - 1) * cgap)) // 2
    for k, (name, rgb) in enumerate(COLORS.items()):
        x = cx0 + k * (cw + cgap)
        boxes.append({"name": name, "box": [x, 880, x + cw, 1240], "rgb": list(rgb)})
    ramp = {"name": "ramp", "box": [260, 1360, 260 + 3320, 1560], "pq_range": [0.0, float(pq(1000))]}
    cells = []
    nc, cell, cgap2 = CODE_BITS + 4, 180, 20
    sx = (W - (nc * cell + (nc - 1) * cgap2)) // 2
    for k in range(nc):
        x = sx + k * (cell + cgap2)
        cells.append([x, 1720, x + cell, 1900])
    s, m = 200, 80
    fids = [[m, m, m + s, m + s], [W - m - s, m, W - m, m + s],
            [m, H - m - s, m + s, H - m], [W - m - s, H - m - s, W - m, H - m]]
    # Orientation tag right of the top-left fiducial.
    tag = [m + s + 60, m + 50, m + s + 160, m + 150]
    return {"width": W, "height": H, "fps": [FPS_NUM, FPS_DEN], "preroll": PREROLL,
            "phase_len": PHASE_LEN, "n_phases": N_PHASES, "n_frames": N_FRAMES,
            "patches": boxes, "ramp": ramp, "code_cells": cells, "code_bits": CODE_BITS,
            "fiducials": fids, "orientation_tag": tag, "cell_nits": CELL_NITS}


def code_bits_for(i):
    """16 cells: [1, gray(11..0), parity(gray 0-5), parity(gray 6-11), 1]."""
    g = i ^ (i >> 1)
    bits = [(g >> (CODE_BITS - 1 - b)) & 1 for b in range(CODE_BITS)]
    p_lo = sum(bits[CODE_BITS - 6:]) & 1
    p_hi = sum(bits[:CODE_BITS - 6]) & 1
    return [1] + bits + [p_lo, p_hi, 1]


def decode_bits(cells):
    """Inverse of code_bits_for; returns frame index or None if the check fails."""
    if len(cells) != CODE_BITS + 4 or cells[0] != 1 or cells[-1] != 1:
        return None
    bits = cells[1:1 + CODE_BITS]
    if (sum(bits[CODE_BITS - 6:]) & 1) != cells[CODE_BITS + 1] or (sum(bits[:CODE_BITS - 6]) & 1) != cells[CODE_BITS + 2]:
        return None
    g = 0
    for b in bits:
        g = (g << 1) | b
    n = 0
    while g:
        n ^= g
        g >>= 1
    return n


# ---------------------------------------------------------------- pixels
def rgb_nits_to_ycc10(rgb):
    r, g, b = (float(pq(c)) for c in rgb)
    y = 0.2627 * r + 0.6780 * g + 0.0593 * b
    cb = (b - y) / 1.8814
    cr = (r - y) / 1.4746
    return (int(round(64 + 876 * y)), int(round(512 + 896 * cb)), int(round(512 + 896 * cr)))


def base_planes(L):
    Y = np.full((H, W), 64, dtype=np.uint16)
    Cb = np.full((H // 2, W // 2), 512, dtype=np.uint16)
    Cr = np.full((H // 2, W // 2), 512, dtype=np.uint16)

    def fill(box, rgb):
        x0, y0, x1, y1 = box
        yv, cbv, crv = rgb_nits_to_ycc10(rgb)
        Y[y0:y1, x0:x1] = yv
        Cb[y0 // 2:y1 // 2, x0 // 2:x1 // 2] = cbv
        Cr[y0 // 2:y1 // 2, x0 // 2:x1 // 2] = crv

    for p in L["patches"]:
        fill(p["box"], p["rgb"])
    x0, y0, x1, y1 = L["ramp"]["box"]
    lo, hi = L["ramp"]["pq_range"]
    ramp = np.linspace(lo, hi, x1 - x0)
    Y[y0:y1, x0:x1] = np.round(64 + 876 * ramp).astype(np.uint16)[None, :]
    for f in L["fiducials"] + [L["orientation_tag"]]:
        fill(f, (FID_NITS,) * 3)
    return Y, Cb, Cr


def l1_stats(L):
    """L1 min/max/avg in 12-bit PQ over max(R',G',B'), code strip assumed half on."""
    Y, _, _ = base_planes(L)
    # Gray/colour patches: use max(R',G',B') per patch weighted by area.
    tot = W * H
    acc = 0.0
    mx = 0.0
    for p in L["patches"]:
        x0, y0, x1, y1 = p["box"]
        v = max(float(pq(c)) for c in p["rgb"])
        acc += v * (x1 - x0) * (y1 - y0)
        mx = max(mx, v)
    x0, y0, x1, y1 = L["ramp"]["box"]
    lo, hi = L["ramp"]["pq_range"]
    acc += (lo + hi) / 2 * (x1 - x0) * (y1 - y0)
    v = float(pq(FID_NITS))
    for f in L["fiducials"] + [L["orientation_tag"]]:
        acc += v * (f[2] - f[0]) * (f[3] - f[1])
    for c in L["code_cells"]:
        acc += 0.5 * float(pq(CELL_NITS)) * (c[2] - c[0]) * (c[3] - c[1])
    return 0, int(round(mx * 4095)), int(round(acc / tot * 4095))


def write_frames(out):
    L = layout()
    Y, Cb, Cr = base_planes(L)
    on = rgb_nits_to_ycc10((CELL_NITS,) * 3)[0]
    cb_bytes, cr_bytes = Cb.tobytes(), Cr.tobytes()
    for i in range(N_FRAMES):
        for bit, (x0, y0, x1, y1) in zip(code_bits_for(i), L["code_cells"]):
            Y[y0:y1, x0:x1] = on if bit else 64
        out.write(Y.tobytes())
        out.write(cb_bytes)
        out.write(cr_bytes)


# ---------------------------------------------------------------- enhancement layer (p7fel_el)
EL_W, EL_H = W // 2, H // 2
EL_FLAT = 512          # = nlq_offset of fel_orig.bin, i.e. zero residual
EL_GAIN = 0.17         # target luma change in PQ code value, fraction of the patch's own 10-bit Y
EL_MAX_DELTA10 = 120   # cap in 10-bit codes: the NLQ range is +-511 12-bit codes (= +-127.75 10-bit)
# Every other grey patch from 10 to 1000 nit, plus two colour patches. The rest are in-frame controls.
EL_PATCHES = ["g10", "g100", "g400", "g1000", "red", "cyan"]


def el_design():
    """Per target patch: BL Y, wanted 10-bit delta, EL code. fel_orig.bin NLQ (all components):
    nlq_offset 512, vdr_in_max 0.125, slope 2048 @ denom 23, threshold 0, vdr 12 bit. The composer's
    inverse NLQ then gives residual = (|EL-512| - 1/2) * 2048 >> 11 = |EL-512| - 1 VDR 12-bit codes
    (= 1/4 of a code in the 10-bit output), assuming the BL->VDR luma map is identity-scaled
    (poly c0=0, c1=1); that is checked empirically, not assumed."""
    out = []
    for p in layout()["patches"]:
        if p["name"] not in EL_PATCHES:
            continue
        y10 = rgb_nits_to_ycc10(p["rgb"])[0]
        d10 = min(int(round(EL_GAIN * y10)), EL_MAX_DELTA10, 940 - y10)
        d12 = 4 * d10
        out.append({"name": p["name"], "box": p["box"], "bl_y10": y10, "delta10": d10,
                    "delta_pct": round(100.0 * d10 / y10, 2), "el_code": EL_FLAT + d12 + 1})
    return out


def write_el_frames(out):
    A = np.full((EL_H, EL_W), EL_FLAT, dtype=np.uint16)
    B = A.copy()
    for d in el_design():
        x0, y0, x1, y1 = (v // 2 for v in d["box"])
        B[y0:y1, x0:x1] = d["el_code"]
    chroma = np.full((EL_H // 2) * (EL_W // 2), EL_FLAT, dtype=np.uint16).tobytes()
    fa = A.tobytes() + chroma + chroma
    fb = B.tobytes() + chroma + chroma
    for i in range(N_FRAMES):
        out.write(fb if phase_of(i) == "B" else fa)


# ---------------------------------------------------------------- RPU configs
NEUTRAL_TRIM = dict(trim_slope=2048, trim_offset=2048, trim_power=2048,
                    trim_chroma_weight=2048, trim_saturation_gain=2048, ms_weight=2048)
# Darker and nearly monochrome: slope 0.625, offset -1/16, power 1.375, saturation -0.5.
EXTREME_TRIM = dict(trim_slope=512, trim_offset=1792, trim_power=3584,
                    trim_chroma_weight=2048, trim_saturation_gain=0, ms_weight=2048)
TRIM_TARGETS = [100, 600, 1000, 4000]


def shots():
    """(start, duration, phase) covering the timeline."""
    out = [(0, PREROLL, "A")]
    for k in range(N_PHASES):
        s = PREROLL + k * PHASE_LEN
        out.append((s, PHASE_LEN, phase_of(s)))
    return out


def rpu_config(variant):
    L = layout()
    mn, mx, avg = l1_stats(L)
    cfg = {
        "cm_version": "V29",
        "profile": "8.1",
        "length": N_FRAMES,
        "level6": {"max_display_mastering_luminance": 10000, "min_display_mastering_luminance": 1,
                   "max_content_light_level": 10000, "max_frame_average_light_level": 400},
        "shots": [],
    }
    for start, dur, ph in shots():
        blocks = []
        if variant == "l1":
            peak = 2081 if ph == "A" else 4095
            blocks.append({"Level1": {"min_pq": mn, "max_pq": peak, "avg_pq": min(avg, peak)}})
        else:
            blocks.append({"Level1": {"min_pq": mn, "max_pq": mx, "avg_pq": avg}})
            trim = EXTREME_TRIM if (variant == "l2" and ph == "B") else NEUTRAL_TRIM
            for t in TRIM_TARGETS:
                blocks.append({"Level2": dict(target_max_pq=pq12(t), **trim)})
        cfg["shots"].append({"start": start, "duration": dur, "metadata_blocks": blocks})
    return cfg


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "layout":
        L = layout()
        L["l1"] = dict(zip(["min_pq", "max_pq", "avg_pq"], l1_stats(L)))
        json.dump(L, sys.stdout, indent=1)
    elif cmd == "frames":
        write_frames(sys.stdout.buffer)
    elif cmd == "el-frames":
        write_el_frames(sys.stdout.buffer)
    elif cmd == "el-design":
        json.dump(el_design(), sys.stdout, indent=1)
    elif cmd == "rpu-json" and len(sys.argv) == 3 and sys.argv[2] in ("l1", "l2", "null"):
        json.dump(rpu_config(sys.argv[2]), sys.stdout, indent=1)
    else:
        sys.exit(__doc__)
