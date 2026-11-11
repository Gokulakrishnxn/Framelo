namespace Framelo.Core;

/// <summary>Decoded audio, already converted to the mix format (48 kHz, stereo, float).</summary>
public sealed class PcmBuffer(float[] samples)
{
    public const int Rate = 48_000;
    public const int Channels = 2;
    public float[] Samples { get; } = samples;
    public long Frames => Samples.Length / Channels;
    public double Duration => (double)Frames / Rate;
}

public enum AudioRole { Microphone, SystemAudio, Imported }

/// <summary>Supplies decoded audio for a source. Implemented with Media Foundation on Windows.</summary>
public interface IAudioSourceProvider
{
    PcmBuffer? Get(MediaSource source, AudioRole role);
}

/// <summary>
/// The one audio mix, used by both preview playback and export, so what you hear is what you get.
/// Linked tracks (microphone, system audio) follow the video edit decisions; independent audio tracks
/// place their own clips. Clip and track volumes, mutes, clip fades, the project fades and per-file clock
/// drift correction are applied here.
/// </summary>
public sealed class AudioMixer
{
    private readonly Project _project;
    private readonly TimeMap _map;
    private readonly IAudioSourceProvider _provider;
    private readonly Dictionary<Guid, VideoClip> _clips;
    private readonly double _duration;

    public AudioMixer(Project project, IAudioSourceProvider provider)
    {
        _project = project;
        _provider = provider;
        _map = new TimeMap(project);
        _clips = project.Timeline.VideoClips.ToDictionary(c => c.Id);
        _duration = project.Duration.Seconds;
    }

    /// <summary>True when the project has at least one audible track.</summary>
    public bool HasAudio => Sources().Any();

    private IEnumerable<(TimelineTrack Track, AudioRole Role)> Sources()
    {
        foreach (var track in _project.Timeline.Tracks)
        {
            if (track.IsMuted) continue;
            if (track.Type == TrackKind.Microphone) yield return (track, AudioRole.Microphone);
            else if (track.Type == TrackKind.SystemAudio) yield return (track, AudioRole.SystemAudio);
            else if (track.Type == TrackKind.Audio && track.AudioClips.Count > 0) yield return (track, AudioRole.Imported);
        }
    }

    private static MediaFile? FileFor(MediaSource source, AudioRole role) => role switch
    {
        AudioRole.Microphone => source.Microphone,
        AudioRole.SystemAudio => source.SystemAudio ?? (source.Screen?.HasAudio == true ? source.Screen : null),
        _ => source.Screen ?? source.SystemAudio ?? source.Microphone,
    };

    /// <summary>Mixes frames [startFrame, startFrame + output.Length/2) of the timeline into interleaved stereo.</summary>
    public void Mix(long startFrame, Span<float> output)
    {
        output.Clear();
        var frames = output.Length / PcmBuffer.Channels;
        foreach (var (track, role) in Sources())
        {
            if (role == AudioRole.Imported) MixIndependent(track, startFrame, output);
            else MixLinked(track, role, startFrame, frames, output);
        }
        ApplyProjectFades(startFrame, output);
        for (var i = 0; i < output.Length; i++) output[i] = Math.Clamp(output[i], -1f, 1f);
    }

    private void MixLinked(TimelineTrack track, AudioRole role, long startFrame, int frames, Span<float> output)
    {
        for (var f = 0; f < frames; f++)
        {
            var t = MediaTime.FromSeconds((startFrame + f) / (double)PcmBuffer.Rate);
            if (_map.Locate(t) is not { } hit) continue;
            var segment = _map.Segments[hit.Index];
            var clip = _clips[segment.ClipId];
            if (clip.IsMuted) continue;
            var source = _project.Source(segment.SourceId);
            if (source == null || FileFor(source, role) is not MediaFile file) continue;
            var pcm = _provider.Get(source, role);
            if (pcm == null) continue;
            var rate = file.RateCorrection > 0 ? file.RateCorrection : 1;
            var fileTime = (hit.SourceTime.Seconds - file.StartOffset) * rate;
            Add(pcm, fileTime, (float)(track.Volume * clip.Volume), output, f);
        }
    }

    private void MixIndependent(TimelineTrack track, long startFrame, Span<float> output)
    {
        var frames = output.Length / PcmBuffer.Channels;
        var windowStart = startFrame / (double)PcmBuffer.Rate;
        var windowEnd = (startFrame + frames) / (double)PcmBuffer.Rate;
        foreach (var clip in track.AudioClips)
        {
            if (clip.IsMuted) continue;
            var start = clip.TimelinePosition.Seconds;
            var end = clip.TimelineEnd.Seconds;
            if (end <= windowStart || start >= windowEnd) continue;
            var source = _project.Source(clip.SourceId);
            if (source == null) continue;
            var pcm = _provider.Get(source, AudioRole.Imported);
            if (pcm == null) continue;
            var first = Math.Max(0, (int)Math.Floor((start - windowStart) * PcmBuffer.Rate));
            var last = Math.Min(frames, (int)Math.Ceiling((end - windowStart) * PcmBuffer.Rate));
            for (var f = first; f < last; f++)
            {
                var t = windowStart + (double)f / PcmBuffer.Rate;
                if (t < start || t >= end) continue;
                var local = t - start;
                var gain = track.Volume * clip.Volume;
                if (clip.FadeIn > 0 && local < clip.FadeIn) gain *= local / clip.FadeIn;
                if (clip.FadeOut > 0 && end - t < clip.FadeOut) gain *= (end - t) / clip.FadeOut;
                Add(pcm, clip.SourceStart.Seconds + local, (float)gain, output, f);
            }
        }
    }

    private static void Add(PcmBuffer pcm, double fileSeconds, float gain, Span<float> output, int frame)
    {
        if (gain == 0 || fileSeconds < 0) return;
        var position = fileSeconds * PcmBuffer.Rate;
        var i0 = (long)position;
        if (i0 >= pcm.Frames) return;
        var i1 = Math.Min(i0 + 1, pcm.Frames - 1);
        var frac = (float)(position - i0);
        var s = pcm.Samples;
        for (var c = 0; c < PcmBuffer.Channels; c++)
        {
            var a = s[i0 * 2 + c];
            var b = s[i1 * 2 + c];
            output[frame * 2 + c] += (a + (b - a) * frac) * gain;
        }
    }

    private void ApplyProjectFades(long startFrame, Span<float> output)
    {
        var fadeIn = _project.Settings.Audio.FadeIn;
        var fadeOut = Math.Min(_project.Settings.Audio.FadeOut, _duration);
        if (fadeIn <= 0 && fadeOut <= 0) return;
        for (var f = 0; f < output.Length / 2; f++)
        {
            var t = (startFrame + f) / (double)PcmBuffer.Rate;
            var gain = 1.0;
            if (fadeIn > 0 && t < fadeIn) gain = t / fadeIn;
            if (fadeOut > 0 && t > _duration - fadeOut) gain = Math.Min(gain, Math.Max(0, (_duration - t) / fadeOut));
            output[f * 2] *= (float)gain;
            output[f * 2 + 1] *= (float)gain;
        }
    }
}
