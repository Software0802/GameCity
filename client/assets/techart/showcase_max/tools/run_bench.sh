#!/usr/bin/env bash
# Feature ablation bench: one Godot process per entry (state never accumulates), cool-down between processes.
# Results: docs/bench_results.json, crops/thumbnails: preview/compare/. Tables: tools/bench_tables.py.
#   run_bench.sh [group ...]     default: every group in scripts/bench_plan.gd
#   COOL=45 RESUME=1 run_bench.sh   cool-down seconds between processes (default 10); RESUME=1 skips finished entries
set -euo pipefail
cd "$(dirname "$0")/../../../../.."
export PATH="/opt/homebrew/bin:$PATH"
COOL="${COOL:-10}"
entries=$(CITY_SHOWCASE_BENCH=1 CITY_SHOWCASE_BENCH_LIST=1 godot --path . --rendering-method forward_plus res://client/techart_showcase.tscn 2>&1 | grep "^BENCH_ENTRY" | sed 's/^BENCH_ENTRY //')
for e in $entries; do
	g="${e%%/*}"
	if [ "$#" -gt 0 ]; then
		match=0
		for want in "$@"; do [ "$want" = "$g" ] && match=1; done
		[ "$match" = 0 ] && continue
	fi
	if [ "${RESUME:-0}" = "1" ] && grep -q "\"$e\"" client/assets/techart/showcase_max/docs/bench_results.json 2>/dev/null; then
		continue
	fi
	CITY_SHOWCASE_BENCH=1 CITY_SHOWCASE_BENCH_ONLY="$e" \
		godot --path . --rendering-method forward_plus --disable-vsync res://client/techart_showcase.tscn 2>&1 \
		| grep -E "^\[bench\]|SCRIPT ERROR|^ERROR:" || true
	sleep "$COOL"
done
