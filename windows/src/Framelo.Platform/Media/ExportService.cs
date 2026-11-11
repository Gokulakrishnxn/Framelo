using System.Diagnostics;
using Framelo.Core;
using Framelo.Rendering;

namespace Framelo.Platform.Media;

public sealed record ExportProgress(long Frame, long FrameCount, TimeSpan Elapsed)
{
    public double Fraction => FrameCount > 0 ? (double)Frame / FrameCount : 0;
    public TimeSpan? Remaining => Frame > 30 ? TimeSpan.FromSeconds(Elapsed.TotalSeconds / Frame * (FrameCount - Frame)) : null;
}

public sealed record ExportResult(string Path, MediaFacts Facts, long Bytes, TimeSpan Elapsed);

/// <summary>
/// Renders the timeline with the shared compositor, mixes audio with the shared mixer, encodes H.264/HEVC + AAC
/// MP4 into a private work folder, reopens and verifies the file, and only then moves it to the destination.
/// Cancelling deletes the work folder.
/// </summary>
public static class ExportService
{
    public static ExportResult Export(Project project, IReadOnlyDictionary<Guid, CursorTrack> cursors, string packagePath,
        ExportSettings settings, string destination, string workRoot, IProgress<ExportProgress>? progress, CancellationToken cancel)
    {
        var clock = Stopwatch.StartNew();
        var work = Path.Combine(workRoot, Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(work);
        var temp = Path.Combine(work, "export.mp4");
        try
        {
            using var video = new VideoSourceCache(packagePath);
            var audioCache = new AudioSourceCache(packagePath);
            var mixer = new AudioMixer(project, audioCache);
            var plan = ExportPlan.For(project, settings, mixer.HasAudio && HasAnyAudioFile(project, audioCache));
            var compositor = new Compositor(new RenderPlan(project, cursors));
            var frames = new MediaFrameSource(video);

            var audioSpec = plan.HasAudio ? new AudioSpec(PcmBuffer.Rate, PcmBuffer.Channels, ExportSettings.AudioBitRate) : null;
            using (var writer = new MfWriter(temp, new VideoSpec(plan.Width, plan.Height, plan.FrameRate, settings.VideoBitRate(plan.Width, plan.Height),
                       settings.Codec == ExportCodec.Hevc), audioSpec, fragmented: false))
            {
                var frameDuration = 10_000_000L / plan.FrameRate;
                var audioFrames = (long)Math.Round(plan.Duration * PcmBuffer.Rate);
                long audioWritten = 0;
                var mix = new float[PcmBuffer.Rate / 10 * PcmBuffer.Channels];
                var pcm = new short[mix.Length];
                for (long f = 0; f < plan.FrameCount; f++)
                {
                    cancel.ThrowIfCancellationRequested();
                    var time = plan.FrameTime(f);
                    var pixels = compositor.RenderBgra(time, plan.Width, plan.Height, frames);
                    writer.WriteVideo(pixels, plan.Width * 4, time.HundredNanoseconds, frameDuration);

                    // Keep audio a little ahead of video so the muxer interleaves evenly.
                    if (plan.HasAudio)
                    {
                        var target = Math.Min(audioFrames, (long)((time.Seconds + 0.5) * PcmBuffer.Rate));
                        while (audioWritten < target)
                        {
                            var n = (int)Math.Min(PcmBuffer.Rate / 10, audioFrames - audioWritten);
                            var span = mix.AsSpan(0, n * PcmBuffer.Channels);
                            mixer.Mix(audioWritten, span);
                            PcmConvert.FloatToInt16(span, pcm);
                            writer.WriteAudio(pcm.AsSpan(0, n * PcmBuffer.Channels), audioWritten * 10_000_000L / PcmBuffer.Rate);
                            audioWritten += n;
                        }
                    }
                    if (f % 5 == 0) progress?.Report(new ExportProgress(f, plan.FrameCount, clock.Elapsed));
                }
                while (plan.HasAudio && audioWritten < audioFrames)
                {
                    cancel.ThrowIfCancellationRequested();
                    var n = (int)Math.Min(PcmBuffer.Rate / 10, audioFrames - audioWritten);
                    var span = mix.AsSpan(0, n * PcmBuffer.Channels);
                    mixer.Mix(audioWritten, span);
                    PcmConvert.FloatToInt16(span, pcm);
                    writer.WriteAudio(pcm.AsSpan(0, n * PcmBuffer.Channels), audioWritten * 10_000_000L / PcmBuffer.Rate);
                    audioWritten += n;
                }
                writer.Finish();
            }
            frames.Clear();
            cancel.ThrowIfCancellationRequested();

            var facts = new MfInspector().Inspect(temp);
            ExportVerifier.Verify(facts, plan);
            try { Mp4Metadata.AddAuthor(temp, settings.Author, project.Name); } catch (IOException) { /* metadata is optional */ }

            Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(destination))!);
            File.Move(temp, destination, overwrite: true);
            progress?.Report(new ExportProgress(plan.FrameCount, plan.FrameCount, clock.Elapsed));
            return new ExportResult(destination, facts!, new FileInfo(destination).Length, clock.Elapsed);
        }
        finally
        {
            try { Directory.Delete(work, recursive: true); } catch (Exception) { }
        }
    }

    private static bool HasAnyAudioFile(Project project, AudioSourceCache cache) =>
        project.Sources.Any(s => cache.Get(s, AudioRole.Microphone) != null || cache.Get(s, AudioRole.SystemAudio) != null ||
                                 (s.Kind == SourceKind.ImportedAudio && cache.Get(s, AudioRole.Imported) != null));
}
