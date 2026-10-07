class_name WorldView
extends Node3D

## Draws the ClientSession mirror as flat-color geometry, one BlockView per 8×8
## interest block (BLOCKS_PER_AXIS² of them). After every session `updated` the view
## pulls take_dirty_blocks() and calls rebuild_block(key) for each; nothing else is
## touched. M4 swaps the geometry inside BlockView.rebuild for the showcase
## generators while keeping this per-block entry.
##
## Data path per block: ClientSession.view_tile(x, y) for the 64 tiles,
## ClientSession.view_edges_in_block(key) for edges, ClientSession.summary(key) when the
## block is not subscribed.

## Brownout tiles toggle at this period.
const FLICKER_SEC := 0.4
const HOVER_ALPHA := 0.38
const Y_HOVER := 0.16

var session: ClientSession = null

var _blocks: Dictionary = {}
var _shared: Dictionary = {}
var _hover: MeshInstance3D
var _hover_material: StandardMaterial3D
var _flicker_on := true
var _flicker_left := FLICKER_SEC


func _ready() -> void:
	_build_shared()
	for by in SliceConstants.BLOCKS_PER_AXIS:
		for bx in SliceConstants.BLOCKS_PER_AXIS:
			var block := InterestId.new(bx, by)
			var view := BlockView.new()
			view.setup(block, _shared)
			add_child(view)
			_blocks[block.key()] = view
	_hover_material = _shared["overlay"].duplicate()
	_hover_material.albedo_color = Palette.with_alpha(Palette.HUD_TEXT, HOVER_ALPHA)
	_hover_material.vertex_color_use_as_albedo = false
	_hover = MeshInstance3D.new()
	_hover.name = "Hover"
	_hover.mesh = _shared["overlay_mesh"]
	_hover.material_override = _hover_material
	_hover.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_hover.visible = false
	add_child(_hover)


func bind(p_session: ClientSession) -> void:
	session = p_session
	session.updated.connect(_on_updated)
	rebuild_all()


func rebuild_all() -> void:
	for key in _blocks:
		rebuild_block(key)


## Per-block rebuild entry. key is InterestId.key(), "bx,by".
func rebuild_block(key: String) -> void:
	if session == null or not _blocks.has(key):
		return
	var view: BlockView = _blocks[key]
	view.rebuild(session)
	view.set_flicker(_flicker_on)


func set_hover(cell: Vector2i, shown: bool, color: Color = Palette.HUD_TEXT) -> void:
	_hover.visible = shown and SliceConstants.in_map(cell.x, cell.y)
	if not _hover.visible:
		return
	_hover.position = Vector3(cell.x + 0.5, Y_HOVER, cell.y + 0.5)
	_hover_material.albedo_color = Palette.with_alpha(color, HOVER_ALPHA)


func block_view(key: String) -> BlockView:
	return _blocks.get(key)


func _on_updated() -> void:
	for key in session.take_dirty_blocks():
		rebuild_block(key)


func _process(delta: float) -> void:
	_flicker_left -= delta
	if _flicker_left > 0.0:
		return
	_flicker_left = FLICKER_SEC
	_flicker_on = not _flicker_on
	for key in _blocks:
		var view: BlockView = _blocks[key]
		if view.brownout_count > 0:
			view.set_flicker(_flicker_on)


func _build_shared() -> void:
	var lit := StandardMaterial3D.new()
	lit.vertex_color_use_as_albedo = true
	lit.roughness = 0.9
	var overlay := StandardMaterial3D.new()
	overlay.vertex_color_use_as_albedo = true
	overlay.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	overlay.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	overlay.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	# Back faces stay culled: the thin boxes' undersides would otherwise show through
	# and fight the ground plane.
	overlay.cull_mode = BaseMaterial3D.CULL_BACK
	_shared = {
		"lit": lit,
		"overlay": overlay,
		"ring": _box(0.96, 0.02, 0.96),
		"fill": _box(0.74, 0.02, 0.74),
		"building": _box(0.62, 1.0, 0.62),
		"roof": _box(0.36, 0.04, 0.36),
		"edge": _box(1.0, 0.04, 0.26),
		# The flat overlay quad is shared by power / brownout / pollution / hover.
		"overlay_mesh": _box(0.98, 0.01, 0.98),
		"summary": _box(SliceConstants.INTEREST_BLOCK - 0.2, 0.01, SliceConstants.INTEREST_BLOCK - 0.2),
	}


static func _box(x: float, y: float, z: float) -> BoxMesh:
	var mesh := BoxMesh.new()
	mesh.size = Vector3(x, y, z)
	return mesh
