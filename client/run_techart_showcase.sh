#!/usr/bin/env bash
# Forward+ showcase (techart-showcase worker). Does not edit project.godot.
#   ./client/run_techart_showcase.sh                      interactive window (keys 1-6 shots, T tier)
#   CITY_SHOWCASE_CAPTURE=1 ./client/run_techart_showcase.sh   render all shots into showcase_max/preview/
# See scripts/showcase_main.gd for the other CITY_SHOWCASE_* variables.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH="/opt/homebrew/bin:$PATH"
exec godot --path . --rendering-method forward_plus --disable-vsync res://client/techart_showcase.tscn "$@"
