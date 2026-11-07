extends Node
## 主游戏循环。场景负责显示与布局，本脚本统一管理输入、编辑事务及后台重建。

enum State { GEOMETRY, EDITING, RECONSTRUCTING }
enum Tool { BRUSH, ERASER }

const VIEW_DIRECTIONS: Array[Vector3] = [Vector3(1, 1, 1), Vector3(-1, 1, 1), Vector3(-1, 1, -1), Vector3(1, 1, -1)]
const FACE_ORDER: Array[int] = [ParallelMap.TOP, ParallelMap.LEFT, ParallelMap.RIGHT]
const FACE_COLORS: Array[Color] = [Color("78a8d4"), Color("465b7b"), Color("e5d6a4")]

@export_category("初始几何体")
@export var min_cell := Vector3i(-3, 0, -3)
@export var max_cell := Vector3i(3, 6, 3)
@export_range(1, 343) var initial_voxel_count: int = 20
## 0 表示每次启动随机生成；其他值用于复现初态。
@export var random_seed: int = 0

@export_category("游戏操作")
@export_range(1, 100) var edit_limit: int = 10
@export_range(1, 100) var history_limit: int = 30
@export var orbit_sensitivity: float = 0.009
@export var snap_duration: float = 0.26
## 视图留白：左、上、右、下。调整 UI 后可同步修改。
@export var view_margins := Vector4(48, 48, 48, 224)

@export_category("重建预算")
@export_range(1, 60000) var search_time_ms: int = 4500
@export_range(1, 100000) var search_nodes: int = 2200

var state: State = State.GEOMETRY
var geometry: Geometry
var parallel_map: ParallelMap
var view_index: int = 0
var tool: Tool = Tool.BRUSH
var face: int = ParallelMap.TOP
var last_result: Dictionary = {}

var _edits: Array[Dictionary] = []
var _cycles: Array[Dictionary] = []
var _round_snapshot: Dictionary = {}
var _editable_keys: Dictionary = {}
var _search_multiplier: int = 1
var _worker: Thread
var _orbit_angles := Vector2(PI / 4.0, asin(1.0 / sqrt(3.0)))
var _snap_tween: Tween
var _drag_button: int = MOUSE_BUTTON_NONE
var _last_pointer := Vector2.ZERO
var _map_scale: float = 50.0
var _map_offset := Vector2.ZERO
var _hover_key: Variant = null

@onready var _geometry_view: Node3D = $GeometryView
@onready var _solid: MeshInstance3D = $GeometryView/Solid
@onready var _outline: MeshInstance3D = $GeometryView/Outline
@onready var _camera: Camera3D = $GeometryView/Camera3D
@onready var _map_view: Node2D = $ParallelMapView
@onready var _ui: CanvasLayer = $UIGame
## UI 内使用场景唯一名查找，工具组的位置和层级可以自由调整。
@onready var _convert: Button = _ui.get_node("%ConvertButton")
@onready var _undo: Button = _ui.get_node("%UndoButton")
@onready var _menu: Control = _ui.get_node("%EditMenu")
@onready var _undo_edit: Button = _ui.get_node("%UndoEditButton")
@onready var _status: Label = _ui.get_node("%StatusLabel")
@onready var _budget: Label = _ui.get_node("%BudgetLabel")
@onready var _tools: Array[Button] = [_ui.get_node("%BrushButton"), _ui.get_node("%EraserButton")]
@onready var _faces: Array[Button] = [_ui.get_node("%TopButton"), _ui.get_node("%LeftButton"), _ui.get_node("%RightButton")]


func _ready() -> void:
	_convert.pressed.connect(_convert_view)
	_undo.pressed.connect(_undo_view)
	_undo_edit.pressed.connect(undo_edit)
	for index: int in range(_tools.size()):
		_tools[index].pressed.connect(select_tool.bind(index))
	for index: int in range(_faces.size()):
		_faces[index].pressed.connect(select_face.bind(FACE_ORDER[index]))
	_map_view.draw.connect(_draw_map)
	get_viewport().size_changed.connect(_fit_views)
	generate_geometry()


func _process(_delta: float) -> void:
	if _worker != null and not _worker.is_alive():
		var result: Variant = _worker.wait_to_finish()
		_worker = null
		state = State.EDITING
		if result is Dictionary:
			_handle_result(result)
		else:
			_status.text = "重建未返回有效结果，请重试。"
			_refresh_ui()


func _exit_tree() -> void:
	# 核心求解器没有取消接口，离开场景前回收线程。
	if _worker != null and _worker.is_started():
		_worker.wait_to_finish()


## 生成边界内的连通初态。每次只向已有体素的共面邻格生长。
func generate_geometry() -> void:
	if state != State.GEOMETRY:
		return
	if min_cell != min_cell.min(max_cell):
		push_error("几何体允许范围无效。")
		return
	var rng := RandomNumberGenerator.new()
	if random_seed == 0:
		rng.randomize()
	else:
		rng.seed = random_seed
	var cells: Dictionary = {Vector3i.ZERO.max(min_cell).min(max_cell): true}
	var span := max_cell - min_cell + Vector3i.ONE
	var count := mini(initial_voxel_count, span.x * span.y * span.z)
	while cells.size() < count:
		var frontier: Dictionary = {}
		for cell: Vector3i in cells:
			for delta: Vector3i in Geometry.NEIGHBORS:
				var next := cell + delta
				if _inside(next) and not cells.has(next):
					frontier[next] = true
		var choices: Array = frontier.keys()
		choices.sort_custom(Geometry.cell_less)
		cells[choices[rng.randi_range(0, choices.size() - 1)]] = true
	geometry = Geometry.new(cells)
	view_index = 0
	_cycles.clear()
	_show_geometry()
	_status.text = "拖动旋转，松开后吸附到等轴测视角。"


## GUI 先处理按钮点击；未被 GUI 消耗的按下事件才会开始视图手势。
func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventMouseButton or not event.pressed or _drag_button != MOUSE_BUTTON_NONE:
		return
	if _over_ui(event.position):
		return
	if state == State.GEOMETRY and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT]:
		_stop_snap()
		_drag_button = event.button_index
	elif state == State.EDITING and event.button_index == MOUSE_BUTTON_LEFT:
		_drag_button = event.button_index
		_paint_at(event.position)
	else:
		return
	_last_pointer = event.position
	get_viewport().set_input_as_handled()


## 已开始的手势在全局接收移动和松开，避免移到 UI 上后丢失释放事件。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion:
		if state == State.EDITING:
			_update_hover(event.position)
		if _drag_button == MOUSE_BUTTON_NONE:
			return
		if state == State.GEOMETRY:
			_orbit_angles.x = wrapf(_orbit_angles.x + event.relative.x * orbit_sensitivity, -PI, PI)
			_orbit_angles.y = clampf(_orbit_angles.y + event.relative.y * orbit_sensitivity, deg_to_rad(-88), deg_to_rad(88))
			_update_camera()
		elif state == State.EDITING:
			# 按线段补采样，快速拖动时也能覆盖经过的三角格。
			var steps := maxi(1, ceili(_last_pointer.distance_to(event.position) / maxf(_map_scale * 0.2, 1.0)))
			for step: int in range(1, steps + 1):
				_paint_at(_last_pointer.lerp(event.position, float(step) / steps))
		_last_pointer = event.position
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton and not event.pressed and event.button_index == _drag_button:
		_drag_button = MOUSE_BUTTON_NONE
		if state == State.GEOMETRY:
			_snap_to_view()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _drag_button != MOUSE_BUTTON_NONE:
		_drag_button = MOUSE_BUTTON_NONE
		if state == State.GEOMETRY:
			_snap_to_view()


func _convert_view() -> void:
	if state == State.GEOMETRY:
		enter_map_mode()
	elif state == State.EDITING:
		start_reconstruction()


func _undo_view() -> void:
	if state == State.GEOMETRY:
		undo_cycle()
	elif state == State.EDITING:
		cancel_map_mode()


## 进入编辑前先固定等轴测视角，原几何体在本轮提交前保持不变。
func enter_map_mode() -> bool:
	if state != State.GEOMETRY or geometry == null:
		return false
	_stop_snap()
	_drag_button = MOUSE_BUTTON_NONE
	view_index = _nearest_view()
	_orbit_angles = _view_angles(view_index)
	_update_camera()
	_round_snapshot = {"geometry": geometry.duplicate_geometry(), "view": view_index}
	parallel_map = ParallelMap.from_geometry(geometry, view_index)
	_editable_keys.clear()
	for x: int in range(min_cell.x, max_cell.x + 1):
		for y: int in range(min_cell.y, max_cell.y + 1):
			for z: int in range(min_cell.z, max_cell.z + 1):
				var local := ParallelMap.world_to_view_cell(Vector3i(x, y, z), view_index)
				for key: Vector3i in ParallelMap.footprint(local):
					_editable_keys[key] = true
	_edits.clear()
	_invalidate_result()
	state = State.EDITING
	_fit_map()
	_status.text = "画笔可以改色和添加，橡皮可以删除；撤回会返还编辑额度。"
	_refresh_ui()
	return true


func cancel_map_mode() -> bool:
	if state != State.EDITING:
		return false
	geometry = _round_snapshot["geometry"].duplicate_geometry()
	view_index = _round_snapshot["view"]
	_show_geometry()
	_status.text = "已取消本轮编辑。"
	return true


func undo_cycle() -> bool:
	if state != State.GEOMETRY or _cycles.is_empty():
		return false
	var snapshot: Dictionary = _cycles.pop_back()
	geometry = snapshot["geometry"].duplicate_geometry()
	view_index = snapshot["view"]
	_show_geometry()
	_status.text = "已撤销一个完整循环。"
	return true


func select_tool(value: int) -> void:
	if state == State.EDITING and value in [Tool.BRUSH, Tool.ERASER]:
		tool = value
		_update_hover(get_viewport().get_mouse_position())
		_refresh_ui()


func select_face(value: int) -> void:
	if state == State.EDITING and value in FACE_ORDER:
		face = value
		_map_view.queue_redraw()
		_refresh_ui()


## 改色、添加、删除共用同一份历史；缺少键代表空白。
func edit_triangle(key: Vector3i) -> bool:
	if state != State.EDITING or not _editable_keys.has(key):
		return false
	var before: Variant = parallel_map.triangles.get(key)
	var after: Variant = face if tool == Tool.BRUSH else null
	if before == after:
		return false
	if _edits.size() >= edit_limit:
		_status.text = "本轮编辑额度已用完，可以撤回或尝试重建。"
		return false
	_edits.append({"key": key, "before": before})
	_set_triangle(key, after)
	_invalidate_result()
	_status.text = "已修改 %d 格。" % _edits.size()
	_refresh_ui()
	return true


func undo_edit() -> bool:
	if state != State.EDITING or _edits.is_empty():
		return false
	var edit: Dictionary = _edits.pop_back()
	_set_triangle(edit["key"], edit["before"])
	_invalidate_result()
	_status.text = "已撤回一次修改，并返还编辑额度。"
	_refresh_ui()
	return true


func _set_triangle(key: Vector3i, value: Variant) -> void:
	if value == null:
		parallel_map.triangles.erase(key)
	else:
		parallel_map.triangles[key] = value
	_map_view.queue_redraw()


func _invalidate_result() -> void:
	last_result = {}
	_search_multiplier = 1


## 工作线程只接收数据副本，不访问场景树或生成 Mesh。
func start_reconstruction() -> bool:
	if state != State.EDITING:
		return false
	_drag_button = MOUSE_BUTTON_NONE
	_hover_key = null
	var options := {"time_budget_ms": search_time_ms * _search_multiplier, "max_search_nodes": search_nodes * _search_multiplier}
	_worker = Thread.new()
	var error := _worker.start(GeometryReconstructor.reconstruct.bind(parallel_map.duplicate_map(), _round_snapshot["geometry"].duplicate_geometry(), min_cell, max_cell, options))
	if error != OK:
		_worker = null
		_status.text = "无法启动重建，请重试。"
		return false
	state = State.RECONSTRUCTING
	_status.text = "正在重建几何体，请稍候…"
	_refresh_ui()
	return true


func _handle_result(result: Dictionary) -> void:
	last_result = result
	var rebuilt: Geometry = result.get("geometry")
	if result.get("status") == "optimal" and bool(result.get("optimal", false)) and rebuilt != null:
		var valid := rebuilt.is_face_connected()
		for cell: Vector3i in rebuilt.voxels:
			valid = valid and _inside(cell)
		if valid and ParallelMap.from_geometry(rebuilt, view_index).projection_equal(parallel_map):
			_cycles.append(_round_snapshot)
			if _cycles.size() > history_limit:
				_cycles.pop_front()
			geometry = rebuilt.duplicate_geometry()
			_show_geometry()
			_status.text = "转换完成，体素改动 %d 块。" % int(result["edit_cost"])
			return
		_status.text = "重建结果未通过复查，已保留编辑图。"
	elif result.get("status") in ["feasible", "budget_exceeded"]:
		# 当前接口不支持恢复搜索栈；重试同一输入时加倍预算，最多八倍。
		_search_multiplier = mini(_search_multiplier * 2, 8)
		_status.text = "尚未完成最优判断，可继续重建，或调整编辑图。"
	elif result.get("status") == "infeasible":
		_status.text = "当前编辑无法形成符合规则的几何体，请撤回或调整。"
	else:
		_status.text = "重建未提交：" + str(result.get("message", "未知错误"))
	_refresh_ui()


func _show_geometry() -> void:
	_stop_snap()
	state = State.GEOMETRY
	parallel_map = null
	_round_snapshot = {}
	_edits.clear()
	_editable_keys.clear()
	_hover_key = null
	_drag_button = MOUSE_BUTTON_NONE
	_orbit_angles = _view_angles(view_index)
	_solid.mesh = geometry.build_mesh()
	_outline.mesh = geometry.build_outline_mesh()
	_update_camera()
	_refresh_ui()


func _refresh_ui() -> void:
	var editing := state != State.GEOMETRY
	var busy := state == State.RECONSTRUCTING
	_geometry_view.visible = not editing
	_map_view.visible = editing
	_menu.visible = editing
	_convert.text = "进入轴测图" if not editing else ("继续重建" if _search_multiplier > 1 else "重建几何体")
	if busy:
		_convert.text = "正在重建…"
	_convert.disabled = busy
	_undo.text = "取消本次编辑" if editing else "撤销完整循环"
	_undo.disabled = busy or (not editing and _cycles.is_empty())
	_undo_edit.disabled = busy or _edits.is_empty()
	_budget.text = "剩余编辑 %d / %d" % [edit_limit - _edits.size(), edit_limit]
	for index: int in range(_tools.size()):
		_tools[index].disabled = busy
		_tools[index].set_pressed_no_signal(index == tool)
	for index: int in range(_faces.size()):
		_faces[index].disabled = busy
		_faces[index].set_pressed_no_signal(FACE_ORDER[index] == face)
	_map_view.queue_redraw()


## 相机绕几何中心旋转；方向与投影编号共用同一套四向定义。
func _orbit_direction() -> Vector3:
	return Vector3(cos(_orbit_angles.x) * cos(_orbit_angles.y), sin(_orbit_angles.y), sin(_orbit_angles.x) * cos(_orbit_angles.y))


func _view_angles(index: int) -> Vector2:
	var direction := VIEW_DIRECTIONS[index].normalized()
	return Vector2(atan2(direction.z, direction.x), asin(direction.y))


func _nearest_view() -> int:
	var best := 0
	for index: int in range(1, VIEW_DIRECTIONS.size()):
		if _orbit_direction().dot(VIEW_DIRECTIONS[index]) > _orbit_direction().dot(VIEW_DIRECTIONS[best]):
			best = index
	return best


func _stop_snap() -> void:
	if _snap_tween != null:
		_snap_tween.kill()
		_snap_tween = null


func _snap_to_view() -> void:
	_stop_snap()
	view_index = _nearest_view()
	var target := _view_angles(view_index)
	target.x = _orbit_angles.x + angle_difference(_orbit_angles.x, target.x)
	_snap_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_method(_apply_angles, _orbit_angles, target, snap_duration)
	_snap_tween.finished.connect(func() -> void: _snap_tween = null)


func _apply_angles(value: Vector2) -> void:
	_orbit_angles = value
	_update_camera()


func _inside(cell: Vector3i) -> bool:
	return cell == cell.max(min_cell) and cell == cell.min(max_cell)


func _view_rect() -> Rect2:
	var size := get_viewport().get_visible_rect().size
	return Rect2(Vector2(view_margins.x, view_margins.y), (size - Vector2(view_margins.x + view_margins.z, view_margins.y + view_margins.w)).max(Vector2.ONE))


func _fit_views() -> void:
	_update_camera()
	if parallel_map != null:
		_fit_map()


## 三维与二维使用相同的可视区域，保证切换时投影的位置和比例一致。
func _update_camera() -> void:
	if geometry == null:
		return
	var center := geometry.get_bounds().get_center()
	var direction := _orbit_direction()
	var distance := geometry.get_bounds().size.length() + 10.0
	_camera.position = center + direction * distance
	_camera.look_at(center, Vector3.UP)
	var right := _camera.global_basis.x
	var up := _camera.global_basis.y
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for cell: Vector3i in geometry.voxels:
		for x: int in range(2):
			for y: int in range(2):
				for z: int in range(2):
					var point := Vector3(cell) + Vector3(x, y, z)
					var projected := Vector2(point.dot(right), point.dot(up))
					minimum = minimum.min(projected)
					maximum = maximum.max(projected)
	var area := _view_rect()
	var span := (maximum - minimum).max(Vector2.ONE * 0.01)
	var scale := minf(minf(area.size.x / span.x, area.size.y / span.y), 105.0 / sqrt(2.0 / 3.0))
	var projected_center := (minimum + maximum) * 0.5
	var screen_center := get_viewport().get_visible_rect().size * 0.5
	center += right * (projected_center.x - center.dot(right) + (screen_center.x - area.get_center().x) / scale)
	center += up * (projected_center.y - center.dot(up) - (screen_center.y - area.get_center().y) / scale)
	_camera.position = center + direction * distance
	_camera.look_at(center, Vector3.UP)
	_camera.size = screen_center.y * 2.0 / scale
	_camera.far = maxf(100.0, distance * 2.0)


func _fit_map() -> void:
	# 空图仍允许继续编辑；窗口变化时保留原来的网格变换。
	if parallel_map.triangles.is_empty():
		_map_view.queue_redraw()
		return
	var minimum := Vector2(INF, INF)
	var maximum := Vector2(-INF, -INF)
	for key: Vector3i in parallel_map.triangles:
		for point: Vector2 in ParallelMap.triangle_vertices(key):
			minimum = minimum.min(point)
			maximum = maximum.max(point)
	var area := _view_rect()
	var span := (maximum - minimum).max(Vector2.ONE * 0.01)
	_map_scale = minf(minf(area.size.x / span.x, area.size.y / span.y), 105.0)
	_map_offset = area.get_center() - (minimum + maximum) * 0.5 * _map_scale
	_map_view.queue_redraw()


## 画布坐标变换只影响显示，不改变三角格与体素的对应关系。
func _triangle_at(point: Vector2) -> Variant:
	var local := (point - _map_offset) / _map_scale
	var offset := local.x / (2.0 * ParallelMap.SQRT_3_OVER_2)
	var oblique := Vector2(local.y + offset, local.y - offset)
	var cell := Vector2i(floori(oblique.x), floori(oblique.y))
	var fraction := oblique - Vector2(cell)
	var key := Vector3i(cell.x, cell.y, 0 if fraction.x >= fraction.y else 1)
	return key if _editable_keys.has(key) else null


func _over_ui(point: Vector2) -> bool:
	for button: Button in [_convert, _undo, _undo_edit] + _tools + _faces:
		if button.is_visible_in_tree() and button.get_global_rect().has_point(point):
			return true
	return false


func _paint_at(point: Vector2) -> void:
	if _over_ui(point):
		return
	var key: Variant = _triangle_at(point)
	if key != null:
		edit_triangle(key)


func _update_hover(point: Vector2) -> void:
	var key: Variant = null if _over_ui(point) else _triangle_at(point)
	if key != null and tool == Tool.ERASER and not parallel_map.triangles.has(key):
		key = null
	if key != _hover_key:
		_hover_key = key
		_map_view.queue_redraw()


func _screen_triangle(key: Vector3i) -> PackedVector2Array:
	var points := PackedVector2Array()
	for point: Vector2 in ParallelMap.triangle_vertices(key):
		points.append(point * _map_scale + _map_offset)
	return points


func _draw_triangle_border(points: PackedVector2Array, color: Color, width: float) -> void:
	var border := points.duplicate()
	border.append(points[0])
	_map_view.draw_polyline(border, color, width, true)


## Node2D 的 draw 信号连接到本脚本，无需另挂画布脚本。
func _draw_map() -> void:
	if parallel_map == null:
		return
	if tool == Tool.BRUSH:
		for key: Vector3i in _editable_keys:
			if not parallel_map.triangles.has(key):
				_draw_triangle_border(_screen_triangle(key), Color(0.42, 0.53, 0.66, 0.12), 1.0)
	for key: Vector3i in parallel_map.triangles:
		var points := _screen_triangle(key)
		_map_view.draw_colored_polygon(points, FACE_COLORS[parallel_map.triangles[key]])
		_draw_triangle_border(points, Color("203047"), 1.2)
	if state == State.EDITING and _hover_key != null:
		var points := _screen_triangle(_hover_key)
		var color := Color("fb6677") if tool == Tool.ERASER else FACE_COLORS[face]
		_map_view.draw_colored_polygon(points, Color(color, 0.5))
		_draw_triangle_border(points, Color("edf3fb"), 2.0)
