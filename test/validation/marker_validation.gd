extends SceneTree
## Independent marker and changed-outline checks. Run Godot headless with --script.

const MIN_CELL := Vector3i(-2, 1, 2)
const MAX_CELL := MIN_CELL + Vector3i.ONE
var checks: int = 0
var failures: int = 0

func _initialize() -> void:
	call_deferred("_run")

func _expect(condition: bool, label: String) -> void:
	checks += 1
	if not condition:
		failures += 1
		if failures <= 10:
			push_error(label)

func _ray_shows_top(geometry: Geometry, support: Vector3i, key: Vector3i, view: int) -> bool:
	# Integer slab intersection through the triangle center, scaled by three.
	var qx: int = 3 * key.x + (2 if key.z == 0 else 1)
	var qz: int = 3 * key.y + (1 if key.z == 0 else 2)
	var nearest_exit: int = -100000
	var visible: bool = false
	for world_cell: Vector3i in geometry.voxels:
		var cell: Vector3i = ParallelMap.world_to_view_cell(world_cell, view)
		var lower := Vector3i(3 * cell.x - qx, 3 * cell.y, 3 * cell.z - qz)
		var upper: Vector3i = lower + Vector3i(3, 3, 3)
		var entry: int = maxi(lower.x, maxi(lower.y, lower.z))
		var exit_depth: int = mini(upper.x, mini(upper.y, upper.z))
		if entry < exit_depth and exit_depth > nearest_exit:
			nearest_exit = exit_depth
			visible = world_cell == support and exit_depth == upper.y
	return visible

func _satisfies(geometry: Geometry, options: Dictionary) -> bool:
	for cell: Vector3i in options["required_cells"]:
		if not geometry.voxels.has(cell):
			return false
	for cell: Vector3i in options["forbidden_cells"]:
		if geometry.voxels.has(cell):
			return false
	return true

func _check_visibility(cells: Array[Vector3i]) -> void:
	for view: int in range(4):
		for support: Vector3i in cells:
			var one := Geometry.new({support: true})
			var map: ParallelMap = ParallelMap.from_geometry(one, view)
			var keys: Array[Vector3i] = ParallelMap.top_face_keys(support, view)
			var options: Dictionary = ParallelMap.top_marker_constraints(map, [support, support], MIN_CELL, MAX_CELL)
			_expect(options["valid"] and options["required_cells"].size() == 1 and options["protected_keys"].size() == 2, "duplicate markers share one support and two keys")
			for mask: int in range(1 << cells.size()):
				var occupancy: Dictionary = {}
				for index: int in range(cells.size()):
					if mask & (1 << index):
						occupancy[cells[index]] = true
				var geometry := Geometry.new(occupancy)
				var expected: bool = _ray_shows_top(geometry, support, keys[0], view) and _ray_shows_top(geometry, support, keys[1], view)
				_expect(ParallelMap.top_face_visible(geometry, support, view) == expected, "visible support matches independent rays, view %d mask %d support %s" % [view, mask, support])
				_expect(_satisfies(geometry, options) == expected, "solver constraints match independent rays, view %d mask %d support %s" % [view, mask, support])

func _check_outline_changes() -> void:
	var original := Geometry.new({MIN_CELL: true})
	var expanded := Geometry.new({MIN_CELL: true, (MIN_CELL + Vector3i.RIGHT): true})
	var original_map: ParallelMap = ParallelMap.from_geometry(original, 0)
	var expanded_map: ParallelMap = ParallelMap.from_geometry(expanded, 0)
	_expect(original_map.triangles.size() < expanded_map.triangles.size(), "fixture expands the target outline")
	for entry: Array in [[original, expanded_map], [expanded, original_map]]:
		var options: Dictionary = ParallelMap.top_marker_constraints(entry[1], [MIN_CELL], MIN_CELL, MAX_CELL)
		_expect(options["valid"], "changed-outline target preserves marker keys")
		var result: Dictionary = GeometryReconstructor.reconstruct(entry[1], entry[0], MIN_CELL, MAX_CELL, options)
		_expect(result["status"] == "optimal" and result["edit_cost"] == 1, "changed outline reconstructed at cost one")
		var rebuilt: Geometry = result["geometry"]
		_expect(rebuilt != null and ParallelMap.from_geometry(rebuilt, 0).projection_equal(entry[1]) and ParallelMap.top_face_visible(rebuilt, MIN_CELL, 0), "changed outline and marker preserved")
	var key: Vector3i = ParallelMap.top_face_keys(MIN_CELL, 0)[0]
	var removed: ParallelMap = original_map.duplicate_map()
	removed.triangles.erase(key)
	_expect(not ParallelMap.top_marker_constraints(removed, [MIN_CELL], MIN_CELL, MAX_CELL)["valid"], "deleted marker triangle rejected")
	var recolored: ParallelMap = original_map.duplicate_map()
	recolored.triangles[key] = ParallelMap.RIGHT
	_expect(not ParallelMap.top_marker_constraints(recolored, [MIN_CELL], MIN_CELL, MAX_CELL)["valid"], "recolored marker triangle rejected")
	_expect(not ParallelMap.top_marker_constraints(original_map, [MIN_CELL + Vector3i.DOWN], MIN_CELL, MAX_CELL)["valid"], "out of range support rejected")
	var empty := ParallelMap.new()
	_expect(GeometryReconstructor.reconstruct(empty, original, MIN_CELL, MAX_CELL)["status"] == "infeasible", "empty target cannot create a nonempty connected geometry")
	var same_color_occluded := Geometry.new({MIN_CELL: true, MAX_CELL: true})
	_expect(ParallelMap.from_geometry(same_color_occluded, 0).projection_equal(original_map), "closer same-column voxel keeps the same colors")
	_expect(not ParallelMap.top_face_visible(same_color_occluded, MIN_CELL, 0), "closer same-color voxel hides the actual support")
	_expect(not ParallelMap.top_marker_constraints(original_map, [MIN_CELL, MAX_CELL], MIN_CELL, MAX_CELL)["valid"], "incompatible supports rejected")

func _run() -> void:
	var cells: Array[Vector3i] = []
	for x: int in range(MIN_CELL.x, MAX_CELL.x + 1):
		for y: int in range(MIN_CELL.y, MAX_CELL.y + 1):
			for z: int in range(MIN_CELL.z, MAX_CELL.z + 1):
				cells.append(Vector3i(x, y, z))
	_check_visibility(cells)
	_check_outline_changes()
	print("MARKER_VALIDATION checks=%d failures=%d" % [checks, failures])
	quit(0 if failures == 0 else 1)
