class_name VoxelChunk
extends MeshInstance3D
## 单个体素块。负责：采样密度（基线 + 差分）→ Surface Nets 网格 → 碰撞。
##
## 关键：块内保存最终的密度缓冲 `_density`（基线 + 已应用差分），
## 便于自检与后续射线/碰撞查询复用，而不必重复采样。

var key: Vector3i
var cells: int = 16
var voxel_size: float = 0.5
var origin: Vector3
var world: VoxelWorld

## 单点累计偏移的上限（米），防止反复挖填导致密度数值发散。
const MAX_OFFSET := 64.0

var _density: PackedFloat32Array = PackedFloat32Array()
var _stride: int = 0

var _static_body: StaticBody3D
var _collision: CollisionShape3D


## 重建本块的密度采样与网格。
## field：程序化基线；edits：影响本块的编辑列表（差分）。
##
## 确定性关键：编辑贡献**可加**（加法可交换）→ 与网络到达顺序无关。
##   最终密度 = 基线 + clamp( Σ 各编辑贡献, -MAX_OFFSET, +MAX_OFFSET )
## 若用 max/min 混合（非可交换），不同 peer 收到编辑的顺序不同就会算出不同地形。
func rebuild(field: ProceduralField, edits: Array) -> void:
	_stride = cells + 1
	var stride := _stride
	var count := stride * stride * stride

	# 1) 采样程序化基线
	_density = PackedFloat32Array()
	_density.resize(count)
	for z in stride:
		for y in stride:
			for x in stride:
				var p := origin + Vector3(x, y, z) * voxel_size
				_density[x + y * stride + z * stride * stride] = field.density(p)

	# 2) 累加所有编辑贡献（可交换 → 确定性）
	if not edits.is_empty():
		var delta := PackedFloat32Array()
		delta.resize(count)
		for edit in edits:
			_accumulate_edit(delta, edit, stride)
		# 3) 应用（带饱和，防止反复挖填使数值发散）
		for i in count:
			_density[i] += clampf(delta[i], -MAX_OFFSET, MAX_OFFSET)

	var result := SurfaceNets.build(_density, cells, voxel_size, origin)
	var mesh: ArrayMesh = result["mesh"]
	if mesh == null:
		self.mesh = null
		_set_collision(PackedVector3Array())
		return

	# 网格顶点已是世界坐标 → 节点本身放在原点（用 identity 变换）。
	mesh.surface_set_material(0, _terrain_material())
	self.mesh = mesh
	_set_collision(result["faces"])


## 用最近邻从已构建的密度缓冲采样（供自检/查询）。
func sample_edited_density(p_local: Vector3) -> float:
	if _density.is_empty():
		return 0.0
	var l := (p_local - origin) / voxel_size
	var x := clampi(roundi(l.x), 0, cells)
	var y := clampi(roundi(l.y), 0, cells)
	var z := clampi(roundi(l.z), 0, cells)
	return _density[x + y * _stride + z * _stride * _stride]


## 单条编辑对密度的**可加**贡献（写入 delta 缓冲）。
##   SUBTRACT（挖）：density 增加 → delta += (radius - dist)
##   ADD（填）：     density 减少 → delta -= (radius - dist)
## 两者都是“平滑核”，且线性可加 → 与顺序无关。
func _accumulate_edit(delta: PackedFloat32Array, edit: TerrainEdit, stride: int) -> void:
	var half := float(cells) * voxel_size * 0.5
	var center := origin + Vector3(half, half, half)
	var reach := edit.Radius + half
	if center.distance_squared_to(edit.Position) > reach * reach:
		return

	var sign := 1.0 if edit.Type == VoxelWorld.EDIT_SUBTRACT else -1.0
	for z in stride:
		for y in stride:
			for x in stride:
				var p := origin + Vector3(x, y, z) * voxel_size
				var dist := p.distance_to(edit.Position)
				if dist > edit.Radius:
					continue
				# 平滑衰减核：中心 1、边缘 0（避免硬边）
				var falloff := 1.0 - dist / edit.Radius
				delta[x + y * stride + z * stride * stride] += sign * falloff * edit.Radius


func _set_collision(faces: PackedVector3Array) -> void:
	if _static_body == null:
		_static_body = StaticBody3D.new()
		add_child(_static_body)
		_collision = CollisionShape3D.new()
		_static_body.add_child(_collision)

	if faces.is_empty():
		_collision.shape = null
		return

	var shape := ConcavePolygonShape3D.new()
	shape.set_faces(faces)
	_collision.shape = shape


func _terrain_material() -> Material:
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.42, 0.36, 0.30)
	mat.roughness = 0.95
	return mat
