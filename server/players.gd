class_name Players
extends RefCounted

## Server-side player table for one round. A player is identified by the sha256 of
## the identity token the server issued in ServerWelcome; the raw token is never
## stored. Rows mirror the "players" array of the save envelope
## (docs/plans/m2-city-phase.md「存档信封」). A disconnect never deletes a row, it
## only updates last_seen_unix, so a returning token lands in the same faction.
## Pure data: no Node, no RPC.


class Record:
	extends RefCounted

	var player_id: int = -1
	## Hex sha256 of the issued token. Empty for a scripted player that has no token.
	var token_sha256: String = ""
	var name: String = ""
	## SliceConstants.Owner. FACTION_A or FACTION_B.
	var faction: int = SliceConstants.Owner.NEUTRAL
	var last_seen_unix: int = 0

	func to_dict() -> Dictionary:
		return {
			"player_id": player_id,
			"token_sha256": token_sha256,
			"name": name,
			"faction": faction,
			"last_seen_unix": last_seen_unix,
		}

	## Returns null when the row cannot be a player (bad id or faction).
	static func from_dict(data: Dictionary) -> Record:
		var record := Record.new()
		record.player_id = int(data.get("player_id", -1))
		record.token_sha256 = str(data.get("token_sha256", ""))
		record.name = str(data.get("name", ""))
		record.faction = int(data.get("faction", SliceConstants.Owner.NEUTRAL))
		record.last_seen_unix = int(data.get("last_seen_unix", 0))
		if record.player_id < Players.FIRST_PLAYER_ID:
			return null
		if not Players.is_player_faction(record.faction):
			return null
		return record


const TOKEN_BYTES := 32
const FIRST_PLAYER_ID := 1

var _records: Array[Record] = []


## A fresh identity token: 32 random bytes as 64 hex characters.
static func new_token() -> String:
	return Crypto.new().generate_random_bytes(TOKEN_BYTES).hex_encode()


## What the table stores for a token.
static func hash_token(token: String) -> String:
	return token.sha256_text()


static func is_player_faction(faction: int) -> bool:
	return faction == SliceConstants.Owner.FACTION_A or faction == SliceConstants.Owner.FACTION_B


func size() -> int:
	return _records.size()


## Rows in player_id order. The array is the live one; do not mutate it.
func records() -> Array[Record]:
	return _records


## Empty hashes never match, so a scripted player cannot be claimed by an empty token.
func find_by_token_hash(token_hash: String) -> Record:
	if token_hash.is_empty():
		return null
	for record in _records:
		if record.token_sha256 == token_hash:
			return record
	return null


func find_by_id(player_id: int) -> Record:
	for record in _records:
		if record.player_id == player_id:
			return record
	return null


func count_faction(faction: int) -> int:
	var count := 0
	for record in _records:
		if record.faction == faction:
			count += 1
	return count


## Faction for a new player: the side with fewer known players, A on a tie.
## Counts every row, online or not, so balance survives restarts.
func pick_faction() -> int:
	var a := count_faction(SliceConstants.Owner.FACTION_A)
	var b := count_faction(SliceConstants.Owner.FACTION_B)
	if b < a:
		return SliceConstants.Owner.FACTION_B
	return SliceConstants.Owner.FACTION_A


## Appends a row with the next free player_id (ids are never reused).
func create(p_name: String, faction: int, token_hash: String, now_unix: int) -> Record:
	var record := Record.new()
	record.player_id = _next_id()
	record.token_sha256 = token_hash
	record.name = p_name
	record.faction = faction
	record.last_seen_unix = now_unix
	_records.append(record)
	return record


func touch(player_id: int, now_unix: int) -> void:
	var record := find_by_id(player_id)
	if record != null:
		record.last_seen_unix = now_unix


func to_save_array() -> Array:
	var rows: Array = []
	for record in _records:
		rows.append(record.to_dict())
	return rows


## Rows that are not dictionaries, fail Record.from_dict, or repeat a player_id are
## skipped with a warning; the rest load in player_id order.
static func from_save_array(raw) -> Players:
	var table := Players.new()
	if not (raw is Array):
		return table
	var seen: Dictionary = {}
	for row in raw:
		if not (row is Dictionary):
			push_warning("Players.from_save_array: row is not a dictionary, skipped")
			continue
		var record := Record.from_dict(row)
		if record == null:
			push_warning("Players.from_save_array: invalid row %s, skipped" % str(row))
			continue
		if seen.has(record.player_id):
			push_warning("Players.from_save_array: duplicate player_id %d, skipped" % record.player_id)
			continue
		seen[record.player_id] = true
		table._records.append(record)
	table._records.sort_custom(func(x: Record, y: Record) -> bool: return x.player_id < y.player_id)
	return table


func _next_id() -> int:
	var next := FIRST_PLAYER_ID
	for record in _records:
		if record.player_id >= next:
			next = record.player_id + 1
	return next
