extends Control
## Whitebox-only orchestration. Reusable data and solver live in res://script/.

const MapCanvasScript = preload("res://test/map_canvas.gd")
const SnapshotStore = preload("res://test/snapshot_store.gd")
const MIN_CELL := Vector3i(-3, 0, -3)
const MAX_CELL := Vector3i(3, 6, 3)
const MAX_STROKES := 10
const MAX_HISTORY := 30
const VIEW_DIRECTIONS := [Vector3(1, 1, 1), Vector3(-1, 1, 1), Vector3(-1, 1, -1), Vector3(1, 1, -1)]
const VIEW_NAMES := ["东南 · 01", "西南 · 02", "西北 · 03", "东北 · 04"]
const NEIGHBORS := [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]
const WALK_DIRECTIONS := [Vector2i.RIGHT, Vector2i.LEFT, Vector2i.UP, Vector2i.DOWN]
const EDIT_PAINT := 0
const EDIT_ADD := 1
const EDIT_DELETE := 2
const PLAYER_COLOR := Color("5fe0bb")
const GOAL_COLOR := Color("ffac66")

var geometry: Geometry
var parallel_map: ParallelMap
var map_mode: bool = false
var is_busy: bool = false
var view_index: int = 0
var brush: int = ParallelMap.TOP
var edit_mode: int = EDIT_PAINT
var player_cell: Vector3i
var destination_cell: Vector3i
var random_seed: int = 0
var stroke_history: Array[Dictionary] = []
var cycle_history: Array[Dictionary] = []
var last_result: Dictionary = {}

var _editing_original: Geometry
var _editing_snapshot: Dictionary = {}
var _pending_feasible: Dictionary = {}
var _thread: Thread
var _worker_started: int = 0
var _geometry_instance: MeshInstance3D
var _outline_instance: MeshInstance3D
var _camera: Camera3D
var _player_marker: MeshInstance3D
var _destination_marker: MeshInstance3D
var _orbit_angles := Vector2(PI / 4.0, asin(1.0 / sqrt(3.0)))
var _orbit_dragging := false
var _orbit_mouse_button := MOUSE_BUTTON_NONE
var _orbit_tween: Tween
var _viewport_container: SubViewportContainer
var _map_canvas: Control
var _stage_label: Label
var _stage_caption: Label
var _stats_label: Label
var _view_label: Label
var _seed_label: Label
var _remaining_label: Label
var _history_label: Label
var _feedback_label: Label
var _busy_panel: PanelContainer
var _busy_label: Label
var _main_button: Button
var _cancel_button: Button
var _undo_stroke_button: Button
var _undo_cycle_button: Button
var _new_button: Button
var _retry_button: Button
var _accept_feasible_button: Button
var _view_buttons: Array[Button] = []
var _brush_buttons: Array[Button] = []
var _edit_mode_row: HBoxContainer
var _edit_mode_buttons: Array[Button] = []
var _editable_keys: Dictionary = {}
var _protected_keys: Dictionary = {}
var _feedback := ""
var _feedback_color := Color("a9bbd0")


func _ready() -> void:
	_build_interface()
	_build_world()
	var session := SnapshotStore.load_session()
	if not session.is_empty():
		var restored: Geometry = SnapshotStore.geometry_from_snapshot(session["current"])
		if not restored.voxels.is_empty() and restored.is_face_connected() and _inside_bounds(restored):
			geometry = restored
			view_index = posmod(int(session["current"].get("view", 0)), 4)
			random_seed = int(session["current"].get("seed", 0))
			_restore_markers(session["current"])
			_reset_orbit()
			for saved: Variant in session["history"]:
				if saved is Dictionary:
					cycle_history.append(saved.duplicate(true))
			_show_feedback("已恢复上次几何体和循环存档。", Color("9dccae"))
	if geometry == null:
		generate_random_geometry()
	else:
		_update_geometry_display()
		_refresh_interface()


func _process(_delta: float) -> void:
	if is_busy and _thread != null:
		_busy_label.text = "正在重建…  %.1f 秒\n求解期间可以继续观察进度" % ((Time.get_ticks_msec() - _worker_started) / 1000.0)
		if not _thread.is_alive():
			var result: Variant = _thread.wait_to_finish()
			_thread = null
			is_busy = false
			_handle_reconstruction_result(result if result is Dictionary else {"status": "error", "message": "重建返回了无效结果。"})


func _exit_tree() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()


func _input(event: InputEvent) -> void:
	if map_mode or is_busy or _viewport_container == null or geometry == null:
		return
	if event is InputEventMouseButton:
		if not event.pressed and _orbit_dragging and event.button_index == _orbit_mouse_button:
			_finish_orbit_drag()
			get_viewport().set_input_as_handled()
		elif event.pressed and not _orbit_dragging and event.button_index in [MOUSE_BUTTON_LEFT, MOUSE_BUTTON_RIGHT] and _viewport_container.get_global_rect().has_point(event.position):
			_stop_orbit_tween()
			_orbit_dragging = true
			_orbit_mouse_button = event.button_index
			_refresh_interface()
			get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and _orbit_dragging:
		_orbit_angles.x = wrapf(_orbit_angles.x + event.relative.x * 0.009, -PI, PI)
		_orbit_angles.y = clampf(_orbit_angles.y + event.relative.y * 0.009, deg_to_rad(-88.0), deg_to_rad(88.0))
		_update_camera()
		get_viewport().set_input_as_handled()


func _notification(what: int) -> void:
	if what == NOTIFICATION_APPLICATION_FOCUS_OUT and _orbit_dragging:
		_finish_orbit_drag()


func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or is_busy:
		return
	if not map_mode and not event.ctrl_pressed and not event.alt_pressed and not event.meta_pressed:
		var direction: Vector2i = {
			KEY_W: Vector2i.UP, KEY_UP: Vector2i.UP, KEY_S: Vector2i.DOWN, KEY_DOWN: Vector2i.DOWN,
			KEY_A: Vector2i.LEFT, KEY_LEFT: Vector2i.LEFT, KEY_D: Vector2i.RIGHT, KEY_RIGHT: Vector2i.RIGHT,
		}.get(event.keycode, Vector2i.ZERO)
		if direction != Vector2i.ZERO:
			move_player(direction)
			get_viewport().set_input_as_handled()
			return
	if event.echo:
		return
	if event.ctrl_pressed and event.keycode == KEY_Z:
		if map_mode:
			undo_stroke()
		else:
			undo_cycle()
		get_viewport().set_input_as_handled()
	elif event.keycode == KEY_Q and not map_mode:
		set_view(view_index - 1)
	elif event.keycode == KEY_E and not map_mode:
		set_view(view_index + 1)
	elif event.keycode == KEY_1:
		_select_brush(ParallelMap.TOP)
	elif event.keycode == KEY_2:
		_select_brush(ParallelMap.LEFT)
	elif event.keycode == KEY_3:
		_select_brush(ParallelMap.RIGHT)
	elif map_mode and event.keycode in [KEY_4, KEY_5, KEY_6]:
		set_edit_mode(event.keycode - KEY_4)
	elif event.keycode == KEY_ESCAPE and map_mode:
		cancel_map_mode()


func generate_random_geometry(seed_value: int = -1) -> void:
	if is_busy:
		return
	random_seed = int(Time.get_unix_time_from_system()) ^ int(Time.get_ticks_usec()) if seed_value < 0 else seed_value
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	var cells: Dictionary = {}
	for x: int in range(-1, 1):
		for y: int in range(2):
			for z: int in range(-1, 1):
				cells[Vector3i(x, y, z)] = true
	var target_count := rng.randi_range(14, 23)
	var attempts := 0
	while cells.size() < target_count and attempts < 1500:
		attempts += 1
		var keys: Array = cells.keys()
		var candidate: Vector3i = keys[rng.randi_range(0, keys.size() - 1)] + NEIGHBORS[rng.randi_range(0, 5)]
		if candidate.x >= -2 and candidate.x <= 2 and candidate.y >= 0 and candidate.y <= 3 and candidate.z >= -2 and candidate.z <= 2:
			cells[candidate] = true
	geometry = Geometry.new(cells)
	view_index = 0
	_spawn_markers(rng)
	_reset_orbit()
	map_mode = false
	parallel_map = null
	stroke_history.clear()
	cycle_history.clear()
	_pending_feasible.clear()
	last_result = {}
	_update_geometry_display()
	_save_session()
	_show_feedback("已生成 %d 块相连体素。拖动旋转，使用 WASD 或方向键移动玩家。" % geometry.voxels.size())
	_refresh_interface()


func set_geometry_for_test(cells: Dictionary, initial_view: int = 0, marker_cells: Array[Vector3i] = []) -> void:
	if is_busy:
		return
	geometry = Geometry.new(cells)
	view_index = posmod(initial_view, 4)
	random_seed = 0
	if marker_cells.size() == 2 and _is_top(marker_cells[0]) and _is_top(marker_cells[1]):
		player_cell = marker_cells[0]
		destination_cell = marker_cells[1]
	else:
		_restore_markers({})
	_reset_orbit()
	map_mode = false
	parallel_map = null
	stroke_history.clear()
	cycle_history.clear()
	last_result = {}
	_pending_feasible.clear()
	_update_geometry_display()
	_refresh_interface()


func set_view(index: int) -> bool:
	if map_mode or is_busy:
		return false
	view_index = posmod(index, 4)
	_reset_orbit()
	_update_camera()
	_refresh_interface()
	_save_session()
	return true


func _is_top(cell: Vector3i) -> bool:
	return geometry != null and geometry.voxels.has(cell) and not geometry.voxels.has(cell + Vector3i.UP)


func _step_target(cell: Vector3i, direction: Vector2i) -> Variant:
	var adjacent := cell + Vector3i(direction.x, 0, direction.y)
	for elevation: int in [0, 1, -1]:
		var candidate := adjacent + Vector3i(0, elevation, 0)
		if _is_top(candidate):
			return candidate
	return null


func _reachable_tops(start: Vector3i) -> Dictionary:
	var reachable := {start: true}
	var frontier: Array[Vector3i] = [start]
	while not frontier.is_empty():
		var current: Vector3i = frontier.pop_back()
		for direction: Vector2i in WALK_DIRECTIONS:
			var next: Variant = _step_target(current, direction)
			if next is Vector3i and not reachable.has(next):
				reachable[next] = true
				frontier.append(next)
	return reachable


func _spawn_markers(rng: RandomNumberGenerator, allow_other_views: bool = true) -> void:
	var fallback: Array[Vector3i] = []
	var fallback_view := view_index
	for offset: int in range(4 if allow_other_views else 1):
		var candidate_view := posmod(view_index + offset, 4)
		var tops: Array[Vector3i] = []
		for cell: Vector3i in geometry.voxels:
			if _is_top(cell) and ParallelMap.top_face_visible(geometry, cell, candidate_view):
				tops.append(cell)
		if tops.size() > fallback.size():
			fallback = tops
			fallback_view = candidate_view
		if tops.size() < 2:
			continue
		var first := rng.randi_range(0, tops.size() - 1)
		for index: int in range(tops.size()):
			var start := tops[(first + index) % tops.size()]
			var reachable := _reachable_tops(start)
			var goals: Array[Vector3i] = []
			for cell: Vector3i in tops:
				if cell != start and reachable.has(cell):
					goals.append(cell)
			if not goals.is_empty():
				player_cell = start
				destination_cell = goals[rng.randi_range(0, goals.size() - 1)]
				view_index = candidate_view
				return
	if not fallback.is_empty():
		view_index = fallback_view
		var first := rng.randi_range(0, fallback.size() - 1)
		player_cell = fallback[first]
		destination_cell = fallback[(first + 1) % fallback.size()]


func _restore_markers(snapshot: Dictionary) -> void:
	var saved_player: Variant = SnapshotStore.marker_from_snapshot(snapshot, "player")
	var saved_destination: Variant = SnapshotStore.marker_from_snapshot(snapshot, "destination")
	if saved_player is Vector3i and saved_destination is Vector3i and _is_top(saved_player) and _is_top(saved_destination):
		player_cell = saved_player
		destination_cell = saved_destination
		return
	var rng := RandomNumberGenerator.new()
	rng.seed = random_seed
	_spawn_markers(rng, false)


func move_player(direction: Vector2i) -> bool:
	if map_mode or is_busy or _orbit_dragging or not _is_top(player_cell) or direction not in WALK_DIRECTIONS:
		return false
	var next: Variant = _step_target(player_cell, direction)
	if next == null:
		return false
	player_cell = next
	_update_marker_display()
	_save_session()
	return true


func _both_markers_visible(value: Geometry, view: int) -> bool:
	return ParallelMap.top_face_visible(value, player_cell, view) and ParallelMap.top_face_visible(value, destination_cell, view)


func _nearest_view(visible_only: bool = false) -> int:
	var direction := _orbit_direction()
	var best_view := -1
	var best_score := -INF
	for index: int in range(VIEW_DIRECTIONS.size()):
		if visible_only and not _both_markers_visible(geometry, index):
			continue
		var candidate: Vector3 = VIEW_DIRECTIONS[index].normalized()
		var score := direction.dot(candidate)
		if score > best_score:
			best_score = score
			best_view = index
	return best_view


func _editable_triangle_keys() -> Dictionary:
	var keys: Dictionary = {}
	for x: int in range(MIN_CELL.x, MAX_CELL.x + 1):
		for y: int in range(MIN_CELL.y, MAX_CELL.y + 1):
			for z: int in range(MIN_CELL.z, MAX_CELL.z + 1):
				var local := ParallelMap.world_to_view_cell(Vector3i(x, y, z), view_index)
				for key: Vector3i in ParallelMap.footprint(local):
					keys[key] = true
	return keys


func enter_map_mode() -> bool:
	if map_mode or is_busy or geometry == null:
		return false
	var editing_view := _nearest_view(true)
	if editing_view < 0:
		_show_feedback("当前四个等轴测视角都无法同时看见两处顶面。请先移动玩家，再进入轴测图。", Color("e9c78e"))
		return false
	_editing_original = geometry.duplicate_geometry()
	_editing_snapshot = SnapshotStore.capture(geometry, view_index, random_seed, player_cell, destination_cell)
	var changed_view := editing_view != view_index
	view_index = editing_view
	_reset_orbit()
	_update_camera()
	parallel_map = ParallelMap.from_geometry(geometry, view_index)
	_editable_keys = _editable_triangle_keys()
	var player_keys := ParallelMap.top_face_keys(player_cell, view_index)
	var destination_keys := ParallelMap.top_face_keys(destination_cell, view_index)
	_protected_keys.clear()
	for key: Vector3i in player_keys + destination_keys:
		_protected_keys[key] = true
	stroke_history.clear()
	_pending_feasible.clear()
	last_result = {}
	map_mode = true
	edit_mode = EDIT_PAINT
	_map_canvas.set_editable_keys(_editable_keys)
	_map_canvas.set_markers({"player": player_keys, "goal": destination_keys})
	_map_canvas.set_map(parallel_map)
	_map_canvas.set_brush(brush)
	_map_canvas.set_edit_mode(edit_mode)
	var notice := "已切到两个标记均可见的等轴测视角。" if changed_view else ""
	_show_feedback(notice + "改色、增加和删除共用 10 次编辑额度。青色玩家与橙色目的地的顶面受保护。")
	_refresh_interface()
	return true


func paint_triangle(key: Vector3i, orientation: int) -> bool:
	if not map_mode or is_busy or not parallel_map.triangles.has(key) or orientation < 0 or orientation > 2:
		return false
	return _edit_triangle(key, orientation)


func add_triangle(key: Vector3i, orientation: int) -> bool:
	if not map_mode or is_busy or parallel_map.triangles.has(key) or not _editable_keys.has(key) or orientation < 0 or orientation > 2:
		return false
	return _edit_triangle(key, orientation)


func delete_triangle(key: Vector3i) -> bool:
	if not map_mode or is_busy or not parallel_map.triangles.has(key):
		return false
	return _edit_triangle(key, null)


func set_edit_mode(mode: int) -> bool:
	if not map_mode or is_busy or mode < EDIT_PAINT or mode > EDIT_DELETE:
		return false
	edit_mode = mode
	_map_canvas.set_edit_mode(mode)
	_refresh_interface()
	return true


func _on_triangle_clicked(key: Vector3i) -> void:
	match edit_mode:
		EDIT_PAINT: paint_triangle(key, brush)
		EDIT_ADD: add_triangle(key, brush)
		EDIT_DELETE: delete_triangle(key)


func _edit_triangle(key: Vector3i, orientation: Variant) -> bool:
	var previous: Variant = parallel_map.triangles.get(key)
	if previous == orientation:
		return false
	if _protected_keys.has(key):
		_show_feedback("这一格属于玩家或目的地的支撑顶面，须保持可见。", Color("e9c78e"))
		return false
	if stroke_history.size() >= MAX_STROKES:
		_show_feedback("本轮已用完 10 次编辑。可以先撤销一笔，或尝试重建。", Color("e9c78e"))
		return false
	stroke_history.append({"key": key, "before": previous})
	_set_triangle(key, orientation)
	_pending_feasible.clear()
	last_result = {}
	_show_feedback("已编辑 %d 次。重建会检查投影、方形面连接和标记可见性。" % stroke_history.size())
	_refresh_interface()
	return true


func _set_triangle(key: Vector3i, orientation: Variant) -> void:
	if orientation == null:
		parallel_map.triangles.erase(key)
	else:
		parallel_map.triangles[key] = orientation
	_map_canvas.set_map(parallel_map)


func undo_stroke() -> bool:
	if not map_mode or is_busy or stroke_history.is_empty():
		return false
	var operation: Dictionary = stroke_history.pop_back()
	_set_triangle(operation["key"], operation["before"])
	_pending_feasible.clear()
	last_result = {}
	_show_feedback("已撤销最近一次编辑，并返还一次操作。")
	_refresh_interface()
	return true


func cancel_map_mode() -> bool:
	if not map_mode or is_busy:
		return false
	geometry = _editing_original.duplicate_geometry()
	_restore_markers(_editing_snapshot)
	var previous_view := int(_editing_snapshot.get("view", view_index))
	if _both_markers_visible(geometry, previous_view):
		view_index = previous_view
	_reset_orbit()
	map_mode = false
	parallel_map = null
	stroke_history.clear()
	_pending_feasible.clear()
	_update_geometry_display()
	_save_session()
	_show_feedback("已取消本轮编辑并恢复原几何体，当前视角可见两个标记。")
	_refresh_interface()
	return true


func start_reconstruction(long_search: bool = false) -> bool:
	if not map_mode or is_busy:
		return false
	var options := {"time_budget_ms": 15000 if long_search else 4500, "max_search_nodes": 12000 if long_search else 2200}
	if not _apply_marker_constraints(options):
		return false
	_thread = Thread.new()
	is_busy = true
	_worker_started = Time.get_ticks_msec()
	var error: Error = _thread.start(_run_reconstruction.bind(parallel_map.duplicate_map(), _editing_original.duplicate_geometry(), options))
	if error != OK:
		_thread = null
		is_busy = false
		_show_feedback("无法启动重建线程，请再次尝试。", Color("ee9b9b"))
	_refresh_interface()
	return error == OK


func _run_reconstruction(map_copy: ParallelMap, original_copy: Geometry, options: Dictionary) -> Dictionary:
	return GeometryReconstructor.reconstruct(map_copy, original_copy, MIN_CELL, MAX_CELL, options)


func _apply_marker_constraints(options: Dictionary) -> bool:
	var supports: Array[Vector3i] = [player_cell, destination_cell]
	var constraints := ParallelMap.top_marker_constraints(parallel_map, supports, MIN_CELL, MAX_CELL)
	if not constraints["valid"]:
		_show_feedback(str(constraints["message"]), Color("ee9b9b"))
		return false
	for key: String in ["required_cells", "forbidden_cells"]:
		var merged: Dictionary = {}
		var existing: Variant = options.get(key, [])
		if existing is Array or existing is Dictionary:
			for cell: Variant in existing:
				if cell is Vector3i:
					merged[cell] = true
		for cell: Vector3i in constraints[key]:
			merged[cell] = true
		options[key] = merged
	return true


func reconstruct_sync_for_test(options: Dictionary = {}) -> Dictionary:
	if not map_mode or is_busy:
		return {"status": "invalid_state", "geometry": null}
	var actual_options := {"time_budget_ms": 30000, "max_search_nodes": 30000}
	actual_options.merge(options, true)
	if not _apply_marker_constraints(actual_options):
		return {"status": "infeasible", "geometry": null, "message": _feedback}
	var result := _run_reconstruction(parallel_map.duplicate_map(), _editing_original.duplicate_geometry(), actual_options)
	_handle_reconstruction_result(result)
	return result


func _handle_reconstruction_result(result: Dictionary) -> void:
	last_result = result
	var rebuilt: Variant = result.get("geometry")
	if rebuilt is Geometry and bool(result.get("optimal", false)):
		_commit_result(result)
		return
	var status: String = str(result.get("status", "error"))
	if rebuilt is Geometry:
		_pending_feasible = result.duplicate(true)
		_show_feedback("已找到有效物体，但尚未证明改动最少。可延长搜索，或明确采用当前有效解。", Color("e9c78e"))
	elif status == "infeasible":
		_pending_feasible.clear()
		_show_feedback("当前编辑无法同时满足投影、方形面连接和标记可见性。可撤销或调整后重试。", Color("ee9b9b"))
	elif status == "budget_exceeded" or status == "timeout" or status == "unknown":
		_pending_feasible.clear()
		_show_feedback("搜索额度已用完，尚不能判断无解。可以延长搜索，或调整编辑后重试。", Color("e9c78e"))
	else:
		_pending_feasible.clear()
		_show_feedback("重建没有提交：" + str(result.get("message", status)), Color("ee9b9b"))
	_refresh_interface()


func _commit_result(result: Dictionary) -> void:
	var rebuilt: Variant = result.get("geometry")
	if not rebuilt is Geometry or not rebuilt.is_face_connected() or not _inside_bounds(rebuilt):
		_show_feedback("重建结果未通过连续性或范围复查，已保留编辑图。", Color("ee9b9b"))
		_refresh_interface()
		return
	var verification := ParallelMap.from_geometry(rebuilt, view_index)
	if not verification.projection_equal(parallel_map):
		_show_feedback("重建结果未通过逐格投影复查，已保留编辑图。", Color("ee9b9b"))
		_refresh_interface()
		return
	if not _both_markers_visible(rebuilt, view_index):
		_show_feedback("重建结果遮挡了玩家或目的地的顶面，已保留编辑图。", Color("ee9b9b"))
		_refresh_interface()
		return
	var added := 0
	var removed := 0
	for cell: Vector3i in rebuilt.voxels:
		if not _editing_original.voxels.has(cell):
			added += 1
	for cell: Vector3i in _editing_original.voxels:
		if not rebuilt.voxels.has(cell):
			removed += 1
	cycle_history.append(_editing_snapshot.duplicate(true))
	while cycle_history.size() > MAX_HISTORY:
		cycle_history.pop_front()
	geometry = rebuilt.duplicate_geometry()
	map_mode = false
	parallel_map = null
	stroke_history.clear()
	_pending_feasible = {}
	last_result = result
	_update_geometry_display()
	_save_session()
	var certificate := "已确认最少改动" if bool(result.get("optimal", false)) else "有效解，未证明最优"
	_show_feedback("转换完成 · 新增 %d / 删除 %d · %s。可通过循环回退恢复。" % [added, removed, certificate], Color("9dccae"))
	_refresh_interface()


func undo_cycle() -> bool:
	if map_mode or is_busy or cycle_history.is_empty():
		return false
	var snapshot: Dictionary = cycle_history.pop_back()
	geometry = SnapshotStore.geometry_from_snapshot(snapshot)
	view_index = posmod(int(snapshot.get("view", 0)), 4)
	random_seed = int(snapshot.get("seed", 0))
	_restore_markers(snapshot)
	_reset_orbit()
	last_result = {}
	_update_geometry_display()
	_save_session()
	_show_feedback("已从循环存档恢复几何体、视角、玩家和目的地。", Color("9dccae"))
	_refresh_interface()
	return true


func _save_session() -> void:
	if geometry != null:
		SnapshotStore.save_session(SnapshotStore.capture(geometry, view_index, random_seed, player_cell, destination_cell), cycle_history)


func _inside_bounds(value: Geometry) -> bool:
	for cell: Vector3i in value.voxels:
		if cell.x < MIN_CELL.x or cell.y < MIN_CELL.y or cell.z < MIN_CELL.z or cell.x > MAX_CELL.x or cell.y > MAX_CELL.y or cell.z > MAX_CELL.z:
			return false
	return true


func _select_brush(orientation: int) -> void:
	if is_busy:
		return
	brush = orientation
	_map_canvas.set_brush(brush)
	_refresh_interface()


func _show_feedback(message: String, color: Color = Color("a9bbd0")) -> void:
	_feedback = message
	_feedback_color = color
	if _feedback_label != null:
		_feedback_label.text = message
		_feedback_label.add_theme_color_override("font_color", color)


func _build_interface() -> void:
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Microsoft YaHei", "Noto Sans CJK SC", "SimHei", "sans-serif"])
	var theme_resource := Theme.new()
	theme_resource.default_font = font
	theme_resource.default_font_size = 15
	theme = theme_resource
	var background := ColorRect.new()
	background.color = Color("0d1420")
	background.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	background.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(background)
	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side: String in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 22)
	add_child(margin)
	var layout := VBoxContainer.new()
	layout.add_theme_constant_override("separation", 16)
	margin.add_child(layout)
	var header := HBoxContainer.new()
	header.add_theme_constant_override("separation", 16)
	layout.add_child(header)
	var titles := VBoxContainer.new()
	titles.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	header.add_child(titles)
	titles.add_child(_label("等角几何实验室", 27, Color("edf3fb")))
	titles.add_child(_label("ISOMETRIC MAZE  /  谜题核心白模", 12, Color("7e93ac")))
	var stage_tag := _panel(Color("19283a"), 9)
	header.add_child(stage_tag)
	_stage_label = _label("01  几何体", 15, Color("bad5f0"))
	stage_tag.add_child(_stage_label)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 18)
	layout.add_child(body)
	var viewer_panel := _panel(Color("141f2e"), 14)
	viewer_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewer_panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_child(viewer_panel)
	var viewer_layout := VBoxContainer.new()
	viewer_layout.add_theme_constant_override("separation", 10)
	viewer_panel.add_child(viewer_layout)
	var viewer_header := HBoxContainer.new()
	viewer_layout.add_child(viewer_header)
	_view_label = _label("", 15, Color("dbe7f5"))
	_view_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	viewer_header.add_child(_view_label)
	_stats_label = _label("", 13, Color("849ab3"))
	viewer_header.add_child(_stats_label)
	var stage_area := Control.new()
	stage_area.name = "StageArea"
	stage_area.custom_minimum_size = Vector2(360, 310)
	stage_area.size_flags_vertical = Control.SIZE_EXPAND_FILL
	viewer_layout.add_child(stage_area)
	_viewport_container = SubViewportContainer.new()
	_viewport_container.name = "GeometryView"
	_viewport_container.stretch = true
	_viewport_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_viewport_container.resized.connect(_update_camera)
	stage_area.add_child(_viewport_container)
	_map_canvas = MapCanvasScript.new()
	_map_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_canvas.triangle_clicked.connect(_on_triangle_clicked)
	stage_area.add_child(_map_canvas)
	_busy_panel = _panel(Color(0.06, 0.1, 0.17, 0.96), 16)
	_busy_panel.set_anchors_and_offsets_preset(Control.PRESET_CENTER)
	_busy_panel.offset_left = -165
	_busy_panel.offset_right = 165
	_busy_panel.offset_top = -48
	_busy_panel.offset_bottom = 48
	stage_area.add_child(_busy_panel)
	_busy_label = _label("正在重建…", 17, Color("e7effa"))
	_busy_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_busy_panel.add_child(_busy_label)
	var camera_row := HBoxContainer.new()
	camera_row.add_theme_constant_override("separation", 8)
	viewer_layout.add_child(camera_row)
	for index: int in range(4):
		var button := _button(VIEW_NAMES[index], func() -> void: set_view(index))
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		camera_row.add_child(button)
		_view_buttons.append(button)
	_stage_caption = _label("", 12, Color("8096b0"))
	_stage_caption.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	viewer_layout.add_child(_stage_caption)
	var sidebar := _panel(Color("152132"), 14)
	sidebar.custom_minimum_size.x = 300
	body.add_child(sidebar)
	var sidebar_scroll := ScrollContainer.new()
	sidebar_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sidebar_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	sidebar.add_child(sidebar_scroll)
	var controls := VBoxContainer.new()
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_theme_constant_override("separation", 9)
	sidebar_scroll.add_child(controls)
	controls.add_child(_label("一次完整转换", 19, Color("e8f0fa")))
	controls.add_child(_label("几何体  →  轴测图  →  新几何体", 13, Color("8fa8c2")))
	controls.add_child(HSeparator.new())
	_main_button = _button("进入轴测图", func() -> void:
		if map_mode:
			start_reconstruction()
		else:
			enter_map_mode()
	, true)
	_main_button.name = "ConvertButton"
	controls.add_child(_main_button)
	_cancel_button = _button("取消本轮编辑", func() -> void: cancel_map_mode())
	controls.add_child(_cancel_button)
	controls.add_child(_label("三角格画笔", 16, Color("d6e3f2")))
	_edit_mode_row = HBoxContainer.new()
	_edit_mode_row.add_theme_constant_override("separation", 7)
	controls.add_child(_edit_mode_row)
	for mode: int in range(3):
		var mode_button := _button(["4 改色", "5 增加", "6 删除"][mode], func() -> void: set_edit_mode(mode))
		mode_button.toggle_mode = true
		mode_button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_edit_mode_row.add_child(mode_button)
		_edit_mode_buttons.append(mode_button)
	var brush_row := HBoxContainer.new()
	brush_row.add_theme_constant_override("separation", 7)
	controls.add_child(brush_row)
	for orientation: int in [ParallelMap.TOP, ParallelMap.LEFT, ParallelMap.RIGHT]:
		var text: String = {ParallelMap.TOP: "1 上", ParallelMap.LEFT: "2 左", ParallelMap.RIGHT: "3 右"}[orientation]
		var button := _button(text, func() -> void: _select_brush(orientation))
		button.set_meta("orientation", orientation)
		button.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		button.toggle_mode = true
		button.add_theme_color_override("font_color", MapCanvasScript.FACE_COLORS[orientation])
		button.add_theme_color_override("font_pressed_color", MapCanvasScript.FACE_COLORS[orientation])
		brush_row.add_child(button)
		_brush_buttons.append(button)
	_remaining_label = _label("", 14, Color("a9bbd0"))
	controls.add_child(_remaining_label)
	_undo_stroke_button = _button("撤销一笔    Ctrl + Z", func() -> void: undo_stroke())
	controls.add_child(_undo_stroke_button)
	_retry_button = _button("延长搜索，再试一次", func() -> void: start_reconstruction(true))
	controls.add_child(_retry_button)
	_accept_feasible_button = _button("采用有效解（未证最优）", func() -> void: _commit_result(_pending_feasible))
	controls.add_child(_accept_feasible_button)
	controls.add_child(HSeparator.new())
	_undo_cycle_button = _button("回退完整循环", func() -> void: undo_cycle())
	_undo_cycle_button.name = "UndoCycleButton"
	controls.add_child(_undo_cycle_button)
	_history_label = _label("", 12, Color("8096b0"))
	controls.add_child(_history_label)
	var legend := HBoxContainer.new()
	legend.add_theme_constant_override("separation", 14)
	legend.add_child(_label("● P 玩家", 12, PLAYER_COLOR))
	legend.add_child(_label("● G 目的地", 12, GOAL_COLOR))
	controls.add_child(legend)
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	controls.add_child(spacer)
	_new_button = _button("重新随机生成", func() -> void: generate_random_geometry())
	_new_button.tooltip_text = "生成新的相连物体，并清空完整循环的回退存档。"
	controls.add_child(_new_button)
	_seed_label = _label("", 11, Color("70859f"))
	controls.add_child(_seed_label)
	controls.add_child(_label("范围 X/Z -3…3 · Y 0…6\n存档保存在本机 user://", 11, Color("70859f")))
	var feedback_panel := _panel(Color("172333"), 10)
	layout.add_child(feedback_panel)
	_feedback_label = _label("", 14, Color("a9bbd0"))
	_feedback_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback_label.custom_minimum_size.y = 34
	feedback_panel.add_child(_feedback_label)
	var footer := _label("WASD / 方向键 移动    ·    Q / E 切视角    ·    1–3 选色    ·    4–6 改色/增加/删除    ·    Ctrl + Z 撤销    ·    Esc 取消编辑", 12, Color("6e839e"))
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	layout.add_child(footer)


func _build_world() -> void:
	var viewport := SubViewport.new()
	viewport.name = "SceneViewport"
	viewport.size = Vector2i(900, 640)
	viewport.own_world_3d = true
	viewport.render_target_update_mode = SubViewport.UPDATE_ALWAYS
	viewport.msaa_3d = Viewport.MSAA_4X
	_viewport_container.add_child(viewport)
	var world := Node3D.new()
	world.name = "WhiteboxWorld"
	viewport.add_child(world)
	var environment := WorldEnvironment.new()
	var settings := Environment.new()
	settings.background_mode = Environment.BG_COLOR
	settings.background_color = Color("141f2e")
	settings.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	settings.ambient_light_color = Color("b0c4dc")
	settings.ambient_light_energy = 0.55
	settings.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	environment.environment = settings
	world.add_child(environment)
	_geometry_instance = MeshInstance3D.new()
	_geometry_instance.name = "VoxelSolid"
	var solid_material := StandardMaterial3D.new()
	solid_material.albedo_color = Color("dce3ed")
	solid_material.roughness = 0.88
	_geometry_instance.material_override = solid_material
	world.add_child(_geometry_instance)
	_outline_instance = MeshInstance3D.new()
	_outline_instance.name = "SolidEdges"
	var edge_material := StandardMaterial3D.new()
	edge_material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge_material.albedo_color = Color("263448")
	edge_material.render_priority = 2
	_outline_instance.material_override = edge_material
	world.add_child(_outline_instance)
	_camera = Camera3D.new()
	_camera.name = "IsometricCamera"
	_camera.projection = Camera3D.PROJECTION_ORTHOGONAL
	_camera.keep_aspect = Camera3D.KEEP_HEIGHT
	_camera.near = 0.05
	_camera.far = 100.0
	_camera.current = true
	world.add_child(_camera)
	var light := DirectionalLight3D.new()
	light.name = "FixedUpperLeftLight"
	light.light_energy = 1.65
	light.light_color = Color("fff5df")
	light.rotation_degrees = Vector3(-45, -35, 0)
	# There is no ground plane in this whitebox. Disabling self shadows avoids
	# shadow-map acne while retaining the screen-fixed upper-left shading.
	light.shadow_enabled = false
	_camera.add_child(light)
	var player_mesh := CapsuleMesh.new()
	player_mesh.radius = 0.14
	player_mesh.height = 0.42
	_player_marker = _create_marker(world, "PlayerMarker", player_mesh, PLAYER_COLOR)
	var goal_mesh := TorusMesh.new()
	goal_mesh.inner_radius = 0.21
	goal_mesh.outer_radius = 0.34
	_destination_marker = _create_marker(world, "DestinationMarker", goal_mesh, GOAL_COLOR)


func _create_marker(world: Node3D, marker_name: String, mesh: Mesh, color: Color) -> MeshInstance3D:
	var marker := MeshInstance3D.new()
	marker.name = marker_name
	marker.mesh = mesh
	var material := StandardMaterial3D.new()
	material.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	material.albedo_color = color
	marker.material_override = material
	world.add_child(marker)
	return marker


func _update_marker_display() -> void:
	_player_marker.visible = _is_top(player_cell)
	_destination_marker.visible = _is_top(destination_cell)
	_player_marker.position = Vector3(player_cell) + Vector3(0.5, 1.22, 0.5)
	_destination_marker.position = Vector3(destination_cell) + Vector3(0.5, 1.07, 0.5)


func _update_geometry_display() -> void:
	if geometry == null or _geometry_instance == null:
		return
	_geometry_instance.mesh = geometry.build_mesh()
	_outline_instance.mesh = geometry.build_outline_mesh()
	_update_marker_display()
	_update_camera()


func _snapped_angles(index: int) -> Vector2:
	var direction: Vector3 = VIEW_DIRECTIONS[index].normalized()
	return Vector2(atan2(direction.z, direction.x), asin(direction.y))


func _orbit_direction() -> Vector3:
	var horizontal := cos(_orbit_angles.y)
	return Vector3(cos(_orbit_angles.x) * horizontal, sin(_orbit_angles.y), sin(_orbit_angles.x) * horizontal)


func _stop_orbit_tween() -> void:
	if _orbit_tween != null:
		_orbit_tween.kill()
		_orbit_tween = null


func _reset_orbit() -> void:
	_stop_orbit_tween()
	_orbit_dragging = false
	_orbit_mouse_button = MOUSE_BUTTON_NONE
	_orbit_angles = _snapped_angles(view_index)


func _finish_orbit_drag() -> void:
	_orbit_dragging = false
	_orbit_mouse_button = MOUSE_BUTTON_NONE
	view_index = _nearest_view()
	var target := _snapped_angles(view_index)
	var tween_target := Vector2(_orbit_angles.x + angle_difference(_orbit_angles.x, target.x), target.y)
	_orbit_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_orbit_tween.tween_method(_apply_orbit_angles, _orbit_angles, tween_target, 0.26)
	_orbit_tween.finished.connect(func() -> void:
		_orbit_tween = null
		_apply_orbit_angles(target)
		_refresh_interface()
	)
	_refresh_interface()
	_save_session()


func _apply_orbit_angles(angles: Vector2) -> void:
	_orbit_angles = angles
	_update_camera()


func _update_camera() -> void:
	if geometry == null or _camera == null or geometry.voxels.is_empty():
		return
	var minimum := Vector3(INF, INF, INF)
	var maximum := Vector3(-INF, -INF, -INF)
	for cell: Vector3i in geometry.voxels:
		minimum = minimum.min(Vector3(cell))
		maximum = maximum.max(Vector3(cell) + Vector3.ONE)
	var center := (minimum + maximum) * 0.5
	var direction := _orbit_direction()
	_camera.position = center + direction * 20.0
	_camera.look_at(center, Vector3.UP)
	var right := _camera.global_basis.x
	var up := _camera.global_basis.y
	var projected_min := Vector2(INF, INF)
	var projected_max := Vector2(-INF, -INF)
	for cell: Vector3i in geometry.voxels:
		for x: int in range(2):
			for y: int in range(2):
				for z: int in range(2):
					var point := Vector3(cell) + Vector3(x, y, z)
					var projected := Vector2(point.dot(right), point.dot(up))
					projected_min = projected_min.min(projected)
					projected_max = projected_max.max(projected)
	var projected_center := (projected_min + projected_max) * 0.5
	center += right * (projected_center.x - center.dot(right)) + up * (projected_center.y - center.dot(up))
	_camera.position = center + direction * 20.0
	_camera.look_at(center, Vector3.UP)
	var view_size := _viewport_container.size
	if view_size.x < 1.0 or view_size.y < 1.0:
		view_size = Vector2(900, 640)
	var span := projected_max - projected_min
	var pixels_per_unit := minf((view_size.x - 104.0) / maxf(span.x, 0.1), (view_size.y - 104.0) / maxf(span.y, 0.1))
	# A projected world edge has length sqrt(2/3), whereas map edges are one
	# unit. This cap matches MapCanvas's 105-pixel maximum triangle edge.
	pixels_per_unit = clampf(pixels_per_unit, 3.0, 105.0 / sqrt(2.0 / 3.0))
	_camera.size = view_size.y / pixels_per_unit


func _refresh_interface() -> void:
	if _stage_label == null:
		return
	_stage_label.text = "02  轴测图编辑" if map_mode else "01  几何体"
	_viewport_container.visible = not map_mode
	_map_canvas.visible = map_mode
	_map_canvas.editing_enabled = map_mode and not is_busy
	_map_canvas.queue_redraw()
	_busy_panel.visible = is_busy
	_view_label.text = "几何体 / 自由旋转" if _orbit_dragging else ("轴测图 / " if map_mode else "几何体 / ") + VIEW_NAMES[view_index]
	_stats_label.text = "%d 个三角格" % parallel_map.triangles.size() if map_mode and parallel_map != null else "%d 个体素" % (geometry.voxels.size() if geometry != null else 0)
	_stage_caption.text = "滚轮缩放 · 右键平移 · 玩家和目的地的顶面受保护" if map_mode else "按住鼠标拖动旋转，松开吸附 · WASD / 方向键移动玩家"
	_main_button.text = "正在重建…" if is_busy else ("重建几何体 →" if map_mode else "进入轴测图 →")
	_main_button.disabled = is_busy
	_cancel_button.visible = map_mode
	_cancel_button.disabled = is_busy
	_remaining_label.text = "剩余编辑  %d / %d" % [MAX_STROKES - stroke_history.size(), MAX_STROKES] if map_mode else "进入轴测图后启用画笔"
	_edit_mode_row.visible = map_mode
	_undo_stroke_button.disabled = not map_mode or is_busy or stroke_history.is_empty()
	_undo_cycle_button.disabled = map_mode or is_busy or cycle_history.is_empty()
	_history_label.text = "循环存档  %d / %d    ·    几何体界面 Ctrl + Z" % [cycle_history.size(), MAX_HISTORY]
	_new_button.disabled = map_mode or is_busy
	_seed_label.text = "随机种子  %d" % random_seed
	_retry_button.visible = map_mode and not last_result.is_empty() and not bool(last_result.get("optimal", false)) and str(last_result.get("status", "")) != "infeasible"
	_retry_button.disabled = is_busy
	_accept_feasible_button.visible = map_mode and not _pending_feasible.is_empty()
	_accept_feasible_button.disabled = is_busy
	for index: int in range(_view_buttons.size()):
		_view_buttons[index].disabled = map_mode or is_busy
		_view_buttons[index].set_pressed_no_signal(index == view_index and not _orbit_dragging)
	for mode: int in range(_edit_mode_buttons.size()):
		_edit_mode_buttons[mode].disabled = is_busy
		_edit_mode_buttons[mode].set_pressed_no_signal(mode == edit_mode)
	for button: Button in _brush_buttons:
		button.disabled = not map_mode or is_busy
		button.set_pressed_no_signal(int(button.get_meta("orientation")) == brush)
	_show_feedback(_feedback, _feedback_color)


func _label(text: String, font_size: int, color: Color) -> Label:
	var label := Label.new()
	label.text = text
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	return label


func _panel(color: Color, radius: int) -> PanelContainer:
	var panel := PanelContainer.new()
	var style := StyleBoxFlat.new()
	style.bg_color = color
	style.set_corner_radius_all(radius)
	style.content_margin_left = 16
	style.content_margin_right = 16
	style.content_margin_top = 13
	style.content_margin_bottom = 13
	panel.add_theme_stylebox_override("panel", style)
	return panel


func _button(text: String, callback: Callable, primary: bool = false) -> Button:
	var button := Button.new()
	button.text = text
	button.custom_minimum_size.y = 40 if primary else 34
	button.focus_mode = Control.FOCUS_NONE
	button.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	button.add_theme_font_size_override("font_size", 15 if primary else 13)
	button.add_theme_color_override("font_color", Color("e7f0fb"))
	button.add_theme_color_override("font_disabled_color", Color("53677f"))
	for state: String in ["normal", "hover", "pressed", "disabled"]:
		var style := StyleBoxFlat.new()
		style.set_corner_radius_all(7)
		style.content_margin_left = 10
		style.content_margin_right = 10
		style.bg_color = Color("254263") if primary else Color("203148")
		if state == "hover":
			style.bg_color = Color("31587f") if primary else Color("2d425d")
		elif state == "pressed":
			style.bg_color = Color("37628e") if primary else Color("304c6b")
		elif state == "disabled":
			style.bg_color = Color("192638")
		button.add_theme_stylebox_override(state, style)
	button.pressed.connect(callback)
	return button
