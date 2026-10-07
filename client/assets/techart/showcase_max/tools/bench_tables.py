#!/usr/bin/env python3
"""Print markdown tables from docs/bench_results.json (written by CITY_SHOWCASE_BENCH=1)."""
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
rows = json.load(open(os.path.join(HERE, "..", "docs", "bench_results.json")))


def table(group):
    items = [r for r in rows.values() if r["group"] == group]
    print("| 项 | 镜头 | draw_ms | 基线 A / B | delta_ms | TIME_PROCESS | 显存 MB | 实际生效 | 参数 |")
    print("| --- | --- | ---: | ---: | ---: | ---: | ---: | --- | --- |")
    for r in items:
        eff = r.get("effective", {})
        print("| %s | %s | %.1f | %.1f / %.1f | %+.1f | %.1f | %.0f | msaa=%s taa=%s scale=%.2f | `%s` |" % (
            r["tag"], r["shot"], r["draw_ms"], r.get("ref_a", 0), r.get("ref_b", 0), r.get("delta_ms", 0),
            r.get("proc_ms", 0), r["vram_mb"], eff.get("msaa_3d"), eff.get("taa"), eff.get("scale", 1.0), json.dumps(r["fx"])))


if __name__ == "__main__":
    for g in (sys.argv[1:] or sorted({r["group"] for r in rows.values()})):
        print("\n### %s\n" % g)
        table(g)
