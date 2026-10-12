class_name Planet
extends Node3D
## 一颗行星。对应 Astroneer 的 AAstroPlanet。
##
## 渲染模式（可切换）：
##   RAYMARCH    —— GPU 光线步进（Astroneer 风格，零网格重建）
##   MESH        —— CPU Surface Nets 网格（回退，无 RenderingDevice 时）
##   PROXY_ONLY  —— 只渲染低模球（远景 / 非当前行星）
##
## 重力场：每颗行星都有独立球面重力场（指向自身质心）。
##   gravity_info_at(world_pos) -> { strength, up, toward_center }
##   strength 随距离衰减（平方反比近似 + 影响半径截断），供玩家选择主导星球。

enum RenderMode { RAYMARCH, MESH, PROXY_ONLY }

@export var definition: PlanetDefinition
@export var render_mode: RenderMode = RenderMode.RAYMARCH

## 轨道参数（对应 ASolarBody 的 Orbit* 字段，由 SolarSystem 驱动）。
var orbit_radius: float = 1000.0
var orbit_angle: float = 0.0
var orbit_speed: float = 0.02
var orbit_inclination: float = 0.0
var orbit_tilt: float = 0.0

## 自转（度/秒）。
var spin_speed: float = 0.0
## 轴倾角（弧度）。
var axial_tilt: float = 0.0

## 重力影响半径倍数（相对行星半径）。超过此距离重力衰减到 0。
var gravity_reach: float = 6.0
## 表面重力（m/s²），来自 definition.gravity_strength。

var volume: VoxelVolume
var terrain: RaymarchTerrain
var voxel_world: VoxelWorld            # MESH 模式（回退）
var _proxy: MeshInstance3D
var _proxy_mat: StandardMaterial3D
var proxy_distance: float = 900.0

signal ready_for_play()


func _ready() -> void:
	if definition == null:
		definition = PlanetDefinition.create_default_earthlike()
	_build_proxy()

	var has_rd := RenderingServer.get_rendering_device() != null
	var use_raymarch := render_mode == RenderMode.RAYMARCH and has_rd
	if render_mode == RenderMode.RAYMARCH and not has_rd:
		use_raymarch = false

	if render_mode == RenderMode.PROXY_ONLY:
		pass
	elif use_raymarch:
		_setup_raymarch()
	else:
		_setup_mesh()

	ready_for_play.emit()


func _setup_raymarch() -> void:
	volume = VoxelVolume.new()
	volume.name = "VoxelVolume"
	# delta 窗口中心：先放在面向太阳的一侧表面附近
	volume.center = Vector3(definition.radius, 0, 0)
	add_child(volume)
	volume.setup(definition)

	terrain = RaymarchTerrain.new()
	terrain.name = "RaymarchTerrain"
	add_child(terrain)
	terrain.setup(volume)


func _setup_mesh() -> void:
	voxel_world = VoxelWorld.new()
	voxel_world.name = "VoxelWorld"
	voxel_world.setup(definition)
	add_child(voxel_world)


## 低模代理：远处用简单球体渲染，对应 Astroneer 的 PlanetProxyActor。
func _build_proxy() -> void:
	_proxy = MeshInstance3D.new()
	_proxy.name = "Proxy"
	var sphere := SphereMesh.new()
	sphere.radius = definition.radius
	sphere.height = definition.radius * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	_proxy.mesh = sphere
	_proxy_mat = StandardMaterial3D.new()
	_proxy_mat.albedo_color = definition.surface_color
	_proxy_mat.roughness = 0.95
	_proxy_mat.metallic = 0.0
	# 极弱的自发光：深空里背光面仍能看清轮廓（真实行星也有星光/反照）
	_proxy_mat.emission_enabled = true
	_proxy_mat.emission = definition.surface_color * 0.18
	_proxy_mat.emission_energy_multiplier = 0.5
	_proxy.material_override = _proxy_mat
	add_child(_proxy)


## 让代理球可见（当本行星不是“细节行星”时）。
func set_proxy_only(enabled: bool) -> void:
	if _proxy != null:
		_proxy.visible = enabled
	if terrain != null:
		terrain.visible = not enabled
	if voxel_world != null:
		voxel_world.visible = not enabled


## 行星表面颜色（供代理球与 UI）。
func surface_color() -> Color:
	return definition.surface_color


## 大气/光晕颜色。
func atmosphere_color() -> Color:
	return definition.atmosphere_color


# ───────────────────────── 重力场 ─────────────────────────

## 查询世界坐标处的重力信息。
## 返回 { strength: float, up: Vector3, toward_center: Vector3, dist: float }
##   up = 背离质心的单位向量（角色“上”方向）
##   strength = 该点的重力加速度（m/s²），超出影响半径则为 0
func gravity_info_at(world_pos: Vector3) -> Dictionary:
	var center := global_position
	var d := world_pos - center
	var dist := d.length()
	var reach := definition.radius * gravity_reach
	if dist > reach or dist < 1e-3:
		return { "strength": 0.0, "up": Vector3.UP, "toward_center": Vector3.DOWN, "dist": dist }

	var toward := -d / dist          # 指向质心
	var up := d / dist               # 背离质心（角色“上”）

	# 表面处为定义值；向外按平方衰减；进入地表内部保持（避免穿地时重力反转）
	var surface_r := definition.radius
	var strength: float
	if dist >= surface_r:
		strength = definition.gravity_strength * (surface_r * surface_r) / (dist * dist)
		# 影响半径边缘平滑归零，避免硬边界
		var t := clampf((reach - dist) / (reach * 0.25), 0.0, 1.0)
		strength *= t
	else:
		# 地表内：线性过渡到 0（到质心处为 0）
		strength = definition.gravity_strength * (dist / surface_r)

	return { "strength": strength, "up": up, "toward_center": toward, "dist": dist }


## 兼容旧接口：返回该点的重力向量（指向质心 × 强度）。
func get_gravity_at(world_pos: Vector3) -> Vector3:
	var info := gravity_info_at(world_pos)
	return info["toward_center"] * info["strength"]


## 该点的“上”方向。
func get_up_at(world_pos: Vector3) -> Vector3:
	return (world_pos - global_position).normalized()


# ───────────────────────── 编辑接口 ─────────────────────────

## 本地产生了一条地形编辑（挖/填）时发出。
## 由**外部**（如网络层）决定是否广播；世界系统本身不依赖网络。
signal edit_created(edit: TerrainEdit)


## 统一编辑入口（两种渲染模式都可用）。
## 注意：只做本地应用。若需网络同步，连接 `edit_created` 信号。
func apply_edit(edit: TerrainEdit) -> void:
	if volume != null:
		volume.apply_edit(edit)
	elif voxel_world != null:
		voxel_world.apply_edit(edit)


func dig(world_pos: Vector3, radius: float, material: int = 0) -> void:
	var edit := TerrainEdit.new()
	edit.PlanetId = definition.world_seed
	edit.Type = VoxelWorld.EDIT_SUBTRACT
	edit.Shape = VoxelWorld.SHAPE_SPHERE
	edit.Position = world_pos - global_position   # 存行星局部坐标
	edit.Radius = radius
	edit.Material = material
	apply_edit(edit)
	edit_created.emit(edit)


func build(world_pos: Vector3, radius: float, material: int = 0) -> void:
	var edit := TerrainEdit.new()
	edit.PlanetId = definition.world_seed
	edit.Type = VoxelWorld.EDIT_ADD
	edit.Shape = VoxelWorld.SHAPE_SPHERE
	edit.Position = world_pos - global_position
	edit.Radius = radius
	edit.Material = material
	apply_edit(edit)
	edit_created.emit(edit)


## 表面采样密度（世界坐标）。
func sample_density(world_pos: Vector3) -> float:
	if volume != null:
		return volume.sample_density(world_pos - global_position)
	return 1.0


## 世界坐标射线求交（返回世界坐标命中点）。
func raycast(from: Vector3, dir: Vector3, max_dist: float = 2000.0) -> Variant:
	if volume == null:
		return null
	var hit = volume.raycast(from - global_position, dir, max_dist)
	if hit == null:
		return null
	return (hit as Vector3) + global_position


# ───────────────────────── 每帧 ─────────────────────────

func _process(delta: float) -> void:
	# 自转
	if spin_speed != 0.0:
		rotate_y(deg_to_rad(spin_speed) * delta)

	# LOD：远离时切代理球。
	# 注意：细节行星（有体素地形）**永远不用代理球**——否则玩家在地表时
	# 会被自己的代理球包裹（代理球半径 = 行星半径，而玩家站在半径之内）。
	if _proxy == null:
		return
	if render_mode == RenderMode.PROXY_ONLY:
		_proxy.visible = true
		return
	# 有体素地形时：只在玩家离得非常远（超过 3 倍行星半径）时才用代理球
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var d := cam.global_position.distance_to(global_position)
	var near := d < maxf(proxy_distance, definition.radius * 3.0)
	if terrain != null:
		terrain.visible = near
	if voxel_world != null:
		voxel_world.visible = near
	_proxy.visible = not near
