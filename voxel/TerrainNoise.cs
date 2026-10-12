using Godot;
using System;

namespace UnrealWorld.Voxel;

/// <summary>
/// 地形基线的共享噪声实现。
///
/// **关键约束**：本文件与 `assets/shaders/terrain_noise.gdshaderinc` 必须**逐位一致**，
/// 因为渲染（GPU/GLSL）与碰撞（CPU/C#）必须算出同一个密度场，否则玩家会穿模或悬空。
/// 因此只用：整数哈希 + IEEE754 float32 基本算术（加减乘除、floor、smoothstep）。
/// 不使用任何库噪声（FastNoiseLite 等），以保证两端可精确复刻。
///
/// 基线公式（与 shader 的 tn_baseline() 一致）：
///   r    = length(p)
///   n    = fbm(p * freq, octaves, seed)      // 世界坐标采样
///   lat  = 1 - 0.12 * |p.y / r|              // 极地略扁
///   density = (r - radius) + n * amplitude * lat
/// density &lt; 0 = 实体，&gt; 0 = 空气。
/// </summary>
public static class TerrainNoise
{
    /// <summary>整数哈希（与 GLSL 版相同的常量与步骤）。</summary>
    public static uint Hash(uint x)
    {
        x ^= x >> 16;
        x *= 0x7feb352du;
        x ^= x >> 15;
        x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }

    /// <summary>格点随机值 ∈ [0,1)。用 24 位整数保证 float32 精确表示（与 GLSL 逐位一致）。</summary>
    public static float Lattice(int x, int y, int z, int seed)
    {
        uint hx = Hash(unchecked((uint)x) * 0x9E3779B1u);
        uint hy = Hash(unchecked((uint)y) * 0x85EBCA77u);
        uint hz = Hash(unchecked((uint)z) * 0xC2B2AE3Du);
        uint hs = Hash(unchecked((uint)seed) * 0x27D4EB2Fu);
        uint v = Hash(hx ^ hy ^ hz ^ hs);
        // 取高 24 位：值域 [0, 2^24)，float32 可精确表示，避免大整数转浮点丢精度
        return (v >> 8) * (1.0f / 16777216.0f);
    }

    private static float Smooth(float t) => t * t * (3.0f - 2.0f * t);

    /// <summary>三线性值噪声。</summary>
    public static float ValueNoise(float x, float y, float z, int seed)
    {
        float fx = MathF.Floor(x), fy = MathF.Floor(y), fz = MathF.Floor(z);
        int ix = (int)fx, iy = (int)fy, iz = (int)fz;
        float tx = Smooth(x - fx), ty = Smooth(y - fy), tz = Smooth(z - fz);

        float c000 = Lattice(ix, iy, iz, seed);
        float c100 = Lattice(ix + 1, iy, iz, seed);
        float c010 = Lattice(ix, iy + 1, iz, seed);
        float c110 = Lattice(ix + 1, iy + 1, iz, seed);
        float c001 = Lattice(ix, iy, iz + 1, seed);
        float c101 = Lattice(ix + 1, iy, iz + 1, seed);
        float c011 = Lattice(ix, iy + 1, iz + 1, seed);
        float c111 = Lattice(ix + 1, iy + 1, iz + 1, seed);

        float x00 = c000 + (c100 - c000) * tx;
        float x10 = c010 + (c110 - c010) * tx;
        float x01 = c001 + (c101 - c001) * tx;
        float x11 = c011 + (c111 - c011) * tx;
        float y0 = x00 + (x10 - x00) * ty;
        float y1 = x01 + (x11 - x01) * ty;
        return y0 + (y1 - y0) * tz;
    }

    /// <summary>分形叠加（octaves 层，lacunarity=2.03，gain=0.5）。</summary>
    public static float Fbm(float x, float y, float z, int octaves, int seed)
    {
        float amp = 0.5f, sum = 0.0f;
        for (int i = 0; i < octaves; i++)
        {
            sum += amp * ValueNoise(x, y, z, seed);
            x *= 2.03f; y *= 2.03f; z *= 2.03f;
            amp *= 0.5f;
        }
        return sum;
    }

    /// <summary>
    /// 基线密度（行星局部坐标，米）。
    /// </summary>
    public static float Baseline(Vector3 p, float radius, float freq, int octaves, float amplitude, int seed)
    {
        float r = MathF.Sqrt(p.X * p.X + p.Y * p.Y + p.Z * p.Z);
        if (r < 1e-4f) r = 1e-4f;
        float dy = p.Y / r;
        float n = Fbm(p.X * freq, p.Y * freq, p.Z * freq, octaves, seed);
        float lat = 1.0f - 0.12f * MathF.Abs(dy);
        return (r - radius) + n * amplitude * lat;
    }
}
