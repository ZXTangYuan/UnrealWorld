class_name VoxelVolume
extends Node3D
## 无限体素地形的“窗口”管理（渲染侧）。
##
## 无限模型（对应 Astroneer）：
##   density(p) = baseline(p)  [解析，GLSL 复刻，永不存储]
##              + delta(p)     [玩家挖填，稀疏列表 → 光栅化进窗口纹理]
##
## 本节点只负责：
##   - 维护 delta 窗口（跟随玩家，只有窗口内的修改器需要光栅化）
##   - 把 delta 上传成 3D 纹理（R32F）供 shader 采样
##   - 提供 CPU 侧精确查询（碰撞/射线）——直接问 C# 核心，无边界问题
##
## 世界无限：玩家走到哪里，基线就在哪里由 shader 解析生成，没有体积边界。

const WINDOW_RES := 64           # 窗口纹理分辨率（64³）
const WINDOW_WORLD_SIZE := 64.0  # 窗口世界边长（米）→ 1m/voxel

var core: VoxelTerrainCore
var definition: PlanetDefinition

## 窗口中心（行星局部坐标），跟随玩家。
var center: Vector3 = Vector3.ZERO

var _texture_rd: Texture3DRD
var _rd_rid: RID
var _last_raster_center: Vector3 = Vector3(1e9, 0, 0)

signal window_recentered(center: Vector3)


func setup(def: PlanetDefinition) -> void:
	definition = def
	core = VoxelTerrainCore.new()
	core.Configure(def.radius, def.terrain_noise_frequency,
		def.terrain_octaves, def.terrain_amplitude, def.world_seed)
	_create_texture()
	_last_raster_center = center
	_rasterize()


func _create_texture() -> void:
	var rd := RenderingServer.get_rendering_device()
	if rd == null:
		push_error("VoxelVolume 需要 RenderingDevice")
		return
	var fmt := RDTextureFormat.new()
	fmt.width = WINDOW_RES
	fmt.height = WINDOW_RES
	fmt.depth = WINDOW_RES
	fmt.format = RenderingDevice.DATA_FORMAT_R32_SFLOAT
	fmt.texture_type = RenderingDevice.TEXTURE_TYPE_3D
	fmt.usage_bits = (RenderingDevice.TEXTURE_USAGE_SAMPLING_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_UPDATE_BIT
		| RenderingDevice.TEXTURE_USAGE_CAN_COPY_FROM_BIT)
	_rd_rid = rd.texture_create(fmt, RDTextureView.new())
	_texture_rd = Texture3DRD.new()
	_texture_rd.texture_rd_rid = _rd_rid


## 若玩家移动超出窗口 1/4，则把窗口中心对齐到玩家并重新光栅化。
## 参数是**世界坐标**（玩家在父级 Planet 之下的局部坐标即可，内部统一为行星局部）。
func follow(player_pos: Vector3) -> void:
	# 转成行星局部坐标（本节点是 Planet 的子节点，to_local 即为行星局部）
	var local := to_local(player_pos) if is_inside_tree() else player_pos
	var moved := local.distance_to(_last_raster_center)
	if moved < WINDOW_WORLD_SIZE * 0.25:
		return
	center = local
	_rasterize()
	window_recentered.emit(center)


## 应用一条编辑（网络消息或本地）。加进 C# 稀疏列表并重新光栅化窗口。
func apply_edit(edit: TerrainEdit) -> void:
	core.AddEdit(edit.Position, edit.Radius, edit.Type, edit.Material)
	# 若编辑在窗口附近，立即重光栅化；否则等窗口移动到那里时再算。
	if edit.Position.distance_to(center) < WINDOW_WORLD_SIZE * 0.75 + edit.Radius:
		_rasterize()


func _rasterize() -> void:
	if core == null:
		return
	var bytes := core.RasterizeDeltaWindow(center, WINDOW_WORLD_SIZE, WINDOW_RES)
	var rd := RenderingServer.get_rendering_device()
	if rd != null:
		rd.texture_update(_rd_rid, 0, bytes)
	_last_raster_center = center


func get_texture() -> Texture3DRD:
	return _texture_rd


func delta_origin() -> Vector3:
	return center - Vector3.ONE * (WINDOW_WORLD_SIZE * 0.5)


func window_world_size() -> float:
	return WINDOW_WORLD_SIZE


# ───────────────── 精确查询（CPU，无边界） ─────────────────

## 采样密度（行星局部坐标）。负=实体。
func sample_density(p_local: Vector3) -> float:
	return core.SampleDensity(p_local)


## 沿射线步进求交，返回命中点（行星局部坐标）；未命中返回 null。
## 用解析基线的球壳范围加速。
func raycast(from: Vector3, dir: Vector3, max_dist: float = 600.0) -> Variant:
	var d := dir.normalized()
	var r_in: float = maxf(definition.radius - definition.terrain_amplitude * 1.5 - 8.0, 1.0)
	var r_out: float = definition.radius + definition.terrain_amplitude * 1.5 + 8.0

	# 与球壳求交，缩小步进范围
	var b := from.dot(d)
	var c := from.dot(from)
	var disc_out := b * b - (c - r_out * r_out)
	if disc_out < 0.0:
		return null
	var t0 := -b - sqrt(disc_out)
	var t1 := -b + sqrt(disc_out)
	var disc_in := b * b - (c - r_in * r_in)
	if disc_in >= 0.0:
		var ti0 := -b - sqrt(disc_in)
		var ti1 := -b + sqrt(disc_in)
		if ti0 > 0.0:
			t1 = ti0
		elif ti1 > 0.0:
			t0 = ti1

	var t := maxf(t0, 0.0)
	var t_end := minf(t1, max_dist)
	var steps := 0
	while t < t_end and steps < 512:
		var p := from + d * t
		var den := core.SampleDensity(p)
		if den < 0.05:
			return p
		t += maxf(den, 0.1 + t * 0.002)
		steps += 1
	return null


## 密度梯度（碰撞法线用）。
func gradient(p_local: Vector3) -> Vector3:
	return core.Gradient(p_local, 0.5)
