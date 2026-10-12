// 地形基线噪声（GLSL）——必须与 scripts/voxel/TerrainNoise.cs **逐位一致**。
// 渲染与碰撞必须算出同一密度场，否则玩家穿模/悬空。
// 只用整数哈希 + float32 基本算术，避免任何库噪声带来的实现差异。
//
// 用法：在 spatial shader 里 `#include "res://addons/unreal_world/shaders/terrain_noise.gdshaderinc"`

// ── 整数哈希（与 C# Hash() 相同） ──
uint tn_hash(uint x) {
	x ^= x >> 16u;
	x *= 0x7feb352du;
	x ^= x >> 15u;
	x *= 0x846ca68bu;
	x ^= x >> 16u;
	return x;
}

float tn_lattice(int x, int y, int z, int seed) {
	uint hx = tn_hash(uint(x) * 0x9E3779B1u);
	uint hy = tn_hash(uint(y) * 0x85EBCA77u);
	uint hz = tn_hash(uint(z) * 0xC2B2AE3Du);
	uint hs = tn_hash(uint(seed) * 0x27D4EB2Fu);
	uint v = tn_hash(hx ^ hy ^ hz ^ hs);
	// 取高 24 位：值域 [0, 2^24)，float32 可精确表示
	return float(v >> 8u) * (1.0 / 16777216.0);
}

float tn_smooth(float t) { return t * t * (3.0 - 2.0 * t); }

float tn_value_noise(vec3 p, int seed) {
	vec3 f = floor(p);
	ivec3 i = ivec3(f);
	vec3 t = vec3(tn_smooth(p.x - f.x), tn_smooth(p.y - f.y), tn_smooth(p.z - f.z));

	float c000 = tn_lattice(i.x,     i.y,     i.z, seed);
	float c100 = tn_lattice(i.x + 1, i.y,     i.z, seed);
	float c010 = tn_lattice(i.x,     i.y + 1, i.z, seed);
	float c110 = tn_lattice(i.x + 1, i.y + 1, i.z, seed);
	float c001 = tn_lattice(i.x,     i.y,     i.z + 1, seed);
	float c101 = tn_lattice(i.x + 1, i.y,     i.z + 1, seed);
	float c011 = tn_lattice(i.x,     i.y + 1, i.z + 1, seed);
	float c111 = tn_lattice(i.x + 1, i.y + 1, i.z + 1, seed);

	float x00 = mix(c000, c100, t.x);
	float x10 = mix(c010, c110, t.x);
	float x01 = mix(c001, c101, t.x);
	float x11 = mix(c011, c111, t.x);
	float y0 = mix(x00, x10, t.y);
	float y1 = mix(x01, x11, t.y);
	return mix(y0, y1, t.z);
}

float tn_fbm(vec3 p, int octaves, int seed) {
	float amp = 0.5;
	float sum = 0.0;
	for (int i = 0; i < 8; i++) {
		if (i >= octaves) break;
		sum += amp * tn_value_noise(p, seed);
		p *= 2.03;
		amp *= 0.5;
	}
	return sum;
}

// 基线密度（行星局部坐标，米）。< 0 实体，> 0 空气。
float tn_baseline(vec3 p, float radius, float freq, int octaves, float amplitude, int seed) {
	float r = length(p);
	r = max(r, 1e-4);
	float dy = p.y / r;
	float n = tn_fbm(p * freq, octaves, seed);
	float lat = 1.0 - 0.12 * abs(dy);
	return (r - radius) + n * amplitude * lat;
}
