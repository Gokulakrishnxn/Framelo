using System.Text.Json.Nodes;
using Framelo.Core;
using Xunit;

namespace Framelo.Core.Tests;

public static class TestData
{
    public static MediaSource Source(double seconds = 10, bool mic = true) => new()
    {
        Kind = SourceKind.Recording, Name = "Test", Duration = seconds,
        Screen = new MediaFile { RelativePath = "media/screen.mp4", Duration = seconds, PixelWidth = 1920, PixelHeight = 1080 },
        Microphone = mic ? new MediaFile { RelativePath = "media/microphone.wav", Duration = seconds, HasAudio = true } : null,
        Capture = new CaptureInfo { Width = 1920, Height = 1080 },
    };

    public static Project Project(double seconds = 10) => Core.Project.Make("Test", Source(seconds));

    public static string TempDir()
    {
        var d = Path.Combine(Path.GetTempPath(), "framelo-tests-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(d);
        return d;
    }
}

public class MediaTimeTests
{
    [Fact]
    public void TicksAreExactForCommonFrameRates()
    {
        foreach (var fps in new[] { 24, 25, 30, 50, 60, 120 })
            Assert.Equal(0, MediaTime.Timescale % fps);
        Assert.Equal(60_000, MediaTime.FromSeconds(1).Ticks);
        Assert.Equal(new MediaTime(30_000), new MediaTime(60_000).DividedBy(2));
    }

    [Fact]
    public void RangesAreHalfOpen()
    {
        var r = new MediaRange(new MediaTime(10), new MediaTime(10));
        Assert.True(r.Contains(new MediaTime(10)));
        Assert.False(r.Contains(new MediaTime(20)));
        Assert.False(r.Overlaps(new MediaRange(new MediaTime(20), new MediaTime(5))));
    }

    [Fact]
    public void HundredNanosecondConversionRoundTrips()
    {
        var t = MediaTime.FromSeconds(12.345);
        Assert.Equal(t, MediaTime.FromHundredNanoseconds(t.HundredNanoseconds));
    }
}

public class ProjectFormatTests
{
    private static string Fixture => File.ReadAllText(Path.Combine(AppContext.BaseDirectory, "Fixtures", "mac-project.json"));

    [Fact]
    public void OpensAProjectSavedByTheMacApp()
    {
        var p = ProjectJson.Deserialize(Fixture);
        Assert.Equal(1, p.FormatVersion);
        Assert.Equal(TrackKind.Video, p.Timeline.Tracks[0].Type);
        Assert.Equal(2, p.Timeline.VideoClips.Count);
        Assert.Equal(TrackKind.SystemAudio, p.Timeline.Tracks[2].Type);
        Assert.Equal("media/screen.mov", p.Sources[0].Screen!.RelativePath);
        Assert.Equal(p.Sources[0].Id, p.Timeline.VideoClips[0].SourceId);
        Assert.Single(p.Timeline.SuppressedAutoZoomRanges);
        TimelineValidator.Validate(p);
    }

    [Fact]
    public void RewritesTheMacFormatWithoutLosingAnything()
    {
        var original = JsonNode.Parse(Fixture)!;
        var rewritten = JsonNode.Parse(ProjectJson.Serialize(ProjectJson.Deserialize(Fixture)))!;
        Assert.True(JsonNode.DeepEquals(Normalise(original), Normalise(rewritten)),
            "Re-encoded project differs from the macOS file.");
    }

    // Swift writes 1.0 as 1; System.Text.Json may write 1. Compare numbers by value.
    private static JsonNode? Normalise(JsonNode? node) => node switch
    {
        JsonObject o => new JsonObject(o.OrderBy(kv => kv.Key).Select(kv => KeyValuePair.Create(kv.Key, Normalise(kv.Value)))),
        JsonArray a => new JsonArray(a.Select(Normalise).ToArray()),
        JsonValue v when v.TryGetValue<double>(out var d) => JsonValue.Create(Math.Round(d, 9)),
        JsonValue v => JsonValue.Create(v.ToString()),
        _ => null,
    };

    [Fact]
    public void UsesSwiftSpellings()
    {
        var json = ProjectJson.Serialize(TestData.Project());
        Assert.Contains("\"sourceID\"", json);
        Assert.Contains("\"type\": \"video\"", json);
        Assert.DoesNotContain("exportURL", json); // nil optionals are omitted
        Assert.Matches("\"createdAt\": \"\\d{4}-\\d\\d-\\d\\dT\\d\\d:\\d\\d:\\d\\dZ\"", json);
    }

    [Fact]
    public void CaptureTargetMatchesSwiftEnumEncoding()
    {
        var config = new RecordingConfig { Target = new CaptureTarget.Region(2, 10, 20, 300, 200) };
        var json = ProjectJson.Serialize(config);
        Assert.Contains("\"region\"", json);
        Assert.Contains("\"displayID\": 2", json);
        var back = ProjectJson.Deserialize<RecordingConfig>(json);
        Assert.Equal(config.Target, back.Target);
    }
}

public class TimelineEditTests
{
    [Fact]
    public void SplitKeepsSourceContinuity()
    {
        var p = TestData.Project();
        var (l, r) = TimelineEditor.Split(p.Timeline, MediaTime.FromSeconds(4));
        var clips = p.Timeline.VideoClips;
        Assert.Equal(2, clips.Count);
        Assert.Equal(clips[0].SourceEnd, clips[1].SourceStart);
        Assert.Equal(clips[0].TimelineEnd, clips[1].TimelinePosition);
        Assert.NotEqual(l, r);
        TimelineValidator.Validate(p);
    }

    [Fact]
    public void RippleDeleteRangeShiftsLaterZooms()
    {
        var p = TestData.Project();
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(6), EndTime = MediaTime.FromSeconds(8) });
        TimelineEditor.DeleteRange(p.Timeline, MediaRange.FromBounds(MediaTime.FromSeconds(2), MediaTime.FromSeconds(4)));
        Assert.Equal(MediaTime.FromSeconds(8), p.Timeline.Duration);
        Assert.Equal(MediaTime.FromSeconds(4), p.Timeline.ZoomEvents[0].StartTime);
        TimelineValidator.Validate(p);
    }

    [Fact]
    public void TrimHeadWithRipple()
    {
        var p = TestData.Project();
        var id = p.Timeline.VideoClips[0].Id;
        TimelineEditor.Trim(p.Timeline, id, sourceStart: MediaTime.FromSeconds(1));
        Assert.Equal(MediaTime.FromSeconds(9), p.Timeline.Duration);
        Assert.Equal(MediaTime.Zero, p.Timeline.VideoClips[0].TimelinePosition);
    }

    [Fact]
    public void SpeedChangesDuration()
    {
        var p = TestData.Project();
        TimelineEditor.SetSpeed(p.Timeline, p.Timeline.VideoClips[0].Id, 2);
        Assert.Equal(MediaTime.FromSeconds(5), p.Timeline.Duration);
    }

    [Fact]
    public void TimeMapFindsSourceTimeAndGaps()
    {
        var p = TestData.Project();
        TimelineEditor.Split(p.Timeline, MediaTime.FromSeconds(5));
        TimelineEditor.Move(p.Timeline, p.Timeline.VideoClips[1].Id, MediaTime.FromSeconds(6));
        var map = new TimeMap(p);
        Assert.Null(map.Locate(MediaTime.FromSeconds(5.5)));
        Assert.Equal(MediaTime.FromSeconds(5.5), map.Locate(MediaTime.FromSeconds(6.5))!.Value.SourceTime);
        Assert.Single(map.Gaps);
    }
}

public class CommandStackTests
{
    [Fact]
    public void UndoRedoRestoresExactly()
    {
        var stack = new CommandStack();
        var p = TestData.Project();
        var before = ProjectJson.Serialize(p);
        p = stack.Perform(EditCommand.Split(MediaTime.FromSeconds(3)), p);
        Assert.Equal(2, p.Timeline.VideoClips.Count);
        p = stack.Undo(p);
        Assert.Single(p.Timeline.VideoClips);
        Assert.Equal(Strip(before), Strip(ProjectJson.Serialize(p)));
        p = stack.Redo(p);
        Assert.Equal(2, p.Timeline.VideoClips.Count);
    }

    [Fact]
    public void InvalidEditLeavesProjectUntouched()
    {
        var stack = new CommandStack();
        var p = TestData.Project();
        Assert.Throws<TimelineValidationException>(() => stack.Perform(EditCommand.SetSpeed(p.Timeline.VideoClips[0].Id, 100), p));
        Assert.Equal(1, p.Timeline.VideoClips[0].PlaybackSpeed);
        Assert.False(stack.CanUndo);
    }

    [Fact]
    public void SliderDragsCoalesce()
    {
        var stack = new CommandStack();
        var p = TestData.Project();
        var t0 = DateTimeOffset.UtcNow;
        for (var i = 0; i < 10; i++)
            p = stack.Perform(EditCommand.Settings("Padding", s => s.Screen.Padding = 0.01 * i, "padding"), p, t0.AddMilliseconds(i * 50));
        p = stack.Undo(p);
        Assert.Equal(0.07, p.Settings.Screen.Padding);
        Assert.False(stack.CanUndo);
    }

    private static string Strip(string json) => System.Text.RegularExpressions.Regex.Replace(json, "\"updatedAt\": \"[^\"]+\"", "");
}

public class RecordingStorageTests
{
    [Fact]
    public void WavRepairFixesHeaderAfterCrash()
    {
        var dir = TestData.TempDir();
        var path = Path.Combine(dir, "a.wav");
        var w = new WavFile(path, 48000, 2, 32, true);
        w.Write(new byte[8 * 1000]);
        w.Flush();
        w.Write(new byte[8 * 500 + 3]); // torn frame, never flushed: simulate a crash by not disposing
        typeof(WavFile).GetField("_stream", System.Reflection.BindingFlags.NonPublic | System.Reflection.BindingFlags.Instance)!
            .GetValue(w).As<FileStream>().Dispose();
        Assert.True(WavFile.Repair(path));
        Assert.Equal(44 + 8 * 1500, new FileInfo(path).Length);
        Assert.False(WavFile.Repair(path));
    }

    private sealed class FakeInspector : IMediaInspector
    {
        public MediaFacts? Inspect(string path) => !File.Exists(path) ? null :
            path.EndsWith(".mp4") ? new MediaFacts(5, 1280, 720, false, true) : new MediaFacts(5, 0, 0, true, false);
    }

    [Fact]
    public void RecoveryRebuildsInterruptedSessionAndQuarantinesJunk()
    {
        var store = new ProjectStore(new LibraryLocation(TestData.TempDir()));
        store.PrepareLibrary();
        var id = Guid.NewGuid();
        var package = store.CreatePackage(id);
        File.WriteAllBytes(Path.Combine(package, "media", "screen.mp4"), new byte[100]);
        File.WriteAllBytes(Path.Combine(package, "media", "empty.wav"), Array.Empty<byte>());
        var journal = new RecordingJournal { Id = id, Name = "Demo", State = JournalState.Recording };
        journal.SetOffset(0.1, JournalTrackKind.Screen);
        journal.Write(package);

        var junk = store.CreatePackage(Guid.NewGuid());
        File.WriteAllText(Path.Combine(junk, "media", "x.bin"), "data");

        var report = RecoveryService.Run(store, new FakeInspector());
        Assert.Equal(new[] { id }, report.Recovered);
        Assert.Single(report.Quarantined);
        Assert.Equal(1, report.RemovedEmptyFiles);
        var project = store.Load(id);
        Assert.True(project.IsRecovered);
        Assert.Equal("Demo (Recovered)", project.Name);
        Assert.Equal(MediaTime.FromSeconds(0.1), project.Timeline.VideoClips[0].SourceStart);
        Assert.Equal(JournalState.Complete, RecordingJournal.Read(package).State);
    }

    [Fact]
    public void ClockRemovesPauses()
    {
        var clock = new RecordingClock(1000);
        clock.Start(1000);
        Assert.Equal(1.0, clock.SessionTime(2000));
        clock.Pause(2000);
        Assert.Null(clock.SessionTime(2500));
        clock.Resume(4000);
        Assert.Equal(1.5, clock.SessionTime(4500));
    }

    [Fact]
    public void CursorLinesRoundTripAndTolerateTruncation()
    {
        var text = CursorTrack.EncodeMove(new CursorSample(0, 0.1, 0.2)) + CursorTrack.EncodeDown(0.5, 0.3, 0.4) +
                   CursorTrack.EncodeUp(0.7) + CursorTrack.EncodeKind(0.6, CursorKind.IBeam) + "{\"k\":\"m\",\"t\":1,\"x\":0.";
        var track = CursorTrack.Parse(text);
        Assert.Single(track.Samples);
        Assert.Equal(0.7, track.Clicks[0].ReleaseTime);
        Assert.Equal(CursorKind.IBeam, track.KindAt(1));
        // macOS line order differs ({"x":..,"k":..}); key order must not matter.
        Assert.Single(CursorTrack.Parse("{\"x\":0.5,\"k\":\"m\",\"y\":0.4,\"t\":0.27}\n").Samples);
    }
}

internal static class CastExtensions
{
    public static T As<T>(this object? o) => (T)o!;
}
