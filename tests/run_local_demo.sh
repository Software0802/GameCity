#!/bin/bash
# 本机一键演示：起一个专用无头服务器，再开一个（或两个）带窗口的客户端。
#
#   tests/run_local_demo.sh            # 一个客户端（阵营 A）
#   tests/run_local_demo.sh --two      # 两个客户端（A 和 B），各自独立身份文件
#   DEMO_PACE=1.0 tests/run_local_demo.sh   # 正式节奏（默认 0.05：升档约 6 秒，便于观看）
#
# 关闭客户端窗口后脚本会用 stop 文件优雅停掉服务器（存档后退出）。
# 存档和身份文件在 ./.demo/ 下，删掉该目录即重新开局。
set -u
cd "$(dirname "$0")/.." || exit 1
export PATH="/opt/homebrew/bin:$PATH"
GODOT=${GODOT:-godot}
PORT=${DEMO_PORT:-24567}
PACE=${DEMO_PACE:-0.05}
ROUND=${DEMO_ROUND_SECONDS:-604800}
DEMO=./.demo
mkdir -p "$DEMO/save"

command -v "$GODOT" >/dev/null || { echo "godot not on PATH (brew install --cask godot)"; exit 1; }
[ -f .godot/global_script_class_cache.cfg ] || "$GODOT" --headless --path . --import >/dev/null 2>&1

echo "server: port $PORT pace $PACE save-dir $DEMO/save (log: $DEMO/server.log)"
"$GODOT" --headless --path . res://server/main.tscn -- \
	--port "$PORT" --pace "$PACE" --round-seconds "$ROUND" \
	--save-dir "$DEMO/save" --save-interval 10 --status-file "$DEMO/status.json" \
	> "$DEMO/server.log" 2>&1 &
SERVER_PID=$!
trap 'touch "$DEMO/save/stop"; sleep 2; kill "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null' EXIT

for _ in 1 2 3 4 5 6 7 8 9 10; do grep -q 'Server ready' "$DEMO/server.log" 2>/dev/null && break; sleep 0.5; done
grep -q 'Server ready' "$DEMO/server.log" || { echo "server did not start:"; tail -n 20 "$DEMO/server.log"; exit 1; }

echo "controls: WASD/edge pan, wheel zoom, toolbar 1-8, LMB cast, drag paints, RMB/Esc cancel"
echo "note: keep both windows at least partly visible; a fully hidden window gets throttled by macOS"
# Windows are staggered and shrunk so neither fully covers the other (an occluded window
# can be put to sleep by macOS and its connection then crawls). A starts last and ends frontmost.
B_PID=""
if [ "${1:-}" = "--two" ]; then
	"$GODOT" --path . --position 480,300 --resolution 1024x640 -- --join 127.0.0.1 --port "$PORT" --name PlayerB --identity "$DEMO/identity-B.cfg" > "$DEMO/client-B.log" 2>&1 &
	B_PID=$!
	sleep 2
fi
"$GODOT" --path . --position 40,60 --resolution 1024x640 -- --join 127.0.0.1 --port "$PORT" --name PlayerA --identity "$DEMO/identity-A.cfg" > "$DEMO/client-A.log" 2>&1 &
A_PID=$!
wait "$A_PID" 2>/dev/null
[ -n "$B_PID" ] && wait "$B_PID" 2>/dev/null
echo "clients closed; stopping server (saves first)"
