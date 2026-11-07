extends SceneTree
## Independent integration checks. Run with Godot --headless --script this file.

const GeometryType = preload("res://script/geometry.gd")
const MapType = preload("res://script/parallel_map.gd")
const Reconstructor = preload("res://script/geometry_reconstructor.gd")

var failures: Array[String] = []
var checks: int = 0

func _initialize() -> void:
	call_deferred("_run")

func expect(condition: bool, message: String) -> void:
	checks += 1
	if not condition:
		failures.append(message)
		push_error(message)

func geometry_from_cells(cells: Array) -> Geometry:
	var voxels: Dictionary = {}
	for value in cells:
		voxels[Vector3i(value)] = true
	return GeometryType.new(voxels)

func geometry_from_mask(mask: int, cells: Array[Vector3i]) -> Geometry:
	var voxels: Dictionary = {}
	for index in range(cells.size()):
		if mask & (1 << index):
			voxels[cells[index]] = true
	return GeometryType.new(voxels)

func map_signature(map: ParallelMap) -> String:
	return dictionary_signature(map.triangles)

func dictionary_signature(triangles: Dictionary) -> String:
	var entries: Array[String] = []
	for key: Vector3i in triangles:
		entries.append("%d,%d,%d:%d" % [key.x, key.y, key.z, triangles[key]])
	entries.sort()
	return "|".join(entries)

func outline_signature(map: ParallelMap) -> String:
	var entries: Array[String] = []
	for key: Vector3i in map.triangles:
		entries.append("%d,%d,%d" % [key.x, key.y, key.z])
	entries.sort()
	return "|".join(entries)

func mask_cost(first: int, second: int) -> int:
	var value: int = first ^ second
	var count: int = 0
	while value:
		value &= value - 1
		count += 1
	return count

func mask_connected(mask: int, cells: Array[Vector3i]) -> bool:
	if mask == 0:
		return false
	var reached: int = mask & -mask
	var previous: int = 0
	while previous != reached:
		previous = reached
		for first in range(cells.size()):
			if not reached & (1 << first):
				continue
			for second in range(cells.size()):
				if not mask & (1 << second):
					continue
				var delta: Vector3i = cells[first] - cells[second]
				if absi(delta.x) + absi(delta.y) + absi(delta.z) == 1:
					reached |= 1 << second
	return reached == mask

func mask_from_geometry(geometry: Geometry, cells: Array[Vector3i]) -> int:
	var mask: int = 0
	for index in range(cells.size()):
		if geometry.voxels.has(cells[index]):
			mask |= 1 << index
	return mask

func ray_image(geometry: Geometry, view_index: int) -> Dictionary:
	# Independent integer slab intersections through triangle centroids.
	# Coordinates multiplied by three so every calculation remains exact.
	var local_cells: Array[Vector3i] = []
	var min_a: int = 100000
	var max_a: int = -100000
	var min_b: int = 100000
	var max_b: int = -100000
	for world_cell: Vector3i in geometry.voxels:
		var local: Vector3i = MapType.world_to_view_cell(world_cell, view_index)
		local_cells.append(local)
		var a: int = local.x - local.y
		var b: int = local.z - local.y
		min_a = mini(min_a, a - 1)
		max_a = maxi(max_a, a)
		min_b = mini(min_b, b - 1)
		max_b = maxi(max_b, b)
	var image: Dictionary = {}
	for a in range(min_a, max_a + 1):
		for b in range(min_b, max_b + 1):
			for half in range(2):
				var qx: int = 3 * a + (2 if half == 0 else 1)
				var qz: int = 3 * b + (1 if half == 0 else 2)
				var nearest_exit: int = -100000
				var orientation: int = -1
				for cell in local_cells:
					var lower: Vector3i = Vector3i(3 * cell.x - qx, 3 * cell.y, 3 * cell.z - qz)
					var upper: Vector3i = lower + Vector3i(3, 3, 3)
					var entry: int = maxi(lower.x, maxi(lower.y, lower.z))
					var exit_depth: int = mini(upper.x, mini(upper.y, upper.z))
					if entry >= exit_depth or exit_depth <= nearest_exit:
						continue
					nearest_exit = exit_depth
					orientation = 0 if upper.x == exit_depth else (2 if upper.y == exit_depth else 1)
				if orientation >= 0:
					image[Vector3i(a, b, half)] = orientation
	return image

func check_mesh(geometry: Geometry) -> void:
	var mesh: ArrayMesh = geometry.build_mesh()
	expect(mesh.get_surface_count() > 0, "mesh has a renderable surface")
	var triangle_vertices: int = 0
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		triangle_vertices += indices.size() if not indices.is_empty() else vertices.size()
		expect(normals.size() == vertices.size(), "mesh vertices have normals")
		for index in range(vertices.size()):
			expect(is_equal_approx(normals[index].length(), 1.0), "mesh normal is normalized")
	var exposed_faces: int = 0
	var directions: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.FORWARD, Vector3i.BACK]
	for cell: Vector3i in geometry.voxels:
		for direction in directions:
			if not geometry.voxels.has(cell + direction):
				exposed_faces += 1
	expect(triangle_vertices == exposed_faces * 6, "mesh only contains exposed faces")

func _run() -> void:
	var cells: Array[Vector3i] = []
	for x in range(2):
		for y in range(2):
			for z in range(2):
				cells.append(Vector3i(x, y, z))
	var shapes: Array[Geometry] = []
	var masks: Array[int] = []
	var groups: Dictionary = {}
	var connected_masks: Array[int] = []
	var projection_checks: int = 0
	for mask in range(1, 256):
		var geometry: Geometry = geometry_from_mask(mask, cells)
		shapes.append(geometry)
		masks.append(mask)
		expect(geometry.is_face_connected() == mask_connected(mask, cells), "connectivity matches independent neighbor flood")
		if mask_connected(mask, cells):
			connected_masks.append(mask)
		var map: ParallelMap = MapType.from_geometry(geometry, 0)
		var signature: String = map_signature(map)
		if not groups.has(signature):
			groups[signature] = []
		groups[signature].append(mask)
		for view in range(4):
			var actual: ParallelMap = MapType.from_geometry(geometry, view)
			expect(map_signature(actual) == dictionary_signature(ray_image(geometry, view)), "independent rays match mask %d view %d" % [mask, view])
			projection_checks += 1
	for view in range(4):
		for cell in [Vector3i(-3, 2, 1), Vector3i.ZERO, Vector3i(3, -1, -2)]:
			expect(MapType.view_to_world_cell(MapType.world_to_view_cell(cell, view), view) == cell, "view transform round trip")
	check_mesh(geometry_from_mask(255, cells))
	check_mesh(geometry_from_mask(31, cells))
	var rng := RandomNumberGenerator.new()
	rng.seed = 20261030
	var keys: Array = groups.keys()
	keys.sort()
	var optimization_checks: int = 0
	var required_checks: int = 0
	for trial in range(64):
		var old_mask: int = connected_masks[rng.randi_range(0, connected_masks.size() - 1)]
		var key: String = keys[rng.randi_range(0, keys.size() - 1)]
		var target_mask: int = groups[key][0]
		var old: Geometry = geometry_from_mask(old_mask, cells)
		var target: ParallelMap = MapType.from_geometry(geometry_from_mask(target_mask, cells), 0)
		var expected_cost: int = 100000
		for candidate: int in groups[key]:
			if connected_masks.has(candidate):
				expected_cost = mini(expected_cost, mask_cost(old_mask, candidate))
		var result: Dictionary = Reconstructor.reconstruct(target, old, Vector3i.ZERO, Vector3i.ONE, {"time_budget_ms": 20000, "max_search_nodes": 100000})
		if expected_cost == 100000:
			expect(result.status == "infeasible", "infeasible matches exhaustive search")
		else:
			expect(result.status == "optimal", "finite small-domain optimum is certified")
			if result.geometry != null:
				expect(int(result.edit_cost) == expected_cost, "minimum edit cost matches exhaustive search")
				expect(result.geometry.is_face_connected(), "reconstructed shape is connected")
				expect(MapType.from_geometry(result.geometry, 0).projection_equal(target), "reconstruction projects exactly")
			else:
				expect(false, "feasible optimum includes geometry")
		optimization_checks += 1
		var must_index: int = rng.randi_range(0, 7)
		var ban_index: int = rng.randi_range(0, 7)
		var required: Array[Vector3i] = [cells[must_index]]
		var forbidden: Array[Vector3i] = [cells[ban_index]]
		var expected_required: int = 100000
		for candidate: int in groups[key]:
			if connected_masks.has(candidate) and candidate & (1 << must_index) and not candidate & (1 << ban_index):
				expected_required = mini(expected_required, mask_cost(old_mask, candidate))
		var constrained: Dictionary = Reconstructor.reconstruct(target, old, Vector3i.ZERO, Vector3i.ONE, {"time_budget_ms": 20000, "max_search_nodes": 100000, "required_cells": required, "forbidden_cells": forbidden})
		expect((constrained.status == "infeasible") == (expected_required == 100000), "required/forbidden feasibility matches brute force")
		if expected_required < 100000:
			expect(constrained.status == "optimal" and int(constrained.edit_cost) == expected_required, "required/forbidden optimum matches brute force")
		required_checks += 1
	var fixture: Dictionary = find_edit_fixture(cells, connected_masks)
	if not fixture.is_empty():
		var fixture_file := FileAccess.open("res://test/validation/edit_fixture.json", FileAccess.WRITE)
		fixture_file.store_string(JSON.stringify(fixture, "\t"))
		fixture_file.close()
	expect(not fixture.is_empty(), "found same-outline nonzero edit fixture within ten strokes")
	var old_one: Geometry = geometry_from_cells([Vector3i.ZERO])
	var disconnected_target: ParallelMap = MapType.from_geometry(geometry_from_cells([Vector3i(0, 1, 1), Vector3i(1, 1, 1)]), 0)
	var limited: Dictionary = Reconstructor.reconstruct(disconnected_target, old_one, Vector3i.ZERO, Vector3i.ONE, {"time_budget_ms": 20000, "max_search_nodes": 1})
	expect(limited.status in ["budget_exceeded", "feasible"], "node-budget exhaustion is not reported as infeasible")
	for view in range(4):
		var original: Geometry = geometry_from_mask(191, cells)
		var map: ParallelMap = MapType.from_geometry(original, view)
		var result: Dictionary = Reconstructor.reconstruct(map, original, Vector3i.ZERO, Vector3i.ONE, {"time_budget_ms": 20000, "max_search_nodes": 100000})
		expect(result.status == "optimal" and int(result.edit_cost) == 0, "unedited round trip costs zero in view %d" % view)
		if result.geometry != null:
			expect(mask_from_geometry(result.geometry, cells) == 191, "unedited round trip restores original voxels")
	var report: Dictionary = {"checks": checks, "projection_cases": projection_checks, "optimization_cases": optimization_checks, "required_forbidden_cases": required_checks, "fixture": fixture, "failures": failures, "status": "passed" if failures.is_empty() else "failed"}
	print(JSON.stringify(report))
	var file := FileAccess.open("res://test/validation/core_results.json", FileAccess.WRITE)
	file.store_string(JSON.stringify(report, "\t"))
	file.close()
	quit(0 if failures.is_empty() else 1)

func find_edit_fixture(cells: Array[Vector3i], connected_masks: Array[int]) -> Dictionary:
	var maps: Dictionary = {}
	for mask in connected_masks:
		maps[mask] = MapType.from_geometry(geometry_from_mask(mask, cells), 0)
	for first in connected_masks:
		var before: ParallelMap = maps[first]
		for second in connected_masks:
			if first == second:
				continue
			var after: ParallelMap = maps[second]
			if outline_signature(before) != outline_signature(after):
				continue
			var edits: Array = []
			for triangle: Vector3i in before.triangles:
				if before.triangles[triangle] != after.triangles[triangle]:
					edits.append({"triangle": [triangle.x, triangle.y, triangle.z], "orientation": after.triangles[triangle]})
			if edits.is_empty() or edits.size() > 10:
				continue
			var old_cells: Array = []
			var new_cells: Array = []
			for index in range(cells.size()):
				var cell: Vector3i = cells[index]
				if first & (1 << index):
					old_cells.append([cell.x, cell.y, cell.z])
				if second & (1 << index):
					new_cells.append([cell.x, cell.y, cell.z])
			return {"original": old_cells, "target_example": new_cells, "view_index": 0, "edits": edits}
	return {}

