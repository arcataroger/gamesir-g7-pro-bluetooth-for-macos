#!/usr/bin/env python3
"""Remove SVG <path> elements that lie entirely inside a normalized rectangle. Used to drop the wordmark.
usage: strip-region.py file.svg x0 y0 x1 y1   (fractions of the viewBox)"""
import re, sys
f, x0, y0, x1, y1 = sys.argv[1], *map(float, sys.argv[2:6])
s = open(f).read()
W, H = map(float, re.search(r'viewBox="0 0 ([\d.]+) ([\d.]+)"', s).groups())
def inside(d):
    n = [float(v) for v in re.findall(r'-?\d+\.?\d*', d)]; pts = list(zip(n[0::2], n[1::2]))
    return bool(pts) and all(x0*W <= x <= x1*W and y0*H <= y <= y1*H for x, y in pts)
out, removed = [], 0
for line in s.splitlines():
    m = re.match(r'<path d="([^"]+)"', line)
    if m and inside(m.group(1)): removed += 1; continue
    out.append(line)
open(f, "w").write("\n".join(out) + "\n"); print("removed", removed, "paths")
