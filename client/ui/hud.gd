class_name Hud
extends Control

## HUD over the city (art brief S04): background #12151A, primary #E8ECF0,
## secondary #8B939C, faction A positive, faction B negative, warn #F0C93A.
## Shows treasury, income per second, population, jobs, tax rate (FactionState),
## time remaining (ScoreTick.seconds_remaining as d h m s), both totals, the last
## five alerts with their time, the crisis banner, and the connection line.

const FONT_BODY := 18
const FONT_SMALL := 15
const FONT_BANNER := 21
const REFRESH_SEC := 0.25
const MARGIN := 12.0
const ALERTS_WIDTH := 380.0
const ALERTS_TOP := 96.0
const BANNER_TOP := 88.0

var session: ClientSession = null
var connection_text: String = ""
var connection_warn: bool = false
var hover_text: String = ""

var _funds: Label
var _income: Label
var _pop: Label
var _jobs: Label
var _tax: Label
var _clock: Label
var _scores: RichTextLabel
var _alert_lines: Array[Label] = []
var _clock_panel: PanelContainer
var _alerts_panel: PanelContainer
var _status_panel: PanelContainer
var _banner: PanelContainer
var _banner_label: Label
var _status: Label
var _overlay: PanelContainer
var _overlay_label: Label
var _refresh_left := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_build_stats()
	_build_clock()
	_build_alerts()
	_build_banner()
	_build_status()
	_build_overlay()
	resized.connect(_layout)
	get_viewport().size_changed.connect(_layout)
	_layout.call_deferred()
	refresh()


func bind(p_session: ClientSession) -> void:
	session = p_session
	session.updated.connect(refresh)
	refresh()


func _process(delta: float) -> void:
	_refresh_left -= delta
	if _refresh_left <= 0.0:
		_refresh_left = REFRESH_SEC
		refresh()


func refresh() -> void:
	var state: FactionState = null
	if session != null:
		state = session.faction_state
	if state != null:
		_funds.text = format_int(roundi(state.treasury))
		_income.text = "%+.1f/s" % state.income_per_sec
		_pop.text = format_int(state.population)
		_jobs.text = format_int(state.jobs)
		_income.add_theme_color_override(
			"font_color", Palette.HUD_POSITIVE if state.income_per_sec >= 0.0 else Palette.HUD_NEGATIVE
		)
	else:
		_funds.text = "--"
		_income.text = "--"
		_pop.text = "--"
		_jobs.text = "--"
	if session != null:
		_tax.text = "%d%%" % roundi(session.view_tax_rate() * 100.0)
	else:
		_tax.text = "--"
	_refresh_clock_and_scores()
	_refresh_alerts()
	_refresh_banner()
	_refresh_status()
	_refresh_overlay()


## d h m s, as in "6d 23h 59m 30s".
static func format_duration(total_seconds: int) -> String:
	var seconds := maxi(0, total_seconds)
	var days := seconds / 86400
	var hours := (seconds % 86400) / 3600
	var minutes := (seconds % 3600) / 60
	var secs := seconds % 60
	return "%dd %02dh %02dm %02ds" % [days, hours, minutes, secs]


static func format_int(value: int) -> String:
	var negative := value < 0
	var digits := str(absi(value))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	if negative:
		out = "-" + out
	return out


func _refresh_clock_and_scores() -> void:
	var tick: ScoreTick = null
	if session != null:
		tick = session.last_score
	if tick == null:
		_clock.text = "Round  --"
		_scores.text = "[color=%s]A --[/color]   [color=%s]B --[/color]" % [
			Palette.hex(Palette.FACTION_A), Palette.hex(Palette.FACTION_B)
		]
		return
	_clock.text = "Round  %s" % format_duration(tick.seconds_remaining)
	var a_text := "--"
	var b_text := "--"
	for line in tick.factions:
		var pct := "%d%%" % roundi(line.total() * 100.0)
		if line.faction == SliceConstants.Owner.FACTION_A:
			a_text = pct
		elif line.faction == SliceConstants.Owner.FACTION_B:
			b_text = pct
	_scores.text = "[color=%s]A %s[/color]   [color=%s]B %s[/color]" % [
		Palette.hex(Palette.FACTION_A), a_text, Palette.hex(Palette.FACTION_B), b_text
	]


func _refresh_alerts() -> void:
	var alerts: Array[Dictionary] = []
	if session != null:
		alerts = session.alerts
	for i in _alert_lines.size():
		var line := _alert_lines[i]
		var index := alerts.size() - 1 - i
		if index < 0:
			line.text = ""
			line.visible = false
			continue
		var alert: Dictionary = alerts[index]
		line.visible = true
		line.text = "%s  %s" % [alert["time"], alert["text"]]
		var color := Palette.WARN
		if int(alert["kind"]) == ClientSession.AlertKind.REJECT:
			color = Palette.HUD_NEGATIVE
		line.add_theme_color_override("font_color", color)


func _refresh_banner() -> void:
	var crisis: CrisisEvent = null
	if session != null:
		crisis = session.crisis
	if crisis == null or not crisis.active:
		_banner.visible = false
		return
	_banner.visible = true
	var kind := crisis.kind.to_upper().replace("_", " ")
	if kind.is_empty():
		kind = "CRISIS"
	var left := ""
	if crisis.ends_at_unix > 0:
		var remaining := crisis.ends_at_unix - int(Time.get_unix_time_from_system())
		if remaining > 0:
			left = "  ·  %d:%02d left" % [remaining / 60, remaining % 60]
	var detail := ""
	if crisis.kind == CrisisEvent.KIND_GRID_STORM:
		detail = "  ·  plant capacity halved"
	elif not crisis.detail.is_empty():
		detail = "  ·  %s" % crisis.detail
	_banner_label.text = "%s%s%s" % [kind, detail, left]


func _refresh_status() -> void:
	var parts: Array[String] = []
	if not connection_text.is_empty():
		parts.append(connection_text)
	if session != null:
		parts.append("faction %s" % ClientSession.faction_name(session.faction))
		if session.welcome != null and not session.welcome.name.is_empty():
			parts.append(session.welcome.name)
		if session.pending_count() > 0:
			parts.append("pending %d" % session.pending_count())
	if not hover_text.is_empty():
		parts.append(hover_text)
	_status.text = "  ·  ".join(parts)
	_status.add_theme_color_override("font_color", Palette.WARN if connection_warn else Palette.HUD_TEXT_2)


func _refresh_overlay() -> void:
	var text := ""
	if connection_warn:
		text = connection_text
	elif session != null and session.match_end != null:
		var winner := ClientSession.faction_name(session.match_end.winner)
		if session.match_end.winner == SliceConstants.Owner.NEUTRAL:
			winner = "nobody"
		text = "Round over  ·  winner %s  ·  %s" % [winner, session.match_end.reason]
	elif session != null and not session.match_started and not connection_text.is_empty():
		text = "Waiting for the round to start"
	_overlay.visible = not text.is_empty()
	_overlay_label.text = text
	_overlay_label.add_theme_color_override("font_color", Palette.WARN if connection_warn else Palette.HUD_TEXT)


func _build_stats() -> void:
	var panel := _panel(Vector2(MARGIN, MARGIN))
	panel.name = "Stats"
	var row := HBoxContainer.new()
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_theme_constant_override("separation", 22)
	panel.add_child(row)
	_funds = _stat(row, "Treasury")
	_income = _stat(row, "Income")
	_pop = _stat(row, "Population")
	_jobs = _stat(row, "Jobs")
	_tax = _stat(row, "Tax")


func _stat(row: HBoxContainer, title: String) -> Label:
	var cell := VBoxContainer.new()
	cell.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cell.add_theme_constant_override("separation", 0)
	var head := Label.new()
	head.text = title
	head.add_theme_font_size_override("font_size", FONT_SMALL)
	head.add_theme_color_override("font_color", Palette.HUD_TEXT_2)
	cell.add_child(head)
	var value := Label.new()
	value.text = "--"
	value.add_theme_font_size_override("font_size", FONT_BODY)
	value.add_theme_color_override("font_color", Palette.HUD_TEXT)
	cell.add_child(value)
	row.add_child(cell)
	return value


func _build_clock() -> void:
	_clock_panel = _panel(Vector2.ZERO)
	_clock_panel.name = "Clock"
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 2)
	_clock_panel.add_child(column)
	_clock = Label.new()
	_clock.add_theme_font_size_override("font_size", FONT_BODY)
	_clock.add_theme_color_override("font_color", Palette.HUD_TEXT)
	_clock.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	column.add_child(_clock)
	_scores = RichTextLabel.new()
	_scores.bbcode_enabled = true
	_scores.fit_content = true
	_scores.scroll_active = false
	_scores.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_scores.autowrap_mode = TextServer.AUTOWRAP_OFF
	_scores.custom_minimum_size = Vector2(200, 0)
	_scores.add_theme_font_size_override("normal_font_size", FONT_BODY)
	_scores.add_theme_color_override("default_color", Palette.HUD_TEXT)
	column.add_child(_scores)
	_clock_panel.resized.connect(_layout)


func _build_alerts() -> void:
	_alerts_panel = _panel(Vector2.ZERO)
	_alerts_panel.name = "Alerts"
	_alerts_panel.custom_minimum_size = Vector2(ALERTS_WIDTH, 0)
	var column := VBoxContainer.new()
	column.mouse_filter = Control.MOUSE_FILTER_IGNORE
	column.add_theme_constant_override("separation", 2)
	_alerts_panel.add_child(column)
	var title := Label.new()
	title.text = "Alerts"
	title.add_theme_font_size_override("font_size", FONT_SMALL)
	title.add_theme_color_override("font_color", Palette.HUD_TEXT_2)
	column.add_child(title)
	for i in ClientSession.MAX_ALERTS:
		var line := Label.new()
		line.add_theme_font_size_override("font_size", FONT_SMALL)
		line.add_theme_color_override("font_color", Palette.WARN)
		line.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		line.visible = false
		column.add_child(line)
		_alert_lines.append(line)
	_alerts_panel.resized.connect(_layout)


func _build_banner() -> void:
	_banner = PanelContainer.new()
	_banner.name = "CrisisBanner"
	_banner.add_theme_stylebox_override("panel", Palette.panel_style(Palette.WARN, 6, 10))
	_banner.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_banner.visible = false
	add_child(_banner)
	_banner_label = Label.new()
	_banner_label.add_theme_font_size_override("font_size", FONT_BANNER)
	_banner_label.add_theme_color_override("font_color", Palette.HUD_BG)
	_banner_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_banner.add_child(_banner_label)
	_banner.resized.connect(_layout)


func _build_status() -> void:
	_status_panel = _panel(Vector2.ZERO)
	_status_panel.name = "Status"
	_status = Label.new()
	_status.add_theme_font_size_override("font_size", FONT_SMALL)
	_status.add_theme_color_override("font_color", Palette.HUD_TEXT_2)
	_status_panel.add_child(_status)
	_status_panel.resized.connect(_layout)


## Control.position is relative to the parent's top-left whatever the anchors are,
## so the right- and bottom-aligned panels are placed from the viewport area (this
## control sits under a CanvasLayer, so its parent area is the viewport).
func _layout() -> void:
	var area := get_parent_area_size()
	if area.x <= 0.0 or area.y <= 0.0:
		area = size
	if area.x <= 0.0 or area.y <= 0.0:
		return
	_clock_panel.position = Vector2(area.x - MARGIN - _clock_panel.size.x, MARGIN)
	_alerts_panel.position = Vector2(area.x - MARGIN - _alerts_panel.size.x, ALERTS_TOP)
	_banner.position = Vector2((area.x - _banner.size.x) * 0.5, BANNER_TOP)
	_status_panel.position = Vector2(MARGIN, area.y - MARGIN - _status_panel.size.y)


func _build_overlay() -> void:
	var center := CenterContainer.new()
	center.name = "OverlayCenter"
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(center)
	_overlay = PanelContainer.new()
	_overlay.name = "Overlay"
	_overlay.add_theme_stylebox_override("panel", Palette.panel_style(Palette.with_alpha(Palette.HUD_BG, 0.92), 8, 18))
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_overlay.visible = false
	center.add_child(_overlay)
	_overlay_label = Label.new()
	_overlay_label.add_theme_font_size_override("font_size", FONT_BANNER)
	_overlay_label.add_theme_color_override("font_color", Palette.HUD_TEXT)
	_overlay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_overlay.add_child(_overlay_label)


func _panel(at: Vector2) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.position = at
	panel.add_theme_stylebox_override("panel", Palette.panel_style(Palette.with_alpha(Palette.HUD_BG, 0.88), 6, 10))
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(panel)
	return panel
