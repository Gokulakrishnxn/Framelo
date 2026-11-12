using System.Text;
using Framelo.Core;
using Framelo.Platform.Media;
using Xunit;

namespace Framelo.Platform.Tests;

public class ExportEndToEndTests
{
    /// <summary>A recording package as RecordingSession leaves it: fragmented screen MP4, WAV microphone, cursor.</summary>
    private static (Project Project, string Package, Dictionary<Guid, CursorTrack> Cursor) Recording(double seconds)
    {
        var package = MediaFoundationTests.TempDir();
        Directory.CreateDirectory(Path.Combine(package, "media"));
        MediaFoundationTests.WriteClip(Path.Combine(package, "media", "screen.mp4"), 320, 240, 30, seconds, audio: false, fragmented: true);
        using (var wav = new WavFile(Path.Combine(package, "media", "microphone.wav"), 48_000, 2, 32, isFloat: true))
        {
            var frames = (int)(seconds * 48_000);
            var data = new float[frames * 2];
            for (var i = 0; i < frames; i++) data[2 * i] = data[2 * i + 1] = (float)Math.Sin(2 * Math.PI * 330 * i / 48_000) * 0.3f;
            wav.Write(System.Runtime.InteropServices.MemoryMarshal.AsBytes(data.AsSpan()));
        }
        var cursor = new StringBuilder();
        for (var t = 0.0; t < seconds; t += 1.0 / 60) cursor.Append(CursorTrack.EncodeMove(new CursorSample(t, 0.2 + t * 0.2, 0.5)));
        cursor.Append(CursorTrack.EncodeDown(0.8, 0.36, 0.5)).Append(CursorTrack.EncodeUp(0.9));
        File.WriteAllText(Path.Combine(package, ProjectPackage.CursorFile), cursor.ToString());

        var inspector = new MfInspector();
        var screen = inspector.Inspect(Path.Combine(package, "media", "screen.mp4"))!;
        var mic = inspector.Inspect(Path.Combine(package, "media", "microphone.wav"))!;
        var source = new MediaSource
        {
            Kind = SourceKind.Recording, Name = "E2E", Duration = screen.Duration, CursorPath = ProjectPackage.CursorFile,
            Screen = new MediaFile { RelativePath = "media/screen.mp4", Duration = screen.Duration, PixelWidth = screen.PixelWidth, PixelHeight = screen.PixelHeight },
            Microphone = new MediaFile { RelativePath = "media/microphone.wav", Duration = mic.Duration, HasAudio = true },
            Capture = new CaptureInfo { Width = 320, Height = 240, Scale = 1 },
        };
        var project = Project.Make("E2E", source);
        var tracks = new Dictionary<Guid, CursorTrack> { [source.Id] = CursorTrack.Load(Path.Combine(package, ProjectPackage.CursorFile)) };
        return (project, package, tracks);
    }

    [Fact]
    public void ExportsAVerifiedPlayableMp4WithAudio()
    {
        var (project, package, cursor) = Recording(3);
        // Edit: cut the middle second out and add a zoom, like a user would.
        TimelineEditor.DeleteRange(project.Timeline, MediaRange.FromBounds(MediaTime.FromSeconds(1), MediaTime.FromSeconds(2)));
        project.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(0.2), EndTime = MediaTime.FromSeconds(1.8), Scale = 2 });
        TimelineValidator.Validate(project);

        var destination = Path.Combine(MediaFoundationTests.TempDir(), "out", "Demo.mp4");
        var work = MediaFoundationTests.TempDir();
        var settings = new ExportSettings { Resolution = ExportResolution.P720, FrameRate = 30, Author = "Framelo Tests" };
        var reports = 0;
        var result = ExportService.Export(project, cursor, package, settings, destination, work,
            new Progress<ExportProgress>(_ => reports++), CancellationToken.None);

        Assert.True(File.Exists(destination));
        Assert.Equal(960, result.Facts.PixelWidth);   // 4:3 source, Auto aspect, 720p short side
        Assert.Equal(720, result.Facts.PixelHeight);
        Assert.True(result.Facts.HasAudio);
        Assert.Equal("h264", result.Facts.VideoCodec);
        Assert.InRange(result.Facts.Duration, 1.9, 2.1);
        Assert.Empty(Directory.EnumerateFileSystemEntries(work));     // the work folder is cleaned up
        Assert.Contains("Framelo Tests", Encoding.UTF8.GetString(File.ReadAllBytes(destination)));

        // The file decodes, and its audio is the microphone tone.
        using var reader = new MfVideoReader(destination);
        Assert.NotNull(reader.FrameAt(1.0));
        var pcm = MfAudioDecoder.Decode(destination)!;
        Assert.True(pcm.Samples.Skip(24_000).Take(9600).Max() > 0.1f);
    }

    [Fact]
    public void CancellingLeavesNothingBehind()
    {
        var (project, package, cursor) = Recording(2);
        var destination = Path.Combine(MediaFoundationTests.TempDir(), "Cancelled.mp4");
        var work = MediaFoundationTests.TempDir();
        using var cancel = new CancellationTokenSource();
        cancel.Cancel();
        Assert.ThrowsAny<OperationCanceledException>(() => ExportService.Export(project, cursor, package,
            new ExportSettings { Resolution = ExportResolution.P720, FrameRate = 30 }, destination, work, null, cancel.Token));
        Assert.False(File.Exists(destination));
        Assert.Empty(Directory.EnumerateFileSystemEntries(work));
    }

    [Fact]
    public void RecoveryRebuildsAProjectFromRealRecordingFiles()
    {
        var (_, package, _) = Recording(2);
        var library = new LibraryLocation(MediaFoundationTests.TempDir());
        var store = new ProjectStore(library);
        var id = Guid.NewGuid();
        var target = store.CreatePackage(id);
        foreach (var f in Directory.GetFiles(Path.Combine(package, "media"))) File.Copy(f, Path.Combine(target, "media", Path.GetFileName(f)));
        var journal = new RecordingJournal { Id = id, Name = "Crashed", State = JournalState.Recording };
        journal.SetOffset(0, JournalTrackKind.Screen);
        journal.SetOffset(0, JournalTrackKind.Microphone);
        journal.Write(target);
        var report = RecoveryService.Run(store, new MfInspector());
        Assert.Equal(new[] { id }, report.Recovered);
        var project = store.Load(id);
        Assert.NotNull(project.Sources[0].Microphone);
        Assert.InRange(project.Duration.Seconds, 1.9, 2.1);
    }
}
