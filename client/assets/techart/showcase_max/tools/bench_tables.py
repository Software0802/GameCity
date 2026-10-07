#!/usr/bin/env python3
"""Print markdown tables from docs/bench_results.json (written by CITY_SHOWCASE_BENCH=1)."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
path = os.path.join(HERE, "..", "docs", "bench_results.json")
rows = json.load(open(path))


def get(group, tag):
    return rows.get("%s/%s" % (group, tag))


def table(group, base_tag=None, cols=("tag", "shot", "draw_ms", "delta", "vram_mb")):
    items = [r for k, r in rows.items() if r["group"] == group]
    base = get(group, base_tag)["draw_ms"] if base_tag and get(group, base_tag) else None
    print("| 项 | 镜头 | draw_ms | 相对基线 | TIME_PROCESS | 显存 MB | 参数 |")
    print("| --- | --- | ---: | ---: | ---: | ---: | --- |")
    for r in items:
        d = "" if base is None else "%+.1f" % (r["draw_ms"] - base)
        print("| %s | %s | %.1f | %s | %.1f | %.0f | `%s` |" % (r["tag"], r["shot"], r["draw_ms"], d, r.get("proc_ms", 0), r["vram_mb"], json.dumps(r["fx"])))


if __name__ == "__main__":
    groups = sys.argv[1:] or sorted({r["group"] for r in rows.values()})
    bases = {"gi": "none", "fx": None, "aa": "none", "shadow": "atlas_8192", "lights": "omni_0", "sky": "panorama_clamped", "glass": "both_off"}
    for g in groups:
        print("\n### %s\n" % g)
        table(g, bases.get(g))
