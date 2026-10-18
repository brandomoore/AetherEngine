#!/usr/bin/env python3
"""Fake phone recording for testing analyze.py: the l2 clip filmed at 30 fps with perspective,
vignetting and noise. Runs are given as 'pulse' (B phases darken, 3-frame latency) or 'steady'.

Needs pulse_l2.mp4 from build.sh (in $PULSE_OUT, default ../out).

Usage: sim_recording.py out.mp4 pulse,steady
"""
import os
import subprocess
import sys

import numpy as np

import gen_pulse as G

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.environ.get("PULSE_OUT", os.path.join(HERE, "..", "out"))
OW, OH = 1280, 720
CAM_FPS = 30.0


def clip_luma():
    cmd = ["ffmpeg", "-v", "error", "-i", os.path.join(OUT, "pulse_l2.mp4"), "-vf", "scale=960:540", "-pix_fmt", "gray",
           "-f", "rawvideo", "-"]
    raw = subprocess.check_output(cmd)
    return np.frombuffer(raw, np.uint8).reshape(-1, 540, 960).astype(np.float32) / 255.0


def warp_maps():
    # Camera sees the screen slightly rotated and keystoned.
    src = np.array([[0, 0], [960, 0], [0, 540], [960, 540]], float)
    dst = np.array([[150, 110], [1150, 80], [170, 650], [1130, 690]], float)
    A = []
    for (x, y), (u, v) in zip(dst, src):
        A.append([x, y, 1, 0, 0, 0, -u * x, -u * y, -u])
        A.append([0, 0, 0, x, y, 1, -v * x, -v * y, -v])
    Hm = np.linalg.svd(np.array(A))[2][-1].reshape(3, 3)
    gx, gy = np.meshgrid(np.arange(OW), np.arange(OH))
    P = Hm @ np.stack([gx.ravel(), gy.ravel(), np.ones(gx.size)])
    u = (P[0] / P[2]).reshape(OH, OW)
    v = (P[1] / P[2]).reshape(OH, OW)
    inside = (u >= 0) & (u < 959) & (v >= 0) & (v < 539)
    return np.clip(u, 0, 959).astype(int), np.clip(v, 0, 539).astype(int), inside


def main():
    out, runs = sys.argv[1], sys.argv[2].split(",")
    clip = clip_luma()
    u, v, inside = warp_maps()
    vign = 1 - 0.25 * (((np.arange(OW) - OW / 2) / OW) ** 2 + ((np.arange(OH)[:, None] - OH / 2) / OH) ** 2)
    rng = np.random.default_rng(1)
    enc = subprocess.Popen(["ffmpeg", "-v", "error", "-y", "-f", "rawvideo", "-pix_fmt", "gray", "-s", f"{OW}x{OH}",
                            "-r", "30", "-i", "-", "-c:v", "libx264", "-crf", "18", "-pix_fmt", "yuv420p", out],
                           stdin=subprocess.PIPE)

    def emit(img):
        img = img * vign + rng.normal(0, 0.01, img.shape) + 0.02
        enc.stdin.write((np.clip(img, 0, 1) * 255).astype(np.uint8).tobytes())

    for kind in runs:
        for _ in range(60):  # 2 s of UI slate
            emit(np.full((OH, OW), 0.3))
        clip_fps = G.FPS_NUM / G.FPS_DEN
        for k in range(int(G.N_FRAMES / clip_fps * CAM_FPS)):
            i = min(int(k / CAM_FPS * clip_fps), G.N_FRAMES - 1)
            frame = clip[i]
            if kind == "pulse" and G.phase_of(max(i - 3, 0)) == "B":
                frame = 0.85 * frame ** 1.2
            img = np.where(inside, frame[v, u], 0.0)
            emit(img)
    enc.stdin.close()
    enc.wait()


if __name__ == "__main__":
    main()
