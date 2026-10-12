class_name SurfaceNets
extends RefCounted
## 等值面提取（Surface Nets / Naive Surface Nets）。
##
## 为什么不用 Marching Cubes：SN 代码量约 1/10，结果同样平滑，且天然生成四边形。
## 输入：一个块的密度采样网格（符号决定内/外）。输出：三角形网格 + 碰撞面。
##
## 约定：density < 0 = 实体（内部），density > 0 = 空气（外部）。
## 法线由密度场梯度给出，因此自动平滑。

## 立方体 8 角点（单位立方体内的偏移，分量 ∈ {0,1}）。
const CORNER_OFFSETS: Array[Vector3] = [
	Vector3(0, 0, 0), Vector3(1, 0, 0), Vector3(0, 1, 0), Vector3(1, 1, 0),
	Vector3(0, 0, 1), Vector3(1, 0, 1), Vector3(0, 1, 1), Vector3(1, 1, 1),
]

## 立方体 12 条棱（角点对）。
const EDGES: Array = [
	[0, 1], [2, 3], [4, 5], [6, 7],   # X 方向
	[0, 2], [1, 3], [4, 6], [5, 7],   # Y 方向
	[0, 4], [1, 5], [2, 6], [3, 7],   # Z 方向
]

## 构建网格。
## density: 长度 (cells+1)^3 的密度采样，索引 _gidx(x,y,z)。
## origin: 该块在行星局部空间的原点（米）。voxel_size: 单个体素边长（米）。
## 返回 { "mesh": ArrayMesh, "faces": PackedVector3Array }（faces 供碰撞用）。
static func build(density: PackedFloat32Array, cells: int,
		voxel_size: float, origin: Vector3) -> Dictionary:
	var stride := cells + 1
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	var indices := PackedInt32Array()
	var cell_vertex := PackedInt32Array()
	cell_vertex.resize(cells * cells * cells)
	cell_vertex.fill(-1)

	# ── 第一遍：每个 cell 生成一个顶点（在棱交点均值处） ──
	for z in cells:
		for y in cells:
			for x in cells:
				var d := PackedFloat32Array()
				d.resize(8)
				var neg := 0
				for c in 8:
					var v := density[_gidx(x + (c & 1), y + ((c >> 1) & 1), z + ((c >> 2) & 1), stride)]
					d[c] = v
					if v < 0.0:
						neg += 1
				if neg == 0 or neg == 8:
					continue  # 全内或全外，无表面

				var acc := Vector3.ZERO
				var cnt := 0
				for e in EDGES:
					var a := d[e[0]]
					var b := d[e[1]]
					if (a < 0.0) == (b < 0.0):
						continue
					var t := a / (a - b)
					acc += CORNER_OFFSETS[e[0]].lerp(CORNER_OFFSETS[e[1]], t)
					cnt += 1
				if cnt == 0:
					continue

				var local := Vector3(x, y, z) + acc / float(cnt)
				cell_vertex[_cidx(x, y, z, cells)] = verts.size()
				verts.append(origin + local * voxel_size)
				norms.append(_cell_gradient(d, x, y, z, density, stride))

	# ── 第二遍：每条符号变化的棱连接相邻 4 个 cell 的顶点成四边形 ──
	# X 棱：连接采样 (x,y,z)-(x+1,y,z)
	for z in range(1, cells):
		for y in range(1, cells):
			for x in range(0, cells):
				_emit_quad(indices, cell_vertex, cells, density, stride,
					Vector3i(x, y, z), Vector3i(1, 0, 0))
	# Y 棱
	for z in range(1, cells):
		for y in range(0, cells):
			for x in range(1, cells):
				_emit_quad(indices, cell_vertex, cells, density, stride,
					Vector3i(x, y, z), Vector3i(0, 1, 0))
	# Z 棱
	for z in range(0, cells):
		for y in range(1, cells):
			for x in range(1, cells):
				_emit_quad(indices, cell_vertex, cells, density, stride,
					Vector3i(x, y, z), Vector3i(0, 0, 1))

	if verts.is_empty():
		return {"mesh": null, "faces": PackedVector3Array()}

	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	arrays[Mesh.ARRAY_INDEX] = indices

	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)

	# 碰撞面（三角形顶点列表）
	var faces := PackedVector3Array()
	faces.resize(indices.size())
	for i in indices.size():
		faces[i] = verts[indices[i]]

	return {"mesh": mesh, "faces": faces}


## 沿 axis 方向、以 base 为低角点的棱：若符号变化则连接其 4 个相邻 cell。
static func _emit_quad(indices: PackedInt32Array, cell_vertex: PackedInt32Array,
		cells: int, density: PackedFloat32Array, stride: int,
		base: Vector3i, axis: Vector3i) -> void:
	var a := density[_gidx(base.x, base.y, base.z, stride)]
	var b := density[_gidx(base.x + axis.x, base.y + axis.y, base.z + axis.z, stride)]
	if (a < 0.0) == (b < 0.0):
		return

	# 棱周围 4 个 cell（绕棱一圈）。u,v 为垂直于 axis 的两个方向。
	var u: Vector3i
	var v: Vector3i
	if axis.x == 1:
		u = Vector3i(0, 1, 0); v = Vector3i(0, 0, 1)
	elif axis.y == 1:
		u = Vector3i(0, 0, 1); v = Vector3i(1, 0, 0)
	else:
		u = Vector3i(1, 0, 0); v = Vector3i(0, 1, 0)

	var v0 := _cell_v(cell_vertex, cells, base - u - v)
	var v1 := _cell_v(cell_vertex, cells, base - v)
	var v2 := _cell_v(cell_vertex, cells, base)
	var v3 := _cell_v(cell_vertex, cells, base - u)
	if v0 < 0 or v1 < 0 or v2 < 0 or v3 < 0:
		return

	# 绕序由低角点符号决定，保证法线朝外（空气侧）。
	if a < 0.0:
		indices.append_array([v0, v1, v2, v0, v2, v3])
	else:
		indices.append_array([v0, v3, v2, v0, v2, v1])


static func _cell_v(cell_vertex: PackedInt32Array, cells: int, c: Vector3i) -> int:
	if c.x < 0 or c.y < 0 or c.z < 0 or c.x >= cells or c.y >= cells or c.z >= cells:
		return -1
	return cell_vertex[_cidx(c.x, c.y, c.z, cells)]


## 采样索引（网格维 = cells+1）。
static func _gidx(x: int, y: int, z: int, stride: int) -> int:
	return x + y * stride + z * stride * stride


## cell 索引（维 = cells）。
static func _cidx(x: int, y: int, z: int, cells: int) -> int:
	return x + y * cells + z * cells * cells


## 用 8 角点密度求 cell 中心处的梯度（三线性场的解析梯度），作为平滑法线。
static func _cell_gradient(d: PackedFloat32Array, _x: int, _y: int, _z: int,
		_density: PackedFloat32Array, _stride: int) -> Vector3:
	# d 索引 = dx + dy*2 + dz*4
	var gx := (d[1] + d[3] + d[5] + d[7]) - (d[0] + d[2] + d[4] + d[6])
	var gy := (d[2] + d[3] + d[6] + d[7]) - (d[0] + d[1] + d[4] + d[5])
	var gz := (d[4] + d[5] + d[6] + d[7]) - (d[0] + d[1] + d[2] + d[3])
	var g := Vector3(gx, gy, gz)
	if g.length_squared() < 1e-12:
		return Vector3.UP
	return g.normalized()
