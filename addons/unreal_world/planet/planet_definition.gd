class_name PlanetDefinition
extends Resource
## 一颗行星的纯数据定义（无逻辑）。
## 对应 Astroneer 的 AAstroPlanet 可配置部分 + EPlanetIdentifier。

enum Identifier {
	TERRAN,
	TERRAN_MOON,
	ARID,
	EXOTIC,
	EXOTIC_MOON,
	TUNDRA,
	RADIATED,
}

@export var id: StringName = &"terran"
@export var display_name: String = "Terran"
@export var identifier: Identifier = Identifier.TERRAN

## 行星半径（米）。Astroneer 行星量级为几百米。
@export var radius: float = 256.0
## 世界种子：决定程序化基线与轨道。同一 seed 必然生成同一世界。
@export var world_seed: int = 0
## 表面重力强度（m/s²）。
@export var gravity_strength: float = 9.8
@export var atmosphere_height: float = 120.0

## 地形起伏噪声参数（供程序化基线使用）。
@export var terrain_noise_frequency: float = 0.006
@export var terrain_amplitude: float = 24.0
@export var terrain_octaves: int = 4

## 视觉：表面基色 / 大气色（供代理球与着色）。
@export var surface_color: Color = Color(0.30, 0.45, 0.25)
@export var atmosphere_color: Color = Color(0.45, 0.60, 0.85)
## 是否为主要行星（有体素细节，可着陆）。
@export var is_landable: bool = false

## 恒星轨道参数（星图用；对应 ASolarBody 的 Orbit* 字段）。
@export var orbit_radius: float = 12000.0
@export var orbit_period: float = 300.0
@export var orbit_phase: float = 0.0

static func create_default_earthlike() -> PlanetDefinition:
	var d := PlanetDefinition.new()
	d.id = &"terran"
	d.display_name = "Terran"
	d.identifier = Identifier.TERRAN
	d.radius = 256.0
	d.world_seed = 20261013
	return d
