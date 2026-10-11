#!/usr/bin/env python3
"""Build a tiny HEVC/PQ MP4 that carries a real ST 2094-40 (HDR10+) T.35 SEI.

Layout of the payload follows libavutil/hdr_dynamic_metadata.c's parser exactly, so
`ffprobe -show_frames` reporting "HDR Dynamic Metadata SMPTE2094-40" is the proof the
fixture is genuine rather than a byte pattern that merely looks like one.
"""
import subprocess, sys, base64, os

class BitWriter:
    def __init__(self):
        self.bits = []
    def u(self, n, value):
        for i in range(n - 1, -1, -1):
            self.bits.append((value >> i) & 1)
    def bytes(self):
        while len(self.bits) % 8:
            self.bits.append(0)
        out = bytearray()
        for i in range(0, len(self.bits), 8):
            byte = 0
            for b in self.bits[i:i + 8]:
                byte = (byte << 1) | b
            out.append(byte)
        return bytes(out)


def hdr10plus_payload():
    w = BitWriter()
    w.u(8, 0)            # application_version
    w.u(2, 1)            # num_windows
    w.u(27, 500 * 10000) # targeted_system_display_maximum_luminance (den 10000)
    w.u(1, 0)            # targeted_system_display_actual_peak_luminance_flag
    # window 0
    for maxscl in (17000, 16000, 15000):
        w.u(17, maxscl)
    w.u(17, 12000)       # average_maxrgb
    percentiles = [(1, 1000), (5, 2000), (10, 3000), (25, 5000), (50, 8000),
                   (75, 12000), (90, 16000), (95, 18000), (99, 20000)]
    w.u(4, len(percentiles))
    for pct, val in percentiles:
        w.u(7, pct)
        w.u(17, val)
    w.u(10, 100)         # fraction_bright_pixels
    w.u(1, 0)            # mastering_display_actual_peak_luminance_flag
    # window 0 tone mapping
    w.u(1, 1)            # tone_mapping_flag
    w.u(12, 1000)        # knee_point_x
    w.u(12, 1200)        # knee_point_y
    anchors = [100, 200, 300, 400, 500, 600, 700, 800, 900]
    w.u(4, len(anchors))
    for a in anchors:
        w.u(10, a)
    w.u(1, 0)            # color_saturation_mapping_flag
    body = w.bytes()
    header = bytes([0xB5, 0x00, 0x3C, 0x00, 0x01, 0x04])
    return header + body


def emulation_prevent(rbsp):
    out = bytearray()
    zeros = 0
    for b in rbsp:
        if zeros >= 2 and b <= 3:
            out.append(0x03)
            zeros = 0
        out.append(b)
        zeros = zeros + 1 if b == 0 else 0
    return bytes(out)


def sei_nal(payload):
    rbsp = bytearray()
    rbsp.append(0x4E)  # nal_unit_type 39 (PREFIX_SEI_NUT) << 1
    rbsp.append(0x01)  # nuh_layer_id 0, temporal_id_plus1 1
    rbsp.append(0x04)  # payload_type: user_data_registered_itu_t_t35
    size = len(payload)
    while size >= 255:
        rbsp.append(0xFF)
        size -= 255
    rbsp.append(size)
    rbsp += payload
    rbsp.append(0x80)  # rbsp_trailing_bits
    return b"\x00\x00\x00\x01" + emulation_prevent(bytes(rbsp))


def split_annexb(data):
    starts = []
    i = 0
    while i < len(data) - 3:
        if data[i] == 0 and data[i + 1] == 0 and data[i + 2] == 1:
            starts.append((i, 3))
            i += 3
        elif (i < len(data) - 4 and data[i] == 0 and data[i + 1] == 0
              and data[i + 2] == 0 and data[i + 3] == 1):
            starts.append((i, 4))
            i += 4
        else:
            i += 1
    nals = []
    for idx, (pos, sclen) in enumerate(starts):
        end = starts[idx + 1][0] if idx + 1 < len(starts) else len(data)
        nals.append(data[pos:end])
    return nals


def nal_type(nal):
    body = nal.lstrip(b"\x00")
    body = body[1:]  # drop the 0x01 of the start code
    return (body[0] >> 1) & 0x3F


def main():
    out_dir = sys.argv[1]
    plain = os.path.join(out_dir, "plain.mp4")
    annexb = os.path.join(out_dir, "plain.hevc")
    injected = os.path.join(out_dir, "injected.hevc")
    fixture = os.path.join(out_dir, "hdr10plus-hevc.mp4")

    subprocess.run([
        "ffmpeg", "-y", "-v", "error",
        "-f", "lavfi", "-i", "color=c=black:s=64x64:r=10:d=0.2",
        "-c:v", "libx265", "-pix_fmt", "yuv420p10le",
        "-x265-params", "log-level=none:info=0:keyint=1:min-keyint=1:colorprim=9:transfer=16:colormatrix=9",
        "-color_primaries", "bt2020", "-color_trc", "smpte2084", "-colorspace", "bt2020nc",
        "-frames:v", "2", plain,
    ], check=True)

    subprocess.run([
        "ffmpeg", "-y", "-v", "error", "-i", plain,
        "-c:v", "copy", "-bsf:v", "hevc_mp4toannexb", "-f", "hevc", annexb,
    ], check=True)

    data = open(annexb, "rb").read()
    payload = hdr10plus_payload()
    sei = sei_nal(payload)
    out = bytearray()
    for nal in split_annexb(data):
        if nal_type(nal) <= 31:  # VCL: the SEI must precede the slice in its access unit
            out += sei
        out += nal
    open(injected, "wb").write(bytes(out))

    subprocess.run([
        "ffmpeg", "-y", "-v", "error", "-f", "hevc", "-i", injected,
        "-c:v", "copy", "-tag:v", "hvc1", fixture,
    ], check=True)

    probe = subprocess.run([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_frames",
        "-show_entries", "frame=side_data_list", fixture,
    ], capture_output=True, text=True)
    ok = "SMPTE2094-40" in probe.stdout or "HDR10+" in probe.stdout
    print(probe.stdout[:600])
    print("SIZE:", os.path.getsize(fixture), "bytes")
    print("HDR10+ PARSED BY FFMPEG:", ok)
    if ok:
        print("BASE64_START")
        print(base64.b64encode(open(fixture, "rb").read()).decode())
        print("BASE64_END")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
