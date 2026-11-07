extends SceneTree
## 正式主场景的交互回归。加 -- --capture --output <目录> 可保存实际渲染截图。

const GAME = preload("res://scene/game.tscn")
var app: Node
var checks: int = 0
var failures: Array[String] = []
var output_directory: String
var capture: bool = false


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	capture = args.has("--capture")
	var index := args.find("--output")
	output_directory = args[index + 1] if index >= 0 and index + 1 < args.size() else OS.get_user_data_dir()
	DirAccess.make_dir_recursive_absolute(output_directory)
	call_deferred("_run")


func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func frames(count: int = 3) -> void:
	for frame: int in range(count):
		await process_frame


func pointer(position: Vector2, pressed: bool, button: int = MOUSE_BUTTON_LEFT) -> void:
	var event := InputEventMouseButton.new()
	event.position = position
	event.button_index = button
	event.pressed = pressed
	root.push_input(event, true)


func click(button: Button) -> void:
	var position := button.get_global_rect().get_center()
	pointer(position, true)
	pointer(position, false)


func signature(value: Geometry) -> String:
	return str(value.sorted_cells())


func fixture(cells: Dictionary, view: int = 0) -> void:
	app.geometry = Geometry.new(cells)
	app.view_index = view
	app._cycles.clear()
	app._show_geometry()


func key_center(key: Vector3i) -> Vector2:
	var points := ParallelMap.triangle_vertices(key)
	return (points[0] + points[1] + points[2]) / 3.0 * app._map_scale + app._map_offset


func screenshot(name: String) -> void:
	if capture:
		await frames(4)
		await RenderingServer.frame_post_draw
		expect(root.get_texture().get_image().save_png(output_directory.path_join(name + ".png")) == OK, "capture " + name)


func wait_for_reconstruction() -> void:
	var deadline := Time.get_ticks_msec() + 10000
	while app.state == app.State.RECONSTRUCTING and Time.get_ticks_msec() < deadline:
		await create_timer(0.01).timeout
	expect(app.state != app.State.RECONSTRUCTING, "background reconstruction finishes")


func apply_target(target: ParallelMap) -> void:
	var old: Dictionary = app.parallel_map.triangles.duplicate()
	app.select_tool(app.Tool.ERASER)
	for key: Vector3i in old:
		if not target.triangles.has(key):
			expect(app.edit_triangle(key), "remove target triangle")
	app.select_tool(app.Tool.BRUSH)
	for key: Vector3i in target.triangles:
		if old.get(key) != target.triangles[key]:
			app.select_face(target.triangles[key])
			expect(app.edit_triangle(key), "paint or add target triangle")
	expect(app.parallel_map.projection_equal(target), "editing produces the exact target")


func check_camera_alignment() -> void:
	for view: int in range(4):
		app.view_index = view
		app._orbit_angles = app._view_angles(view)
		app._update_camera()
		expect(app.enter_map_mode(), "enter view %d" % view)
		for point: Vector3i in [Vector3i.ZERO, Vector3i.RIGHT, Vector3i.UP, Vector3i.BACK, Vector3i(2, 1, 1)]:
			var local := point
			match view:
				1: local = Vector3i(point.z, point.y, -point.x)
				2: local = Vector3i(-point.x, point.y, -point.z)
				3: local = Vector3i(-point.z, point.y, point.x)
			var grid := Vector2i(local.x - local.y, local.z - local.y)
			var map_point: Vector2 = ParallelMap.grid_to_screen(grid) * app._map_scale + app._map_offset
			expect(app._camera.unproject_position(Vector3(point)).distance_to(map_point) < 0.1, "3D and 2D align in view %d" % view)
		var source: String = signature(app.geometry)
		click(app._undo)
		expect(app.state == app.State.GEOMETRY and signature(app.geometry) == source, "cancel restores geometry")
		expect(app._cycles.is_empty(), "cancel creates no cycle")


func check_orbit() -> void:
	app.view_index = 0
	app._show_geometry()
	var original: String = signature(app.geometry)
	var start := Vector2(600, 300)
	pointer(start, true)
	expect(app._drag_button == MOUSE_BUTTON_LEFT, "background press starts orbit")
	var motion := InputEventMouseMotion.new()
	motion.position = start + Vector2(170, -155)
	motion.relative = Vector2(170, -155)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	expect(app._orbit_angles.y < 0.0, "orbit can look below the geometry")
	pointer(app._convert.get_global_rect().get_center(), false)
	expect(app._drag_button == MOUSE_BUTTON_NONE, "release over UI ends orbit")
	expect(app.state == app.State.GEOMETRY, "orbit release does not click UI")
	await create_timer(app.snap_duration + 0.1).timeout
	expect(app.view_index == 1, "orbit snaps to the nearest upper view")
	expect(app._orbit_direction().distance_to(app.VIEW_DIRECTIONS[1].normalized()) < 0.001, "snap completes at exact isometric direction")
	expect(signature(app.geometry) == original, "orbit never rotates voxel coordinates")
	pointer(start, true)
	app.notification(Node.NOTIFICATION_APPLICATION_FOCUS_OUT)
	expect(app._drag_button == MOUSE_BUTTON_NONE, "focus loss releases the gesture")
	await create_timer(app.snap_duration + 0.1).timeout


func check_editing(target: ParallelMap) -> void:
	click(app._convert)
	expect(app.state == app.State.EDITING, "actual convert button enters editing")
	expect(app._drag_button == MOUSE_BUTTON_NONE, "UI press never starts a view gesture")
	expect(app._menu.visible and not app._geometry_view.visible and app._map_view.visible, "editing switches the two views and menu")
	var initial: ParallelMap = app.parallel_map.duplicate_map()
	var existing: Vector3i = initial.triangles.keys()[0]
	var blank: Variant = null
	for key: Vector3i in target.triangles:
		if not initial.triangles.has(key):
			blank = key
			break
	expect(blank != null, "fixture contains a new outline triangle")
	click(app._faces[1])
	expect(app.face == ParallelMap.LEFT, "left face button selects the brush face")
	click(app._tools[1])
	expect(app.tool == app.Tool.ERASER and app.face == ParallelMap.LEFT, "eraser preserves selected brush face")
	pointer(key_center(existing), true)
	pointer(key_center(existing), false)
	expect(not app.parallel_map.triangles.has(existing), "actual map input erases a triangle")
	click(app._undo_edit)
	expect(app.parallel_map.projection_equal(initial), "actual undo-edit button restores erased triangle")
	click(app._tools[0])
	app.select_face(target.triangles[blank])
	var old_scale: float = app._map_scale
	var old_offset: Vector2 = app._map_offset
	pointer(key_center(blank), true)
	pointer(key_center(blank), false)
	expect(app.parallel_map.triangles.has(blank), "brush adds a blank triangle")
	expect(app._map_scale == old_scale and app._map_offset == old_offset, "outline editing does not refit the map")
	click(app._undo_edit)
	expect(app.parallel_map.projection_equal(initial), "undo addition restores blank")
	app.select_face(initial.triangles[existing])
	expect(not app.edit_triangle(existing) and app._edits.is_empty(), "same-color painting costs no edit")
	var adjacent := existing
	var nearest := INF
	for candidate: Vector3i in initial.triangles:
		var distance := key_center(existing).distance_to(key_center(candidate))
		if candidate != existing and initial.triangles[candidate] == initial.triangles[existing] and distance < nearest:
			adjacent = candidate
			nearest = distance
	app.select_face((int(initial.triangles[existing]) + 1) % 3)
	pointer(key_center(existing), true)
	var stroke := InputEventMouseMotion.new()
	stroke.position = key_center(adjacent)
	stroke.relative = stroke.position - key_center(existing)
	stroke.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(stroke, true)
	pointer(stroke.position, false)
	expect(adjacent != existing and app.parallel_map.triangles[existing] == app.face and app.parallel_map.triangles[adjacent] == app.face, "continuous map drag paints both endpoints")
	while not app._edits.is_empty():
		app.undo_edit()
	expect(app.parallel_map.projection_equal(initial), "drag edits can be fully undone")
	for index: int in range(app.edit_limit):
		app.select_face((int(app.parallel_map.triangles[existing]) + 1) % 3)
		expect(app.edit_triangle(existing), "effective edit fits the budget")
	app.select_face((int(app.parallel_map.triangles[existing]) + 1) % 3)
	expect(not app.edit_triangle(existing), "edit beyond budget is refused")
	click(app._undo_edit)
	expect(app._edits.size() == app.edit_limit - 1, "undo refunds one edit")
	for index: int in range(app.edit_limit - 1):
		expect(app.undo_edit(), "undo remaining edit")
	expect(app.parallel_map.projection_equal(initial), "mixed editing fully restores the target")
	var view: int = app.view_index
	app._paint_at(app._faces[0].get_global_rect().get_center())
	expect(app._edits.is_empty() and app.view_index == view, "UI area cannot paint or rotate")
	apply_target(target)


func _run() -> void:
	app = GAME.instantiate()
	root.add_child(app)
	await frames(5)
	expect(app.get_child_count() == 3, "game has exactly three sibling views/UI")
	expect(app._ui.get_child_count() == 3, "UI has exactly three primary children")
	expect(app._menu.find_children("*", "Button").size() == 6, "submenu has six buttons")
	expect(app.geometry.is_face_connected(), "random startup is face connected")
	expect(app.geometry.voxels.size() == app.initial_voxel_count, "startup respects configured voxel count")
	for cell: Vector3i in app.geometry.voxels:
		expect(app._inside(cell), "startup is inside the allowed range")
	expect(not app._menu.visible and app._undo.disabled, "startup hides edit menu and disables empty undo")
	pointer(app._undo.get_global_rect().get_center(), true)
	expect(app._drag_button == MOUSE_BUTTON_NONE, "disabled UI button also blocks orbit input")
	pointer(app._undo.get_global_rect().get_center(), false)
	app.random_seed = 20261107
	app.generate_geometry()
	var seeded: String = signature(app.geometry)
	app.generate_geometry()
	expect(signature(app.geometry) == seeded, "fixed generation seed is reproducible")
	var cells: Dictionary = {}
	for x: int in range(3):
		for z: int in range(2):
			cells[Vector3i(x, 0, z)] = true
	fixture(cells)
	check_camera_alignment()
	await check_orbit()
	fixture(cells)
	await frames()
	await screenshot("game_geometry")
	var expanded := cells.duplicate()
	expanded[Vector3i(-1, 0, 0)] = true
	var target := ParallelMap.from_geometry(Geometry.new(expanded), 0)
	check_editing(target)
	await screenshot("game_parallel_map")
	click(app._convert)
	expect(app.state == app.State.RECONSTRUCTING, "convert button starts actual worker")
	expect(app._convert.disabled and app._undo.disabled and app._tools[0].disabled, "worker locks UI")
	expect(not app.cancel_map_mode() and not app.undo_edit(), "worker locks edit transactions")
	expect(signature(app.geometry) == signature(Geometry.new(cells)), "worker input does not mutate current geometry")
	await wait_for_reconstruction()
	expect(app.state == app.State.GEOMETRY and app.last_result.get("status") == "optimal", "certified result commits")
	expect(app.last_result.get("edit_cost") == 1, "expansion is a certified one-voxel optimum")
	expect(ParallelMap.from_geometry(app.geometry, 0).projection_equal(target), "committed geometry projects exactly")
	expect(app._cycles.size() == 1 and not app._undo.disabled, "successful cycle is independently undoable")
	click(app._convert)
	apply_target(ParallelMap.from_geometry(Geometry.new(cells), 0))
	click(app._convert)
	await wait_for_reconstruction()
	expect(app._cycles.size() == 2 and app.last_result.get("edit_cost") == 1, "contraction creates a second cycle")
	click(app._undo)
	expect(ParallelMap.from_geometry(app.geometry, 0).projection_equal(target), "undo contraction restores expanded projection")
	click(app._undo)
	expect(signature(app.geometry) == signature(Geometry.new(cells)) and app._cycles.is_empty(), "undo expansion restores exact original geometry")
	click(app._convert)
	click(app._convert)
	await wait_for_reconstruction()
	expect(app.last_result.get("edit_cost") == 0 and signature(app.geometry) == signature(Geometry.new(cells)), "unedited cycle costs zero and preserves exact geometry")
	fixture({Vector3i.ZERO: true})
	click(app._convert)
	app.select_tool(app.Tool.ERASER)
	var removed: Vector3i = app.parallel_map.triangles.keys()[0]
	expect(app.edit_triangle(removed), "remove part of a single-cube footprint")
	var invalid_target: ParallelMap = app.parallel_map.duplicate_map()
	click(app._convert)
	await wait_for_reconstruction()
	expect(app.state == app.State.EDITING and app.last_result.get("status") == "infeasible", "infeasible input stays in editing")
	expect(app.parallel_map.projection_equal(invalid_target) and app._cycles.is_empty(), "failure preserves target and adds no history")
	click(app._undo)
	expect(app.geometry.voxels.size() == 1 and app.parallel_map == null, "cancel after failure restores original")
	click(app._convert)
	app.select_tool(app.Tool.ERASER)
	for triangle: Vector3i in app.parallel_map.triangles.keys():
		expect(app.edit_triangle(triangle), "erase a complete small projection")
	var empty_scale: float = app._map_scale
	app._fit_views()
	expect(app.parallel_map.triangles.is_empty() and is_finite(app._map_scale) and app._map_scale == empty_scale, "empty target survives viewport refitting")
	click(app._undo_edit)
	expect(app.parallel_map.triangles.size() == 1, "empty target can still be undone")
	click(app._undo)
	click(app._convert)
	app.search_nodes = 0 # 确定性触发预算耗尽，避免依赖机器速度。
	click(app._convert)
	await wait_for_reconstruction()
	expect(app.last_result.get("status") == "budget_exceeded" and app.state == app.State.EDITING, "budget exhaustion is not infeasibility")
	expect(app._search_multiplier == 2 and app._convert.text == "继续重建", "same convert button offers increased-budget retry")
	app._handle_result({"status": "feasible", "optimal": false, "geometry": app.geometry.duplicate_geometry()})
	expect(app.state == app.State.EDITING and app._cycles.is_empty(), "unproven feasible result never auto-commits")
	app.select_tool(app.Tool.BRUSH)
	var key: Vector3i = app.parallel_map.triangles.keys()[0]
	app.select_face((int(app.parallel_map.triangles[key]) + 1) % 3)
	expect(app.edit_triangle(key) and app.last_result.is_empty() and app._search_multiplier == 1, "editing invalidates previous result and retry budget")
	click(app._undo)
	var report := {"checks": checks, "failures": failures, "screenshots": capture, "status": "passed" if failures.is_empty() else "failed"}
	print(JSON.stringify(report))
	var file := FileAccess.open(output_directory.path_join("game_results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	app.queue_free()
	await frames()
	quit(0 if failures.is_empty() else 1)
