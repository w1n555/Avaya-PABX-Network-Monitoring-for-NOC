#!/usr/bin/env python3
"""One-time download of Hong Kong raster tiles for offline IIS.

Saves:  <site>/map/tiles/{z}/{x}/{y}.jpg
Source: Esri World Street Map (OSM.org tile server blocks bulk download).
Runtime: Leaflet reads local files only — no CDN.

Zoom 10–14. Re-run to refresh the basemap.
"""
from __future__ import annotations

import math
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

SITE = Path(__file__).resolve().parents[1]
OUT = SITE / "map" / "tiles"
# HK: Island + Kowloon + NT + Lantau
SOUTH, WEST = 22.13, 113.82
NORTH, EAST = 22.57, 114.50
Z_MIN, Z_MAX = 10, 14
# Do NOT use tile.openstreetmap.org — bulk fetch is blocked (HTTP 403
# "Access blocked" PNG). One-time cache from Esri raster tiles instead.
# URL order is z/y/x. Saved locally as {z}/{x}/{y}.jpg for Leaflet.
URL = (
    "https://server.arcgisonline.com/ArcGIS/rest/services/"
    "World_Street_Map/MapServer/tile/{z}/{y}/{x}"
)
UA = "CM-NOC-HK-offline/1.0 (intranet; one-time Hong Kong extract)"
SLEEP = 0.28
BLOCKED_SIZES = {6987, 103, 415}  # known OSM/Carto block / empty stubs


def lon2x(lon: float, z: int) -> int:
    return int(math.floor((lon + 180.0) / 360.0 * (1 << z)))


def lat2y(lat: float, z: int) -> int:
    lat = max(min(lat, 85.05112878), -85.05112878)
    r = math.radians(lat)
    return int(
        math.floor(
            (1.0 - math.log(math.tan(r) + 1.0 / math.cos(r)) / math.pi) / 2.0 * (1 << z)
        )
    )


def plan() -> list[tuple[int, int, int]]:
    jobs: list[tuple[int, int, int]] = []
    for z in range(Z_MIN, Z_MAX + 1):
        x0, x1 = lon2x(WEST, z), lon2x(EAST, z)
        y0, y1 = lat2y(NORTH, z), lat2y(SOUTH, z)
        if y0 > y1:
            y0, y1 = y1, y0
        for x in range(x0, x1 + 1):
            for y in range(y0, y1 + 1):
                jobs.append((z, x, y))
    return jobs


def main() -> int:
    jobs = plan()
    OUT.mkdir(parents=True, exist_ok=True)
    done = skip = fail = 0
    opener = urllib.request.build_opener()
    opener.addheaders = [("User-Agent", UA)]
    print(f"tiles {len(jobs)} → {OUT}", flush=True)
    for i, (z, x, y) in enumerate(jobs, 1):
        dest = OUT / str(z) / str(x) / f"{y}.jpg"
        if dest.is_file() and dest.stat().st_size > 800:
            skip += 1
            if i % 200 == 0:
                print(f"  {i}/{len(jobs)} skip={skip} ok={done} fail={fail}", flush=True)
            continue
        dest.parent.mkdir(parents=True, exist_ok=True)
        url = URL.format(z=z, x=x, y=y)
        try:
            with opener.open(url, timeout=30) as r:
                data = r.read()
            if len(data) < 800 or len(data) in BLOCKED_SIZES:
                raise RuntimeError(f"blocked/empty tile {len(data)} bytes")
            if data[:3] != b"\xff\xd8\xff" and data[:8] != b"\x89PNG\r\n\x1a\n":
                raise RuntimeError(f"not an image ({data[:8]!r})")
            dest.write_bytes(data)
            done += 1
        except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as exc:
            fail += 1
            print(f"  FAIL {z}/{x}/{y} {exc}", flush=True)
        if i % 50 == 0:
            print(f"  {i}/{len(jobs)} skip={skip} ok={done} fail={fail}", flush=True)
        time.sleep(SLEEP)
    print(f"done skip={skip} ok={done} fail={fail}", flush=True)
    return 1 if fail and done == 0 else 0


if __name__ == "__main__":
    sys.exit(main())
