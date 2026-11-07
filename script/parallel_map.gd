class_name ParallelMap
extends RefCounted
## Exact orthographic isometric map. Keys are Vector3i(a, b, triangle_half).
## Empty keys are transparent; lighting never affects these orientation labels.

const RIGHT: int = 0
const LEFT: int = 1
const TOP: int = 2
const SQRT_3_OVER_2: float = 0.8660254037844386

var triangles: Dictionary = {}
var view_index: int = 0

func _init(initial_triangles: Dictionary = {}, initial_view_index: int = 0) -> void:
	triangles = initial_triangles.duplicate()
	view_index = posmod(initial_view_index, 4)

static func world_to_view_cell(cell: Vector3i, view: int) -> Vector3i:
	match posmod(view, 4):
		1: return Vector3i(cell.z, cell.y, -cell.x - 1)
		2: return Vector3i(-cell.x - 1, cell.y, -cell.z - 1)
		3: return Vector3i(-cell.z - 1, cell.y, cell.x)
	return cell

static func view_to_world_cell(cell: Vector3i, view: int) -> Vector3i:
	match posmod(view, 4):
		1: return Vector3i(-cell.z - 1, cell.y, cell.x)
		2: return Vector3i(-cell.x - 1, cell.y, -cell.z - 1)
		3: return Vector3i(cell.z, cell.y, -cell.x - 1)
	return cell

static func footprint(local_cell: Vector3i) -> Dictionary:
	var a: int = local_cell.x - local_cell.y
	var b: int = local_cell.z - local_cell.y
	return {
		Vector3i(a, b, 0): RIGHT,
		Vector3i(a, b - 1, 1): RIGHT,
		Vector3i(a, b, 1): LEFT,
		Vector3i(a - 1, b, 0): LEFT,
		Vector3i(a - 1, b - 1, 0): TOP,
		Vector3i(a - 1, b - 1, 1): TOP,
	}

static func triangle_columns(key: Vector3i) -> Dictionary:
	if key.z == 0:
		return {RIGHT: Vector2i(key.x, key.y), LEFT: Vector2i(key.x + 1, key.y), TOP: Vector2i(key.x + 1, key.y + 1)}
	return {LEFT: Vector2i(key.x, key.y), RIGHT: Vector2i(key.x, key.y + 1), TOP: Vector2i(key.x + 1, key.y + 1)}

## The two triangles projected by the upper face of this world cell.
static func top_face_keys(cell: Vector3i, view: int) -> Array[Vector3i]:
	var keys: Array[Vector3i] = []
	var patch: Dictionary = footprint(world_to_view_cell(cell, view))
	for key: Vector3i in patch:
		if patch[key] == TOP:
			keys.append(key)
	return keys

## Checks the actual owners of both triangles, including same-color occlusion.
static func top_face_visible(geometry: Geometry, cell: Vector3i, view: int) -> bool:
	if geometry == null or not geometry.voxels.has(cell) or geometry.voxels.has(cell + Vector3i.UP):
		return false
	var support: Vector3i = world_to_view_cell(cell, view)
	var keys: Array[Vector3i] = top_face_keys(cell, view)
	for occupied: Vector3i in geometry.voxels:
		var other: Vector3i = world_to_view_cell(occupied, view)
		if not _front_less(other, support):
			continue
		var patch: Dictionary = footprint(other)
		for key: Vector3i in keys:
			if patch.has(key):
				return false
	return true

## Produce world-space solver options that keep each marker on its visible top face.
static func top_marker_constraints(map: ParallelMap, support_cells: Array[Vector3i], min_cell: Vector3i, max_cell: Vector3i) -> Dictionary:
	var required_cells: Array[Vector3i] = []
	var forbidden_cells: Array[Vector3i] = []
	var protected_keys: Array[Vector3i] = []
	var result: Dictionary = {
		"valid": false, "required_cells": required_cells, "forbidden_cells": forbidden_cells,
		"protected_keys": protected_keys, "message": "",
	}
	if map == null or min_cell != min_cell.min(max_cell):
		result["message"] = "标记约束缺少轴测图或重建范围无效。"
		return result

	var first_corner: Vector3i = world_to_view_cell(min_cell, map.view_index)
	var last_corner: Vector3i = world_to_view_cell(max_cell, map.view_index)
	var local_min: Vector3i = first_corner.min(last_corner)
	var local_max: Vector3i = first_corner.max(last_corner)
	var forbidden: Dictionary = {}
	for cell: Vector3i in support_cells:
		if required_cells.has(cell):
			continue
		if not _inside_box(cell, min_cell, max_cell):
			result["message"] = "标记的支撑体素超出重建范围。"
			return result
		required_cells.append(cell)
		var above: Vector3i = cell + Vector3i.UP
		if _inside_box(above, min_cell, max_cell):
			forbidden[above] = true
		var support: Vector3i = world_to_view_cell(cell, map.view_index)
		for key: Vector3i in top_face_keys(cell, map.view_index):
			if not map.triangles.has(key) or map.triangles[key] != TOP:
				result["message"] = "玩家与目的地的支撑顶面必须保留。"
				return result
			if not protected_keys.has(key):
				protected_keys.append(key)
			for column: Vector2i in triangle_columns(key).values():
				var first: int = maxi(local_min.y, maxi(local_min.x - column.x, local_min.z - column.y))
				var last: int = mini(local_max.y, mini(local_max.x - column.x, local_max.z - column.y))
				for y: int in range(first, last + 1):
					var other := Vector3i(column.x + y, y, column.y + y)
					if _front_less(other, support):
						forbidden[view_to_world_cell(other, map.view_index)] = true
	for cell: Vector3i in required_cells:
		if forbidden.has(cell):
			result["message"] = "玩家与目的地的支撑面在当前视角会互相遮挡。"
			return result
	for cell: Vector3i in forbidden:
		forbidden_cells.append(cell)
	required_cells.sort_custom(Geometry.cell_less)
	forbidden_cells.sort_custom(Geometry.cell_less)
	protected_keys.sort_custom(Geometry.cell_less)
	result["valid"] = true
	return result

static func _inside_box(cell: Vector3i, min_cell: Vector3i, max_cell: Vector3i) -> bool:
	return cell == cell.max(min_cell) and cell == cell.min(max_cell)

static func grid_to_screen(point: Vector2i) -> Vector2:
	return Vector2(SQRT_3_OVER_2 * float(point.x - point.y), 0.5 * float(point.x + point.y))

static func triangle_vertices(key: Vector3i) -> Array[Vector2]:
	var p: Vector2i = Vector2i(key.x, key.y)
	if key.z == 0:
		return [grid_to_screen(p), grid_to_screen(p + Vector2i(1, 0)), grid_to_screen(p + Vector2i.ONE)]
	return [grid_to_screen(p), grid_to_screen(p + Vector2i(0, 1)), grid_to_screen(p + Vector2i.ONE)]

static func from_geometry(geometry: Geometry, view: int = 0) -> ParallelMap:
	var result := ParallelMap.new({}, view)
	var local_cells: Array[Vector3i] = []
	for cell: Vector3i in geometry.sorted_cells():
		local_cells.append(world_to_view_cell(cell, view))
	local_cells.sort_custom(_front_less)
	for cell: Vector3i in local_cells:
		var patch: Dictionary = footprint(cell)
		for key: Vector3i in patch:
			if not result.triangles.has(key):
				result.triangles[key] = patch[key]
	return result

static func _front_less(a: Vector3i, b: Vector3i) -> bool:
	var depth_a: int = a.x + a.y + a.z
	var depth_b: int = b.x + b.y + b.z
	if depth_a != depth_b:
		return depth_a > depth_b
	return Geometry.cell_less(a, b)

func duplicate_map() -> ParallelMap:
	return ParallelMap.new(triangles, view_index)

func projection_equal(other: ParallelMap) -> bool:
	if other == null or triangles.size() != other.triangles.size() or view_index != other.view_index:
		return false
	for key: Vector3i in triangles:
		if not other.triangles.has(key) or other.triangles[key] != triangles[key]:
			return false
	return true
