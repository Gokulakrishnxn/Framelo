using Framelo.Core;
using NAudio.Wave;

namespace Framelo.Platform.Media;

/// <summary>Plays the timeline mix through the default output device (WASAPI shared mode).</summary>
public sealed class AudioPlayer : IDisposable
{
    private sealed class MixProvider(AudioMixer mixer, long startFrame) : ISampleProvider
    {
        private long _frame = startFrame;
        public WaveFormat WaveFormat { get; } = WaveFormat.CreateIeeeFloatWaveFormat(PcmBuffer.Rate, PcmBuffer.Channels);
        public long Frame => Interlocked.Read(ref _frame);

        public int Read(float[] buffer, int offset, int count)
        {
            var frames = count / PcmBuffer.Channels;
            mixer.Mix(_frame, buffer.AsSpan(offset, frames * PcmBuffer.Channels));
            Interlocked.Add(ref _frame, frames);
            return frames * PcmBuffer.Channels;
        }
    }

    private WasapiOut? _output;

    /// <summary>Starts the mix at a timeline time. A device failure leaves playback silent rather than failing.</summary>
    public void Play(AudioMixer mixer, double fromSeconds)
    {
        Stop();
        try
        {
            _output = new WasapiOut(NAudio.CoreAudioApi.AudioClientShareMode.Shared, 60);
            _output.Init(new MixProvider(mixer, (long)(fromSeconds * PcmBuffer.Rate)));
            _output.Play();
        }
        catch (Exception)
        {
            Stop();
        }
    }

    public void Stop()
    {
        var output = _output;
        _output = null;
        if (output == null) return;
        try { output.Stop(); } catch (Exception) { }
        output.Dispose();
    }

    public void Dispose() => Stop();
}
