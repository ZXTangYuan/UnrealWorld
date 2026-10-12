class_name ProceduralField
extends RefCounted
## 程序化密度基线：由 (planet_seed, position) 确定性算出密度。
## 对应 Astroneer 的 UProceduralExpression_* 表达式图 —— 这里用等价的解析式表达。
##
## 关键：基线**永不存储**。任何时刻都能按需重算，这是“无限世界可存档”的根本。
## 返回：density < 0 = 实体（行星内部），> 0 = 空气（外部）。

var definition: PlanetDefinition
var _noise: FastNoiseLite
var _seed: int
## 噪声频率（每米）。由 terrain_noise_frequency 归一化而来。
var _noise_scale: float

func _init(def: PlanetDefinition) -> void:
	definition = def
	_seed = def.world_seed
	_noise = FastNoiseLite.new()
	_noise.seed = def.world_seed
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	# 频率按“行星半径”归一化，使不同半径的行星有相似的宏观起伏。
	_noise.frequency = def.terrain_noise_frequency
	_noise.fractal_octaves = def.terrain_octaves
	_noise.fractal_type = FastNoiseLite.FRACTAL_FBM
	# 单位方向向量放大到行星尺度采样，避免数值过小
	_noise_scale = def.radius

## 采样行星局部坐标 p 处的密度（米制）。
func density(p: Vector3) -> float:
	var r := p.length()
	# 基础球 SDF：表面在 r = radius 处，故距离 = r - radius。
	var base := r - definition.radius

	# 球面噪声位移：用方向向量（已归一）采样 3D 噪声，避免球面接缝。
	var dir: Vector3 = p / maxf(r, 1e-4)
	var n := _noise.get_noise_3d(dir.x * _noise_scale,
			dir.y * _noise_scale, dir.z * _noise_scale)
	# 群系调制：极点略低（极地扁平），赤道略鼓。
	var lat_factor := 1.0 - 0.12 * absf(dir.y)
	var displacement := n * definition.terrain_amplitude * lat_factor

	return base + displacement

## 采样密度场梯度（用于法线 / 表面朝向）。
func gradient(p: Vector3, eps: float = 0.5) -> Vector3:
	return Vector3(
		density(p + Vector3(eps, 0, 0)) - density(p - Vector3(eps, 0, 0)),
		density(p + Vector3(0, eps, 0)) - density(p - Vector3(0, eps, 0)),
		density(p + Vector3(0, 0, eps)) - density(p - Vector3(0, 0, eps)),
	)
