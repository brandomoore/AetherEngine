#!/usr/bin/env python3
"""Cut a phone recording into one piece per arm using the harness's wall-clock log, then run
analyze.py on each piece with its own label (no reliance on counting runs in order).

  cut.py REC.MOV LOG [--sync VIDEO_S=HH:MM:SS.S] [--slates] [--out DIR]

LOG is the devicectl console log (sequence_*.log) or the app's pulled pulse-log.txt; both carry
'[Pulse] wall=<epoch> ...' lines. The video's wall-clock start comes from its QuickTime creationdate
(1 s resolution). For sub-second accuracy, read the UTC clock on a slate frame (--slates writes one
still per slate into DIR) and pass --sync <seconds into the video>=<clock shown>.
"""
import argparse
import datetime as dt
import importlib.util
import json
import re
import subprocess
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
HAVE_PIL = importlib.util.find_spec("PIL") is not None  # the per-arm plot needs Pillow
PAD = 1.0  # seconds kept either side of an arm; analyze.py drops undecodable frames anyway


def parse_iso_time(raw):
    """ISO 8601 to epoch seconds. `datetime.fromisoformat` takes `Z` and `+0100` (no colon) only from
    Python 3.11, and the system Python on macOS is older, so normalise both before parsing."""
    raw = raw.strip()
    if raw.endswith(("Z", "z")):
        raw = raw[:-1] + "+00:00"
    raw = re.sub(r"([+-]\d{2})(\d{2})$", r"\1:\2", raw)   # +0100 -> +01:00
    raw = re.sub(r"([+-]\d{2})$", r"\1:00", raw)           # +01 -> +01:00
    # Python <= 3.10 also wants 0, 3 or 6 fractional digits.
    raw = re.sub(r"\.(\d+)", lambda m: "." + (m.group(1) + "000000")[:6], raw, count=1)
    parsed = dt.datetime.fromisoformat(raw)
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=dt.timezone.utc)
    return parsed.timestamp()


def video_start(rec):
    out = subprocess.run(["ffprobe", "-v", "error", "-show_entries", "format_tags", "-of", "json", rec],
                         capture_output=True, text=True, check=True).stdout
    tags = json.loads(out)["format"].get("tags", {})
    raw = tags.get("com.apple.quicktime.creationdate") or tags.get("creation_time")
    if not raw:
        return None
    return parse_iso_time(raw)


def parse_log(path):
    events = []
    for line in Path(path).read_text(errors="replace").splitlines():
        m = re.search(r"\[Pulse\] wall=([\d.]+) t=[\d.]+ (.*)", line)
        if m and (float(m.group(1)), m.group(2)) not in events[-3:]:  # console echoes the app's own log lines
            events.append((float(m.group(1)), m.group(2)))
    if not events:
        sys.exit(f"no '[Pulse] wall=' lines in {path} (log from an older build?)")
    arms, slates, open_ = [], [], {}
    for wall, msg in events:
        if m := re.match(r"slate (\S+)", msg):
            slates.append((wall, m.group(1)))
        elif m := re.match(r"arm (\S+) start mode=(\S+) url=(\S+)", msg):
            open_ = {"label": m.group(1), "mode": m.group(2), "clip": m.group(3), "start": wall}
        elif (m := re.match(r"arm (\S+) end", msg)) and open_:
            open_["end"] = wall
            arms.append(open_)
            open_ = {}
    return arms, slates


def sync_offset(spec, day_of):
    vsec, clock = spec.split("=")
    h, m, s = clock.replace("UTC", "").strip().split(":")
    midnight = dt.datetime.fromtimestamp(day_of, dt.timezone.utc).replace(hour=0, minute=0, second=0,
                                                                          microsecond=0).timestamp()
    return midnight + int(h) * 3600 + int(m) * 60 + float(s) - float(vsec)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("recording")
    ap.add_argument("log")
    ap.add_argument("--sync", help="VIDEO_SECONDS=HH:MM:SS.S read off a slate frame")
    ap.add_argument("--slates", action="store_true", help="only dump one still per slate, then stop")
    ap.add_argument("--out", default=None, help="output dir (default <recording>_arms next to the recording)")
    ap.add_argument("--scale", type=int, default=None, help="passed to analyze.py")
    a = ap.parse_args()

    rec = a.recording
    out = Path(a.out or Path(rec).with_suffix("").as_posix() + "_arms")
    out.mkdir(parents=True, exist_ok=True)
    arms, slates = parse_log(a.log)
    t0 = video_start(rec)
    if a.sync:
        t0 = sync_offset(a.sync, t0 if t0 is not None else arms[0]["start"])
    elif t0 is None:
        sys.exit("recording has no creation date; pass --sync")
    print(f"video starts at {dt.datetime.fromtimestamp(t0, dt.timezone.utc):%H:%M:%S.%f}"[:-3] + " UTC"
          + (" (from --sync)" if a.sync else " (from creationdate, ±1 s)"))

    if a.slates:
        for n, (wall, label) in enumerate(slates):
            v = wall - t0 + 2.5  # mid-slate
            p = out / f"slate{n + 1:02d}_{label}_{v:.1f}s.png"
            subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{v:.2f}", "-i", rec, "-frames:v", "1",
                            "-vf", "scale=1280:-2", str(p)], check=True)
            print(f"slate {label}: video {v:.1f}s -> {p}")
        print("read the clock on one still, then rerun with --sync <video seconds>=<clock>")
        return

    summary = []
    for n, arm in enumerate(arms):
        lo = max(0.0, arm["start"] - t0 - PAD)
        dur = arm["end"] - arm["start"] + 2 * PAD
        tag = f"{n + 1:02d}_{arm['label']}"
        clip = out / f"{tag}.mov"
        subprocess.run(["ffmpeg", "-v", "error", "-y", "-ss", f"{lo:.2f}", "-i", rec, "-t", f"{dur:.2f}",
                        "-map", "0:v:0", "-c", "copy", str(clip)], check=True)
        cmd = [sys.executable, str(HERE / "analyze.py"), str(clip), "--arms", arm["label"],
               "--json", str(out / f"{tag}.json")]
        if HAVE_PIL:
            cmd += ["--png", str(out / f"{tag}.png")]
        if a.scale:
            cmd += ["--scale", str(a.scale)]
        print(f"\n=== {tag}  {arm['mode']} {arm['clip']}  video {lo:.1f}s +{dur:.1f}s ===", flush=True)
        r = subprocess.run(cmd)
        runs = []
        if r.returncode == 0 and (out / f"{tag}.json").exists():
            runs = json.loads((out / f"{tag}.json").read_text())
        summary.append({"arm": arm["label"], "mode": arm["mode"], "clip": arm["clip"],
                        "video_start": round(lo, 2), "duration": round(dur, 2),
                        "runs": [{k: v for k, v in x.items() if not isinstance(v, (list, dict))}
                                 for x in runs]})
    (out / "summary.json").write_text(json.dumps(summary, indent=1))
    print("\narm   mode       verdict(s)")
    for s in summary:
        v = ", ".join(f"{x.get('verdict')}({x.get('n_sig')})" for x in s["runs"]) or "no run decoded"
        print(f"{s['arm']:<5} {s['mode']:<10} {v}")


if __name__ == "__main__":
    main()
