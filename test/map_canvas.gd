extends Control
## Test-only drawing/picking surface. The actual map remains a ParallelMap.

signal triangle_clicked(key: Vector3i)

const FACE_COLORS := [Color("78a8d4"), Color("465b7b"), Color("e5d6a4")]
const EDIT_PAINT := 0
const EDIT_ADD := 1
const EDIT_DELETE := 2
const PLAYER_COLOR := Color("5fe0bb")
const GOAL_COLOR := Color("ffac66")

var map_data: ParallelMap
var brush: int = ParallelMap.TOP
var editing_enabled: bool = true
var hover_key: Variant = null
var edit_mode: int = EDIT_PAINT
var _scale: float = 50.0
var _offset := Vector2.ZERO
var _keys: Array = []
var _fit_keys: Array = []
var _editable_keys: Dictionary = {}
var _markers: Dictionary = {}
var _protected_keys: Dictionary = {}
var _pan_button: int = MOUSE_BUTTON_NONE
var _drawing := Node2D.new()


func _ready() -> void:
	name = "MapCanvas"
	mouse_filter = Control.MOUSE_FILTER_STOP
	mouse_default_cursor_shape = Control.CURSOR_CROSS
	clip_contents = true
	add_child(_drawing)
	_drawing.draw.connect(_draw_map)
	resized.connect(_fit_map)
	mouse_exited.connect(func() -> void:
		hover_key = null
		_drawing.queue_redraw()
	)


func set_map(value: ParallelMap) -> void:
	var new_session: bool = value != map_data
	map_data = value
	hover_key = null
	_keys = [] if map_data == null else map_data.triangles.keys()
	_keys.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z)))
	)
	if new_session:
		_fit_keys = _keys.duplicate()
		_pan_button = MOUSE_BUTTON_NONE
		_fit_map()
	else:
		_drawing.queue_redraw()


func set_editable_keys(value: Dictionary) -> void:
	if value == _editable_keys:
		return
	_editable_keys = value.duplicate()
	if _fit_keys.is_empty():
		_fit_map()
	_drawing.queue_redraw()


func set_edit_mode(value: int) -> void:
	edit_mode = clampi(value, EDIT_PAINT, EDIT_DELETE)
	hover_key = triangle_at(get_local_mouse_position()) if editing_enabled else null
	_drawing.queue_redraw()


func set_markers(value: Dictionary) -> void:
	_markers = value.duplicate(true)
	_protected_keys.clear()
	for keys: Array in _markers.values():
		for key: Vector3i in keys:
			_protected_keys[key] = true
	_drawing.queue_redraw()


func set_brush(value: int) -> void:
	brush = clampi(value, 0, 2)
	_drawing.queue_redraw()


func triangle_screen_center(key: Vector3i) -> Vector2:
	var vertices: Array[Vector2] = ParallelMap.triangle_vertices(key)
	return (vertices[0] + vertices[1] + vertices[2]) / 3.0 * _scale + _offset


func _fit_map() -> void:
	var fit_keys: Array = _fit_keys if not _fit_keys.is_empty() else _editable_keys.keys()
	if map_data == null or fit_keys.is_empty() or size.x <= 1.0 or size.y <= 1.0:
		_drawing.queue_redraw()
		return
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for key: Vector3i in fit_keys:
		for point: Vector2 in ParallelMap.triangle_vertices(key):
			minimum = minimum.min(point)
			maximum = maximum.max(point)
	var span := maximum - minimum
	var padding: float = minf(104.0, minf(size.x, size.y) * 0.25)
	_scale = minf((size.x - padding) / maxf(span.x, 1.0), (size.y - padding) / maxf(span.y, 1.0))
	_scale = clampf(_scale, 1.0, 105.0)
	_offset = size * 0.5 - (minimum + maximum) * 0.5 * _scale
	_drawing.queue_redraw()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if _pan_button != MOUSE_BUTTON_NONE:
			_offset += event.relative
			accept_event()
		hover_key = triangle_at(event.position) if editing_enabled else null
		_drawing.queue_redraw()
	if not event is InputEventMouseButton:
		return
	if event.button_index in [MOUSE_BUTTON_RIGHT, MOUSE_BUTTON_MIDDLE]:
		if event.pressed or _pan_button == event.button_index:
			_pan_button = event.button_index if event.pressed else MOUSE_BUTTON_NONE
			accept_event()
		return
	if event.pressed and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
		var map_point: Vector2 = (event.position - _offset) / _scale
		var multiplier: float = 1.2 if event.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.2
		_scale = clampf(_scale * multiplier, 5.0, 180.0)
		_offset = event.position - map_point * _scale
		hover_key = triangle_at(event.position) if editing_enabled else null
		_drawing.queue_redraw()
		accept_event()
		return
	if event.button_index == MOUSE_BUTTON_LEFT and event.pressed and editing_enabled:
		var key: Variant = triangle_at(event.position)
		if key != null:
			triangle_clicked.emit(key)
			accept_event()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT:
		_pan_button = MOUSE_BUTTON_NONE


func triangle_at(point: Vector2) -> Variant:
	if map_data == null:
		return null
	var map_point := (point - _offset) / _scale
	# Invert the oblique lattice coordinates, then choose the half of the unit cell.
	var offset: float = map_point.x / (2.0 * ParallelMap.SQRT_3_OVER_2)
	var oblique := Vector2(map_point.y + offset, map_point.y - offset)
	var cell := Vector2i(floori(oblique.x), floori(oblique.y))
	var fraction: Vector2 = oblique - Vector2(cell)
	var half: int = 0 if fraction.x >= fraction.y else 1
	var key := Vector3i(cell.x, cell.y, half)
	if _can_pick(key):
		return key
	# A click exactly on an edge can also belong to a neighboring editable triangle.
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for side in range(2):
				key = Vector3i(cell.x + dx, cell.y + dy, side)
				if _can_pick(key) and Geometry2D.is_point_in_polygon(map_point, PackedVector2Array(ParallelMap.triangle_vertices(key))):
					return key
	return null


func _can_pick(key: Vector3i) -> bool:
	var occupied: bool = map_data.triangles.has(key)
	if edit_mode == EDIT_ADD:
		return not occupied and _editable_keys.has(key)
	return occupied


func _screen_triangle(key: Vector3i) -> PackedVector2Array:
	var triangle := PackedVector2Array()
	for point: Vector2 in ParallelMap.triangle_vertices(key):
		triangle.append(point * _scale + _offset)
	return triangle


func _stroke_triangle(triangle: PackedVector2Array, color: Color, width: float) -> void:
	var outline: PackedVector2Array = triangle.duplicate()
	outline.append(outline[0])
	_drawing.draw_polyline(outline, color, width, true)


func _draw_map() -> void:
	if map_data == null:
		return
	if edit_mode == EDIT_ADD:
		for key: Vector3i in _editable_keys:
			if not map_data.triangles.has(key):
				_stroke_triangle(_screen_triangle(key), Color(0.42, 0.53, 0.66, 0.21), 1.0)
	for key: Vector3i in _keys:
		var triangle: PackedVector2Array = _screen_triangle(key)
		var orientation: int = int(map_data.triangles[key])
		_drawing.draw_colored_polygon(triangle, FACE_COLORS[orientation])
		_stroke_triangle(triangle, Color(0.10, 0.15, 0.23, 0.9), 1.2)
	if hover_key != null and editing_enabled and _can_pick(hover_key):
		var hover_triangle: PackedVector2Array = _screen_triangle(hover_key)
		var locked: bool = _protected_keys.has(hover_key) and (edit_mode == EDIT_DELETE or brush != ParallelMap.TOP)
		var removing: bool = edit_mode == EDIT_DELETE or locked
		var preview: Color = Color("fb6677") if removing else FACE_COLORS[brush]
		preview.a = 0.48
		_drawing.draw_colored_polygon(hover_triangle, preview)
		_stroke_triangle(hover_triangle, Color("fb6677") if removing else Color("f2f7ff"), 2.5)
	_draw_markers()


func _draw_markers() -> void:
	var player: Array = _markers.get("player", [])
	var goal: Array = _markers.get("goal", [])
	var shared_face: bool = not player.is_empty() and player == goal
	if not player.is_empty():
		_draw_marker(_marker_anchor(player), Vector2(-11.0, -13.0) if shared_face else Vector2(0.0, -13.0), PLAYER_COLOR, "P")
	if not goal.is_empty():
		_draw_marker(_marker_anchor(goal), Vector2(11.0, -13.0) if shared_face else Vector2(0.0, -13.0), GOAL_COLOR, "G")


func _marker_anchor(keys: Array) -> Vector2:
	var anchor := Vector2.ZERO
	for key: Vector3i in keys:
		anchor += triangle_screen_center(key)
	return anchor / float(keys.size())


func _draw_marker(anchor: Vector2, offset: Vector2, color: Color, caption: String) -> void:
	var center: Vector2 = anchor + offset
	var ink := Color("152239")
	_drawing.draw_line(anchor, center, ink, 3.0, true)
	_drawing.draw_circle(center, 10.0, ink, true, -1.0, true)
	_drawing.draw_circle(center, 8.0, color, true, -1.0, true)
	var font: Font = ThemeDB.fallback_font
	var caption_size: Vector2 = font.get_string_size(caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12)
	_drawing.draw_string(font, center + Vector2(-caption_size.x * 0.5, 4.0), caption, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, ink)
