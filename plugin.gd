@tool
extends EditorPlugin
## UnrealWorld 插件入口。
##
## 本插件主要提供**类与资源**（Planet / SolarSystem / Star / VoxelVolume /
## RaymarchTerrain / VoxelTerrainCore 等），无需在编辑器里挂载工具面板。
## 因此 _enter_tree / _exit_tree 保持为空——注册由 Godot 的 class_name 自动完成。

func _enter_tree() -> void:
	pass

func _exit_tree() -> void:
	pass
