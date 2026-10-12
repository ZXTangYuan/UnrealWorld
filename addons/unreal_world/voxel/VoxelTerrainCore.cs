using Godot;
using System;
using System.Collections.Generic;
using System.Threading.Tasks;

namespace ProjectA.Voxel;

/// <summary>
/// 体素地形核心（C#，权威数据 + 性能关键路径）。
///
/// **无限世界的模型**（对应 Astroneer 的“解析基线 + 有界修改器”）：
///     density(p) = baseline(p) + delta(p)
///   - baseline(p)：解析函数，**永不存储**，由 <see cref="TerrainNoise"/> 计算
///     （渲染端由 GLSL 复刻同一函数）→ 世界因此无限，没有体积边界。
///   - delta(p)：玩家挖填的稀疏修改器列表（<see cref="Edit"/>）→ 只存改动，存档极小。
///
/// 渲染用一个跟随玩家的 **delta 窗口纹理**（delta 几乎处处为 0，窗口内才非零）；
/// 碰撞/射线查询直接用稀疏列表精确求值（不依赖窗口，无边界问题）。
///
/// 多核：窗口光栅化与编辑重算都用 <see cref="Parallel.For"/> 按切片动态调度。
/// </summary>
[GlobalClass]
public partial class VoxelTerrainCore : RefCounted
{
    /// <summary>一条挖/填修改器（稀疏存储）。</summary>
    private struct Edit
    {
        public Vector3 Pos;
        public float Radius;
        public int Type;   // 1=挖(加密度→空气) 0=填(减密度→实体)
        public int Material;
    }

    private readonly List<Edit> _edits = new();

    // 行星参数（构造后固定）
    private float _planetRadius = 256f;
    private float _freq = 0.02f;
    private int _octaves = 4;
    private float _amplitude = 8f;
    private int _seed = 0;

    public int EditCount => _edits.Count;

    public void Configure(float planetRadius, float frequency, int octaves, float amplitude, int seed)
    {
        _planetRadius = planetRadius;
        _freq = frequency;
        _octaves = octaves;
        _amplitude = amplitude;
        _seed = seed;
    }

    /// <summary>添加一条编辑并返回其包围盒（用于判断需要重光栅化的窗口范围）。</summary>
    public void AddEdit(Vector3 pos, float radius, int type, int material = 0)
    {
        _edits.Add(new Edit { Pos = pos, Radius = radius, Type = type, Material = material });
    }

    public void ClearEdits() => _edits.Clear();

    /// <summary>取回全部编辑（存档用）。每项为 [x,y,z,radius,type,material]。</summary>
    public float[] GetEdits()
    {
        var outv = new float[_edits.Count * 6];
        for (int i = 0; i < _edits.Count; i++)
        {
            var e = _edits[i];
            int o = i * 6;
            outv[o] = e.Pos.X; outv[o + 1] = e.Pos.Y; outv[o + 2] = e.Pos.Z;
            outv[o + 3] = e.Radius; outv[o + 4] = e.Type; outv[o + 5] = e.Material;
        }
        return outv;
    }

    /// <summary>从存档恢复编辑。</summary>
    public void SetEdits(float[] data)
    {
        _edits.Clear();
        for (int i = 0; i + 5 < data.Length; i += 6)
        {
            _edits.Add(new Edit
            {
                Pos = new Vector3(data[i], data[i + 1], data[i + 2]),
                Radius = data[i + 3],
                Type = (int)data[i + 4],
                Material = (int)data[i + 5],
            });
        }
    }

    // ───────────────────────── 求值（CPU，精确、无边界） ─────────────────────────

    /// <summary>解析基线（与 shader 的 tn_baseline 一致）。</summary>
    public float Baseline(Vector3 p) =>
        TerrainNoise.Baseline(p, _planetRadius, _freq, _octaves, _amplitude, _seed);

    /// <summary>稀疏修改器的 delta 贡献（平滑可加核）。</summary>
    public float Delta(Vector3 p)
    {
        float d = 0f;
        for (int i = 0; i < _edits.Count; i++)
        {
            var e = _edits[i];
            float dx = p.X - e.Pos.X, dy = p.Y - e.Pos.Y, dz = p.Z - e.Pos.Z;
            float d2 = dx * dx + dy * dy + dz * dz;
            if (d2 >= e.Radius * e.Radius) continue;
            float dist = MathF.Sqrt(d2);
            float sign = e.Type == 1 ? 1f : -1f;
            d += sign * (1f - dist / e.Radius) * e.Radius;
        }
        return d;
    }

    /// <summary>完整密度（基线 + 修改器）。&lt;0 实体，&gt;0 空气。</summary>
    public float SampleDensity(Vector3 p) => Baseline(p) + Delta(p);

    /// <summary>密度梯度（中心差分），用于碰撞法线与表面朝向。</summary>
    public Vector3 Gradient(Vector3 p, float eps = 0.5f)
    {
        return new Vector3(
            SampleDensity(p + new Vector3(eps, 0, 0)) - SampleDensity(p - new Vector3(eps, 0, 0)),
            SampleDensity(p + new Vector3(0, eps, 0)) - SampleDensity(p - new Vector3(0, eps, 0)),
            SampleDensity(p + new Vector3(0, 0, eps)) - SampleDensity(p - new Vector3(0, 0, eps)));
    }

    // ───────────────────────── 窗口光栅化（渲染用） ─────────────────────────

    /// <summary>
    /// 把 delta 光栅化进一个以 center 为中心、边长 worldSize 的窗口缓冲（res³）。
    /// 只算 delta（不含基线）——基线由 shader 解析求值。
    /// 返回字节数组（R32F），供上传 3D 纹理。
    /// </summary>
    public byte[] RasterizeDeltaWindow(Vector3 center, float worldSize, int res)
    {
        var buf = new float[res * res * res];
        Vector3 origin = center - new Vector3(worldSize * 0.5f, worldSize * 0.5f, worldSize * 0.5f);
        float vs = worldSize / res;

        // 只考虑与窗口相交的编辑，避免无谓计算
        var relevant = new List<Edit>();
        float half = worldSize * 0.5f;
        foreach (var e in _edits)
        {
            float dx = MathF.Abs(e.Pos.X - center.X);
            float dy = MathF.Abs(e.Pos.Y - center.Y);
            float dz = MathF.Abs(e.Pos.Z - center.Z);
            if (dx <= half + e.Radius && dy <= half + e.Radius && dz <= half + e.Radius)
                relevant.Add(e);
        }
        if (relevant.Count == 0)
            return new byte[buf.Length * sizeof(float)];   // 全 0

        var rel = relevant.ToArray();
        // 动态多核：按 Z 切片分配
        Parallel.For(0, res, z =>
        {
            float zf = origin.Z + z * vs;
            int off = z * res * res;
            for (int y = 0; y < res; y++)
            {
                float yf = origin.Y + y * vs;
                int row = off + y * res;
                for (int x = 0; x < res; x++)
                {
                    float xf = origin.X + x * vs;
                    float d = 0f;
                    for (int i = 0; i < rel.Length; i++)
                    {
                        var e = rel[i];
                        float dx = xf - e.Pos.X, dy = yf - e.Pos.Y, dz = zf - e.Pos.Z;
                        float d2 = dx * dx + dy * dy + dz * dz;
                        if (d2 >= e.Radius * e.Radius) continue;
                        float dist = MathF.Sqrt(d2);
                        float sign = e.Type == 1 ? 1f : -1f;
                        d += sign * (1f - dist / e.Radius) * e.Radius;
                    }
                    buf[row + x] = d;
                }
            }
        });

        var bytes = new byte[buf.Length * sizeof(float)];
        Buffer.BlockCopy(buf, 0, bytes, 0, bytes.Length);
        return bytes;
    }
}
