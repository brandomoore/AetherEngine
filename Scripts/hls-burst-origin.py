#!/usr/bin/env python3
r"""A live HLS origin whose DELIVERY RHYTHM is scripted (AE#684).

`aetherctl hlsfixture` publishes on a metronome, and a metronome is the one thing no IPTV origin is:
the defect this was written for only exists when a delivery arrives later than the segment is long.
This serves a sliding playlist over pre-cut TS segments and publishes segment k at

    end of segment k  -  what was prefilled  +  delays[k % len(delays)]

seconds after it starts, so the mean cadence stays the segment duration (the origin never falls
behind real time) and the jitter is the delay cycle. `--freeze-at K --freeze-seconds F` holds
everything from segment K on for F seconds: an outage, after which the backlog lands at once.
Every request is one stderr line stamped with seconds since start.

    # 720x576 25 fps, 2 s GOPs, 6 s segments, a white frame and a 40 ms beep on every whole second
    ffmpeg -f lavfi -i "color=c=black:s=720x576:r=25:d=600,drawbox=x=0:y=0:w=720:h=576:color=white:\
t=fill:enable='lt(mod(t,1),0.039)',format=yuv420p" \
           -f lavfi -i "aevalsrc='if(lt(mod(t,1),0.04),0.8*sin(2*PI*1000*t),0)':s=48000:d=600:c=stereo" \
           -c:v libx264 -preset ultrafast -profile:v main -g 50 -keyint_min 50 -sc_threshold 0 -bf 0 \
           -b:v 1500k -maxrate 1500k -bufsize 3000k -x264-params nal-hrd=cbr \
           -c:a aac -b:a 128k -ar 48000 -f hls -hls_time 6 -hls_list_size 0 -hls_segment_type mpegts \
           -hls_flags independent_segments -hls_segment_filename 'seg6/seg%d.ts' seg6/out.m3u8

    Scripts/hls-burst-origin.py --dir seg6 --delays 0,0.3,2.6,0.2,0.6,2.4,0.1,0.5 &
    aetherctl play --live --live-ingest --fast-zap --seconds 180 http://127.0.0.1:8684/live.m3u8

Threaded and HTTP/1.0 on purpose: the ingest fetches up to four segments at once, and a
keep-alive connection would hide which request paid for what.
"""
import argparse, os, sys, threading, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

ap = argparse.ArgumentParser()
ap.add_argument("--dir", required=True)
ap.add_argument("--port", type=int, default=8684)
ap.add_argument("--dur", type=float, default=6.0)
ap.add_argument("--durs", default="", help="comma list of per-segment durations, cycled (overrides --dur)")
ap.add_argument("--target-duration", type=int, default=6)
ap.add_argument("--window", type=int, default=6)
ap.add_argument("--prefill", type=int, default=6, help="segments already published at start")
ap.add_argument("--delays", default="0", help="comma list of per-segment publish delays, cycled")
ap.add_argument("--freeze-at", type=int, default=-1)
ap.add_argument("--freeze-seconds", type=float, default=0)
ap.add_argument("--latency-ms", type=float, default=0, help="delay before every response header")
ap.add_argument("--rate-kbps", type=float, default=0, help="link rate shared by all in-flight responses")
args = ap.parse_args()

delays = [float(x) for x in args.delays.split(",")]
count = len([f for f in os.listdir(args.dir) if f.startswith("seg") and f.endswith(".ts")])
durs = [float(x) for x in args.durs.split(",")] if args.durs else [args.dur]
seg_dur = [durs[k % len(durs)] for k in range(count)]
ends = []
acc = 0.0
for k in range(count):
    acc += seg_dur[k]
    ends.append(acc)
prefill_end = ends[args.prefill - 1] if args.prefill > 0 else 0.0
publish = []
for k in range(count):
    p = 0.0 if k < args.prefill else ends[k] - prefill_end + delays[k % len(delays)]
    publish.append(p)
if args.freeze_at >= 0:
    thaw = publish[args.freeze_at] + args.freeze_seconds
    for k in range(args.freeze_at, count):
        publish[k] = max(publish[k], thaw)
for k in range(1, count):
    publish[k] = max(publish[k], publish[k - 1])

t0 = time.monotonic()
lock = threading.Lock()


def log(msg):
    with lock:
        sys.stderr.write("%8.3f %s\n" % (time.monotonic() - t0, msg))
        sys.stderr.flush()


rate_lock = threading.Lock()
rate_clock = [0.0]


def send_paced(wfile, body):
    """One virtual clock for every response: a second connection gets no bandwidth of its own."""
    if args.rate_kbps <= 0:
        wfile.write(body)
        return
    chunk = 16 * 1024
    for i in range(0, len(body), chunk):
        part = body[i:i + chunk]
        with rate_lock:
            now = time.monotonic()
            start = max(now, rate_clock[0])
            rate_clock[0] = start + len(part) * 8 / (args.rate_kbps * 1000.0)
            due = rate_clock[0]
        wait = due - time.monotonic()
        if wait > 0:
            time.sleep(wait)
        wfile.write(part)


def playlist():
    now = time.monotonic() - t0
    last = -1
    for k in range(count):
        if publish[k] <= now:
            last = k
        else:
            break
    first = max(0, last - args.window + 1)
    lines = ["#EXTM3U", "#EXT-X-VERSION:3", "#EXT-X-TARGETDURATION:%d" % args.target_duration,
             "#EXT-X-MEDIA-SEQUENCE:%d" % first]
    for k in range(first, last + 1):
        lines.append("#EXTINF:%.3f," % seg_dur[k])
        lines.append("seg%d.ts" % k)
    return ("\n".join(lines) + "\n").encode(), last


class H(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"

    def log_message(self, *a):
        pass

    def do_GET(self):
        if args.latency_ms > 0:
            time.sleep(args.latency_ms / 1000.0)
        path = self.path.split("?")[0]
        if path.endswith(".m3u8"):
            body, last = playlist()
            log("REQ playlist last=seg%d" % last)
            self.send_response(200)
            self.send_header("Content-Type", "application/vnd.apple.mpegurl")
        elif path.endswith(".ts"):
            name = os.path.basename(path)
            try:
                with open(os.path.join(args.dir, name), "rb") as f:
                    body = f.read()
            except OSError:
                log("REQ %s 404" % name)
                self.send_response(404)
                self.end_headers()
                return
            log("REQ %s" % name)
            self.send_response(200)
            self.send_header("Content-Type", "video/mp2t")
        else:
            self.send_response(404)
            self.end_headers()
            return
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        try:
            send_paced(self.wfile, body)
        except OSError:
            pass


gaps = [publish[k] - publish[k - 1] for k in range(args.prefill, min(count, args.prefill + 40))]
log("origin up: %d segments, publish gaps (first 40 after prefill): %s" % (
    count, " ".join("%.1f" % g for g in gaps)))
ThreadingHTTPServer(("127.0.0.1", args.port), H).serve_forever()
