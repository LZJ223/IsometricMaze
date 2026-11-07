class_name GeometryReconstructor
extends RefCounted
## Exact minimum voxel-edit reconstruction in a finite, inclusive world box.
## Projection uses column-front thresholds and a minimum-weight closure/min-cut.
## Connectivity is imposed by complete conflict-driven branching, not greedy fill.
## Safe on a worker Thread: only data is created here, never scene/render objects.

const INF: int = 1_000_000_000

static func reconstruct(map: ParallelMap, original: Geometry, min_cell: Vector3i, max_cell: Vector3i, options: Dictionary = {}) -> Dictionary:
	if map == null or original == null:
		return {"status": "invalid_input", "geometry": null, "edit_cost": -1, "optimal": false, "message": "缺少轴测图或原几何体。", "stats": {}}
	var solver := Solver.new(map, original, min_cell, max_cell, options)
	return solver.run()


class FlowGraph:
	extends RefCounted
	var adjacency: Array = []
	var destination: Array[int] = []
	var capacity: Array[int] = []
	var levels: Array[int] = []
	var cursor: Array[int] = []
	var deadline: int
	var aborted: bool = false
	var augmentations: int = 0

	func _init(node_count: int, limit: int) -> void:
		deadline = limit
		for i: int in range(node_count):
			adjacency.append([])
		levels.resize(node_count)
		cursor.resize(node_count)

	func add_edge(from: int, to: int, cap: int) -> void:
		var index: int = destination.size()
		adjacency[from].append(index)
		destination.append(to)
		capacity.append(cap)
		adjacency[to].append(index + 1)
		destination.append(from)
		capacity.append(0)

	func _expired() -> bool:
		if deadline >= 0 and Time.get_ticks_msec() >= deadline:
			aborted = true
		return aborted

	func _bfs() -> bool:
		levels.fill(-1)
		levels[0] = 0
		var queue: Array[int] = [0]
		var index: int = 0
		while index < queue.size():
			if _expired():
				return false
			var node: int = queue[index]
			index += 1
			for edge: int in adjacency[node]:
				var next: int = destination[edge]
				if capacity[edge] > 0 and levels[next] == -1:
					levels[next] = levels[node] + 1
					queue.append(next)
		return levels[1] >= 0

	func _push(node: int, amount: int) -> int:
		if node == 1:
			return amount
		while cursor[node] < adjacency[node].size():
			var edge: int = adjacency[node][cursor[node]]
			var next: int = destination[edge]
			if capacity[edge] > 0 and levels[next] == levels[node] + 1:
				var sent: int = _push(next, mini(amount, capacity[edge]))
				if sent > 0:
					capacity[edge] -= sent
					capacity[edge ^ 1] += sent
					return sent
			cursor[node] += 1
		return 0

	func max_flow() -> int:
		var flow: int = 0
		while _bfs():
			cursor.fill(0)
			while not _expired():
				var sent: int = _push(0, GeometryReconstructor.INF)
				if sent == 0:
					break
				flow += sent
				augmentations += 1
				if flow >= GeometryReconstructor.INF:
					return flow
		return flow

	func source_side() -> Dictionary:
		var seen: Dictionary = {0: true}
		var queue: Array[int] = [0]
		var index: int = 0
		while index < queue.size():
			var node: int = queue[index]
			index += 1
			for edge: int in adjacency[node]:
				var next: int = destination[edge]
				if capacity[edge] > 0 and not seen.has(next):
					seen[next] = true
					queue.append(next)
		return seen


class Solver:
	extends RefCounted
	var target: ParallelMap
	var old: Geometry
	var minimum: Vector3i
	var maximum: Vector3i
	var settings: Dictionary
	var started: int
	var deadline: int
	var max_nodes: int
	var columns: Array = []
	var column_index: Dictionary = {}
	var cell_index: Dictionary = {}
	var base_edges: Array = []
	var node_count: int = 2
	var fixed_deletions: int = 0
	var exhausted: bool = false
	var preparation_error: String = ""
	var preparation_status: String = "infeasible"
	var stats: Dictionary = {"columns": 0, "candidate_cells": 0, "search_nodes": 0, "min_cut_calls": 0, "flow_augmentations": 0, "pruned_branches": 0, "elapsed_ms": 0}

	func _init(map: ParallelMap, original: Geometry, min_cell: Vector3i, max_cell: Vector3i, options: Dictionary) -> void:
		target = map.duplicate_map()
		old = original.duplicate_geometry()
		minimum = min_cell
		maximum = max_cell
		settings = options.duplicate(true)
		started = Time.get_ticks_msec()
		var budget: int = int(settings.get("time_budget_ms", 5000))
		deadline = -1 if budget < 0 else started + budget
		max_nodes = int(settings.get("max_search_nodes", 10000))

	func _expired() -> bool:
		if deadline >= 0 and Time.get_ticks_msec() >= deadline:
			exhausted = true
		return exhausted

	func _inside(cell: Vector3i) -> bool:
		return cell.x >= minimum.x and cell.y >= minimum.y and cell.z >= minimum.z and cell.x <= maximum.x and cell.y <= maximum.y and cell.z <= maximum.z

	func _column_less(a: Vector2i, b: Vector2i) -> bool:
		return a.x < b.x if a.x != b.x else a.y < b.y

	func _prepare() -> bool:
		if minimum.x > maximum.x or minimum.y > maximum.y or minimum.z > maximum.z:
			preparation_error = "重建范围无效。"
			preparation_status = "invalid_input"
			return false
		if target.triangles.is_empty():
			preparation_error = "空图不能重建为非空连续物体。"
			return false
		var possible: Dictionary = {}
		var triangle_keys: Array = target.triangles.keys()
		for key in triangle_keys:
			if not key is Vector3i or key.z < 0 or key.z > 1 or not target.triangles[key] is int or target.triangles[key] < 0 or target.triangles[key] > 2:
				preparation_error = "三角图包含无效坐标或朝向。"
				preparation_status = "invalid_input"
				return false
			for column: Vector2i in ParallelMap.triangle_columns(key).values():
				possible[column] = true
		triangle_keys.sort_custom(Geometry.cell_less)
		var local_min: Vector3i = ParallelMap.world_to_view_cell(minimum, target.view_index)
		var local_max: Vector3i = local_min
		for x: int in [minimum.x, maximum.x]:
			for y: int in [minimum.y, maximum.y]:
				for z: int in [minimum.z, maximum.z]:
					var corner: Vector3i = ParallelMap.world_to_view_cell(Vector3i(x, y, z), target.view_index)
					local_min = local_min.min(corner)
					local_max = local_max.max(corner)
		var ordered: Array = possible.keys()
		ordered.sort_custom(_column_less)
		for column: Vector2i in ordered:
			if _expired():
				return false
			var patch: Dictionary = ParallelMap.footprint(Vector3i(column.x, 0, column.y))
			var allowed: bool = true
			for key: Vector3i in patch:
				if not target.triangles.has(key):
					allowed = false
					break
			if not allowed:
				continue
			var first: int = maxi(local_min.y, maxi(local_min.x - column.x, local_min.z - column.y))
			var last: int = mini(local_max.y, mini(local_max.x - column.x, local_max.z - column.y))
			if first > last:
				continue
			var cells: Array[Vector3i] = []
			var depths: Array[int] = []
			var nodes: Array[int] = []
			for depth: int in range(first, last + 1):
				var local_cell := Vector3i(column.x + depth, depth, column.y + depth)
				var world_cell: Vector3i = ParallelMap.view_to_world_cell(local_cell, target.view_index)
				cells.append(world_cell)
				depths.append(local_cell.x + local_cell.y + local_cell.z)
				nodes.append(node_count)
				cell_index[world_cell] = cell_index.size()
				node_count += 1
			column_index[column] = columns.size()
			columns.append({"id": column, "cells": cells, "depths": depths, "nodes": nodes})
			for i: int in range(1, nodes.size()):
				base_edges.append(Vector3i(nodes[i], nodes[i - 1], GeometryReconstructor.INF))
		for key: Vector3i in triangle_keys:
			var covering: Dictionary = ParallelMap.triangle_columns(key)
			var owner_id: Vector2i = covering[int(target.triangles[key])]
			if not column_index.has(owner_id):
				preparation_error = "有三角格没有允许存在的显示立方体列。"
				return false
			var owner: Dictionary = columns[column_index[owner_id]]
			base_edges.append(Vector3i(0, owner["nodes"][0], GeometryReconstructor.INF))
			for other_id: Vector2i in covering.values():
				if other_id == owner_id or not column_index.has(other_id):
					continue
				var other: Dictionary = columns[column_index[other_id]]
				for j: int in range(other["cells"].size()):
					var owner_threshold: int = -1
					for i: int in range(owner["cells"].size()):
						if owner["depths"][i] > other["depths"][j]:
							owner_threshold = i
							break
					if owner_threshold < 0:
						base_edges.append(Vector3i(other["nodes"][j], 1, GeometryReconstructor.INF))
					else:
						base_edges.append(Vector3i(other["nodes"][j], owner["nodes"][owner_threshold], GeometryReconstructor.INF))
		for cell: Vector3i in old.voxels:
			if not cell_index.has(cell):
				fixed_deletions += 1
		stats["columns"] = columns.size()
		stats["candidate_cells"] = cell_index.size()
		return true

	func _finish(status: String, geometry: Geometry = null, cost: int = -1, message: String = "") -> Dictionary:
		stats["elapsed_ms"] = Time.get_ticks_msec() - started
		return {"status": status, "geometry": geometry, "edit_cost": cost, "optimal": status == "optimal", "message": message, "stats": stats.duplicate()}

	func _make_flags(value: Variant) -> Dictionary:
		var result: Dictionary = {}
		if value is Array or value is Dictionary:
			for cell in value:
				if cell is Vector3i:
					result[cell] = true
		return result

	func _state_key(required: Dictionary, forbidden: Dictionary) -> String:
		var required_ids: Array[int] = []
		var forbidden_ids: Array[int] = []
		for cell: Vector3i in required:
			required_ids.append(int(cell_index.get(cell, -1)))
		for cell: Vector3i in forbidden:
			if cell_index.has(cell):
				forbidden_ids.append(int(cell_index[cell]))
		required_ids.sort()
		forbidden_ids.sort()
		return str(required_ids) + ":" + str(forbidden_ids)

	func _relax(required: Dictionary, forbidden: Dictionary) -> Dictionary:
		for cell: Vector3i in required:
			if forbidden.has(cell) or not cell_index.has(cell):
				return {}
		stats["min_cut_calls"] += 1
		var graph := FlowGraph.new(node_count, deadline)
		var option_cells: Array = []
		for column: Dictionary in columns:
			if _expired():
				return {}
			var cells: Array = column["cells"]
			var nodes: Array = column["nodes"]
			var options: Array = []
			var costs: Array[int] = []
			for top: int in range(-1, cells.size()):
				var kept: Array[Vector3i] = []
				var cost: int = 0
				var valid: bool = true
				for rank: int in range(cells.size()):
					var cell: Vector3i = cells[rank]
					var occupied: bool = false
					if rank == top:
						occupied = true
					elif rank < top:
						occupied = required.has(cell) or (old.voxels.has(cell) and not forbidden.has(cell))
					if occupied:
						kept.append(cell)
					if (required.has(cell) and not occupied) or (forbidden.has(cell) and occupied):
						valid = false
					if occupied != old.voxels.has(cell):
						cost += 1
				options.append(kept)
				costs.append(cost)
				if not valid:
					# Exclude exactly this front label, including the empty label.
					if top == -1:
						graph.add_edge(0, nodes[0], GeometryReconstructor.INF)
					elif top == cells.size() - 1:
						graph.add_edge(nodes[top], 1, GeometryReconstructor.INF)
					else:
						graph.add_edge(nodes[top], nodes[top + 1], GeometryReconstructor.INF)
			option_cells.append(options)
			for i: int in range(cells.size()):
				var delta: int = costs[i + 1] - costs[i]
				if delta >= 0:
					graph.add_edge(nodes[i], 1, delta)
				else:
					graph.add_edge(0, nodes[i], -delta)
		for edge: Vector3i in base_edges:
			graph.add_edge(edge.x, edge.y, edge.z)
		var flow: int = graph.max_flow()
		stats["flow_augmentations"] += graph.augmentations
		if graph.aborted:
			exhausted = true
			return {}
		if flow >= GeometryReconstructor.INF:
			return {}
		var selected: Dictionary = graph.source_side()
		var result: Dictionary = {}
		for index: int in range(columns.size()):
			var column: Dictionary = columns[index]
			var top: int = -1
			for i: int in range(column["nodes"].size()):
				if selected.has(column["nodes"][i]):
					top = i
			for cell: Vector3i in option_cells[index][top + 1]:
				result[cell] = true
		var cost: int = fixed_deletions
		for cell: Vector3i in cell_index:
			if result.has(cell) != old.voxels.has(cell):
				cost += 1
		return {"geometry": Geometry.new(result), "cost": cost}

	func run() -> Dictionary:
		if _expired() or max_nodes == 0:
			return _finish("budget_exceeded", null, -1, "计算预算已用尽，尚未判定是否有解。")
		if not _prepare():
			if exhausted:
				return _finish("budget_exceeded", null, -1, "计算预算已用尽，尚未判定是否有解。")
			return _finish(preparation_status, null, -1, preparation_error)
		var required: Dictionary = _make_flags(settings.get("required_cells", []))
		var forbidden: Dictionary = _make_flags(settings.get("forbidden_cells", []))
		for cell: Vector3i in required:
			if forbidden.has(cell) or not cell_index.has(cell):
				return _finish("infeasible", null, -1, "必留位置与目标图、边界或禁用条件冲突。")
		var pending: Array = [{"required": required, "forbidden": forbidden}]
		var seen: Dictionary = {}
		var best: Geometry = null
		var best_cost: int = GeometryReconstructor.INF
		while not pending.is_empty():
			if _expired() or (max_nodes >= 0 and int(stats["search_nodes"]) >= max_nodes):
				exhausted = true
				break
			var state: Dictionary = pending.pop_back()
			required = state["required"]
			forbidden = state["forbidden"]
			var key: String = _state_key(required, forbidden)
			if seen.has(key):
				continue
			seen[key] = true
			stats["search_nodes"] += 1
			var relaxed: Dictionary = _relax(required, forbidden)
			if exhausted:
				break
			if relaxed.is_empty():
				stats["pruned_branches"] += 1
				continue
			var cost: int = relaxed["cost"]
			if cost >= best_cost:
				stats["pruned_branches"] += 1
				continue
			var geometry: Geometry = relaxed["geometry"]
			var components: Array = geometry.connected_components()
			if components.size() == 1:
				# Every published result is independently reprojected before commit.
				if not ParallelMap.from_geometry(geometry, target.view_index).projection_equal(target):
					return _finish("internal_error", null, -1, "重建的投影复查失败，未输出几何体。")
				best = geometry
				best_cost = cost
				if best_cost == 0:
					break
				continue
			if components.is_empty():
				continue
			components.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
				if a.size() != b.size():
					return a.size() < b.size()
				var a_cells: Array = a.keys()
				var b_cells: Array = b.keys()
				a_cells.sort_custom(Geometry.cell_less)
				b_cells.sort_custom(Geometry.cell_less)
				return Geometry.cell_less(a_cells[0], b_cells[0]))
			var component: Dictionary = components[0]
			var component_cells: Array = component.keys()
			component_cells.sort_custom(Geometry.cell_less)
			var u: Vector3i = component_cells[0]
			var v: Vector3i = u
			for cell: Vector3i in geometry.sorted_cells():
				if not component.has(cell):
					v = cell
					break
			var boundary: Dictionary = {}
			for cell: Vector3i in component:
				for delta: Vector3i in Geometry.NEIGHBORS:
					var neighbor: Vector3i = cell + delta
					if cell_index.has(neighbor) and not geometry.voxels.has(neighbor) and not forbidden.has(neighbor):
						boundary[neighbor] = true
			var branches: Array = []
			for remove_cell: Vector3i in [u, v]:
				if not required.has(remove_cell):
					var banned: Dictionary = forbidden.duplicate()
					banned[remove_cell] = true
					branches.append({"required": required.duplicate(), "forbidden": banned})
			var boundary_cells: Array = boundary.keys()
			boundary_cells.sort_custom(Geometry.cell_less)
			for keep_cell: Vector3i in boundary_cells:
				if required.has(keep_cell):
					continue
				var forced: Dictionary = required.duplicate()
				forced[keep_cell] = true
				branches.append({"required": forced, "forbidden": forbidden.duplicate()})
			# Stack is reversed so the declared branch order remains deterministic.
			branches.reverse()
			pending.append_array(branches)
		if exhausted:
			if best != null:
				return _finish("feasible", best, best_cost, "已找到连续解；预算耗尽，尚未证明改动最少。")
			return _finish("budget_exceeded", null, -1, "计算预算已用尽；尚未找到解，不能据此判定无解。")
		if best == null:
			return _finish("infeasible", null, -1, "当前关卡范围内不存在同投影的连续物体。")
		return _finish("optimal", best, best_cost, "已找到新增与删除总数最少的连续物体。")
