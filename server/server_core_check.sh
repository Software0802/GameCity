#!/bin/bash
# server-core end-to-end check. Runs from the repo root, needs godot on PATH
# (or GODOT=/path/to/godot) and an imported project (godot --headless --path . --import).
#
#   ./server/server_core_check.sh            → SERVER_CORE_OK, exit 0
#   KEEP=1 ./server/server_core_check.sh     → keep the scratch dir for inspection
#
# Scenarios (each prints its evidence, any failure prints SERVER_CORE_FAIL and exits 1):
#   1 handshake   two clients with different names get tokens and different factions
#   2 reconnect   one of them reconnects with its token: same faction, returning=true,
#                 and its claimed tile is still owned
#   3 restart     the server is killed with SIGKILL after a periodic save and restarted:
#                 status.json tick continues from the save (never 0), the player table
#                 is still there (reconnect works); then a stop-file shutdown and another
#                 restart continue the tick exactly
#   4 clock       --round-seconds 20: MatchEnd{clock, final_scores} reaches the client in
#                 about 20 s, the host log says "MatchEnd: clock", the grid storm fired at
#                 the half-way mark, and a command after the end is MATCH_NOT_ACTIVE
#   5 refusals    a command before hello is NOT_AUTHENTICATED; a wrong protocol is refused
#   6 legacy      --smoke-host + client/smoke_client.tscn → SMOKE_OK and "MatchEnd: server_stop"
set -u
export PATH="/opt/homebrew/bin:$PATH"
cd "$(dirname "$0")/.." || exit 1
GODOT=${GODOT:-godot}
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/gamecity-server-core.XXXXXX")
PORT=${PORT:-$((24800 + RANDOM % 150))}
SERVER_PID=""
SERVER_LOG=""

log() { echo "[server_core_check] $*"; }
fail() { echo "SERVER_CORE_FAIL $*"; [ -n "$SERVER_LOG" ] && { echo "---- server log tail ----"; tail -20 "$SERVER_LOG"; }; exit 1; }
cleanup() {
	[ -n "$SERVER_PID" ] && kill -9 "$SERVER_PID" 2>/dev/null
	wait 2>/dev/null
	if [ "${KEEP:-0}" = "1" ]; then log "scratch kept at $SCRATCH"; else rm -rf "$SCRATCH"; fi
}
trap cleanup EXIT

# start_server <log name> <args...>
start_server() {
	SERVER_LOG="$SCRATCH/$1.log"; shift
	"$GODOT" --headless --path . res://server/main.tscn -- "$@" > "$SERVER_LOG" 2>&1 &
	SERVER_PID=$!
}
stop_server_hard() {
	kill -9 "$SERVER_PID" 2>/dev/null; wait "$SERVER_PID" 2>/dev/null; SERVER_PID=""
}
# wait_for_server_exit <seconds>
wait_for_server_exit() {
	local n=0
	while kill -0 "$SERVER_PID" 2>/dev/null; do
		n=$((n + 1)); [ "$n" -ge $(( $1 * 10 )) ] && return 1; sleep 0.1
	done
	wait "$SERVER_PID" 2>/dev/null; local code=$?; SERVER_PID=""; return $code
}
# wait_for_file <path> <seconds>
wait_for_file() {
	local n=0
	until [ -s "$1" ]; do n=$((n + 1)); [ "$n" -ge $(( $2 * 10 )) ] && return 1; sleep 0.1; done
}
# wait_for_log <text> <seconds>
wait_for_log() {
	local n=0
	until grep -q "$1" "$SERVER_LOG" 2>/dev/null; do n=$((n + 1)); [ "$n" -ge $(( $2 * 10 )) ] && return 1; sleep 0.1; done
}
json_int() { grep -o "\"$2\":[0-9-]*" "$1" | head -1 | cut -d: -f2; }
json_str() { grep -o "\"$2\":\"[^\"]*\"" "$1" | head -1 | cut -d: -f2 | tr -d '"'; }
field() { echo "$1" | tr ' ' '\n' | grep "^$2=" | head -1 | cut -d= -f2-; }
# client <args...>  → prints the CLIENT_* lines
client() {
	"$GODOT" --headless --path . res://server/check_client.tscn -- --join 127.0.0.1 --port "$PORT" "$@" 2>&1 | grep -E '^CLIENT_'
}

SAVES="$SCRATCH/saves"; STATUS="$SCRATCH/status.json"
SERVER_ARGS=(--port "$PORT" --save-dir "$SAVES" --status-file "$STATUS" --save-interval 2 --round-seconds 600)

# ---------------------------------------------------------------- 1 handshake
log "scenario 1: handshake on port $PORT"
start_server s1 "${SERVER_ARGS[@]}" --new-round
wait_for_file "$STATUS" 15 || fail "server never wrote status.json"
client --name alice --claim --token-file "$SCRATCH/alice.tok" --hold 2 > "$SCRATCH/alice1.out" &
ALICE_JOB=$!
BOB1=$(client --name bob --claim --token-file "$SCRATCH/bob.tok" --hold 2)
wait $ALICE_JOB
ALICE1=$(cat "$SCRATCH/alice1.out")
echo "$ALICE1"; echo "$BOB1"
echo "$ALICE1" | grep -q '^CLIENT_OK' || fail "alice did not finish the handshake"
echo "$BOB1" | grep -q '^CLIENT_OK' || fail "bob did not finish the handshake"
ALICE_FACTION=$(field "$ALICE1" faction); BOB_FACTION=$(field "$BOB1" faction)
ALICE_TOKEN=$(field "$ALICE1" token); BOB_TOKEN=$(field "$BOB1" token)
BOB_TILE=$(field "$BOB1" claimed)
[ "$ALICE_FACTION" != "$BOB_FACTION" ] || fail "both clients got faction $ALICE_FACTION"
[ ${#ALICE_TOKEN} -eq 64 ] && [ ${#BOB_TOKEN} -eq 64 ] || fail "tokens are not 64 hex chars"
[ "$ALICE_TOKEN" != "$BOB_TOKEN" ] || fail "tokens are identical"
[ "$(field "$ALICE1" returning)" = "false" ] && [ "$(field "$BOB1" returning)" = "false" ] || fail "first visit flagged as returning"
[ "$(cat "$SCRATCH/bob.tok")" = "$BOB_TOKEN" ] || fail "token file does not hold bob's token"
grep -q "welcome .*faction=$ALICE_FACTION .*name=alice" "$SERVER_LOG" || fail "server log lacks alice's welcome"
log "scenario 1 ok: alice faction=$ALICE_FACTION bob faction=$BOB_FACTION bob claimed $BOB_TILE"

# ---------------------------------------------------------------- 2 reconnect
log "scenario 2: bob reconnects with his token"
BOB2=$(client --name bob --token-file "$SCRATCH/bob.tok" --expect-owned "$BOB_TILE")
echo "$BOB2"
echo "$BOB2" | grep -q '^CLIENT_OK' || fail "bob could not reconnect"
[ "$(field "$BOB2" faction)" = "$BOB_FACTION" ] || fail "bob's faction changed on reconnect"
[ "$(field "$BOB2" returning)" = "true" ] || fail "reconnect not flagged returning"
[ "$(field "$BOB2" token)" = "$BOB_TOKEN" ] || fail "reconnect changed the token"
[ "$(field "$BOB2" owned)" = "$BOB_TILE" ] || fail "bob's tile $BOB_TILE not seen as owned after reconnect"
log "scenario 2 ok: faction=$BOB_FACTION returning=true tile $BOB_TILE still owned"

# ---------------------------------------------------------------- 3 restart
log "scenario 3a: SIGKILL after a periodic save, then restart"
sleep 3
wait_for_log "(interval)" 10 || fail "no periodic save in the log"
NEWEST=$(ls "$SAVES"/world-*.json | tail -1)
SAVED_TICK=$(json_int "$NEWEST" tick); TICK_BEFORE_KILL=$(json_int "$STATUS" tick)
log "newest save $(basename "$NEWEST") tick=$SAVED_TICK, status tick=$TICK_BEFORE_KILL, $(ls "$SAVES"/world-*.json | wc -l | tr -d ' ') save files"
[ "$SAVED_TICK" -gt 0 ] || fail "saved tick is $SAVED_TICK"
[ "$(ls "$SAVES"/world-*.json | wc -l | tr -d ' ')" -le 3 ] || fail "more than 3 save files kept"
stop_server_hard
start_server s3a "${SERVER_ARGS[@]}"
wait_for_log "Server ready" 15 || fail "server did not restart"
grep -q "restored world-.*tick=$SAVED_TICK" "$SERVER_LOG" || fail "restart did not restore tick $SAVED_TICK"
sleep 3
TICK_AFTER=$(json_int "$STATUS" tick)
[ "$TICK_AFTER" -ge "$SAVED_TICK" ] && [ "$TICK_AFTER" -gt 0 ] || fail "tick after restart is $TICK_AFTER (saved $SAVED_TICK)"
[ "$(json_int "$STATUS" players_known)" = "2" ] || fail "player table lost: players_known=$(json_int "$STATUS" players_known)"
BOB3=$(client --name bob --token-file "$SCRATCH/bob.tok" --expect-owned "$BOB_TILE")
echo "$BOB3"
echo "$BOB3" | grep -q '^CLIENT_OK' || fail "bob could not reconnect after restart"
[ "$(field "$BOB3" faction)" = "$BOB_FACTION" ] && [ "$(field "$BOB3" returning)" = "true" ] || fail "bob's identity did not survive the restart"
log "scenario 3a ok: tick $TICK_BEFORE_KILL → killed → restored $SAVED_TICK → now $TICK_AFTER, bob returning in faction $BOB_FACTION"

log "scenario 3b: stop file, then restart continues the tick exactly"
sleep 1
TICK_BEFORE_STOP=$(json_int "$STATUS" tick)
touch "$SAVES/stop"
wait_for_server_exit 10 || fail "server did not exit on the stop file"
grep -q "Server stop: stop_file" "$SERVER_LOG" || fail "stop file not logged"
STOP_TICK=$(json_int "$(ls "$SAVES"/world-*.json | tail -1)" tick)
[ "$STOP_TICK" -ge "$TICK_BEFORE_STOP" ] || fail "shutdown save tick $STOP_TICK < $TICK_BEFORE_STOP"
start_server s3b "${SERVER_ARGS[@]}"
wait_for_log "Server ready" 15 || fail "server did not restart after stop file"
grep -q "restored world-.*tick=$STOP_TICK" "$SERVER_LOG" || fail "restart did not restore tick $STOP_TICK"
stop_server_hard
log "scenario 3b ok: stop at tick $STOP_TICK, restart resumed at $STOP_TICK"

# ---------------------------------------------------------------- 4 clock
log "scenario 4: --round-seconds 20 ends with MatchEnd{clock}"
PORT=$((PORT + 1))
start_server s4 --port "$PORT" --save-dir "$SCRATCH/saves4" --status-file "$SCRATCH/status4.json" --round-seconds 20 --new-round
wait_for_file "$SCRATCH/status4.json" 15 || fail "clock server never wrote status"
T0=$(date +%s)
CAROL=$(client --name carol --claim --wait-end --deadline 45)
T1=$(date +%s)
echo "$CAROL"
echo "$CAROL" | grep -q '^CLIENT_END reason=clock' || fail "no MatchEnd{clock} at the client"
END_LINE=$(echo "$CAROL" | grep '^CLIENT_END')
[ "$(field "$END_LINE" final_scores)" = "true" ] || fail "final_scores missing"
[ "$(field "$END_LINE" crisis_seen)" = "true" ] || fail "grid storm not seen before the end"
[ "$(field "$END_LINE" post_end_reject)" = "MATCH_NOT_ACTIVE" ] || fail "command after the end was not MATCH_NOT_ACTIVE"
wait_for_log "MatchEnd: clock" 5 || fail "host log lacks MatchEnd: clock"
ELAPSED=$((T1 - T0))
[ "$ELAPSED" -ge 15 ] && [ "$ELAPSED" -le 35 ] || fail "round took ${ELAPSED}s from client start"
[ "$(json_str "$SCRATCH/status4.json" phase)" = "ended" ] || fail "status phase is not ended"
grep -q '"phase":"ended"' "$(ls "$SCRATCH/saves4"/world-*.json | tail -1)" || fail "save phase is not ended"
LATE=$(client --name dave --deadline 10)
echo "$LATE"
echo "$LATE" | grep -q '^CLIENT_OK' || fail "late joiner could not join the ended round"
stop_server_hard
log "scenario 4 ok: MatchEnd: clock after ~${ELAPSED}s, winner=$(field "$END_LINE" winner), save and status say ended"

# ---------------------------------------------------------------- 5 refusals
log "scenario 5: command before hello, wrong protocol"
PORT=$((PORT + 1))
start_server s5 --port "$PORT" --save-dir "$SCRATCH/saves5" --round-seconds 600 --new-round
wait_for_log "Server ready" 15 || fail "refusal server did not start"
EARLY=$(client --name erin --early-command)
echo "$EARLY"
[ "$(field "$EARLY" early_reject)" = "NOT_AUTHENTICATED" ] || fail "command before hello was not NOT_AUTHENTICATED"
WRONG=$(client --name frank --protocol 99)
echo "$WRONG"
echo "$WRONG" | grep -q '^CLIENT_REFUSED' || fail "wrong protocol was not refused"
wait_for_log "hello refused .*protocol 99" 5 || fail "host log lacks the protocol refusal"
stop_server_hard
log "scenario 5 ok"

# ---------------------------------------------------------------- 6 legacy smoke
log "scenario 6: --smoke-host with client/smoke_client.tscn"
PORT=$((PORT + 1))
start_server s6 --port "$PORT" --smoke-host
sleep 1
SMOKE=$("$GODOT" --headless --path . res://client/smoke_client.tscn -- --join 127.0.0.1 --port "$PORT" 2>&1 | grep -E '^SMOKE_')
echo "$SMOKE"
[ "$SMOKE" = "SMOKE_OK" ] || fail "legacy smoke: $SMOKE"
wait_for_server_exit 10 || fail "smoke host did not exit after MatchEnd"
grep -q "MatchEnd: server_stop" "$SERVER_LOG" || fail "host log lacks MatchEnd: server_stop"
log "scenario 6 ok"

echo "SERVER_CORE_OK"
