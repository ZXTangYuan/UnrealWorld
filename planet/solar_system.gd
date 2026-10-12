class_name SolarSystem
extends Node3D
## 太阳系：恒星 + 八大行星（参照真实太阳系的比例与外观）。
##
## **尺度说明**：真实太阳系尺度（地球 6371km、海王星轨道 45 亿 km）无法直接放进
## float32 场景，因此**整体按比例缩小**（行星半径 ÷ ~25，轨道 ÷ ~26000），
## 保持**相对关系合理**：类地行星小且靠近、气态巨行星大且远，
## 轨道间距递增（提丢斯-波得式），既不挤成一坨也不小如灰尘。
##
## 只有"当前细节行星"（默认地球）跑 raymarch 体素地形，其余用代理球。

@export var detail_planet_index: int = 2      # 地球（0=水星…）
@export var time_scale: float = 1.0

var star: Star
var planets: Array[Planet] = []
var detail_planet: Planet

## 八大行星参数。
## radius: 显示半径（米，已按 ~1/25 缩放真实半径）
## orbit:  轨道半径（米，已大幅缩小但保持相对次序与递增间距）
## period: 公转周期（秒，按真实比例压缩）
const PLANETS := [
	# 水星：小、最近、灰褐
	{ "name": "Mercury", "radius": 320.0, "orbit": 7000.0, "period": 88.0,
	  "gravity": 3.7, "color": Color(0.52, 0.48, 0.44), "atmos": Color(0.30, 0.30, 0.32),
	  "tilt": 0.03, "spin": 0.6, "seed": 1001, "freq": 0.012, "amp": 40.0, "reach": 5.0 },
	# 金星：稍大、黄白、厚大气
	{ "name": "Venus", "radius": 400.0, "orbit": 10500.0, "period": 225.0,
	  "gravity": 8.9, "color": Color(0.85, 0.76, 0.55), "atmos": Color(0.90, 0.82, 0.60),
	  "tilt": 0.05, "spin": -0.2, "seed": 1002, "freq": 0.010, "amp": 32.0, "reach": 5.0 },
	# 地球：蓝绿、海洋感、可着陆（细节行星）
	{ "name": "Earth", "radius": 420.0, "orbit": 14500.0, "period": 365.0,
	  "gravity": 9.8, "color": Color(0.22, 0.42, 0.62), "atmos": Color(0.42, 0.62, 0.95),
	  "tilt": 0.409, "spin": 6.0, "seed": 20261013, "freq": 0.008, "amp": 34.0, "reach": 6.0 },
	# 火星：红、小
	{ "name": "Mars", "radius": 300.0, "orbit": 19000.0, "period": 687.0,
	  "gravity": 3.7, "color": Color(0.62, 0.34, 0.22), "atmos": Color(0.72, 0.50, 0.38),
	  "tilt": 0.44, "spin": 5.8, "seed": 1004, "freq": 0.012, "amp": 26.0, "reach": 5.0 },
	# 木星：最大、条纹米黄
	{ "name": "Jupiter", "radius": 1050.0, "orbit": 27000.0, "period": 4333.0,
	  "gravity": 24.8, "color": Color(0.80, 0.70, 0.55), "atmos": Color(0.88, 0.78, 0.62),
	  "tilt": 0.05, "spin": 14.0, "seed": 1005, "freq": 0.006, "amp": 26.0, "reach": 8.0 },
	# 土星：大、淡黄（无环，环需额外几何）
	{ "name": "Saturn", "radius": 900.0, "orbit": 36000.0, "period": 10759.0,
	  "gravity": 10.4, "color": Color(0.86, 0.79, 0.60), "atmos": Color(0.92, 0.86, 0.68),
	  "tilt": 0.47, "spin": 13.0, "seed": 1006, "freq": 0.006, "amp": 22.0, "reach": 8.0 },
	# 天王星：青蓝
	{ "name": "Uranus", "radius": 620.0, "orbit": 45000.0, "period": 30687.0,
	  "gravity": 8.7, "color": Color(0.55, 0.78, 0.82), "atmos": Color(0.62, 0.85, 0.88),
	  "tilt": 1.706, "spin": -9.0, "seed": 1007, "freq": 0.007, "amp": 18.0, "reach": 7.0 },
	# 海王星：深蓝
	{ "name": "Neptune", "radius": 600.0, "orbit": 54000.0, "period": 60190.0,
	  "gravity": 11.2, "color": Color(0.24, 0.36, 0.72), "atmos": Color(0.32, 0.46, 0.85),
	  "tilt": 0.494, "spin": 9.5, "seed": 1008, "freq": 0.007, "amp": 20.0, "reach": 7.0 },
]

var _elapsed: float = 0.0


func _ready() -> void:
	_build_star()
	_build_planets()


func _build_star() -> void:
	star = Star.new()
	star.name = "Sun"
	star.radius = 4200.0
	star.position = Vector3.ZERO
	add_child(star)


func _build_planets() -> void:
	for i in PLANETS.size():
		var t: Dictionary = PLANETS[i]

		var def := PlanetDefinition.new()
		def.id = StringName(str(t["name"]).to_lower())
		def.display_name = t["name"]
		def.radius = t["radius"]
		def.gravity_strength = t["gravity"]
		def.terrain_noise_frequency = t["freq"]
		def.terrain_amplitude = t["amp"]
		def.terrain_octaves = 5
		def.world_seed = t["seed"]
		def.surface_color = t["color"]
		def.atmosphere_color = t["atmos"]
		def.is_landable = (i == detail_planet_index)

		var p := Planet.new()
		p.definition = def
		p.name = "Planet_%s" % t["name"]
		p.orbit_radius = t["orbit"]
		p.orbit_angle = TAU * float(i) / float(PLANETS.size())   # 均匀铺开，避免挤在一起
		p.orbit_speed = TAU / maxf(t["period"], 1.0) * time_scale
		p.orbit_tilt = t["tilt"]
		# 细节行星（玩家所在）不自转：否则地形随行星转走、玩家被落下
		p.spin_speed = 0.0 if i == detail_planet_index else t["spin"]
		p.axial_tilt = t["tilt"]
		p.gravity_reach = t["reach"]
		p.render_mode = Planet.RenderMode.RAYMARCH if i == detail_planet_index \
			else Planet.RenderMode.PROXY_ONLY
		# 细节行星固定在**自己的轨道位置**（不公转，但也不与太阳重叠）
		p.position = _orbit_pos(p)
		add_child(p)
		planets.append(p)

		if i == detail_planet_index:
			detail_planet = p


func _process(delta: float) -> void:
	_elapsed += delta
	for i in planets.size():
		# 细节行星（玩家所在）**不公转**：否则地形画布随行星漂移、玩家被甩下。
		# 其余行星正常公转。
		if i == detail_planet_index:
			continue
		var p := planets[i]
		p.orbit_angle += p.orbit_speed * delta
		p.position = _orbit_pos(p)

	# 太阳光照方向：照向"当前有玩家的行星"，否则照向细节行星。
	# 这样行星的昼夜面随公转变化（真实光照，不是发光球）。
	if star != null:
		var target := detail_planet.global_position if detail_planet != null else Vector3.ZERO
		var viewer := get_viewport().get_camera_3d()
		if viewer != null:
			# 若有玩家在细节行星上，则以玩家为光照参考（近处光照更准）
			target = viewer.global_position
		star.aim_at(target)


## 轨道位置：带轻微倾角，使行星不共面（更自然）。
func _orbit_pos(p: Planet) -> Vector3:
	var a := p.orbit_angle
	var x := cos(a) * p.orbit_radius
	var z := sin(a) * p.orbit_radius
	var y := sin(a * 2.0) * p.orbit_radius * 0.03   # 轻微轨道倾角
	# 绕 X 轴倾斜（模拟黄道倾角）
	var tilt := p.orbit_tilt
	var y2 := y * cos(tilt) - z * sin(tilt) * 0.0
	return Vector3(x, y2, z)


## 找出某世界坐标处重力最强的行星（供玩家重力场使用）。
func dominant_planet_at(world_pos: Vector3) -> Dictionary:
	var best: Planet = null
	var best_strength := 0.0
	var best_info: Dictionary = {}
	for p in planets:
		var info: Dictionary = p.gravity_info_at(world_pos)
		var s: float = info["strength"]
		if s > best_strength:
			best_strength = s
			best = p
			best_info = info
	return { "planet": best, "info": best_info }
