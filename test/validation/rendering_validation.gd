extends SceneTree
## Actual GL rendering regression, isolated from normal user saves.
## godot --path . --script res://test/validation/rendering_validation.gd -- --output <directory>

const GAME = preload("res://scene/game.tscn")
var app: Node
var renderer: Node
var checks := 0
var failures: Array[String] = []
var metrics: Dictionary = {}
var output_directory: String


func _initialize() -> void:
	var args := OS.get_cmdline_user_args()
	var index := args.find("--output")
	output_directory = args[index + 1] if index >= 0 and index + 1 < args.size() else OS.get_user_data_dir().path_join("rendering_validation")
	DirAccess.make_dir_recursive_absolute(output_directory)
	call_deferred("run")


func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)


func settle() -> void:
	for frame: int in range(6):
		await process_frame
	await RenderingServer.frame_post_draw


func capture(name: String) -> Image:
	await settle()
	var result := root.get_texture().get_image()
	result.save_png(output_directory.path_join(name + ".png"))
	return result


func fixture(cells: Dictionary) -> void:
	app.geometry = Geometry.new(cells)
	app.view_index = 0
	app._show_geometry()


func image_difference(a: Image, b: Image) -> int:
	var result := 0
	for y: int in range(a.get_height()):
		for x: int in range(a.get_width()):
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				result += 1
	return result


func data_roundtrip() -> void:
	var data: Image = renderer.data_viewport.get_texture().get_image()
	data.save_png(output_directory.path_join("geometry_data.png"))
	var direction: Vector3 = app._camera.global_basis.z
	var normals: Array[Vector3] = [Vector3(signf(direction.x), 0, 0), Vector3(0, signf(direction.y), 0), Vector3(0, 0, signf(direction.z))]
	var expected_ids := [1 if direction.x > 0 else 2, 3 if direction.y > 0 else 4, 5 if direction.z > 0 else 6]
	var face_index := 0
	var samples: Array = []
	for normal: Vector3 in normals:
		var point: Vector3 = Vector3.ONE * 0.5 + normal * 0.5
		var pixel: Vector2 = app._camera.unproject_position(point).floor()
		var sample: Color = data.get_pixelv(Vector2i(pixel))
		var id := roundi(sample.r * 8.0)
		expect(id == expected_ids[face_index] and sample.a == 1.0, "RGBA8 six-axis face label round trip %d" % face_index)
		var pixel_center := pixel + Vector2(0.5, 0.5)
		var ray_origin: Vector3 = app._camera.project_ray_origin(pixel_center)
		var ray_direction: Vector3 = app._camera.project_ray_normal(pixel_center)
		var hit := ray_origin + ray_direction * (normal.dot(point - ray_origin) / normal.dot(ray_direction))
		var expected_depth: float = (hit - app._camera.global_position).dot(-app._camera.global_basis.z)
		var actual_depth: float = (roundi(sample.g * 255.0) * 256 + roundi(sample.b * 255.0)) / 65535.0 * app._camera.far
		expect(absf(actual_depth - expected_depth) < app._camera.far / 65535.0 * 1.5, "RGBA8 16-bit depth round trip %d" % face_index)
		samples.append({"label": id, "depth_error": absf(actual_depth - expected_depth), "rgba": [sample.r, sample.g, sample.b, sample.a]})
		face_index += 1
	metrics["data_samples_positive" if direction.y > 0 else "data_samples_negative"] = samples


func check_depth_edge_and_grazing() -> void:
	var floor_cells := {}
	for x: int in range(-3, 4):
		for z: int in range(-3, 4):
			floor_cells[Vector3i(x, 0, z)] = true
	var steps: Dictionary = floor_cells.duplicate()
	steps[Vector3i(0, 1, 0)] = true
	fixture(steps)
	renderer.jitter_amplitude = 0.0
	await settle()
	# Behind the raised block's far edge, the two visible surfaces are both
	# upward-facing. Normals alone cannot see this occlusion boundary.
	var edge_a: Vector2 = app._camera.unproject_position(Vector3(0, 2, 0))
	var edge_b: Vector2 = app._camera.unproject_position(Vector3(0, 2, 1))
	var center := (edge_a + edge_b) * 0.5
	var perpendicular := (edge_b - edge_a).orthogonal().normalized()
	var data: Image = renderer.data_viewport.get_texture().get_image()
	var a: Color = data.get_pixelv(Vector2i(center + perpendicular * 3.0))
	var b: Color = data.get_pixelv(Vector2i(center - perpendicular * 3.0))
	expect(roundi(a.r * 8) == 3 and roundi(b.r * 8) == 3, "depth-edge fixture has equal upward normals on both sides")
	var packed_a := roundi(a.g * 255) * 256 + roundi(a.b * 255)
	var packed_b := roundi(b.g * 255) * 256 + roundi(b.b * 255)
	expect(absf(float(packed_a - packed_b) / 65535.0 * app._camera.far) > 0.5, "depth-edge fixture has an actual depth discontinuity")
	var with_line: Image = renderer.outline_viewport.get_texture().get_image()
	renderer.line_width = 0.0
	await settle()
	var without_line: Image = renderer.outline_viewport.get_texture().get_image()
	var region := Rect2i(Vector2i(center) - Vector2i(4, 4), Vector2i(9, 9))
	expect(image_difference(with_line.get_region(region), without_line.get_region(region)) > 3, "depth branch inks a same-normal occlusion boundary")
	renderer.line_width = 2.0
	fixture(floor_cells)
	app._apply_angles(Vector2(PI / 4.0, 0.012))
	await settle()
	with_line = renderer.outline_viewport.get_texture().get_image()
	data = renderer.data_viewport.get_texture().get_image()
	renderer.line_width = 0.0
	await settle()
	without_line = renderer.outline_viewport.get_texture().get_image()
	var interior_count := 0
	var false_edges := 0
	for y: int in range(3, data.get_height() - 3):
		for x: int in range(3, data.get_width() - 3):
			var sample: Color = data.get_pixel(x, y)
			if roundi(sample.r * 8) != 3 or sample.a < 1.0:
				continue
			var interior := true
			for dy: int in [-2, 0, 2]:
				for dx: int in [-2, 0, 2]:
					var neighbor: Color = data.get_pixel(x + dx, y + dy)
					interior = interior and neighbor.a == 1.0 and roundi(neighbor.r * 8) == 3
			if interior:
				interior_count += 1
				if with_line.get_pixel(x, y) != without_line.get_pixel(x, y):
					false_edges += 1
	expect(interior_count > 30 and false_edges == 0, "near-grazing coplanar voxel faces have no internal false ink")
	metrics["grazing_interior_pixels"] = interior_count
	metrics["grazing_false_edges"] = false_edges
	renderer.line_width = 2.0
	renderer.jitter_amplitude = 0.85


func check_snap_sync() -> void:
	app._apply_angles(Vector2(1.71, -0.18))
	app._snap_to_view()
	var frames := 0
	var synchronized := true
	while app._snap_tween != null:
		await process_frame
		await RenderingServer.frame_post_draw
		frames += 1
		synchronized = synchronized and renderer.color_camera.global_transform.is_equal_approx(app._camera.global_transform)
		synchronized = synchronized and renderer.data_camera.global_transform.is_equal_approx(app._camera.global_transform)
	expect(frames > 1 and synchronized, "every rendered snap frame shares the final camera transform")


func run() -> void:
	if DisplayServer.get_name() == "headless":
		push_error("This validation needs an actual rendering device, not headless.")
		quit(2)
		return
	app = GAME.instantiate()
	root.add_child(app)
	await settle()
	renderer = app._renderer
	expect(app.get_child_count() == 3 and not app._geometry_view.has_node("Outline"), "old outline entity removed without changing game scene contract")
	fixture({Vector3i.ZERO: true})
	var still := await capture("single_cube")
	data_roundtrip()
	await settle()
	var repeated := root.get_texture().get_image()
	expect(still.get_data() == repeated.get_data(), "stationary frames are byte-identical")
	var original_angles: Vector2 = app._orbit_angles
	app._apply_angles(original_angles + Vector2(0.31, -0.17))
	await capture("free_orbit")
	app._apply_angles(original_angles)
	var restored := await capture("same_view_returned")
	expect(still.get_data() == restored.get_data(), "return to identical direction reproduces every pixel")
	app._apply_angles(Vector2(PI * 1.25, -asin(1.0 / sqrt(3.0))))
	await settle()
	data_roundtrip()
	app._apply_angles(original_angles)
	await settle()
	renderer.style_seed += 1
	var changed_seed := await capture("different_seed")
	var changed_pixels := image_difference(still, changed_seed)
	metrics["seed_changed_pixels"] = changed_pixels
	expect(changed_pixels > 100, "changing style seed visibly changes the drawing")
	renderer.style_seed -= 1
	renderer.jitter_amplitude = 0.0
	await settle()
	var flat: Image = root.get_texture().get_image()
	renderer.line_width = 0.0
	var no_ink := await capture("no_outline")
	expect(image_difference(flat, no_ink) > 500, "line width parameter actually controls the outline stage")
	# Deep inside the three planar faces, disabling outlines changes nothing.
	var clean_faces := true
	for normal: Vector3 in [Vector3.RIGHT, Vector3.UP, Vector3.BACK]:
		var center: Vector3 = Vector3.ONE * 0.5 + normal * 0.5
		var screen: Vector2i = Vector2i(app._camera.unproject_position(center))
		for y: int in range(-8, 9):
			for x: int in range(-8, 9):
				clean_faces = clean_faces and flat.get_pixelv(screen + Vector2i(x, y)) == no_ink.get_pixelv(screen + Vector2i(x, y))
	expect(clean_faces, "sloped depth on all three planes creates no interior false edges")
	renderer.line_width = 2.0
	renderer.jitter_amplitude = 3.0
	var strong := await capture("strong_jitter")
	expect(image_difference(strong, flat) > 100, "jitter stage moves the rendered silhouette and fill together")
	# Alpha is taken from one already composited image: ink and fill share a
	# continuous interior with no holes, even at the supported max amplitude.
	var final_image: Image = renderer.outline_viewport.get_texture().get_image()
	var original_fill: Image = renderer.color_viewport.get_texture().get_image()
	var missing_coverage := 0
	for y: int in range(final_image.get_height()):
		for x: int in range(final_image.get_width()):
			if original_fill.get_pixel(x, y).a > 0.99 and final_image.get_pixel(x, y).a < 0.99:
				missing_coverage += 1
	expect(missing_coverage == 0, "outline compositor preserves opaque fill coverage before shared warp")
	metrics["missing_opaque_fill_pixels"] = missing_coverage
	# The output layer is geometry-only and cannot distort UI.
	var ui_region := Rect2i(1028, 704, 230, 72)
	expect(still.get_region(ui_region).get_data() == strong.get_region(ui_region).get_data(), "jitter leaves UI pixels unchanged")
	var old_size := root.size
	var old_content := root.content_scale_size
	root.content_scale_size = Vector2i(960, 640)
	root.size = Vector2i(960, 640)
	await settle()
	expect(renderer.color_viewport.size == Vector2i(root.get_visible_rect().size) and renderer.data_viewport.size == renderer.color_viewport.size, "all source buffers follow logical viewport resize")
	app.enter_map_mode()
	await settle()
	expect(not renderer._presentation.visible and renderer.color_viewport.render_target_update_mode == SubViewport.UPDATE_DISABLED, "editing hides output and stops unused geometry passes")
	app.cancel_map_mode()
	await settle()
	expect(renderer._presentation.visible, "cancel restores the rendered geometry")
	root.content_scale_size = old_content
	root.size = old_size
	renderer.jitter_amplitude = 0.85
	await check_snap_sync()
	await check_depth_edge_and_grazing()
	var cells := {}
	for x: int in range(4):
		cells[Vector3i(x, 0, 0)] = true
	cells[Vector3i(0, 1, 0)] = true
	cells[Vector3i(0, 0, 1)] = true
	fixture(cells)
	await capture("stepped_geometry")
	app._apply_angles(Vector2(0.3, -0.5))
	await capture("below_geometry")
	app.random_seed = 80429
	app.initial_voxel_count = 23
	app._show_geometry()
	app.generate_geometry()
	await capture("handdrawn_preview")
	var summary := {"status": "passed" if failures.is_empty() else "failed", "checks": checks, "failures": failures, "metrics": metrics}
	var file := FileAccess.open(output_directory.path_join("rendering_results.json"), FileAccess.WRITE)
	file.store_string(JSON.stringify(summary, "\t"))
	print(JSON.stringify(summary))
	app.queue_free()
	await process_frame
	quit(0 if failures.is_empty() else 1)
