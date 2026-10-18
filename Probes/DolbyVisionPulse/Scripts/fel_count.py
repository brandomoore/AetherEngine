#!/usr/bin/env python3
"""Profile 7 FEL counter clip: the base layer and the enhancement layer each carry their own frame number.

Same pattern, timeline and RPU variants as gen_pulse.py, plus readable counters for filming:

  top band     "BL 0123" in base-layer pixels | "EL 0123" in enhancement-layer residual only
  slow row     "BL S005" | "EL S005"  (frame // 24, readable when the fast numbers blur on camera)
  code cells   BL: gen_pulse.py's Gray-code row; EL: a second row below it, drawn in residual only

Every counter sits on a dark grey panel (~20 nit, Y 380); a lit stroke is +120 10-bit codes (~90 nit), which
is the largest positive residual fel_orig.bin's NLQ can carry (|EL-512| - 1 12-bit codes, vdr_in_max 0.125).
Composed properly, both sides show the same number. A MEL player (residual ignored) shows an empty EL panel and
an EL code row that does not decode. A player pairing the wrong EL frame shows a different EL number.

Both layers use the same fixed GOP (b-adapt 0, 3 B-frames, pyramid) so EL and BL POC order match. build.sh
encodes and muxes the clips (p7fel_count_{null,l2}.mp4, count_mel.mp4).

Usage: fel_count.py frames     -> raw 3840x2160 yuv420p10le BL frames on stdout (feed x265)
       fel_count.py el-frames  -> raw 1920x1080 yuv420p10le EL frames on stdout (feed x265)
       fel_count.py layout     -> panel/cell boxes as JSON
       fel_count.py read <composed.yuv> [bitdepth=10]  -> per frame: BL code, EL code (decoded back from cells)
                                                   of raw 3840x2160 yuv420p frames from any composer
"""
import json
import sys

import numpy as np

import gen_pulse as gp

W, H, N_FRAMES = gp.W, gp.H, gp.N_FRAMES
EL_W, EL_H = W // 2, H // 2
PANEL_Y = 380          # PQ 0.36, ~20 nit, neutral
LIFT10 = 120           # stroke lift in 10-bit codes (BL pixels or EL residual)
EL_ON = gp.EL_FLAT + 4 * LIFT10 + 1
SLOW = 24              # slow counter period in frames

# 5x7 glyphs, rows top to bottom
FONT = {
    "0": ["01110", "10001", "10011", "10101", "11001", "10001", "01110"],
    "1": ["00100", "01100", "00100", "00100", "00100", "00100", "01110"],
    "2": ["01110", "10001", "00001", "00010", "00100", "01000", "11111"],
    "3": ["11111", "00010", "00100", "00010", "00001", "10001", "01110"],
    "4": ["00010", "00110", "01010", "10010", "11111", "00010", "00010"],
    "5": ["11111", "10000", "11110", "00001", "00001", "10001", "01110"],
    "6": ["00110", "01000", "10000", "11110", "10001", "10001", "01110"],
    "7": ["11111", "00001", "00010", "00100", "01000", "01000", "01000"],
    "8": ["01110", "10001", "10001", "01110", "10001", "10001", "01110"],
    "9": ["01110", "10001", "10001", "01111", "00001", "00010", "01100"],
    "B": ["11110", "10001", "10001", "11110", "10001", "10001", "11110"],
    "L": ["10000", "10000", "10000", "10000", "10000", "10000", "11111"],
    "E": ["11111", "10000", "10000", "11110", "10000", "10000", "11111"],
    "S": ["01111", "10000", "10000", "01110", "00001", "00001", "11110"],
    " ": ["00000"] * 7,
}


def text_mask(s, scale):
    """Boolean mask of s, glyph advance 6 cells (1 cell spacing)."""
    m = np.zeros((7 * scale, (6 * len(s) - 1) * scale), dtype=bool)
    for k, ch in enumerate(s):
        g = np.array([[c == "1" for c in row] for row in FONT[ch]])
        m[:, 6 * k * scale:(6 * k + 5) * scale] = np.kron(g, np.ones((scale, scale), dtype=bool))
    return m


def layout():
    base = gp.layout()
    # Top band between the fiducials, slow row between the ramp and the BL cells, EL cells below the BL cells.
    # All coordinates even, so the half-resolution EL boxes are exact.
    top = {"bl": [520, 160, 1980, 380], "el": [2100, 160, 3560, 380], "scale": 28}
    slow = {"bl": [520, 1566, 1980, 1714], "el": [2100, 1566, 3560, 1714], "scale": 16}
    el_cells = [[c[0], 1940, c[2], 2080] for c in base["code_cells"]]
    panel = [el_cells[0][0] - 20, 1930, el_cells[-1][2] + 20, 2090]
    return {"base": base, "top": top, "slow": slow, "bl_cells": base["code_cells"], "el_cells": el_cells,
            "el_cells_panel": panel, "panel_y": PANEL_Y, "lift10": LIFT10, "el_on": EL_ON}


def place(box, mask):
    """Top-left of mask centred in box, even."""
    x0, y0, x1, y1 = box
    h, w = mask.shape
    return (x0 + (x1 - x0 - w) // 2) & ~1, (y0 + (y1 - y0 - h) // 2) & ~1


def labels(i):
    return f"{i:04d}", f"S{i // SLOW:03d}"


def write_frames(out):
    L = layout()
    Y, Cb, Cr = gp.base_planes(L["base"])
    for band in ("top", "slow"):
        for side in ("bl", "el"):
            x0, y0, x1, y1 = L[band][side]
            Y[y0:y1, x0:x1] = PANEL_Y
    x0, y0, x1, y1 = L["el_cells_panel"]
    Y[y0:y1, x0:x1] = PANEL_Y
    on = gp.rgb_nits_to_ycc10((gp.CELL_NITS,) * 3)[0]
    cb_bytes, cr_bytes = Cb.tobytes(), Cr.tobytes()
    clean = Y.copy()
    for i in range(N_FRAMES):
        Y[:] = clean
        fast, slow = labels(i)
        for band, s in (("top", "BL " + fast), ("slow", "BL " + slow)):
            m = text_mask(s, L[band]["scale"])
            px, py = place(L[band]["bl"], m)
            Y[py:py + m.shape[0], px:px + m.shape[1]][m] = PANEL_Y + LIFT10
        for bit, (x0, y0, x1, y1) in zip(gp.code_bits_for(i), L["bl_cells"]):
            Y[y0:y1, x0:x1] = on if bit else 64
        out.write(Y.tobytes())
        out.write(cb_bytes)
        out.write(cr_bytes)


def write_el_frames(out):
    L = layout()
    Y = np.full((EL_H, EL_W), gp.EL_FLAT, dtype=np.uint16)
    chroma = np.full((EL_H // 2) * (EL_W // 2), gp.EL_FLAT, dtype=np.uint16).tobytes()
    for i in range(N_FRAMES):
        Y[:] = gp.EL_FLAT
        fast, slow = labels(i)
        for band, s in (("top", "EL " + fast), ("slow", "EL " + slow)):
            sc = L[band]["scale"]
            m = text_mask(s, sc // 2)
            px, py = place(L[band]["el"], text_mask(s, sc))
            Y[py // 2:py // 2 + m.shape[0], px // 2:px // 2 + m.shape[1]][m] = EL_ON
        for bit, (x0, y0, x1, y1) in zip(gp.code_bits_for(i), L["el_cells"]):
            if bit:
                Y[y0 // 2:y1 // 2, x0 // 2:x1 // 2] = EL_ON
        out.write(Y.tobytes())
        out.write(chroma)
        out.write(chroma)


def read_cells(Yf, cells, thr):
    """Decode a code row from a full-resolution luma plane in 10-bit codes (centre 50% of each cell)."""
    bits = []
    for x0, y0, x1, y1 in cells:
        dx, dy = (x1 - x0) // 4, (y1 - y0) // 4
        bits.append(int(np.median(Yf[y0 + dy:y1 - dy, x0 + dx:x1 - dx]) > thr))
    return gp.decode_bits(bits)


def read(path, depth=10):
    L = layout()
    on = gp.rgb_nits_to_ycc10((gp.CELL_NITS,) * 3)[0]
    fsize = W * H * 3 // 2
    data = np.memmap(path, dtype=np.uint16, mode="r")
    for k in range(len(data) // fsize):
        Yf = data[k * fsize:k * fsize + W * H].reshape(H, W).astype(np.float64) / (1 << (depth - 10))
        bl = read_cells(Yf, L["bl_cells"], (64 + on) / 2)
        el = read_cells(Yf, L["el_cells"], PANEL_Y + LIFT10 / 2)
        print(k, bl, el, "no-EL" if el is None else "ok" if bl == el else "MISMATCH")


if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else ""
    if cmd == "frames":
        write_frames(sys.stdout.buffer)
    elif cmd == "el-frames":
        write_el_frames(sys.stdout.buffer)
    elif cmd == "layout":
        json.dump({k: v for k, v in layout().items() if k != "base"}, sys.stdout, indent=1)
    elif cmd == "read" and len(sys.argv) in (3, 4):
        read(sys.argv[2], int(sys.argv[3]) if len(sys.argv) == 4 else 10)
    else:
        sys.exit(__doc__)
