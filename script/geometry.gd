class_name Geometry
extends RefCounted
## 以单位体素作为最小方块定义几何体。Y轴方向向上。
## 邻接体素、体素表面定义
const NEIGHBORS: Array[Vector3i] = [Vector3i.RIGHT, Vector3i.LEFT, Vector3i.UP, Vector3i.DOWN, Vector3i.BACK, Vector3i.FORWARD]
const FACE_CORNERS: Array = [
	[Vector3i(1, 0, 0), Vector3i(1, 1, 0), Vector3i(1, 1, 1), Vector3i(1, 0, 1)],
	[Vector3i(0, 0, 1), Vector3i(0, 1, 1), Vector3i(0, 1, 0), Vector3i(0, 0, 0)],
	[Vector3i(0, 1, 1), Vector3i(1, 1, 1), Vector3i(1, 1, 0), Vector3i(0, 1, 0)],
	[Vector3i(0, 0, 0), Vector3i(1, 0, 0), Vector3i(1, 0, 1), Vector3i(0, 0, 1)],
	[Vector3i(1, 0, 1), Vector3i(1, 1, 1), Vector3i(0, 1, 1), Vector3i(0, 0, 1)],
	[Vector3i(0, 0, 0), Vector3i(0, 1, 0), Vector3i(1, 1, 0), Vector3i(1, 0, 0)],
]
## 体素变量定义，Dictionary{ Vector3i(位置) - Bool(状态) }
var voxels: Dictionary = {}

## 初始化，传入体素初始Dictionary
func _init(initial_voxels: Dictionary = {}) -> void:
	for cell in initial_voxels:
		if cell is Vector3i and bool(initial_voxels[cell]):
			voxels[cell] = true

## 几何体复制
func duplicate_geometry() -> Geometry:
	return Geometry.new(voxels)

## 几何体边界查询
func get_bounds() -> AABB:
	if voxels.is_empty():
		return AABB()
	var cells: Array = sorted_cells()
	var minimum: Vector3i = cells[0]
	var maximum: Vector3i = minimum
	for cell: Vector3i in cells:
		minimum = minimum.min(cell)
		maximum = maximum.max(cell)
	return AABB(Vector3(minimum), Vector3(maximum - minimum + Vector3i.ONE))

## 体素位置排序
func sorted_cells() -> Array:
	var result: Array = voxels.keys()
	result.sort_custom(cell_less)
	return result
## 自定义的排序方法
static func cell_less(a: Vector3i, b: Vector3i) -> bool:
	if a.x != b.x:
		return a.x < b.x
	if a.y != b.y:
		return a.y < b.y
	return a.z < b.z

## 邻接组团查找与输出
func connected_components() -> Array:
	var unseen: Dictionary = voxels.duplicate()
	var result: Array = []
	# 递归检查每个体素的邻接体素，被递归到的体素在Unseen中删除
	for seeds: Vector3i in sorted_cells():
		if not unseen.has(seeds):
			continue
		var component: Dictionary = {seeds: true}
		var pending: Array[Vector3i] = [seeds]
		unseen.erase(seeds)
		while not pending.is_empty():
			var cell: Vector3i = pending.pop_back()
			for delta: Vector3i in NEIGHBORS:
				var neighbor: Vector3i = cell + delta
				if unseen.has(neighbor):
					unseen.erase(neighbor)
					component[neighbor] = true
					pending.append(neighbor)
		result.append(component)
	return result
## 几何体相邻判断
func is_face_connected() -> bool:
	return not voxels.is_empty() and connected_components().size() == 1

## 几何实体Mesh网格生成
func build_mesh() -> ArrayMesh:
	var vertices := PackedVector3Array()
	var normals := PackedVector3Array()
	var uvs := PackedVector2Array()
	var indices := PackedInt32Array()
	# 外部面顶点添加
	for cell: Vector3i in sorted_cells():
		for face: int in range(6):
			if voxels.has(cell + NEIGHBORS[face]):
				continue
			var start: int = vertices.size()
			for corner: Vector3i in FACE_CORNERS[face]:
				vertices.append(Vector3(cell + corner))
				normals.append(Vector3(NEIGHBORS[face]))
			uvs.append_array(PackedVector2Array([Vector2.ZERO, Vector2.RIGHT, Vector2.ONE, Vector2.DOWN]))
			for offset: int in [0, 2, 1, 0, 3, 2]:
				indices.append(start + offset)
	# Mesh网格生成
	var mesh := ArrayMesh.new()
	if vertices.is_empty():
		return mesh
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = vertices
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_TEX_UV] = uvs
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh

## 几何实体描边线Mesh网格生成（暂用）
func build_outline_mesh() -> ArrayMesh:
	var edges: Dictionary = {}
	for cell: Vector3i in sorted_cells():
		for face: int in range(6):
			if voxels.has(cell + NEIGHBORS[face]):
				continue
			for i: int in range(4):
				var a: Vector3i = cell + FACE_CORNERS[face][i]
				var b: Vector3i = cell + FACE_CORNERS[face][(i + 1) % 4]
				if cell_less(b, a):
					var swap: Vector3i = a
					a = b
					b = swap
				var key: String = str(a) + ":" + str(b)
				if not edges.has(key):
					edges[key] = {"a": a, "b": b, "normals": []}
				edges[key]["normals"].append(NEIGHBORS[face])
	var lines := PackedVector3Array()
	var ordered: Array = edges.keys()
	ordered.sort()
	for key: String in ordered:
		var edge: Dictionary = edges[key]
		var face_normals: Array = edge["normals"]
		var visible: bool = face_normals.size() == 1
		for normal: Vector3i in face_normals:
			if normal != face_normals[0]:
				visible = true
		if visible:
			lines.append(Vector3(edge["a"]))
			lines.append(Vector3(edge["b"]))
	var mesh := ArrayMesh.new()
	if not lines.is_empty():
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = lines
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arrays)
	return mesh
