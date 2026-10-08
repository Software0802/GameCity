class_name Toolbar
extends Control

## Left tool column (design-v2 "操作"): claim, zone R / C / I, clear zone, road,
## power plant, demolish, and the tax-rate slider. Buttons are toggles in one
## group; the active tool is what PlayInput casts with the left mouse button.
## Keys 1–8 select tools, a right click (not a right drag, which tilts the camera) or
## Esc clears the tool.
##
## Tool → command (PlayInput):
##   CLAIM       left click         ClaimTile(x, y)
##   ZONE_R/C/I  click or drag      SetZone(x, y, R / C / I) per tile entered
##   ZONE_CLEAR  click or drag      SetZone(x, y, NONE) per tile entered
##   ROAD        drag               AddEdge(prev, next) per orthogonal step
##   POWER       left click         PlacePower(x, y)
##   DEMOLISH    left click         DemolishOwn(x, y)
##   tax slider  release            SetTaxRate(value)

signal tool_changed(tool: int)
## The slider was released on a new value.
signal tax_rate_committed(rate: float)

enum Tool { NONE, CLAIM, ZONE_R, ZONE_C, ZONE_I, ZONE_CLEAR, ROAD, POWER, DEMOLISH }

const TOOL_ORDER: Array[Tool] = [
	Tool.CLAIM, Tool.ZONE_R, Tool.ZONE_C, Tool.ZONE_I, Tool.ZONE_CLEAR, Tool.ROAD, Tool.POWER, Tool.DEMOLISH
]
const TOOL_LABELS := {
	Tool.CLAIM: "1  Claim tile",
	Tool.ZONE_R: "2  Zone R",
	Tool.ZONE_C: "3  Zone C",
	Tool.ZONE_I: "4  Zone I",
	Tool.ZONE_CLEAR: "5  Clear zone",
	Tool.ROAD: "6  Road",
	Tool.POWER: "7  Power plant",
	Tool.DEMOLISH: "8  Demolish",
}
const TOOL_NAMES := {
	Tool.NONE: "none",
	Tool.CLAIM: "claim",
	Tool.ZONE_R: "zone_r",
	Tool.ZONE_C: "zone_c",
	Tool.ZONE_I: "zone_i",
	Tool.ZONE_CLEAR: "zone_clear",
	Tool.ROAD: "road",
	Tool.POWER: "power",
	Tool.DEMOLISH: "demolish",
}
const FONT_SIZE := 17
const FONT_SMALL := 14
const PANEL_WIDTH := 196.0
const TAX_STEP := 0.01

var tool: Tool = Tool.NONE
var enabled: bool = false
var slider: HSlider

var _panel: PanelContainer
var _buttons: Dictionary = {}
var _tax_label: Label
var _slider_dragging := false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_TOP_LEFT)
	_panel = PanelContainer.new()
	_panel.name = "Panel"
	_panel.position = Vector2(12, 96)
	_panel.custom_minimum_size = Vector2(PANEL_WIDTH, 0)
	_panel.add_theme_stylebox_override("panel", _flat(Palette.with_alpha(Palette.HUD_BG, 0.9), 6, 10))
	add_child(_panel)
	var column := VBoxContainer.new()
	column.name = "Column"
	column.add_theme_constant_override("separation", 6)
	_panel.add_child(column)

	var title := Label.new()
	title.text = "Tools"
	title.add_theme_font_size_override("font_size", FONT_SMALL)
	title.add_theme_color_override("font_color", Palette.HUD_TEXT_2)
	column.add_child(title)

	for entry in TOOL_ORDER:
		var button := Button.new()
		button.name = "Tool_%s" % TOOL_NAMES[entry]
		button.text = TOOL_LABELS[entry]
		button.toggle_mode = true
		button.focus_mode = Control.FOCUS_NONE
		button.alignment = HORIZONTAL_ALIGNMENT_LEFT
		button.add_theme_font_size_override("font_size", FONT_SIZE)
		button.add_theme_color_override("font_color", Palette.HUD_TEXT)
		button.add_theme_color_override("font_hover_color", Palette.HUD_TEXT)
		button.add_theme_color_override("font_pressed_color", Palette.WARN)
		button.add_theme_color_override("font_hover_pressed_color", Palette.WARN)
		button.add_theme_color_override("font_disabled_color", Palette.HUD_TEXT_2)
		button.add_theme_stylebox_override("normal", _flat(Palette.with_alpha(Palette.HUD_TEXT_2, 0.12), 4, 6))
		button.add_theme_stylebox_override("hover", _flat(Palette.with_alpha(Palette.HUD_TEXT_2, 0.24), 4, 6))
		button.add_theme_stylebox_override("disabled", _flat(Palette.with_alpha(Palette.HUD_TEXT_2, 0.06), 4, 6))
		var pressed := _flat(Palette.with_alpha(Palette.WARN, 0.18), 4, 6)
		pressed.border_width_left = 3
		pressed.border_color = Palette.WARN
		button.add_theme_stylebox_override("pressed", pressed)
		button.add_theme_stylebox_override("hover_pressed", pressed)
		button.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
		button.toggled.connect(_on_button_toggled.bind(entry))
		column.add_child(button)
		_buttons[entry] = button

	var rule := HSeparator.new()
	column.add_child(rule)

	_tax_label = Label.new()
	_tax_label.name = "TaxLabel"
	_tax_label.add_theme_font_size_override("font_size", FONT_SIZE)
	_tax_label.add_theme_color_override("font_color", Palette.HUD_TEXT)
	column.add_child(_tax_label)

	slider = HSlider.new()
	slider.name = "TaxSlider"
	slider.min_value = SliceConstants.TAX_RATE_MIN
	slider.max_value = SliceConstants.TAX_RATE_MAX
	slider.step = TAX_STEP
	slider.value = SliceConstants.TAX_RATE_DEFAULT
	slider.focus_mode = Control.FOCUS_NONE
	slider.custom_minimum_size = Vector2(PANEL_WIDTH - 20.0, 24)
	slider.drag_started.connect(_on_slider_drag_started)
	slider.drag_ended.connect(_on_slider_drag_ended)
	slider.value_changed.connect(_on_slider_value_changed)
	column.add_child(slider)

	var hint := Label.new()
	hint.text = "LMB cast · drag paints\nRMB click / Esc cancel"
	hint.add_theme_font_size_override("font_size", FONT_SMALL)
	hint.add_theme_color_override("font_color", Palette.HUD_TEXT_2)
	column.add_child(hint)

	_refresh_tax_label(slider.value)
	set_enabled(false)


func set_tool(next: int) -> void:
	if not enabled and next != Tool.NONE:
		return
	if next == tool:
		return
	tool = next as Tool
	for entry in _buttons:
		var button: Button = _buttons[entry]
		button.set_pressed_no_signal(entry == tool)
	tool_changed.emit(tool)


## Same tool again clears it; this is what the number keys do.
func toggle_tool(next: int) -> void:
	if next == tool:
		set_tool(Tool.NONE)
	else:
		set_tool(next)


func set_enabled(on: bool) -> void:
	enabled = on
	for entry in _buttons:
		var button: Button = _buttons[entry]
		button.disabled = not on
	slider.editable = on
	_panel.modulate = Color(1, 1, 1, 1.0 if on else 0.55)
	if not on:
		set_tool(Tool.NONE)


## Authoritative tax rate from FactionState (or the pending view); ignored mid-drag.
func sync_tax_rate(rate: float) -> void:
	if _slider_dragging:
		return
	slider.set_value_no_signal(rate)
	_refresh_tax_label(rate)


func button_for(entry: int) -> Button:
	return _buttons.get(entry)


static func tool_from_name(text: String) -> int:
	for entry in TOOL_NAMES:
		if TOOL_NAMES[entry] == text:
			return entry
	return Tool.NONE


## Viewport point on the slider track that selects rate; the dev input script uses it.
func tax_slider_point(rate: float) -> Vector2:
	var rect := slider.get_global_rect()
	var grab_width := float(slider.get_theme_icon("grabber").get_width())
	var ratio := clampf(
		(rate - slider.min_value) / (slider.max_value - slider.min_value), 0.0, 1.0
	)
	var x := rect.position.x + grab_width * 0.5 + ratio * (rect.size.x - grab_width)
	return Vector2(x, rect.position.y + rect.size.y * 0.5)


func _on_button_toggled(pressed: bool, entry: Tool) -> void:
	if pressed:
		set_tool(entry)
	elif tool == entry:
		set_tool(Tool.NONE)


func _on_slider_drag_started() -> void:
	_slider_dragging = true


func _on_slider_drag_ended(value_changed: bool) -> void:
	_slider_dragging = false
	if value_changed:
		tax_rate_committed.emit(snappedf(slider.value, TAX_STEP))


func _on_slider_value_changed(value: float) -> void:
	_refresh_tax_label(value)


func _refresh_tax_label(rate: float) -> void:
	_tax_label.text = "Tax rate  %d%%" % roundi(rate * 100.0)


static func _flat(color: Color, radius: int, margin: int) -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.set_content_margin_all(margin)
	return style
