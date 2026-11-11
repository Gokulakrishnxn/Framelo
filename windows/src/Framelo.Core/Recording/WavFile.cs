using System.Buffers.Binary;

namespace Framelo.Core;

/// <summary>
/// Minimal crash-tolerant PCM WAV writer. The RIFF sizes are rewritten on every Flush, so after a crash at most
/// the last unflushed buffer is lost, and Repair fixes the header from the file length if even that was missed.
/// </summary>
public sealed class WavFile : IDisposable
{
    private const int HeaderSize = 44;
    private readonly FileStream _stream;
    private long _dataBytes;

    public int SampleRate { get; }
    public int Channels { get; }
    public int BitsPerSample { get; }
    public bool IsFloat { get; }
    public int BlockAlign => Channels * BitsPerSample / 8;
    public long FramesWritten => _dataBytes / BlockAlign;

    public WavFile(string path, int sampleRate, int channels, int bitsPerSample, bool isFloat)
    {
        SampleRate = sampleRate; Channels = channels; BitsPerSample = bitsPerSample; IsFloat = isFloat;
        _stream = new FileStream(path, FileMode.Create, FileAccess.ReadWrite, FileShare.Read);
        _stream.Write(Header(0));
    }

    public void Write(ReadOnlySpan<byte> pcm)
    {
        _stream.Write(pcm);
        _dataBytes += pcm.Length;
    }

    public void Flush()
    {
        var position = _stream.Position;
        _stream.Position = 0;
        _stream.Write(Header(_dataBytes));
        _stream.Position = position;
        _stream.Flush(true);
    }

    public void Dispose()
    {
        Flush();
        _stream.Dispose();
    }

    private byte[] Header(long dataBytes) => BuildHeader(SampleRate, Channels, BitsPerSample, IsFloat, dataBytes);

    public static byte[] BuildHeader(int sampleRate, int channels, int bits, bool isFloat, long dataBytes)
    {
        var h = new byte[HeaderSize];
        var data = (uint)Math.Min(dataBytes, uint.MaxValue - 36);
        "RIFF"u8.CopyTo(h);
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(4), 36 + data);
        "WAVEfmt "u8.CopyTo(h.AsSpan(8));
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(16), 16);
        BinaryPrimitives.WriteUInt16LittleEndian(h.AsSpan(20), (ushort)(isFloat ? 3 : 1));
        BinaryPrimitives.WriteUInt16LittleEndian(h.AsSpan(22), (ushort)channels);
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(24), (uint)sampleRate);
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(28), (uint)(sampleRate * channels * bits / 8));
        BinaryPrimitives.WriteUInt16LittleEndian(h.AsSpan(32), (ushort)(channels * bits / 8));
        BinaryPrimitives.WriteUInt16LittleEndian(h.AsSpan(34), (ushort)bits);
        "data"u8.CopyTo(h.AsSpan(36));
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(40), data);
        return h;
    }

    /// <summary>Rewrites the sizes in a header written by this class so they match the file. Returns true if changed.</summary>
    public static bool Repair(string path)
    {
        if (!File.Exists(path)) return false;
        using var s = new FileStream(path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
        if (s.Length < HeaderSize) return false;
        var h = new byte[HeaderSize];
        s.ReadExactly(h);
        if (!h.AsSpan(0, 4).SequenceEqual("RIFF"u8) || !h.AsSpan(36, 4).SequenceEqual("data"u8)) return false;
        var block = BinaryPrimitives.ReadUInt16LittleEndian(h.AsSpan(32));
        var data = s.Length - HeaderSize;
        if (block > 0) data -= data % block;   // drop a torn final frame
        var stored = BinaryPrimitives.ReadUInt32LittleEndian(h.AsSpan(40));
        if (stored == data) return false;
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(4), (uint)(36 + data));
        BinaryPrimitives.WriteUInt32LittleEndian(h.AsSpan(40), (uint)data);
        s.Position = 0;
        s.Write(h);
        s.SetLength(HeaderSize + data);
        return true;
    }
}
