#!/usr/bin/env python3
"""Static file server with HTTP Range support (AVPlayer / AVURLAsset require byte ranges;
python -m http.server ignores Range and AVFoundation fails with -11850 / -12939).

Usage: serve.py PORT BIND_ADDR [DIR]   (serves DIR, default ../out next to this script)
"""
import http.server
import os
import re
import sys


class RangeHandler(http.server.SimpleHTTPRequestHandler):
    def send_head(self):
        path = self.translate_path(self.path)
        rng = self.headers.get("Range")
        if not rng or os.path.isdir(path) or not os.path.exists(path):
            return super().send_head()
        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        size = os.path.getsize(path)
        if not m or m.groups() == ("", ""):
            # A multi-range, `bytes=-` or otherwise unparsable header: RFC 9110 says to ignore it.
            return super().send_head()
        a, b = m.groups()
        if a == "":
            start, end = max(0, size - int(b)), size - 1
        else:
            start, end = int(a), (int(b) if b else size - 1)
        end = min(end, size - 1)
        if start > end:
            self.send_response(416)
            self.send_header("Content-Range", f"bytes */{size}")
            self.end_headers()
            return None
        f = open(path, "rb")
        f.seek(start)
        self.send_response(206)
        self.send_header("Content-Type", self.guess_type(path))
        self.send_header("Content-Range", f"bytes {start}-{end}/{size}")
        self.send_header("Content-Length", str(end - start + 1))
        self.end_headers()
        self._remaining = end - start + 1
        return f

    def end_headers(self):
        self.send_header("Accept-Ranges", "bytes")
        super().end_headers()

    def copyfile(self, source, outputfile):
        remaining = getattr(self, "_remaining", None)
        if remaining is None:
            return super().copyfile(source, outputfile)
        while remaining > 0:
            chunk = source.read(min(65536, remaining))
            if not chunk:
                break
            outputfile.write(chunk)
            remaining -= len(chunk)
        self._remaining = None

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    port, bind = int(sys.argv[1]), sys.argv[2]
    root = sys.argv[3] if len(sys.argv) > 3 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "out")
    os.chdir(root)
    http.server.ThreadingHTTPServer((bind, port), RangeHandler).serve_forever()
