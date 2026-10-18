#!/usr/bin/env python3
"""Turn a directory of cut arms (cut.py output) into the tables and figure used in the write-up.

Reads ARMS_DIR/summary.json and every NN_<ARM>.json (analyze.py --json output) and prints:
  1. "Change in camera brightness, B vs A" - per patch, rel as a signed integer percent.
     A non-PULSE arm shows 0 unless the patch has |t| > 5, then the signed percent.
     Rows whose mode starts with "engine" (the engine/FEL route) are bold.
  2. a significance line per arm (patches with |t| > 5, strongest t).
  3. "absolute levels" (phase A level, 3 decimals) for selected arms and patches.
Optionally writes the markdown (--md) and the all-arms trace figure (--png, via analyze.png).

  report.py recordings/take_arms --md report.md --png report.png
"""
import argparse
import json
import math
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

MINUS = "−"


def pct(rel):
    """Signed integer percent, round-half-away, real minus sign, '+' for positives, '0' for zero."""
    p = int(math.floor(abs(rel) * 100 + 0.5))
    if p == 0:
        return "0"
    return ("+" if rel > 0 else MINUS) + str(p)


def cell(res, name):
    p = res["patches"].get(name)
    if p is None:
        return "n/a"
    if res["verdict"] != "PULSE" and abs(p["t"]) <= 5:
        return "0"
    return pct(p["rel"])


def header(name):
    if name.startswith("g") and name[1:].replace(".", "", 1).isdigit():
        return f"{name[1:]} nit"
    return name


def load(arms_dir):
    summary = json.load(open(os.path.join(arms_dir, "summary.json")))
    rows, seen = [], {}
    for n, s in enumerate(summary, 1):
        arm = s["arm"]
        k = seen[arm] = seen.get(arm, 0) + 1
        label = arm if k == 1 else (f"{arm} (repeat)" if k == 2 else f"{arm} (repeat {k - 1})")
        path = os.path.join(arms_dir, f"{n:02d}_{arm}.json")
        runs = json.load(open(path)) if os.path.exists(path) else []
        rows.append({"arm": arm, "label": label, "mode": s.get("mode", ""), "runs": runs})
    return rows


def build(rows, patches, level_arms, level_patches):
    out = ["Change in camera brightness, B vs A (percent):", ""]
    out.append("| Run | Verdict | " + " | ".join(header(p) for p in patches) + " |")
    out.append("|---|---|" + "---|" * len(patches))
    notes = []
    for r in rows:
        bold = r["mode"].startswith("engine")
        if not r["runs"]:
            out.append(f"| {r['label']} | no run decoded |" + " |" * len(patches))
            notes.append(f"- {r['label']}: no run decoded")
            continue
        for k, res in enumerate(r["runs"], 1):
            lab = r["label"] + (f" run {k}" if len(r["runs"]) > 1 else "")
            lab = f"**{lab}**" if bold else lab
            out.append(f"| {lab} | {res['verdict']} | " + " | ".join(cell(res, p) for p in patches) + " |")
            top = max(res["patches"].items(), key=lambda kv: abs(kv[1]["t"]))
            notes.append(f"- {lab}: {res['n_sig']} patches with |t|>5, strongest t = "
                         f"{top[1]['t']:+.1f} ({top[0]})")
    out += [""] + notes + ["", "Absolute levels (phase A):", ""]
    out.append("| Run | " + " | ".join(header(p) for p in level_patches) + " |")
    out.append("|---|" + "---|" * len(level_patches))
    for r in rows:
        if r["arm"] not in level_arms or not r["runs"]:
            continue
        res = r["runs"][0]
        lab = r["label"] + (" (phase A)" if res["verdict"] == "PULSE" else "")
        vals = [f"{res['patches'][p]['level']:.3f}" if p in res["patches"] else "n/a" for p in level_patches]
        out.append(f"| {lab} | " + " | ".join(vals) + " |")
    return "\n".join(out) + "\n"


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("arms_dir")
    ap.add_argument("--md", help="also write the markdown here")
    ap.add_argument("--png", help="write the all-arms trace figure here")
    ap.add_argument("--levels-arms", default="V1,V2,T,S", help="arms for the absolute-levels table")
    ap.add_argument("--patches", default="g10,g100,g400,g1000,g4000,g10000")
    ap.add_argument("--levels-patches", default="g10,g100,g1000,g10000")
    a = ap.parse_args()
    rows = load(a.arms_dir)
    md = build(rows, a.patches.split(","), set(a.levels_arms.split(",")), a.levels_patches.split(","))
    print(md)
    if a.md:
        open(a.md, "w").write(md)
    if a.png:
        import analyze
        results = [dict(res, arm=r["label"]) for r in rows for res in r["runs"]]
        if results:
            analyze.png(results, a.png)


if __name__ == "__main__":
    main()
