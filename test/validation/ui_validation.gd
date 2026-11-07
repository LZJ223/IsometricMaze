extends SceneTree
## End-to-end checks for the playable scene. Use -- --capture for screenshots.

const PLAYER_START := Vector3i(0, 0, 0)
const GOAL := Vector3i(2, 0, 0)
const EXTRA_CELL := Vector3i(-1, 0, 0)
const EDIT_PAINT := 0
const EDIT_ADD := 1
const EDIT_DELETE := 2

var checks: int = 0
var failures: Array[String] = []
var app: Node
var capture: bool = false
var reconstruction_summary: Dictionary = {}


func _initialize() -> void:
	capture = OS.get_cmdline_user_args().has("--capture")
	call_deferred("_run")


func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func wait_frames(count: int = 3) -> void:
	for frame in range(count):
		await process_frame


func geometry_signature(geometry: Geometry) -> String:
	var entries: Array[String] = []
	for cell: Vector3i in geometry.voxels:
		entries.append("%d,%d,%d" % [cell.x, cell.y, cell.z])
	entries.sort()
	return "|".join(entries)


func marker_cells() -> Array[Vector3i]:
	return [app.player_cell, app.destination_cell]


func expect_markers_visible(context: String) -> void:
	for marker: Vector3i in marker_cells():
		expect(ParallelMap.top_face_visible(app.geometry, marker, app.view_index), context)


func camera_projection_check(camera: Camera3D, view: int) -> void:
	expect(camera.projection == Camera3D.PROJECTION_ORTHOGONAL, "view %d camera is orthographic" % view)
	var base: Vector2 = camera.unproject_position(Vector3.ZERO)
	var points: Array[Vector3] = [Vector3.RIGHT, Vector3.UP, Vector3.BACK, Vector3(2, 1, -1)]
	var scale: float = 0.0
	for index in range(points.size()):
		var world: Vector3 = points[index]
		var local: Vector3 = world
		match view:
			1: local = Vector3(world.z, world.y, -world.x)
			2: local = Vector3(-world.x, world.y, -world.z)
			3: local = Vector3(-world.z, world.y, world.x)
		var expected: Vector2 = Vector2(0.8660254037844386 * (local.x - local.z), 0.5 * (local.x + local.z) - local.y)
		var actual: Vector2 = camera.unproject_position(world) - base
		if index == 0:
			scale = actual.dot(expected) / expected.length_squared()
			expect(scale > 0.0, "view %d camera horizontal direction agrees with map" % view)
		expect(actual.distance_to(expected * scale) < 0.3, "view %d isometric camera matches map point %d" % [view, index])


func screenshot(name: String) -> void:
	if not capture:
		return
	await wait_frames(4)
	await RenderingServer.frame_post_draw
	var error: Error = root.get_texture().get_image().save_png("res://test/validation/" + name + ".png")
	expect(error == OK, "save screenshot " + name)


func click_triangle(key: Vector3i) -> void:
	var mouse_event := InputEventMouseButton.new()
	mouse_event.button_index = MOUSE_BUTTON_LEFT
	mouse_event.pressed = true
	mouse_event.position = app._map_canvas.triangle_screen_center(key)
	app._map_canvas._gui_input(mouse_event)


func orbit_check() -> void:
	var press := InputEventMouseButton.new()
	press.position = app._viewport_container.get_global_rect().get_center()
	press.button_index = MOUSE_BUTTON_LEFT
	press.pressed = true
	root.push_input(press, true)
	expect(app._orbit_dragging, "actual viewer mouse press begins orbit")
	var motion := InputEventMouseMotion.new()
	motion.position = press.position
	motion.relative = Vector2(170.0, -155.0)
	motion.button_mask = MOUSE_BUTTON_MASK_LEFT
	root.push_input(motion, true)
	expect(app._orbit_angles.y < 0.0, "orbital drag can tilt below the model")
	var release := press.duplicate() as InputEventMouseButton
	release.pressed = false
	release.position = root.get_visible_rect().size - Vector2(2.0, 2.0)
	root.push_input(release, true)
	expect(not app._orbit_dragging, "mouse release outside the viewport ends orbit")
	await create_timer(0.45).timeout
	expect(app.view_index == 1, "orbit chooses the closest of four isometric views")
	camera_projection_check(app._camera, app.view_index)


func occluded_entry_check() -> void:
	var support := Vector3i.ZERO
	var blocker := Vector3i(1, 1, 1)
	var cells := {support: true, Vector3i(0, 0, 1): true, Vector3i(0, 1, 1): true, blocker: true}
	var markers: Array[Vector3i] = [support, blocker]
	app.set_geometry_for_test(cells, 0, markers)
	await wait_frames()
	var projected: ParallelMap = ParallelMap.from_geometry(app.geometry, 0)
	for key: Vector3i in ParallelMap.top_face_keys(support, 0):
		expect(projected.triangles[key] == ParallelMap.TOP, "same-color blocker still paints the apparent marker support TOP")
	expect(not ParallelMap.top_face_visible(app.geometry, support, 0), "same-color foreground voxel really hides the marker")
	expect(app.enter_map_mode(), "map entry can choose another isometric view")
	if app.map_mode:
		expect(app.view_index != 0, "the map does not use the obscured view")
		expect_markers_visible("alternate view exposes both true supports")
		expect(app.player_cell == support and app.destination_cell == blocker, "switching to a visible view keeps both marker positions")
		expect(app.cancel_map_mode(), "cancel alternate-view editing")
		expect_markers_visible("canceling map editing exits with both supports visible")


func choose_paint_key() -> Vector3i:
	var protected_keys: Array[Vector3i] = []
	for cell: Vector3i in marker_cells():
		protected_keys.append_array(ParallelMap.top_face_keys(cell, app.view_index))
	for key: Vector3i in app.parallel_map.triangles:
		if not protected_keys.has(key):
			return key
	return Vector3i(0, 0, -1)


func map_navigation_check() -> void:
	var canvas: Control = app._map_canvas
	var player_keys: Array[Vector3i] = ParallelMap.top_face_keys(app.player_cell, app.view_index)
	var goal_keys: Array[Vector3i] = ParallelMap.top_face_keys(app.destination_cell, app.view_index)
	var player_anchor: Vector2 = canvas._marker_anchor(player_keys)
	var goal_anchor: Vector2 = canvas._marker_anchor(goal_keys)
	var scale_before: float = canvas._scale
	var wheel := InputEventMouseButton.new()
	wheel.button_index = MOUSE_BUTTON_WHEEL_DOWN
	wheel.pressed = true
	wheel.position = player_anchor
	canvas._gui_input(wheel)
	var ratio: float = canvas._scale / scale_before
	expect(ratio < 1.0, "mouse wheel zooms out")
	expect(canvas._marker_anchor(player_keys).is_equal_approx(player_anchor), "zoom holds the marker top face under the cursor")
	expect(canvas._marker_anchor(goal_keys).is_equal_approx(player_anchor + (goal_anchor - player_anchor) * ratio), "destination marker follows the same lattice zoom")
	var pan := InputEventMouseButton.new()
	pan.button_index = MOUSE_BUTTON_RIGHT
	pan.position = player_anchor
	pan.pressed = true
	canvas._gui_input(pan)
	var motion := InputEventMouseMotion.new()
	motion.relative = Vector2(22.0, 13.0)
	motion.position = player_anchor + motion.relative
	motion.button_mask = MOUSE_BUTTON_MASK_RIGHT
	canvas._gui_input(motion)
	pan.pressed = false
	pan.position = motion.position
	canvas._gui_input(pan)
	expect(canvas._marker_anchor(player_keys).is_equal_approx(player_anchor + motion.relative), "right drag moves the marker with its top face")
	expect(canvas._marker_anchor(goal_keys).is_equal_approx(player_anchor + (goal_anchor - player_anchor) * ratio + motion.relative), "right drag also moves destination with its top face")
	var key: Vector3i = player_keys[0]
	expect(canvas.triangle_at(canvas.triangle_screen_center(key)) == key, "picking follows the zoomed and panned lattice")


func map_edit_check(target: ParallelMap) -> void:
	var initial_map: ParallelMap = app.parallel_map.duplicate_map()
	var marker_key: Vector3i = ParallelMap.top_face_keys(app.player_cell, app.view_index)[0]
	expect(not app.delete_triangle(marker_key), "player support triangle cannot be deleted")
	expect(not app.paint_triangle(marker_key, ParallelMap.LEFT), "player support triangle cannot be recolored")
	var goal_key: Vector3i = ParallelMap.top_face_keys(app.destination_cell, app.view_index)[0]
	expect(not app.delete_triangle(goal_key), "destination support triangle cannot be deleted")
	for triangle: Vector3i in initial_map.triangles:
		var point: Vector2 = app._map_canvas.triangle_screen_center(triangle)
		expect(app._map_canvas.triangle_at(point) == triangle, "map picks painted triangle centroid")
	var key: Vector3i = choose_paint_key()
	expect(key.z >= 0, "fixture includes an unprotected triangle")
	var empty_key: Vector3i
	var found_empty: bool = false
	for candidate: Vector3i in target.triangles:
		if not initial_map.triangles.has(candidate):
			empty_key = candidate
			found_empty = true
			break
	expect(found_empty, "fixture contains an expansion outside the current outline")
	if not found_empty or key.z < 0:
		return
	var original_orientation: int = int(initial_map.triangles[key])
	app._select_brush((original_orientation + 1) % 3)
	click_triangle(key)
	expect(app.stroke_history.size() == 1, "actual canvas click paints selected triangle")
	expect(app.parallel_map.triangles[key] == (original_orientation + 1) % 3, "canvas click uses selected color")
	expect(app.undo_stroke(), "undo color change")
	expect(not app.paint_triangle(key, original_orientation), "same-color painting creates no edit")
	var base_center: Vector2 = app._map_canvas.triangle_screen_center(key)
	app.set_edit_mode(EDIT_ADD)
	var empty_point: Vector2 = app._map_canvas.triangle_screen_center(empty_key)
	expect(app._map_canvas.triangle_at(empty_point) == empty_key, "add mode picks a blank lattice triangle")
	expect(app._map_canvas.triangle_at(base_center) == null, "add mode ignores occupied triangles")
	app._select_brush(int(target.triangles[empty_key]))
	click_triangle(empty_key)
	expect(app.parallel_map.triangles.has(empty_key), "actual canvas click adds a triangle outside the outline")
	expect(app._map_canvas.triangle_screen_center(key).is_equal_approx(base_center), "adding a triangle keeps the camera framing stable")
	app.set_edit_mode(EDIT_DELETE)
	click_triangle(empty_key)
	expect(not app.parallel_map.triangles.has(empty_key), "actual canvas click deletes the added triangle")
	expect(app._map_canvas.triangle_screen_center(key).is_equal_approx(base_center), "deleting a triangle keeps the camera framing stable")
	expect(app.undo_stroke() and app.parallel_map.triangles.has(empty_key), "undo deletion restores the added triangle")
	expect(app.undo_stroke() and not app.parallel_map.triangles.has(empty_key), "undo addition restores a blank triangle")
	for stroke in range(8):
		var next_orientation: int = (int(app.parallel_map.triangles[key]) + 1) % 3
		expect(app.paint_triangle(key, next_orientation), "paint edit %d accepted" % (stroke + 1))
	expect(app.add_triangle(empty_key, ParallelMap.TOP), "ninth edit adds a triangle")
	expect(app.delete_triangle(empty_key), "tenth edit deletes a triangle")
	expect(app.stroke_history.size() == 10, "paint, add, and delete share a ten-edit limit")
	expect(not app.add_triangle(empty_key, ParallelMap.TOP), "eleventh edit is rejected")
	expect(app.undo_stroke() and app.stroke_history.size() == 9, "undo restores one edit slot")
	expect(app.delete_triangle(empty_key), "restored edit slot works")
	for stroke in range(10):
		expect(app.undo_stroke(), "undo mixed edit %d" % (stroke + 1))
	expect(app.parallel_map.projection_equal(initial_map), "mixed undo restores the original outline and colors")


func reconstruct_target(target: ParallelMap, operation: String) -> Dictionary:
	var old: ParallelMap = app.parallel_map.duplicate_map()
	var edit_count: int = 0
	for key: Vector3i in old.triangles:
		if not target.triangles.has(key):
			expect(app.delete_triangle(key), operation + " deletes an actual outline triangle")
			edit_count += 1
	for key: Vector3i in target.triangles:
		var orientation: int = int(target.triangles[key])
		if not old.triangles.has(key):
			expect(app.add_triangle(key, orientation), operation + " adds an actual outline triangle")
			edit_count += 1
		elif int(old.triangles[key]) != orientation:
			expect(app.paint_triangle(key, orientation), operation + " adjusts an overlapping triangle")
			edit_count += 1
	expect(edit_count > 0 and edit_count <= 10, operation + " is within the edit budget")
	expect(app.parallel_map.projection_equal(target), operation + " produces the requested target map")
	var started: int = Time.get_ticks_msec()
	var result: Dictionary = app.reconstruct_sync_for_test({"time_budget_ms": 30000, "max_search_nodes": 100000})
	reconstruction_summary[operation] = {"elapsed_ms": Time.get_ticks_msec() - started, "edit_cost": result.get("edit_cost", -1), "status": result.get("status", "")}
	expect(result.get("status") == "optimal" and int(result.get("edit_cost", -1)) == 1, operation + " certifies a one-voxel optimum")
	expect(not app.map_mode, operation + " returns to the geometry view")
	expect(app.geometry.is_face_connected(), operation + " leaves a connected geometry")
	expect(ParallelMap.from_geometry(app.geometry, app.view_index).projection_equal(target), operation + " exactly reprojects to target")
	expect_markers_visible(operation + " keeps both true supports visible")
	expect(app.player_cell == PLAYER_START and app.destination_cell == GOAL, operation + " preserves exact marker positions")
	return result


func legacy_save_check(snapshot_script: Script, cells: Dictionary) -> void:
	var snapshot: Dictionary = snapshot_script.capture(Geometry.new(cells), 0, 73)
	var legacy: Dictionary = {"cells": snapshot.cells, "view": 0, "seed": 73}
	var path: String = snapshot_script.SAVE_PATH
	var file := FileAccess.open(path, FileAccess.WRITE)
	expect(file != null, "isolated storage allows a version-one fixture")
	if file == null:
		return
	file.store_string(JSON.stringify({"version": 1, "current": legacy, "history": [legacy]}))
	file.close()
	app.queue_free()
	await wait_frames()
	var main_scene: PackedScene = load("res://test/main.tscn")
	app = main_scene.instantiate()
	root.add_child(app)
	await wait_frames()
	expect(geometry_signature(app.geometry) == geometry_signature(Geometry.new(cells)), "version-one save keeps its original geometry")
	expect(app.cycle_history.size() == 1, "version-one cycle history is retained")
	expect_markers_visible("legacy save receives visible top markers")
	expect(app.undo_cycle(), "legacy cycle snapshot still restores")
	expect_markers_visible("legacy cycle receives visible top markers")


func _run() -> void:
	var main_scene: PackedScene = load("res://test/main.tscn")
	app = main_scene.instantiate()
	root.add_child(app)
	await wait_frames(5)
	expect(app.geometry != null and app.geometry.is_face_connected(), "startup geometry is connected")
	expect(not app.map_mode, "startup is geometry mode")
	expect_markers_visible("startup places both markers on visible top faces")
	await occluded_entry_check()
	var original: Dictionary = {}
	for x in range(3):
		for z in range(2):
			original[Vector3i(x, 0, z)] = true
	var base_geometry := Geometry.new(original)
	var expanded: Dictionary = original.duplicate()
	expanded[EXTRA_CELL] = true
	var expanded_geometry := Geometry.new(expanded)
	var markers: Array[Vector3i] = [PLAYER_START, GOAL]
	app.set_geometry_for_test(original, 0, markers)
	await wait_frames()
	for view in range(4):
		expect(app.set_view(view), "set view %d succeeds in geometry mode" % view)
		await create_timer(0.38).timeout
		camera_projection_check(app._camera, view)
	app.set_view(0)
	await create_timer(0.38).timeout
	await orbit_check()
	app.set_view(0)
	await create_timer(0.38).timeout
	var move := InputEventKey.new()
	move.keycode = KEY_D
	move.pressed = true
	root.push_input(move, true)
	expect(app.player_cell == Vector3i(1, 0, 0), "WASD input moves the actual player")
	expect(app.move_player(Vector2i.RIGHT) and app.player_cell == GOAL, "player can reach the destination")
	expect(app.move_player(Vector2i.DOWN) and app.player_cell == Vector3i(2, 0, 1), "player keeps moving after reaching destination")
	expect(not app._feedback.contains("已站上"), "destination is a passive marker without arrival feedback")
	expect(app.move_player(Vector2i.UP), "player can return onto the destination")
	expect(app.move_player(Vector2i.LEFT) and app.move_player(Vector2i.LEFT), "player returns to the starting face")
	expect(app.player_cell == PLAYER_START and app.destination_cell == GOAL, "movement never relocates destination")
	await screenshot("geometry")
	expect(app.enter_map_mode(), "enter map mode with both markers visible")
	await wait_frames()
	expect_markers_visible("map entry uses a view that really exposes both marker supports")
	expect(not app.set_view(1), "camera direction is locked while editing")
	expect(not app.move_player(Vector2i.RIGHT), "player positions remain anchored during map editing")
	var initial_map: ParallelMap = ParallelMap.from_geometry(base_geometry, app.view_index)
	var expanded_map: ParallelMap = ParallelMap.from_geometry(expanded_geometry, app.view_index)
	app.set_edit_mode(EDIT_ADD)
	await screenshot("parallel_map")
	app.set_edit_mode(EDIT_PAINT)
	map_navigation_check()
	map_edit_check(expanded_map)
	expect(app.cancel_map_mode(), "cancel map editing")
	expect(geometry_signature(app.geometry) == geometry_signature(base_geometry), "cancel keeps original voxels")
	expect(app.cycle_history.is_empty(), "cancel creates no completed cycle")
	expect(app.enter_map_mode(), "enter expansion cycle")
	await wait_frames()
	reconstruct_target(expanded_map, "outline expansion")
	if app.map_mode:
		finish()
		return
	var snapshot_script: Script = load("res://test/snapshot_store.gd")
	var saved: Dictionary = snapshot_script.load_session()
	expect(not saved.is_empty() and saved.history.size() == 1, "expansion persists one independent cycle snapshot")
	if not saved.is_empty():
		expect(geometry_signature(snapshot_script.geometry_from_snapshot(saved.current)) == geometry_signature(app.geometry), "persisted geometry restores exact expanded cells")
		expect(saved.current.has("player") and saved.current.has("destination"), "save contains both markers")
	expect(app.enter_map_mode(), "enter outline contraction cycle")
	await wait_frames()
	reconstruct_target(initial_map, "outline contraction")
	if app.map_mode:
		finish()
		return
	expect(app.cycle_history.size() == 2, "both outline edits can be undone as separate cycles")
	expect(app.undo_cycle(), "undo contraction cycle")
	expect(ParallelMap.from_geometry(app.geometry, app.view_index).projection_equal(expanded_map), "cycle undo restores expanded outline")
	expect(app.undo_cycle(), "undo expansion cycle")
	expect(geometry_signature(app.geometry) == geometry_signature(base_geometry), "cycle undo restores exact original voxel set")
	expect(app.player_cell == PLAYER_START and app.destination_cell == GOAL, "cycle undo restores both marker positions")
	expect(app.cycle_history.is_empty(), "cycle undo consumes both snapshots")
	expect(app.enter_map_mode(), "enter background zero-edit cycle")
	expect(app.start_reconstruction(), "start actual background reconstruction")
	var waited: int = 0
	while app.is_busy and waited < 1200:
		await create_timer(0.01).timeout
		waited += 1
	expect(not app.is_busy and not app.map_mode, "background reconstruction applies on main thread")
	expect(geometry_signature(app.geometry) == geometry_signature(base_geometry), "background zero-edit round trip is identical")
	expect_markers_visible("background conversion preserves visible markers")
	await legacy_save_check(snapshot_script, original)
	finish()


func finish() -> void:
	var report: Dictionary = {
		"status": "passed" if failures.is_empty() else "failed",
		"checks": checks,
		"failures": failures,
		"screenshots": capture,
		"outline_reconstruction": reconstruction_summary,
	}
	print(JSON.stringify(report))
	var file := FileAccess.open("res://test/validation/ui_results.json", FileAccess.WRITE)
	if file != null:
		file.store_string(JSON.stringify(report, "\t"))
		file.close()
	if app != null:
		app.queue_free()
		await process_frame
	quit(0 if failures.is_empty() else 1)

