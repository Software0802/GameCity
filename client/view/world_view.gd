class_name WorldView
extends Node3D

## Draws the ClientSession mirror with the live pack, one BlockView per 8×8 interest block
## (BLOCKS_PER_AXIS² of them) in world metres (LiveCfg.P per tile). After every session
## `updated` the view pulls take_dirty_blocks() and rebuilds those blocks in two phases:
## snapshot every dirty block first, then build, so a block's seam ring (its orthogonal
## neighbours' snapshots) is current; finally the orthogonal neighbours of the dirty blocks
## re-check their own signatures and regenerate only the layers the seam changed.
##
## Data path per block: ClientSession.view_tile(x, y) for the 64 tiles,
## ClientSession.view_edges_in_block(key) for edges, ClientSession.summary(key) when the
## block is not subscribed.
##
## Shared once: materials (LiveMats), the tonemap-compensated overlay palette, the terrain
## quad, tree / car meshes, the hover frame. Perf line every PERF_EVERY frames with
## --view-perf (user arg) or GAMECITY_VIEW_PERF=1.

const Cfg := preload("res://client/assets/techart/live/scripts/live_cfg.gd")
const LB := preload("res://client/assets/techart/live/scripts/live_batch.gd")
const LiveMats := preload("res://client/assets/techart/live/scripts/live_mats.gd")
const Pal := preload("res://client/assets/techart/live/scripts/live_palette.gd")
const Props := preload("res://client/assets/techart/live/scripts/live_props.gd")

## Brownout tiles toggle at this period.
const FLICKER_SEC := 0.4
const HOVER_ALPHA := 0.65
const HOVER_Y := 0.45
const HOVER_BAR := 1.2
const PULSE_HZ := 0.35
const PERF_EVERY := 60

var session: ClientSession = null
## Milliseconds spent in the last _on_updated and the worst one so far.
var last_update_ms: float = 0.0
var max_update_ms: float = 0.0
var last_dirty_count: int = 0

var _blocks: Dictionary = {}
var _shared: Dictionary = {}
var _mats = null
var _terrain: MeshInstance3D
var _hover: MeshInstance3D
var _hover_material: ShaderMaterial
var _hover_lin: Dictionary = {}
var _flicker_on := true
var _flicker_left := FLICKER_SEC
var _perf_enabled := false
var _frame := 0


func _ready() -> void:
	_build_shared()
	_build_terrain()
	for by in SliceConstants.BLOCKS_PER_AXIS:
		for bx in SliceConstants.BLOCKS_PER_AXIS:
			var block := InterestId.new(bx, by)
			var view := BlockView.new()
			_blocks[block.key()] = view
			view.setup(block, _shared)
			add_child(view)
	_build_hover()
	_perf_enabled = OS.get_cmdline_user_args().has("--view-perf") or OS.get_environment("GAMECITY_VIEW_PERF") == "1"


func bind(p_session: ClientSession) -> void:
	session = p_session
	session.updated.connect(_on_updated)
	rebuild_all()


func rebuild_all() -> void:
	_rebuild_keys(_blocks.keys())


## Per-block rebuild entry. key is InterestId.key(), "bx,by". Neighbours re-check their seams.
func rebuild_block(key: String) -> void:
	if session == null or not _blocks.has(key):
		return
	_rebuild_keys([key])


func set_hover(cell: Vector2i, shown: bool, color: Color = Palette.HUD_TEXT) -> void:
	_hover.visible = shown and SliceConstants.in_map(cell.x, cell.y)
	if not _hover.visible:
		return
	_hover.position = Vector3(cell.x * Cfg.P, HOVER_Y, cell.y * Cfg.P)
	var html := color.to_html(false)
	if not _hover_lin.has(html):
		_hover_lin[html] = Pal.compensate(color, LiveLighting.TM_PARAMS)
	_hover_material.set_shader_parameter("tint", _hover_lin[html])


func block_view(key: String) -> BlockView:
	return _blocks.get(key)


## Blocks currently drawn in detail (subscribed).
func detailed_block_count() -> int:
	var n := 0
	for key in _blocks:
		if _blocks[key].subscribed:
			n += 1
	return n


func _on_updated() -> void:
	var dirty := session.take_dirty_blocks()
	if dirty.is_empty():
		return
	_rebuild_keys(dirty)


func _rebuild_keys(keys: Array) -> void:
	var t0 := Time.get_ticks_usec()
	var set := {}
	for key in keys:
		set[key] = true
	var seam_changed := {}
	for key in keys:
		var view: BlockView = _blocks[key]
		view.rebuild_count += 1
		var before := view.seam_signature
		view.snapshot(session)
		if view.seam_signature != before:
			seam_changed[key] = true
	for key in keys:
		var view: BlockView = _blocks[key]
		view.build()
		view.set_flicker(_flicker_on)
	# seam ring: a neighbour that was not dirty may still draw a junction or border this change moved
	for key in seam_changed:
		var view: BlockView = _blocks[key]
		for step in BlockView.ORTHOGONAL:
			var nx := view.block.block_x + step.x
			var ny := view.block.block_y + step.y
			var nkey := "%d,%d" % [nx, ny]
			if set.has(nkey) or not _blocks.has(nkey):
				continue
			var nb: BlockView = _blocks[nkey]
			if nb.subscribed:
				nb.build()
				nb.set_flicker(_flicker_on)
	last_dirty_count = keys.size()
	last_update_ms = (Time.get_ticks_usec() - t0) / 1000.0
	max_update_ms = maxf(max_update_ms, last_update_ms)


func _process(delta: float) -> void:
	_mats.set_pulse_phase(fmod(Time.get_ticks_msec() / 1000.0 * PULSE_HZ, 1.0))
	_frame += 1
	if _perf_enabled and _frame % PERF_EVERY == 0:
		_print_perf()
	_flicker_left -= delta
	if _flicker_left > 0.0:
		return
	_flicker_left = FLICKER_SEC
	_flicker_on = not _flicker_on
	_mats.set_flicker(_flicker_on)
	for key in _blocks:
		var view: BlockView = _blocks[key]
		if view.brownout_count > 0:
			view.set_flicker(_flicker_on)


func _print_perf() -> void:
	var worst := 0.0
	var buildings := 0
	for key in _blocks:
		var view: BlockView = _blocks[key]
		worst = maxf(worst, view.last_build_ms)
		buildings += int(view.stats.get("buildings", 0))
	print("VIEW_PERF frame=%d proc_ms=%.2f fps=%.1f vram_mb=%.0f draw_calls=%d prims=%d objects=%d blocks=%d buildings=%d last_update_ms=%.2f max_update_ms=%.2f worst_block_ms=%.2f" % [
		_frame,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_FPS),
		Performance.get_monitor(Performance.RENDER_VIDEO_MEM_USED) / 1048576.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		detailed_block_count(), buildings, last_update_ms, max_update_ms, worst,
	])


func _build_shared() -> void:
	_mats = LiveMats.new()
	_mats.build()
	var pal := Pal.table(LiveLighting.TM_PARAMS)
	_mats.set_palette(pal)
	var quad := LB.new()
	quad.rect_xz(-0.5, -0.5, 0.5, 0.5, 0.0)
	var quad_mesh := ArrayMesh.new()
	quad.commit(quad_mesh)
	var tree_meshes: Array = Props.make_tree_meshes()
	for i in tree_meshes.size():
		var mesh: ArrayMesh = tree_meshes[i]
		if mesh.get_surface_count() == 2:
			mesh.surface_set_material(0, _mats.m["bark"])
			mesh.surface_set_material(1, _mats.m["foliage"])
		else:
			mesh.surface_set_material(0, _mats.m["foliage"])
	var car_meshes: Array = Props.make_car_meshes()
	for mesh in car_meshes:
		var surf_mats := [_mats.m["car_paint"], _mats.m["car_glass"], _mats.m["car_trim"], _mats.m["car_lights"]]
		for i in mini(mesh.get_surface_count(), surf_mats.size()):
			mesh.surface_set_material(i, surf_mats[i])
	_shared = {
		"mats": _mats,
		"pal": pal,
		"quad": quad_mesh,
		"tree_meshes": tree_meshes,
		"car_meshes": car_meshes,
		"blocks": _blocks,
	}


## One grass quad under the whole map (unclaimed land shows it), well past the edges.
func _build_terrain() -> void:
	var extent := Cfg.map_extent()
	var m := Cfg.TERRAIN_MARGIN
	var batch := LB.new()
	batch.rect_xz(-m, -m, extent + m, extent + m, -0.06, true, 1.0)
	var mesh := ArrayMesh.new()
	batch.commit(mesh, _mats.m["terrain"])
	_terrain = MeshInstance3D.new()
	_terrain.name = "Terrain"
	_terrain.mesh = mesh
	_terrain.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_terrain)


## Square frame around one tile, positioned at the tile corner by set_hover.
func _build_hover() -> void:
	var batch := LB.new()
	var p := Cfg.P
	var w := HOVER_BAR
	batch.rect_xz(0.0, 0.0, p, w, 0.0)
	batch.rect_xz(0.0, p - w, p, p, 0.0)
	batch.rect_xz(0.0, w, w, p - w, 0.0)
	batch.rect_xz(p - w, w, p, p - w, 0.0)
	var mesh := ArrayMesh.new()
	_hover_material = _mats.m["hover"]
	_hover_material.set_shader_parameter("alpha", HOVER_ALPHA)
	batch.commit(mesh, _hover_material)
	_hover = MeshInstance3D.new()
	_hover.name = "Hover"
	_hover.mesh = mesh
	_hover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hover.visible = false
	add_child(_hover)
