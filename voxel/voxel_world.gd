class_name VoxelWorld
extends Node3D
## 体素世界：分块流式加载 + 稀疏差分存储 + 网格生成。
##
## 存储模型（决定一切，对应 Astroneer 的 AstroSaveChunk）：
##   final_density(p) = baseline(p) + Σ edits(p)
##   - baseline：程序化基线，永不存储（ProceduralField）
##   - edits：玩家挖填操作，稀疏存储（Dictionary[chunk_key, EditList]）
## 因此：存档只存“玩家改了什么”，世界可无限，联机只同步 edit。

const CHUNK_CELLS := 16          # 每块 16³ 体素
const CHUNK_WORLD_SIZE := 8.0    # 每块世界边长（米）→ voxel_size = 0.5m

# 与 C# TerrainEdit 的 Type/Shape 数值保持一致（GDScript 无法读取 C# 嵌套枚举/常量）。
const EDIT_ADD := 0
const EDIT_SUBTRACT := 1
const EDIT_FLATTEN := 2
const EDIT_PAINT := 3
const SHAPE_SPHERE := 0
const SHAPE_BOX := 1

var field: ProceduralField
var voxel_size: float = CHUNK_WORLD_SIZE / CHUNK_CELLS

## 已加载块：chunk_key(Vector3i) -> VoxelChunk
var _chunks: Dictionary = {}
## 稀疏差分：chunk_key -> Array[TerrainEdit]（仅存该块内的编辑）
var _edits: Dictionary = {}
## 已应用编辑的去重集合（originPeer:sequence），保证幂等。
var _applied_edits: Dictionary = {}

var render_distance: int = 3     # 以块为单位的半径
var _last_center: Vector3i = Vector3i(99999, 0, 0)

signal chunk_built(chunk_key: Vector3i)


func setup(def: PlanetDefinition) -> void:
	field = ProceduralField.new(def)


func _process(_delta: float) -> void:
	# 简化版流式：按相机位置决定中心块，加载/卸载。
	var cam := get_viewport().get_camera_3d()
	if cam == null:
		return
	var center := _chunk_key(cam.global_position)
	if center == _last_center:
		return
	_last_center = center
	_stream_around(center)


func _stream_around(center: Vector3i) -> void:
	var want := {}
	for dz in range(-render_distance, render_distance + 1):
		for dy in range(-render_distance, render_distance + 1):
			for dx in range(-render_distance, render_distance + 1):
				var k := center + Vector3i(dx, dy, dz)
				want[k] = true
				if not _chunks.has(k):
					_build_chunk(k)
	# 卸载远处
	for k in _chunks.keys():
		if not want.has(k):
			var c: VoxelChunk = _chunks[k]
			c.queue_free()
			_chunks.erase(k)


func _chunk_key(world_pos: Vector3) -> Vector3i:
	return Vector3i(
		floori(world_pos.x / CHUNK_WORLD_SIZE),
		floori(world_pos.y / CHUNK_WORLD_SIZE),
		floori(world_pos.z / CHUNK_WORLD_SIZE))


func _build_chunk(key: Vector3i) -> void:
	var chunk := VoxelChunk.new()
	chunk.key = key
	chunk.cells = CHUNK_CELLS
	chunk.voxel_size = voxel_size
	chunk.origin = Vector3(key) * CHUNK_WORLD_SIZE
	chunk.world = self
	add_child(chunk)
	chunk.rebuild(field, _edits.get(key, []))
	_chunks[key] = chunk
	chunk_built.emit(key)


## 应用一条编辑（本地或远端）。
func apply_edit(edit: TerrainEdit) -> void:
	# 幂等去重：同一 (peer, sequence) 只应用一次。
	var dedup_key := "%d:%d" % [edit.OriginPeerId, edit.Sequence]
	if _applied_edits.has(dedup_key):
		return
	_applied_edits[dedup_key] = true

	# 记录到受影响的块（差分存储）
	for key in _chunks_in_edit_range(edit):
		if not _edits.has(key):
			_edits[key] = []
		_edits[key].append(edit)

	# 重建受影响的已加载块
	for key in _chunks_in_edit_range(edit):
		if _chunks.has(key):
			var c: VoxelChunk = _chunks[key]
			c.rebuild(field, _edits.get(key, []))


## 找出被某条编辑影响到的块 key 集合。
func _chunks_in_edit_range(edit: TerrainEdit) -> Array:
	var r := edit.Radius + voxel_size * 2.0
	var lo := _chunk_key(edit.Position - Vector3(r, r, r))
	var hi := _chunk_key(edit.Position + Vector3(r, r, r))
	var out := []
	for z in range(lo.z, hi.z + 1):
		for y in range(lo.y, hi.y + 1):
			for x in range(lo.x, hi.x + 1):
				out.append(Vector3i(x, y, z))
	return out


## 本地产生一条编辑时发出（由外部决定是否网络同步）。
signal edit_created(edit: TerrainEdit)


## 玩家发起挖掘/建造：本地立即应用（网络同步由外部连接 edit_created）。
func dig(position: Vector3, radius: float, material: int = 0) -> void:
	var edit := TerrainEdit.new()
	edit.PlanetId = 0
	edit.Type = EDIT_SUBTRACT
	edit.Shape = SHAPE_SPHERE
	edit.Position = position
	edit.Radius = radius
	edit.Material = material
	apply_edit(edit)
	edit_created.emit(edit)


func build_terrain(position: Vector3, radius: float, material: int = 0) -> void:
	var edit := TerrainEdit.new()
	edit.PlanetId = 0
	edit.Type = EDIT_ADD
	edit.Shape = SHAPE_SPHERE
	edit.Position = position
	edit.Radius = radius
	edit.Material = material
	apply_edit(edit)
	edit_created.emit(edit)
