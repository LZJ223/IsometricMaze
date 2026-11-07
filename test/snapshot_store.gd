extends RefCounted
## Test harness persistence. Core Geometry and reconstruction do not depend on it.

const SAVE_DIRECTORY := "user://isometric_maze_whitebox"
const SAVE_PATH := SAVE_DIRECTORY + "/session.json"
const FORMAT_VERSION := 2


static func capture(geometry: Geometry, view_index: int, random_seed: int, player: Variant = null, destination: Variant = null) -> Dictionary:
	var cells: Array = []
	var sorted_cells: Array = geometry.voxels.keys()
	sorted_cells.sort_custom(func(a: Vector3i, b: Vector3i) -> bool:
		return a.x < b.x or (a.x == b.x and (a.y < b.y or (a.y == b.y and a.z < b.z)))
	)
	for cell: Vector3i in sorted_cells:
		cells.append([cell.x, cell.y, cell.z])
	var snapshot := {"cells": cells, "view": posmod(view_index, 4), "seed": random_seed}
	if player is Vector3i and destination is Vector3i:
		snapshot["player"] = [player.x, player.y, player.z]
		snapshot["destination"] = [destination.x, destination.y, destination.z]
	return snapshot



static func marker_from_snapshot(snapshot: Dictionary, key: String) -> Variant:
	var value: Variant = snapshot.get(key)
	if value is Array and value.size() == 3:
		return Vector3i(int(value[0]), int(value[1]), int(value[2]))
	return null


static func geometry_from_snapshot(snapshot: Dictionary) -> Geometry:
	var cells: Dictionary = {}
	var serialized: Variant = snapshot.get("cells", [])
	if serialized is Array:
		for entry: Variant in serialized:
			if entry is Array and entry.size() == 3:
				cells[Vector3i(int(entry[0]), int(entry[1]), int(entry[2]))] = true
	return Geometry.new(cells)


static func load_session() -> Dictionary:
	if not FileAccess.file_exists(SAVE_PATH):
		return {}
	var file := FileAccess.open(SAVE_PATH, FileAccess.READ)
	if file == null:
		return {}
	var data: Variant = JSON.parse_string(file.get_as_text())
	if data is not Dictionary or int(data.get("version", 0)) not in [1, FORMAT_VERSION]:
		return {}
	if data.get("current") is not Dictionary or data.get("history") is not Array:
		return {}
	return data


static func save_session(current: Dictionary, history: Array) -> bool:
	if DirAccess.make_dir_recursive_absolute(SAVE_DIRECTORY) != OK:
		return false
	var file := FileAccess.open(SAVE_PATH, FileAccess.WRITE)
	if file == null:
		return false
	file.store_string(JSON.stringify({"version": FORMAT_VERSION, "current": current, "history": history}, "\t"))
	return file.get_error() == OK
