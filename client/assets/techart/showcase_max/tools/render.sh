#!/usr/bin/env bash
# Dev helper: render one or more shots with optional feature overrides.
#   render.sh <out_dir> <shots,comma> [fx k=v,k=v] [scale] [warmup]
# Example: render.sh /tmp/r s01_hero_day gi=none 0.5 40
set -euo pipefail
cd "$(dirname "$0")/../../../../.."
export PATH="/opt/homebrew/bin:$PATH"
OUT="$1"
SHOTS="$2"
FX="${3:-}"
SCALE="${4:-1.0}"
WARM="${5:-60}"
TAG="${6:-}"
CITY_SHOWCASE_CAPTURE=1 CITY_SHOWCASE_SHOTS="$SHOTS" CITY_SHOWCASE_OUT="$OUT" CITY_SHOWCASE_FX="$FX" \
CITY_SHOWCASE_SCALE="$SCALE" CITY_SHOWCASE_WARMUP="$WARM" CITY_SHOWCASE_TAG="$TAG" \
	godot --path . --rendering-method forward_plus --disable-vsync res://client/techart_showcase.tscn 2>&1 \
	| grep -v "^\s*$" | grep -v "^Godot Engine\|^Metal "
