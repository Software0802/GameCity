#!/usr/bin/env bash
# GameCity headless end-to-end smoke. One command, numbered steps, timings, non-zero exit on
# any failure, log tails on failure, random high port, mktemp workdir, no godot left behind.
# Step list, assertions, and the worker each step depends on: tests/README.md.
#
#   tests/run_smoke.sh [--skip-import] [--help]
#
# Knobs (environment):
#   GODOT                  godot binary (default: godot on PATH, /opt/homebrew/bin added)
#   SMOKE_ROUND_SECONDS    round length for steps 4-6 (default 60)
#   SMOKE_PACE             --pace for the servers (default 0.01)
#   SMOKE_START_TREASURY   --start-treasury for step 7 (default 60)
#   SMOKE_REQUIRE_ECONOMY  1 = a skipped step 7 counts as a failure (tighten after M2B)
#   SMOKE_KEEP             1 = keep the temp dir even when everything passes
#
# Steps 1-3 are gates: the run stops at the first failure. Steps 4-7 each report their own
# verdict and the run continues, so every missing server feature is named in one pass.
# Written for bash 3.2 (macOS /bin/bash): no mapfile, no associative arrays.

set -u
set -o pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT" || exit 2
export PATH="/opt/homebrew/bin:/usr/sbin:/usr/bin:/bin:$PATH"
GODOT="${GODOT:-godot}"

SMOKE_ROUND_SECONDS="${SMOKE_ROUND_SECONDS:-60}"
SMOKE_PACE="${SMOKE_PACE:-0.01}"
SMOKE_START_TREASURY="${SMOKE_START_TREASURY:-60}"
SMOKE_REQUIRE_ECONOMY="${SMOKE_REQUIRE_ECONOMY:-0}"
SMOKE_KEEP="${SMOKE_KEEP:-0}"
SKIP_IMPORT=0

for arg in "$@"; do
	case "$arg" in
		--skip-import) SKIP_IMPORT=1 ;;
		--help|-h) sed -n '2,20p' "$0"; exit 0 ;;
		*) echo "unknown argument: $arg" >&2; exit 2 ;;
	esac
done

# ---------------------------------------------------------------- bookkeeping

RUN_T0=$(date +%s)
TMPBASE="${TMPDIR:-/tmp}"
TMP="$(mktemp -d "${TMPBASE%/}/gamecity-smoke.XXXXXX")" || exit 2
LOGS="$TMP/logs"
mkdir -p "$LOGS"
PIDS=""
RESULTS=""
FAILED=0
STEP_NO=""
STEP_NAME=""
STEP_T0=0
STEP_LOGS=""
SERVER_PID=""
SPAWNED_PID=""
CLIENT_PID=""

log() { printf '%s\n' "$*"; }
now_s() { date +%s; }

step_begin() {
	STEP_NO=$1
	STEP_NAME=$2
	STEP_T0=$(now_s)
	STEP_LOGS=""
	log ""
	log "=== [$STEP_NO] $STEP_NAME"
}

record() {
	local status=$1 note=$2
	local dt=$(( $(now_s) - STEP_T0 ))
	RESULTS="${RESULTS}${STEP_NO}|${STEP_NAME}|${status}|${dt}s|${note}"$'\n'
	log "--- [$STEP_NO] $status (${dt}s) $note"
}

step_pass() { record PASS "$1"; }
step_skip() { record SKIP "$1"; }

step_fail() {
	FAILED=1
	record FAIL "$1"
	tail_logs $STEP_LOGS
}

# Steps 1-3 cannot be worked around: print, summarize, exit.
fatal_step() {
	step_fail "$1"
	finish
}

tail_logs() {
	local f
	for f in "$@"; do
		[ -f "$f" ] || continue
		log "----- tail -n 40 $f"
		tail -n 40 "$f" | sed 's/^/    /'
	done
}

watch_log() { STEP_LOGS="$STEP_LOGS $1"; }

finish() {
	local total=$(( $(now_s) - RUN_T0 ))
	log ""
	log "=== Summary (${total}s total, workdir $TMP)"
	printf '%-4s %-62s %-7s %5s  %s\n' "step" "name" "verdict" "time" "note"
	printf '%s' "$RESULTS" | while IFS='|' read -r no name status dt note; do
		[ -n "$no" ] || continue
		printf '%-4s %-62s %-7s %5s  %s\n' "$no" "$name" "$status" "$dt" "$note"
	done
	if [ "$FAILED" -ne 0 ]; then
		log "RESULT: FAIL (logs kept in $TMP)"
		exit 1
	fi
	log "RESULT: OK"
	exit 0
}

# ---------------------------------------------------------------- processes

alive() { kill -0 "$1" 2>/dev/null; }

# spawn <logfile> <cmd...>  -> SPAWNED_PID
spawn() {
	local logfile=$1
	shift
	"$@" > "$logfile" 2>&1 &
	SPAWNED_PID=$!
	PIDS="$PIDS $SPAWNED_PID"
}

# wait_exit <pid> <timeout_s>  -> 0 when the process exited, 1 when still running
wait_exit() {
	local pid=$1 limit=$2 half=0
	while alive "$pid"; do
		if [ "$half" -ge $((limit * 2)) ]; then
			return 1
		fi
		sleep 0.5
		half=$((half + 1))
	done
	return 0
}

# stop_pid <pid> [timeout_s]  -> 0 when it left on SIGTERM, 1 when SIGKILL was needed
stop_pid() {
	local pid=$1 limit=${2:-10}
	alive "$pid" || return 0
	kill -TERM "$pid" 2>/dev/null
	if wait_exit "$pid" "$limit"; then
		return 0
	fi
	kill -KILL "$pid" 2>/dev/null
	wait_exit "$pid" 3
	return 1
}

kill_all() {
	local p
	for p in $PIDS; do
		alive "$p" && kill -TERM "$p" 2>/dev/null
	done
	sleep 1
	for p in $PIDS; do
		alive "$p" && kill -KILL "$p" 2>/dev/null
	done
	# Anything still referencing our workdir is ours (every server and client got a path in it).
	if command -v pgrep >/dev/null 2>&1; then
		local strays
		strays=$(pgrep -f "$TMP" 2>/dev/null || true)
		if [ -n "$strays" ]; then
			log "killing stray godot processes: $strays"
			kill -KILL $strays 2>/dev/null || true
		fi
	fi
}

cleanup() {
	local code=$?
	trap - EXIT INT TERM
	kill_all
	if [ "$code" -eq 0 ] && [ "$FAILED" -eq 0 ] && [ "$SMOKE_KEEP" != "1" ]; then
		rm -rf "$TMP"
	fi
	exit "$code"
}
trap cleanup EXIT
trap 'log "interrupted"; FAILED=1; exit 130' INT TERM

# wait_for_line <file> <ERE> <timeout_s>
wait_for_line() {
	local file=$1 re=$2 limit=$3 half=0
	while [ "$half" -lt $((limit * 2)) ]; do
		if [ -f "$file" ] && grep -Eq "$re" "$file"; then
			return 0
		fi
		sleep 0.5
		half=$((half + 1))
	done
	return 1
}

pick_port() {
	local p tries=0
	while [ "$tries" -lt 20 ]; do
		p=$(( 20000 + RANDOM % 20000 ))
		if ! command -v lsof >/dev/null 2>&1 || ! lsof -nP -iUDP:"$p" >/dev/null 2>&1; then
			echo "$p"
			return 0
		fi
		tries=$((tries + 1))
	done
	return 1
}

udp_busy() {
	command -v lsof >/dev/null 2>&1 || return 1
	lsof -nP -iUDP:"$1" >/dev/null 2>&1
}

# start_server <logfile> <args...>  -> SERVER_PID
start_server() {
	local logfile=$1
	shift
	spawn "$logfile" "$GODOT" --headless --path "$ROOT" res://server/main.tscn -- "$@"
	SERVER_PID=$SPAWNED_PID
	watch_log "$logfile"
}

# start_client <logfile> <args...>  -> CLIENT_PID (background)
start_client() {
	local logfile=$1
	shift
	spawn "$logfile" "$GODOT" --headless --path "$ROOT" res://client/smoke_client.tscn -- "$@"
	CLIENT_PID=$SPAWNED_PID
	watch_log "$logfile"
}

# run_client <logfile> <timeout_s> <args...>  -> exit code (124 on timeout)
run_client() {
	local logfile=$1 limit=$2
	shift 2
	start_client "$logfile" "$@"
	local pid=$CLIENT_PID
	if ! wait_exit "$pid" "$limit"; then
		kill -KILL "$pid" 2>/dev/null
		wait "$pid" 2>/dev/null
		return 124
	fi
	wait "$pid" 2>/dev/null
}

# ---------------------------------------------------------------- parsing

# field <file> <LINE_PREFIX> <key>  -> value of key= in the first matching line
field() {
	grep -m1 "^$2 " "$1" 2>/dev/null | tr ' ' '\n' | grep -m1 "^$3=" | cut -d= -f2-
}

# last_field <file> <LINE_PREFIX> <key>  -> value of key= in the last matching line
last_field() {
	grep "^$2 " "$1" 2>/dev/null | tail -n 1 | tr ' ' '\n' | grep -m1 "^$3=" | cut -d= -f2-
}

smoke_fail_line() { grep -m1 '^SMOKE_FAIL' "$1" 2>/dev/null || echo "(no SMOKE_FAIL line; exit $2)"; }

identity_token() {
	grep -E '^token=' "$1" 2>/dev/null | head -n 1 | sed -E 's/^token="?([^"]*)"?$/\1/'
}

# json_int <file> <key>  -> integer value or empty
json_int() {
	grep -Eo "\"$2\"[[:space:]]*:[[:space:]]*-?[0-9]+" "$1" 2>/dev/null | head -n 1 | grep -Eo -- '-?[0-9]+$'
}

mtime_s() {
	python3 -c 'import os,sys;print(int(os.path.getmtime(sys.argv[1])))' "$1" 2>/dev/null \
		|| stat -f %m "$1" 2>/dev/null \
		|| stat -c %Y "$1" 2>/dev/null
}

const_int() { # const_int <file> <NAME> <fallback>
	local v
	v=$(grep -Eo "const $2 := [0-9]+" "$1" 2>/dev/null | grep -Eo '[0-9]+$')
	echo "${v:-$3}"
}

MAP_SIZE=$(const_int shared/slice_constants.gd MAP_SIZE 128)
SPAWN_SIZE=$(const_int server/world_state.gd SPAWN_SIZE 8)

# Tile just outside the spawn corner, same rule as smoke_client.gd _tile_out().
tile_out_for() {
	case "$1" in
		1) echo "$((MAP_SIZE - SPAWN_SIZE - 1)),$((MAP_SIZE - SPAWN_SIZE))" ;;
		*) echo "$SPAWN_SIZE,0" ;;
	esac
}

tile_out2_for() {
	case "$1" in
		1) echo "$((MAP_SIZE - SPAWN_SIZE - 1)),$((MAP_SIZE - SPAWN_SIZE + 1))" ;;
		*) echo "$SPAWN_SIZE,1" ;;
	esac
}

# hint_for <logfiles...>  -> every worker delivery the client evidence points at
hint_for() {
	local hints=""
	if grep -q "round_ends_at_unix=0\|--round-seconds" "$@" 2>/dev/null; then
		hints="$hints; missing --round-seconds / round clock (server-core)"
	fi
	if grep -q "NO_HELLO_RPC" "$@" 2>/dev/null; then
		hints="$hints; missing GameNet.hello_rpc / WELCOME (server-core handshake)"
	fi
	if grep -q "NOT_AUTHENTICATED" "$@" 2>/dev/null; then
		hints="$hints; commands rejected NOT_AUTHENTICATED: WELCOME ordering (server-core)"
	fi
	if grep -q "no claim cost applied" "$@" 2>/dev/null; then
		hints="$hints; claims are free: economy not merged (sim-economy)"
	fi
	if [ -z "$hints" ]; then
		echo "see log tails"
	else
		echo "${hints#; }"
	fi
}

# missing_in_server <token...>  -> the tokens no file under server/ mentions (static probe)
missing_in_server() {
	local t out=""
	for t in "$@"; do
		grep -rq -- "$t" server/ 2>/dev/null || out="$out $t"
	done
	if [ -n "$out" ]; then
		echo " | server/ has no:$out"
	fi
}

log "GameCity smoke  root=$ROOT  workdir=$TMP  godot=$($GODOT --version 2>/dev/null | head -n 1)"
log "round=${SMOKE_ROUND_SECONDS}s pace=$SMOKE_PACE treasury=$SMOKE_START_TREASURY map=$MAP_SIZE spawn=$SPAWN_SIZE"

# ================================================================ 1 import

step_begin 1 "godot --headless --import"
if [ "$SKIP_IMPORT" = "1" ]; then
	step_skip "--skip-import"
else
	watch_log "$LOGS/01-import.log"
	"$GODOT" --headless --path "$ROOT" --import > "$LOGS/01-import.log" 2>&1
	rc=$?
	if [ $rc -ne 0 ]; then
		fatal_step "import exit $rc"
	fi
	n=$(grep -c "SCRIPT ERROR" "$LOGS/01-import.log" 2>/dev/null || true)
	if [ "${n:-0}" -gt 0 ]; then
		fatal_step "import printed $n SCRIPT ERROR line(s)"
	fi
	step_pass "exit 0"
fi

# ================================================================ 2 self-checks

# run_check <no> <script.gd> <OK token>; verdict by exit code, then the token must be present.
run_check() {
	step_begin "$1" "$2"
	local logf="$LOGS/$1-${2%.gd}.log"
	watch_log "$logf"
	"$GODOT" --headless --path "$ROOT" -s "res://server/$2" > "$logf" 2>&1
	local rc=$?
	if [ $rc -ne 0 ]; then
		fatal_step "exit $rc (expected 0 and $3)"
	fi
	if ! grep -q "^$3" "$logf"; then
		fatal_step "exit 0 but no $3 line"
	fi
	step_pass "$3"
}

run_check 2a shared_roundtrip_check.gd SHARED_OK
run_check 2b permission_check.gd PERMISSION_OK
run_check 2c save_roundtrip_check.gd SAVE_OK

if [ -f server/sim_check.gd ]; then
	run_check 2d sim_check.gd SIM_OK
else
	step_begin 2d "sim_check.gd"
	step_skip "server/sim_check.gd absent (sim-economy delivers it)"
fi

step_begin 2e "client script scan (main.tscn, smoke_client.tscn --quit-after 5)"
watch_log "$LOGS/2e-main.log" "$LOGS/2e-smoke.log"
"$GODOT" --headless --path "$ROOT" res://client/main.tscn --quit-after 5 > "$LOGS/2e-main.log" 2>&1
rc_main=$?
"$GODOT" --headless --path "$ROOT" res://client/smoke_client.tscn --quit-after 5 -- --join 127.0.0.1 --port 1 > "$LOGS/2e-smoke.log" 2>&1
rc_smoke=$?
n=$(cat "$LOGS/2e-main.log" "$LOGS/2e-smoke.log" | grep -c -E "SCRIPT ERROR|Parse Error|Failed to load script" || true)
if [ "${n:-0}" -gt 0 ]; then
	fatal_step "$n script error line(s)"
fi
if [ $rc_main -ne 0 ] || [ $rc_smoke -ne 0 ]; then
	fatal_step "exit main=$rc_main smoke=$rc_smoke"
fi
step_pass "no SCRIPT ERROR"

# ================================================================ 3 legacy path

step_begin 3 "legacy smoke (--smoke-host + --expect server_stop)"
P3=$(pick_port) || fatal_step "no free UDP port"
D3="$TMP/step3"
mkdir -p "$D3/save"
start_server "$LOGS/03-host.log" --port "$P3" --smoke-host --save-dir "$D3/save" --status-file "$D3/status.json"
wait_for_line "$LOGS/03-host.log" "Listen|status" 10 || log "host printed no Listen line in 10s; the client retries anyway"
run_client "$LOGS/03-client.log" 40 --join 127.0.0.1 --port "$P3" --expect server_stop --name legacy --identity-file "$D3/identity.cfg"
rc=$?
sleep 1
stop_pid "$SERVER_PID" 10 || log "host needed SIGKILL"
if [ $rc -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/03-client.log"; then
	fatal_step "client exit $rc: $(smoke_fail_line "$LOGS/03-client.log" $rc)"
fi
if ! grep -q 'MatchEnd: server_stop' "$LOGS/03-host.log"; then
	fatal_step "host log lacks 'MatchEnd: server_stop'"
fi
step_pass "SMOKE_OK + host MatchEnd: server_stop"

# ================================================================ 4 handshake and reconnect
# Steps 4, 5, and 6 share one server and one --save-dir so the restart (5) and the clock (6)
# run against the state built here. round_ends_at_unix must therefore survive the restart.

step_begin 4 "handshake + reconnect (two names, two identity files)"
P4=$(pick_port) || fatal_step "no free UDP port"
D4="$TMP/step4"
mkdir -p "$D4/save"
SERVER_ARGS=(--port "$P4" --pace "$SMOKE_PACE" --round-seconds "$SMOKE_ROUND_SECONDS" --free-build --save-dir "$D4/save" --status-file "$D4/status.json")
ID_A="$D4/identity-A.cfg"
ID_B="$D4/identity-B.cfg"
start_server "$LOGS/04-server.log" "${SERVER_ARGS[@]}"
SERVER_T0=$(now_s)
wait_for_line "$LOGS/04-server.log" "Listen|status" 10 || log "server printed no Listen line in 10s; clients retry anyway"
log "server pid=$SERVER_PID port=$P4 args: ${SERVER_ARGS[*]}"

# A joins first and stays online while B joins, leaves, and comes back.
start_client "$LOGS/04-A.log" --join 127.0.0.1 --port "$P4" --name Alice --identity-file "$ID_A" --scenario idle --hold-seconds 45
A_PID=$CLIENT_PID
wait_for_line "$LOGS/04-A.log" "^WELCOME |^NO_HELLO_RPC|^FACTION_ASSIGNED" 15 || log "A: no WELCOME/NO_HELLO_RPC within 15s"

run_client "$LOGS/04-B1.log" 40 --join 127.0.0.1 --port "$P4" --name Bob --identity-file "$ID_B" --scenario b --hold-seconds 2
rcB1=$?
FA=$(field "$LOGS/04-A.log" WELCOME faction)
FB=$(field "$LOGS/04-B1.log" WELCOME faction)
TOK_A=$(identity_token "$ID_A")
TOK_B=$(identity_token "$ID_B")
OUT_B=$(tile_out_for "${FB:-1}")
fail4=""
if [ $rcB1 -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/04-B1.log"; then
	fail4="B first join: $(smoke_fail_line "$LOGS/04-B1.log" $rcB1)"
elif [ -z "$FA" ] || [ -z "$FB" ]; then
	fail4="no WELCOME line (A='${FA}' B='${FB}')"
elif [ "$FA" = "$FB" ]; then
	fail4="A and B got the same faction $FA"
elif [ "$(field "$LOGS/04-B1.log" WELCOME returning)" != "false" ]; then
	fail4="B first join reported returning=$(field "$LOGS/04-B1.log" WELCOME returning)"
elif [ -z "$TOK_A" ] || [ -z "$TOK_B" ]; then
	fail4="identity file without token (A='$ID_A' B='$ID_B')"
elif [ "$TOK_A" = "$TOK_B" ]; then
	fail4="A and B received the same token"
elif ! grep -q "^TILE $OUT_B owner=$FB " "$LOGS/04-B1.log"; then
	fail4="B never saw TILE $OUT_B owner=$FB"
fi

if [ -z "$fail4" ]; then
	log "A faction=$FA  B faction=$FB  B tile=$OUT_B  tokens differ; B disconnects and rejoins with $ID_B"
	run_client "$LOGS/04-B2.log" 40 --join 127.0.0.1 --port "$P4" --name Bob --identity-file "$ID_B" --scenario b --hold-seconds 1
	rcB2=$?
	FB2=$(field "$LOGS/04-B2.log" WELCOME faction)
	if [ $rcB2 -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/04-B2.log"; then
		fail4="B rejoin: $(smoke_fail_line "$LOGS/04-B2.log" $rcB2)"
	elif [ "$(field "$LOGS/04-B2.log" WELCOME returning)" != "true" ]; then
		fail4="B rejoin with the same token reported returning=$(field "$LOGS/04-B2.log" WELCOME returning)"
	elif [ "$FB2" != "$FB" ]; then
		fail4="B rejoin faction $FB2 != $FB"
	elif [ "$(identity_token "$ID_B")" != "$TOK_B" ]; then
		fail4="B token changed on rejoin"
	elif ! grep -q "^TILE $OUT_B owner=$FB " "$LOGS/04-B2.log"; then
		fail4="B rejoin never saw TILE $OUT_B owner=$FB"
	elif [ "$(field "$LOGS/04-B2.log" BUILD sent)" != "0" ]; then
		fail4="B rejoin had to rebuild (BUILD sent=$(field "$LOGS/04-B2.log" BUILD sent)); server lost the tile state"
	fi
fi

if [ -n "$fail4" ]; then
	step_fail "$fail4 -> $(hint_for "$LOGS/04-B1.log" "$LOGS/04-B2.log" "$LOGS/04-A.log")$(missing_in_server hello_rpc with_welcome)"
else
	step_pass "A=$FA B=$FB, distinct tokens, B returning=true with TILE $OUT_B owner=$FB and nothing to rebuild"
fi

# ================================================================ 5 restart recovery

step_begin 5 "restart recovery (SIGTERM, same --save-dir, status.json tick continues)"
STATUS="$D4/status.json"
fail5=""
tick_before=""
ends_before=""
pid_before=""
if [ -f "$STATUS" ]; then
	tick_before=$(json_int "$STATUS" tick)
	ends_before=$(json_int "$STATUS" round_ends_at_unix)
	pid_before=$(json_int "$STATUS" pid)
	log "before SIGTERM: tick=$tick_before round_ends_at_unix=$ends_before pid=$pid_before"
else
	fail5="no $STATUS: --status-file (and --save-dir) not implemented (server-core persistence)"
fi

if ! stop_pid "$SERVER_PID" 10; then
	fail5="${fail5:-server did not exit within 10s of SIGTERM (save-on-SIGTERM missing, server-core)}"
fi
saves=$(ls -1 "$D4/save" 2>/dev/null | wc -l | tr -d ' ')
if [ "${saves:-0}" -eq 0 ] && [ -z "$fail5" ]; then
	fail5="no save file under --save-dir $D4/save after SIGTERM (server-core persistence)"
fi
log "save files after SIGTERM: ${saves:-0}"
# A was holding; the server stop ends its hold.
wait_exit "$A_PID" 5 || true

if udp_busy "$P4"; then
	fail5="${fail5:-UDP $P4 still bound after the server exited}"
fi

RESTART_T0=$(now_s)
start_server "$LOGS/05-server.log" "${SERVER_ARGS[@]}"
log "restarted server pid=$SERVER_PID"
ready=0
if [ -z "$pid_before" ]; then
	# No status file before the stop either: nothing to poll, step 6 only needs the port up.
	wait_for_line "$LOGS/05-server.log" "Listen|status" 10 || log "restarted server printed no Listen line in 10s"
else
	half=0
	while [ $half -lt 40 ]; do
		if [ -f "$STATUS" ]; then
			m=$(mtime_s "$STATUS")
			p=$(json_int "$STATUS" pid)
			if [ -n "$m" ] && [ "$m" -ge "$RESTART_T0" ] && [ -n "$p" ] && [ "$p" != "$pid_before" ]; then
				ready=1
				break
			fi
		fi
		sleep 0.5
		half=$((half + 1))
	done
fi
tick_after=""
ends_after=""
if [ $ready -eq 1 ]; then
	tick_after=$(json_int "$STATUS" tick)
	ends_after=$(json_int "$STATUS" round_ends_at_unix)
	log "after restart: tick=$tick_after round_ends_at_unix=$ends_after pid=$(json_int "$STATUS" pid)"
	sleep 2.5
	tick_later=$(json_int "$STATUS" tick)
	log "2.5s later: tick=$tick_later"
	if [ -z "$fail5" ]; then
		if [ -z "$tick_after" ] || [ "$tick_after" -lt "${tick_before:-0}" ] || [ "$tick_after" -le 0 ]; then
			fail5="status.json tick reset: before=$tick_before after=$tick_after (save-on-SIGTERM or restore missing, server-core)"
		elif [ -z "$tick_later" ] || [ "$tick_later" -le "$tick_after" ]; then
			fail5="status.json tick stuck at $tick_after after restart: restored server is not ticking (server-core)"
		elif [ "$ends_after" != "$ends_before" ]; then
			fail5="round_ends_at_unix changed across restart: $ends_before -> $ends_after (a stop must not extend the round)"
		else
			remaining=$(( ends_after - $(now_s) ))
			if [ "$remaining" -lt 15 ]; then
				fail5="steps 4-5 used the round budget: ${remaining}s left of ${SMOKE_ROUND_SECONDS}s; raise SMOKE_ROUND_SECONDS"
			fi
		fi
	fi
elif [ -z "$fail5" ]; then
	fail5="no fresh $STATUS within 20s of restart (--status-file, server-core)"
fi

if [ -z "$fail5" ]; then
	run_client "$LOGS/05-B3.log" 40 --join 127.0.0.1 --port "$P4" --name Bob --identity-file "$ID_B" --scenario b --hold-seconds 1
	rcB3=$?
	if [ $rcB3 -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/05-B3.log"; then
		fail5="B after restart: $(smoke_fail_line "$LOGS/05-B3.log" $rcB3)"
	elif [ "$(field "$LOGS/05-B3.log" WELCOME returning)" != "true" ]; then
		fail5="B after restart reported returning=$(field "$LOGS/05-B3.log" WELCOME returning): players not restored"
	elif [ "$(field "$LOGS/05-B3.log" WELCOME faction)" != "$FB" ]; then
		fail5="B after restart faction $(field "$LOGS/05-B3.log" WELCOME faction) != $FB"
	elif ! grep -q "^TILE $OUT_B owner=$FB " "$LOGS/05-B3.log"; then
		fail5="B after restart never saw TILE $OUT_B owner=$FB: world not restored"
	elif [ "$(field "$LOGS/05-B3.log" BUILD sent)" != "0" ]; then
		fail5="B after restart had to rebuild (BUILD sent=$(field "$LOGS/05-B3.log" BUILD sent)): world not restored"
	fi
fi

if [ -n "$fail5" ]; then
	step_fail "$fail5$(missing_in_server --save-dir --status-file)"
else
	step_pass "tick $tick_before -> $tick_after, round_ends_at_unix unchanged, B returning with TILE $OUT_B owner=$FB"
fi

# ================================================================ 6 round end by clock

step_begin 6 "round end (MatchEnd clock, final_scores, winner = builder)"
limit6=$((SMOKE_ROUND_SECONDS + 30))
if ! alive "$SERVER_PID"; then
	step_fail "server from step 5 is not running"
else
	start_client "$LOGS/06-A.log" --join 127.0.0.1 --port "$P4" --name Alice --identity-file "$ID_A" --scenario idle --expect clock --round-seconds "$SMOKE_ROUND_SECONDS"
	A6=$CLIENT_PID
	start_client "$LOGS/06-B.log" --join 127.0.0.1 --port "$P4" --name Bob --identity-file "$ID_B" --scenario b --expect clock --round-seconds "$SMOKE_ROUND_SECONDS"
	B6=$CLIENT_PID
	log "waiting up to ${limit6}s for MatchEnd{clock} (server started $(( $(now_s) - SERVER_T0 ))s ago)"
	wait_exit "$B6" "$limit6" || { kill -KILL "$B6" 2>/dev/null; }
	wait_exit "$A6" 10 || { kill -KILL "$A6" 2>/dev/null; }
	wait "$B6" 2>/dev/null; rcB6=$?
	wait "$A6" 2>/dev/null; rcA6=$?
	fail6=""
	if [ $rcB6 -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/06-B.log"; then
		fail6="B: $(smoke_fail_line "$LOGS/06-B.log" $rcB6)"
	elif [ $rcA6 -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/06-A.log"; then
		fail6="A: $(smoke_fail_line "$LOGS/06-A.log" $rcA6)"
	else
		reason=$(field "$LOGS/06-B.log" MATCH_END reason)
		scores=$(field "$LOGS/06-B.log" MATCH_END final_scores)
		winner=$(field "$LOGS/06-B.log" MATCH_END winner)
		winnerA=$(field "$LOGS/06-A.log" MATCH_END winner)
		if [ "$reason" != "clock" ]; then
			fail6="MATCH_END reason=$reason"
		elif [ "$scores" != "true" ]; then
			fail6="MATCH_END without final_scores"
		elif [ -z "$winner" ] || [ "$winner" = "-1" ]; then
			fail6="MATCH_END winner=$winner (NEUTRAL)"
		elif [ -n "${FB:-}" ] && [ "$winner" != "$FB" ]; then
			fail6="winner=$winner but the builder is faction $FB"
		elif [ "$winnerA" != "$winner" ]; then
			fail6="A saw winner=$winnerA, B saw winner=$winner"
		fi
	fi
	stop_pid "$SERVER_PID" 10 || log "server needed SIGKILL"
	if [ -n "$fail6" ]; then
		step_fail "$fail6 -> $(hint_for "$LOGS/06-B.log" "$LOGS/06-A.log")$(missing_in_server --round-seconds)"
	else
		step_pass "MatchEnd clock, final_scores present, winner=$winner (builder), $(grep -c '^FINAL_SCORE' "$LOGS/06-B.log") score lines"
	fi
fi

# ================================================================ 7 INSUFFICIENT_FUNDS

step_begin 7 "INSUFFICIENT_FUNDS (no --free-build, --start-treasury $SMOKE_START_TREASURY)"
skip7=""
if ! grep -rq -- "--start-treasury" server/ 2>/dev/null; then
	skip7="missing --start-treasury: no server/ script parses it (server-core), so the treasury cannot be set to $SMOKE_START_TREASURY and sim-economy's INSUFFICIENT_FUNDS stays unverified"
elif ! grep -q "INSUFFICIENT_FUNDS" server/world_state.gd 2>/dev/null && ! grep -rq "INSUFFICIENT_FUNDS" server/sim 2>/dev/null; then
	skip7="server parses --start-treasury but server/world_state.gd and server/sim/ never return INSUFFICIENT_FUNDS (sim-economy not merged)"
fi
if [ -n "$skip7" ]; then
	if [ "$SMOKE_REQUIRE_ECONOMY" = "1" ]; then
		step_fail "$skip7 (SMOKE_REQUIRE_ECONOMY=1)"
	else
		step_skip "$skip7"
	fi
else
	P7=$(pick_port) || fatal_step "no free UDP port"
	D7="$TMP/step7"
	mkdir -p "$D7/save"
	start_server "$LOGS/07-server.log" --port "$P7" --pace "$SMOKE_PACE" --round-seconds 600 --start-treasury "$SMOKE_START_TREASURY" --save-dir "$D7/save" --status-file "$D7/status.json"
	wait_for_line "$LOGS/07-server.log" "Listen|status" 10 || log "server printed no Listen line in 10s"
	start_client "$LOGS/07-A.log" --join 127.0.0.1 --port "$P7" --name Alice --identity-file "$D7/identity-A.cfg" --scenario idle --hold-seconds 25
	A7=$CLIENT_PID
	wait_for_line "$LOGS/07-A.log" "^WELCOME |^NO_HELLO_RPC" 15 || true
	run_client "$LOGS/07-B.log" 40 --join 127.0.0.1 --port "$P7" --name Bob --identity-file "$D7/identity-B.cfg" --scenario broke --hold-seconds 1
	rcB7=$?
	FB7=$(field "$LOGS/07-B.log" WELCOME faction)
	OUT2=$(tile_out2_for "${FB7:-1}")
	fail7=""
	if [ $rcB7 -ne 0 ] || ! grep -q '^SMOKE_OK' "$LOGS/07-B.log"; then
		fail7="B: $(smoke_fail_line "$LOGS/07-B.log" $rcB7)"
	elif ! grep -q "^REJECT .*name=INSUFFICIENT_FUNDS tile=$OUT2 " "$LOGS/07-B.log"; then
		fail7="no REJECT INSUFFICIENT_FUNDS for the second claim $OUT2"
	elif ! grep -q '^BROKE_OK' "$LOGS/07-B.log"; then
		fail7="no BROKE_OK line"
	fi
	stop_pid "$A7" 5 || true
	stop_pid "$SERVER_PID" 10 || log "server needed SIGKILL"
	if [ -n "$fail7" ]; then
		step_fail "$fail7 -> $(hint_for "$LOGS/07-B.log")$(missing_in_server INSUFFICIENT_FUNDS)"
	else
		step_pass "$(grep -m1 '^BROKE_OK' "$LOGS/07-B.log")"
	fi
fi

finish
