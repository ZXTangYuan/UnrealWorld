using Godot;
using System;

namespace UnrealWorld.Net;

/// <summary>
/// 一条地形编辑操作。这是网络上传输的唯一地形数据 —— 不传体素，只传“改动”。
/// 与 Astroneer 的 EDeformType / BoundedVoxelVolumeModifier 同构。
/// 确定性：所有 peer 用同一 planet_seed + 同一 edit 序列，重放结果必然一致。
///
/// 继承 RefCounted 以便通过信号传给 GDScript，并把字段导出为 GDScript 可见属性。
/// </summary>
[GlobalClass]
public partial class TerrainEdit : RefCounted
{
    /// <summary>编辑类型，对应 Astroneer 的 EDeformType 子集。</summary>
    public enum EditType : byte
    {
        Add = 0,        // 填土
        Subtract = 1,   // 挖土
        Flatten = 2,    // 平整
        Paint = 3,      // 上色
    }

    public enum EditShape : byte
    {
        Sphere = 0,
        Box = 1,
    }

    [Export] public int PlanetId { get; set; }
    /// <summary>0=Add 1=Subtract 2=Flatten 3=Paint（用 int 便于 GDScript 读取）。</summary>
    [Export] public int Type { get; set; }
    /// <summary>0=Sphere 1=Box。</summary>
    [Export] public int Shape { get; set; }
    /// <summary>行星局部坐标（PlanetSpace），float32 足够（半径 ≤ ~600m）。</summary>
    [Export] public Vector3 Position { get; set; }
    [Export] public float Radius { get; set; }
    /// <summary>体素材质 id（Paint 时使用；Add 时是填土材质）。</summary>
    [Export] public int Material { get; set; }
    /// <summary>发起者的编辑序号，用于排序 / 幂等去重。</summary>
    [Export] public long Sequence { get; set; }
    /// <summary>发起 peer 的 id（0 = 本地/服务器）。</summary>
    [Export] public int OriginPeerId { get; set; }

    public TerrainEdit() { }

    // GDScript 无法直接访问 C# 嵌套枚举，故暴露整型常量。
    public const int TYPE_ADD = 0;
    public const int TYPE_SUBTRACT = 1;
    public const int TYPE_FLATTEN = 2;
    public const int TYPE_PAINT = 3;
    public const int SHAPE_SPHERE = 0;
    public const int SHAPE_BOX = 1;

    public EditType TypeEnum => (EditType)Type;
    public EditShape ShapeEnum => (EditShape)Shape;

    public byte[] Serialize()
    {
        // 手写紧凑二进制：1+1+4+12+4+4+4+4 = 34 字节
        var buffer = new byte[34];
        int o = 0;
        buffer[o++] = (byte)Type;
        buffer[o++] = (byte)Shape;
        WriteInt32(buffer, ref o, PlanetId);
        WriteSingle(buffer, ref o, Position.X);
        WriteSingle(buffer, ref o, Position.Y);
        WriteSingle(buffer, ref o, Position.Z);
        WriteSingle(buffer, ref o, Radius);
        WriteInt32(buffer, ref o, Material);
        WriteUInt32(buffer, ref o, (uint)Sequence);
        WriteInt32(buffer, ref o, OriginPeerId);
        return buffer;
    }

    public static TerrainEdit Deserialize(byte[] buffer)
    {
        int o = 0;
        return new TerrainEdit
        {
            Type = buffer[o++],
            Shape = buffer[o++],
            PlanetId = ReadInt32(buffer, ref o),
            Position = new Vector3(
                ReadSingle(buffer, ref o),
                ReadSingle(buffer, ref o),
                ReadSingle(buffer, ref o)),
            Radius = ReadSingle(buffer, ref o),
            Material = ReadInt32(buffer, ref o),
            Sequence = ReadUInt32(buffer, ref o),
            OriginPeerId = ReadInt32(buffer, ref o),
        };
    }

    private static void WriteInt32(byte[] b, ref int o, int v)
    {
        b[o++] = (byte)v; b[o++] = (byte)(v >> 8);
        b[o++] = (byte)(v >> 16); b[o++] = (byte)(v >> 24);
    }
    private static void WriteUInt32(byte[] b, ref int o, uint v)
    {
        b[o++] = (byte)v; b[o++] = (byte)(v >> 8);
        b[o++] = (byte)(v >> 16); b[o++] = (byte)(v >> 24);
    }
    private static void WriteSingle(byte[] b, ref int o, float v)
    {
        var bytes = BitConverter.GetBytes(v);
        Buffer.BlockCopy(bytes, 0, b, o, 4); o += 4;
    }
    private static int ReadInt32(byte[] b, ref int o)
    {
        int v = b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24); o += 4; return v;
    }
    private static uint ReadUInt32(byte[] b, ref int o)
    {
        uint v = (uint)(b[o] | (b[o + 1] << 8) | (b[o + 2] << 16) | (b[o + 3] << 24)); o += 4; return v;
    }
    private static float ReadSingle(byte[] b, ref int o)
    {
        float v = BitConverter.ToSingle(b, o); o += 4; return v;
    }
}
