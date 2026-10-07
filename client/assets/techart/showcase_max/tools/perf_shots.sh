#!/usr/bin/env bash
# Per-shot frame times, one Godot process per shot and tier (a fresh process keeps TIME_PROCESS meaningful).
# Output: docs/perf_shots.jsonl (one JSON row per shot and tier). Images go to a throw-away directory.
#   perf_shots.sh [out_dir_for_images]
set -euo pipefail
cd "$(dirname "$0")/../../../../.."
export PATH="/opt/homebrew/bin:$PATH"
IMG="${1:-/tmp/showcase_perf_images}"
OUT="client/assets/techart/showcase_max/docs/perf_shots.jsonl"
mkdir -p "$IMG"
rm -f "$OUT"
for tier in shot interactive; do
	for shot in s01_hero_day s01_hero_dusk s02_far s03_near_block s00_cinematic_day s00_cinematic_dusk; do
		CITY_SHOWCASE_CAPTURE=1 CITY_SHOWCASE_PROFILE="$tier" CITY_SHOWCASE_SHOTS="$shot" \
		CITY_SHOWCASE_OUT="$IMG" CITY_SHOWCASE_TAG="_$tier" CITY_SHOWCASE_PERF="$OUT" \
			godot --path . --rendering-method forward_plus --disable-vsync res://client/techart_showcase.tscn 2>&1 \
			| grep -E "^\[capture\]"
	done
done
