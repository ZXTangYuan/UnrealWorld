shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_opaque;
// 无限体素地形渲染器（Astroneer 风格）。
//
// 密度 = 解析基线（GLSL 复刻 TerrainNoise.cs） + delta 窗口纹理
//   - 基线永不存储 → 世界无限、无边界
//   - delta 是玩家挖填，几乎处处为 0；只在窗口内非零
//
// 光线步进在 fragment shader 内完成，命中写 DEPTH 参与深度缓冲。

#include "res://addons/unreal_world/shaders/terrain_noise.gdshaderinc"

// ── 行星与地形参数 ──
// 行星质心的世界坐标。所有基线/delta 计算都在**行星局部空间**进行，
// 这样行星公转时地形不会漂移（多行星必需）。
uniform vec3 planet_center = vec3(0.0);
uniform float planet_radius = 256.0;
uniform float noise_freq = 0.02;
uniform int noise_octaves = 4;
uniform int world_seed = 0;
uniform float noise_amplitude = 8.0;

// ── delta 窗口 ──
uniform sampler3D delta_tex : filter_linear, repeat_disable;
uniform vec3 delta_origin = vec3(0.0);
uniform float delta_world_size = 64.0;

// ── 光线步进 ──
uniform int max_steps = 128;
uniform float max_dist = 600.0;
uniform float surf_eps = 0.06;
uniform vec3 sun_dir = vec3(0.45, 0.8, 0.35);

// 完整密度（输入世界坐标，内部转行星局部）
float density_at(vec3 p_world) {
	vec3 p = p_world - planet_center;
	float d = tn_baseline(p, planet_radius, noise_freq, noise_octaves, noise_amplitude, world_seed);
	vec3 uv = (p - delta_origin) / delta_world_size;
	if (all(greaterThan(uv, vec3(0.0))) && all(lessThan(uv, vec3(1.0)))) {
		d += texture(delta_tex, uv).r;
	}
	return d;
}

// 光线与“球壳”求交（只在行星表面附近步进，极大加速）
// 返回 (t_enter, t_exit)；无交返回 t_exit < t_enter
vec2 shell_intersect(vec3 ro, vec3 rd, float r_in, float r_out) {
	float b = dot(ro, rd);
	float c = dot(ro, ro);
	float disc_out = b * b - (c - r_out * r_out);
	if (disc_out < 0.0) return vec2(1.0, -1.0);
	float t0 = -b - sqrt(disc_out);
	float t1 = -b + sqrt(disc_out);
	float disc_in = b * b - (c - r_in * r_in);
	if (disc_in >= 0.0) {
		float ti0 = -b - sqrt(disc_in);
		float ti1 = -b + sqrt(disc_in);
		if (ti0 > 0.0) { t1 = ti0; }
		else if (ti1 > 0.0) { t0 = ti1; }
	}
	return vec2(t0, t1);
}

// 中心差分法线（6 次采样，但平滑无阶梯）。e 用固定小值，与命中步长解耦。
vec3 calc_normal(vec3 p, float e) {
	return normalize(vec3(
		density_at(p + vec3(e, 0, 0)) - density_at(p - vec3(e, 0, 0)),
		density_at(p + vec3(0, e, 0)) - density_at(p - vec3(0, e, 0)),
		density_at(p + vec3(0, 0, e)) - density_at(p - vec3(0, 0, e))));
}

// 按高度与坡度着色（简单群系感）
vec3 terrain_color(vec3 p_world, vec3 n) {
	vec3 pl = p_world - planet_center;
	float alt = (length(pl) - planet_radius) / max(noise_amplitude, 0.001);  // ~[-1,1]
	float slope = 1.0 - clamp(dot(n, normalize(pl)), 0.0, 1.0);
	vec3 rock = vec3(0.34, 0.31, 0.28);
	vec3 soil = vec3(0.46, 0.38, 0.28);
	vec3 grass = vec3(0.30, 0.42, 0.24);
	vec3 snow = vec3(0.85, 0.87, 0.90);
	vec3 c = mix(soil, grass, clamp(alt * 1.5 + 0.5, 0.0, 1.0));
	c = mix(c, snow, clamp((alt - 0.75) * 2.0, 0.0, 1.0));
	c = mix(c, rock, clamp(slope * 1.6, 0.0, 1.0));
	return c;
}

void fragment() {
	vec3 ro = CAMERA_POSITION_WORLD;
	vec3 frag_world = (INV_VIEW_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 rd = normalize(frag_world - ro);

	// 只在行星表面 ±(amplitude+margin) 的球壳内步进（行星局部空间）
	vec3 ro_local = ro - planet_center;
	// 球壳收窄到地形幅度附近（越窄步进越少、越快）
	float r_in = max(planet_radius - noise_amplitude * 1.2 - 4.0, 1.0);
	float r_out = planet_radius + noise_amplitude * 1.2 + 4.0;
	// ── 关键优化：站在地表时，看向太空的像素直接丢弃 ──
	// 判据：相机在球壳内（地表附近），且射线"向外"（与径向同向）→ 不可能命中地面。
	float cam_r = length(ro_local);
	if (cam_r < r_out && cam_r > r_in * 0.5 && dot(rd, normalize(ro_local)) > 0.02) {
		discard;   // 地表向外看 → 天空，无需步进
	}
	vec2 tt = shell_intersect(ro_local, rd, r_in, r_out);
	if (tt.y < max(tt.x, 0.0)) {
		discard;   // 光线不穿过球壳
	}

	// 关键：若相机在球壳外，从球壳入口开始步进；若在球壳内（地表），从 t=0 开始。
	// 这样"从地表向上看太空"时不会在球壳内侧命中。
	// ── 关键性能修复 ──
	// 旧实现从 t=0 开始，导致看向地平线时要在球壳里走数百米（近千步）才放弃。
	// 正确做法：
	//   (1) 若射线起点在球壳**内**，直接从 0 开始（地表视角，通常很快命中）；
	//   (2) 若在球壳**外**，从球壳入口 tt.x 开始，跳过所有空区域。
	//   并且给步长设一个与"距表面深度"相关的下限，避免沿切线方向空转。
	float t = 0.0;
	float t_exit = min(tt.y, max_dist);
	if (tt.x > 0.0) {
		t = tt.x;   // 从球壳入口开始，跳过外部空区域
	}
	// 起点必须为空气；若相机埋在实体里，直接放弃
	if (density_at(ro + rd * t) < 0.0) {
		discard;
	}
	bool hit = false;
	// 自适应步长：起始步长按球壳厚度归一，沿切线方向也能快速推进
	float base_step = max(0.5, (t_exit - t) / float(max_steps));
	for (int i = 0; i < max_steps; i++) {
		if (t > t_exit) break;
		vec3 p = ro + rd * t;
		float d = density_at(p);
		if (d < surf_eps) { hit = true; break; }
		// 步长 = max(SDF 距离, 自适应下限)，保证不超过步数预算
		float step = max(d, base_step * 0.3 + t * 0.002);
		t += step;
	}
	if (!hit) {
		discard;
	}

	vec3 p = ro + rd * t;
	// 法线步长固定（不随距离放大）——这是消除阶梯伪影的关键
	float e = max(0.35, noise_amplitude * 0.02);
	vec3 n = calc_normal(p, e);
	vec3 L = normalize(sun_dir);
	float diff = max(dot(n, L), 0.0);
	float amb = 0.30 + 0.25 * max(dot(n, normalize(p - planet_center)), 0.0);
	float ao = 1.0;
	for (int i = 1; i <= 2; i++) {
		ao -= 0.13 * max(density_at(p + n * float(i) * e * 4.0), 0.0);
	}
	ao = clamp(ao, 0.35, 1.0);

	ALBEDO = terrain_color(p, n) * (amb + 0.9 * diff) * ao;

	vec4 clip = PROJECTION_MATRIX * VIEW_MATRIX * vec4(p, 1.0);
	DEPTH = clip.z / clip.w;
}
