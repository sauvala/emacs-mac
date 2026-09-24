#!/usr/bin/env python3
"""Measure the undrawn band below Emacs's drawing in a screen recording.

Usage: resize-band.py RECORDING [X]

Reads a vertical strip at device-pixel column X (default 300) of each
frame.  Below the lowest green internal-border row (resize-band.el),
rows of the layer background #202020 are window area that Emacs has
not drawn yet.  Prints how many frames show a band wider than 4 px and
the widest band.  Needs ffmpeg.
"""
import subprocess, sys

path = sys.argv[1]
x = int(sys.argv[2]) if len(sys.argv) > 2 else 300
probe = subprocess.run(['ffprobe', '-v', 'error', '-select_streams', 'v:0',
                        '-show_entries', 'stream=height', '-of', 'csv=p=0',
                        path], capture_output=True, text=True, check=True)
H, W = int(probe.stdout.strip()), 20
raw = subprocess.run(['ffmpeg', '-v', 'error', '-i', path, '-vf',
                      f'crop={W}:{H}:{x}:0', '-f', 'rawvideo',
                      '-pix_fmt', 'rgb24', '-'],
                     capture_output=True, check=True).stdout
bands = []
for i in range(len(raw) // (W * H * 3)):
    frame = raw[i * W * H * 3:(i + 1) * W * H * 3]
    def px(y):
        o = (y * W + W // 2) * 3
        return frame[o], frame[o + 1], frame[o + 2]
    green = [y for y in range(H)
             if (lambda p: p[1] > 150 and p[0] < 110 and p[2] < 110)(px(y))]
    if not green:
        continue
    y, band = max(green) + 1, 0
    while y < H and all(abs(c - 0x20) < 8 for c in px(y)):
        band += 1
        y += 1
    bands.append(band)
print(f"{path}: {len(bands)} frames, {sum(b > 4 for b in bands)} with an "
      f"undrawn band over 4 px, widest {max(bands, default=0)} px")
