class_name RaymarchTerrain
extends MeshInstance3D
## 无限地形渲染节点（GPU raymarch）。
##
## 用一个覆盖整个行星的“画布”网格：着色器对每条视线在行星球壳内步进 SDF，
## 命中即写 DEPTH。基线由 shader 解析求值（无限），delta 来自窗口纹理（挖填）。
##
## 注意：画布用 cull_disabled + 反深度，保证相机在球内/球外都被覆盖。

var volume: VoxelVolume
var _mat: ShaderMaterial


func setup(vol: VoxelVolume) -> void:
	volume = vol
	# 画布：一个比行星大的球，包裹整个行星（相机总在其内）
	# 画布只需覆盖行星的**表面球壳**（着色器内部会做球壳求交裁剪）。
	# 用 1.25 倍半径：足够覆盖 r_out，又不会让相机在球内浪费大量像素。
	var sphere := SphereMesh.new()
	sphere.radius = vol.definition.radius * 1.25
	sphere.height = sphere.radius * 2.0
	sphere.radial_segments = 24
	sphere.rings = 12
	mesh = sphere

	_mat = ShaderMaterial.new()
	_mat.shader = load("res://addons/unreal_world/shaders/raymarch_terrain.gdshader")
	_push_uniforms()
	material_override = _mat
	cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF

	volume.window_recentered.connect(_on_recenter)


func _push_uniforms() -> void:
	var d := volume.definition
	_mat.set_shader_parameter("planet_radius", d.radius)
	_mat.set_shader_parameter("noise_freq", d.terrain_noise_frequency)
	_mat.set_shader_parameter("noise_octaves", d.terrain_octaves)
	_mat.set_shader_parameter("noise_amplitude", d.terrain_amplitude)
	_mat.set_shader_parameter("world_seed", d.world_seed)
	_mat.set_shader_parameter("delta_tex", volume.get_texture())
	_mat.set_shader_parameter("delta_origin", volume.delta_origin())
	_mat.set_shader_parameter("delta_world_size", volume.window_world_size())


func _on_recenter(_center: Vector3) -> void:
	_mat.set_shader_parameter("delta_origin", volume.delta_origin())


## 画布与 planet_center 跟随行星（行星公转时地形不漂移）。
## 着色器在世界空间工作，因此必须把行星质心的**世界坐标**传进去，
## 并把画布网格放在行星质心处（这样相机在球内/球外都被覆盖）。
func sync_to_planet() -> void:
	if _mat == null or volume == null:
		return
	# 画布中心 = 行星质心（世界坐标）
	var planet_center := volume.global_position
	global_position = planet_center
	_mat.set_shader_parameter("planet_center", planet_center)
	# delta 窗口：volume.delta_origin() 是行星局部坐标，需转世界坐标
	_mat.set_shader_parameter("delta_origin", planet_center + volume.delta_origin())


## 屏幕射线求交（挖掘定位用）。
func raycast(camera: Camera3D, screen_pos: Vector2) -> Variant:
	var from := camera.project_ray_origin(screen_pos)
	var dir := camera.project_ray_normal(screen_pos)
	return volume.raycast(from, dir)
