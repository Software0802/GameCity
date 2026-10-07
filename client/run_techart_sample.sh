#!/usr/bin/env bash
# One-shot Forward+ preview of the M1 interchange sample.
# Does not edit project.godot. Headless smoke stays on GL Compatibility.
set -euo pipefail
cd "$(dirname "$0")/.."
exec godot --path . --rendering-method forward_plus \
	res://client/techart_sample.tscn "$@"
