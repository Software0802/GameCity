#!/usr/bin/env python3
"""Download the CC0 Poly Haven assets used by showcase_max.

Usage: python3 fetch_polyhaven.py [asset_id ...]
Textures land in ../textures/<id>_{diff,arm,nor}.jpg (albedo, AO/rough/metal packed, GL normal).
HDRIs land in ../hdri/<id>_2k.hdr. Every map is <= 2K; resolutions below are chosen to stay
inside the 150 MB budget. Source: https://api.polyhaven.com/files/<asset_id>
"""
import json
import os
import sys
import urllib.request

HERE = os.path.dirname(os.path.abspath(__file__))
TEX = os.path.join(HERE, "..", "textures")
HDR = os.path.join(HERE, "..", "hdri")

# id: (diffuse res, arm res, normal res)
MATERIALS = {
    "asphalt_02": ("2k", "2k", "1k"),
    "concrete_tiles_02": ("2k", "1k", "1k"),
    "concrete_floor_worn_001": ("2k", "1k", "1k"),
    "brick_wall_006": ("2k", "2k", "1k"),
    "beige_wall_002": ("2k", "1k", "1k"),
    "factory_wall": ("1k", "1k", "1k"),
    "corrugated_iron_02": ("1k", "1k", "1k"),
    "concrete_wall_008": ("1k", "1k", "1k"),
    "tarred_gravel": ("1k", "1k", "1k"),
    "roof_09": ("1k", "1k", "1k"),
    "leafy_grass": ("2k", "1k", "1k"),
    "floor_pattern_02": ("1k", "1k", "1k"),
    "gravel_embedded_concrete": ("1k", "1k", "1k"),
    "grey_plaster": ("1k", "1k", "1k"),
    "rectangular_facade_tiles": ("1k", "1k", "1k"),
}
HDRIS = {
    "kloofendal_48d_partly_cloudy_puresky": "2k",
    "kloppenheim_06_puresky": "2k",
}


def get(url, dest):
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return
    print("  ->", os.path.basename(dest))
    req = urllib.request.Request(url, headers={"User-Agent": "gamecity-showcase/1.0"})
    with urllib.request.urlopen(req, timeout=120) as r, open(dest, "wb") as f:
        f.write(r.read())


def files(asset):
    url = "https://api.polyhaven.com/files/" + asset
    req = urllib.request.Request(url, headers={"User-Agent": "gamecity-showcase/1.0"})
    with urllib.request.urlopen(req, timeout=60) as r:
        return json.load(r)


def main():
    os.makedirs(TEX, exist_ok=True)
    os.makedirs(HDR, exist_ok=True)
    only = set(sys.argv[1:])
    for aid, (d, a, n) in MATERIALS.items():
        if only and aid not in only:
            continue
        print(aid)
        j = files(aid)
        get(j["Diffuse"][d]["jpg"]["url"], os.path.join(TEX, "%s_diff.jpg" % aid))
        get(j["arm"][a]["jpg"]["url"], os.path.join(TEX, "%s_arm.jpg" % aid))
        get(j["nor_gl"][n]["jpg"]["url"], os.path.join(TEX, "%s_nor.jpg" % aid))
    for aid, res in HDRIS.items():
        if only and aid not in only:
            continue
        print(aid)
        j = files(aid)
        get(j["hdri"][res]["hdr"]["url"], os.path.join(HDR, "%s_%s.hdr" % (aid, res)))


if __name__ == "__main__":
    main()
