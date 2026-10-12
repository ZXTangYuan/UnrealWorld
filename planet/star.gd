class_name Star
extends Node3D
## 恒星（太阳）。
##
## 真正提供光照：挂一盏 DirectionalLight3D，**方向由恒星指向各行星**，
## 因此行星昼夜面、光照角度都随太阳位置变化（不是"发光球"）。
##
## 组成：
##   - 自发光球体（视觉上的太阳）
##   - 光晕（外层半透明球）
##   - DirectionalLight3D（真实光照，方向每帧朝向当前参考行星/玩家）
##   - OmniLight3D（近距离泛光，可选）

@export var radius: float = 2600.0
@export var light_energy: float = 2.2
@export var light_color: Color = Color(1.0, 0.96, 0.88)
@export var corona_color: Color = Color(1.0, 0.72, 0.35)
@export var corona_scale: float = 1.18

var light: DirectionalLight3D
var _body: MeshInstance3D
var _corona: MeshInstance3D
var _glow: OmniLight3D


func _ready() -> void:
	_build_body()
	_build_corona()
	_build_light()


func _build_body() -> void:
	_body = MeshInstance3D.new()
	_body.name = "StarBody"
	var sphere := SphereMesh.new()
	sphere.radius = radius
	sphere.height = radius * 2.0
	sphere.radial_segments = 64
	sphere.rings = 32
	_body.mesh = sphere

	# 自发光材质（不受光照影响，始终明亮）
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(1.0, 0.93, 0.72)
	mat.emission_enabled = true
	mat.emission = Color(1.0, 0.88, 0.55)
	mat.emission_energy_multiplier = 3.5
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.disable_receive_shadows = true
	_body.material_override = mat
	_body.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_body)


func _build_corona() -> void:
	_corona = MeshInstance3D.new()
	_corona.name = "Corona"
	var sphere := SphereMesh.new()
	sphere.radius = radius * corona_scale
	sphere.height = radius * corona_scale * 2.0
	sphere.radial_segments = 48
	sphere.rings = 24
	_corona.mesh = sphere

	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	mat.albedo_color = Color(corona_color.r, corona_color.g, corona_color.b, 0.22)
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.disable_receive_shadows = true
	_corona.material_override = mat
	_corona.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_corona)

	# 太阳附近的泛光（让行星面向太阳的一侧更亮）
	# 太阳附近的泛光：范围限制在太阳附近，避免把远处行星表面照成橙色。
	_glow = OmniLight3D.new()
	_glow.name = "StarGlow"
	_glow.light_color = light_color
	_glow.light_energy = 0.35
	_glow.omni_range = radius * 2.2
	_glow.shadow_enabled = false
	add_child(_glow)


func _build_light() -> void:
	light = DirectionalLight3D.new()
	light.name = "SunLight"
	light.light_color = light_color
	light.light_energy = light_energy
	light.shadow_enabled = false
	# DirectionalLight 的方向由它的朝向决定，我们每帧更新朝向使其照向目标
	add_child(light)


## 让阳光照向指定目标（通常是玩家或参考行星）。
## DirectionalLight3D 沿自身 -Z 发光，因此让 -Z 指向目标。
func aim_at(target_pos: Vector3) -> void:
	if light == null:
		return
	var to_target := target_pos - global_position
	if to_target.length_squared() < 1e-6:
		return
	# look_at 让 -Z 朝向目标
	var up := Vector3.UP
	if absf(to_target.normalized().dot(up)) > 0.99:
		up = Vector3.RIGHT
	light.look_at(target_pos, up)
