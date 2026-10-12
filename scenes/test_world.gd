extends Node3D
## UnrealWorld 独立测试场景：装配太阳系（不含玩家/网络），验证插件自洽。
## 运行：godot --path . --rendering-driver vulkan res://scenes/test_world.tscn

var solar_system: SolarSystem
var _cam: Camera3D


func _ready() -> void:
	var we := WorldEnvironment.new()
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color(0.004, 0.006, 0.014)
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.10, 0.12, 0.18)
	env.ambient_light_energy = 0.28
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = env
	add_child(we)

	solar_system = SolarSystem.new()
	solar_system.name = "SolarSystem"
	add_child(solar_system)

	# 俯视相机
	_cam = Camera3D.new()
	_cam.fov = 62.0
	_cam.far = 200000.0
	_cam.position = Vector3(0, 34000, 48000)
	add_child(_cam)
	_cam.look_at(Vector3.ZERO, Vector3.UP)
	_cam.current = true

	print("[test_world] 太阳系就绪：%d 行星" % solar_system.planets.size())
