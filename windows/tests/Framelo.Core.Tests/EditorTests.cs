using Framelo.Core;
using Xunit;

namespace Framelo.Core.Tests;

public class AudioMixerTests
{
    private sealed class Provider(Dictionary<AudioRole, PcmBuffer> buffers) : IAudioSourceProvider
    {
        public PcmBuffer? Get(MediaSource source, AudioRole role) => buffers.GetValueOrDefault(role);
    }

    private static PcmBuffer Ramp(double seconds)
    {
        var frames = (int)(seconds * PcmBuffer.Rate);
        var s = new float[frames * 2];
        for (var i = 0; i < frames; i++) s[2 * i] = s[2 * i + 1] = (float)i / frames;
        return new PcmBuffer(s);
    }

    private static float At(AudioMixer mixer, double seconds)
    {
        var buf = new float[2];
        mixer.Mix((long)(seconds * PcmBuffer.Rate), buf);
        return buf[0];
    }

    [Fact]
    public void MicrophoneFollowsCutsAndOffsets()
    {
        var p = TestData.Project(10);
        p.Sources[0].Microphone!.StartOffset = 1;   // mic started 1 s into the session
        var mic = Ramp(9);
        var mixer = new AudioMixer(p, new Provider(new() { [AudioRole.Microphone] = mic }));
        Assert.Equal(0, At(mixer, 0.5));                          // before the mic file starts
        Assert.Equal(1.0 / 9, At(mixer, 2), 3);                    // session 2 s → file 1 s
        TimelineEditor.DeleteRange(p.Timeline, MediaRange.FromBounds(MediaTime.FromSeconds(2), MediaTime.FromSeconds(5)));
        mixer = new AudioMixer(p, new Provider(new() { [AudioRole.Microphone] = mic }));
        Assert.Equal(4.0 / 9, At(mixer, 2), 3);                    // timeline 2 s now shows session 5 s
    }

    [Fact]
    public void MutesVolumesAndFades()
    {
        var p = TestData.Project(10);
        var ones = new PcmBuffer(Enumerable.Repeat(0.5f, PcmBuffer.Rate * 10 * 2).ToArray());
        var provider = new Provider(new() { [AudioRole.Microphone] = ones });
        p.Timeline.Track(TrackKind.Microphone)!.Volume = 0.5;
        Assert.Equal(0.25, At(new AudioMixer(p, provider), 5), 4);
        p.Settings.Audio.FadeIn = 2;
        Assert.Equal(0.125, At(new AudioMixer(p, provider), 1), 4);
        p.Timeline.VideoClips[0].IsMuted = true;
        Assert.Equal(0, At(new AudioMixer(p, provider), 5));
    }

    [Fact]
    public void FasterClipsPlayFasterAudio()
    {
        var p = TestData.Project(10);
        TimelineEditor.SetSpeed(p.Timeline, p.Timeline.VideoClips[0].Id, 2);
        var mixer = new AudioMixer(p, new Provider(new() { [AudioRole.Microphone] = Ramp(10) }));
        Assert.Equal(0.4, At(mixer, 2), 3);
    }
}

public class EditorSessionTests
{
    [Fact]
    public void EditsAreSavedAndUndoable()
    {
        var store = new ProjectStore(new LibraryLocation(TestData.TempDir()));
        var p = TestData.Project();
        store.Save(p);
        using (var session = new EditorSession(store, p) { SaveDelay = TimeSpan.FromHours(1) })
        {
            var changes = 0;
            session.Changed += () => changes++;
            session.Perform(EditCommand.Split(MediaTime.FromSeconds(5)));
            Assert.False(session.TryPerform(EditCommand.Split(MediaTime.FromSeconds(50)), out var error));
            Assert.NotNull(error);
            session.Undo();
            session.Redo();
            Assert.Equal(3, changes);
        }
        Assert.Equal(2, store.Load(p.Id).Timeline.VideoClips.Count); // saved on dispose
    }
}

public class PreferencesTests
{
    [Fact]
    public void DefaultsApplyToNewProjectsAndPreferencesRoundTrip()
    {
        var prefs = new Preferences { DefaultPresetId = "graphite", AutoZoomByDefault = false, CursorSmoothingDefault = 0.2, ExportFrameRate = 30, DisplayName = "Ada Lovelace" };
        var p = TestData.Project();
        prefs.ApplyTo(p);
        Assert.Equal(BackgroundKind.Solid, p.Settings.Background.Kind);
        Assert.False(p.Settings.Motion.AutoZoomEnabled);
        Assert.Equal(0.2, p.Settings.Cursor.Smoothing);
        Assert.Equal(30, p.Settings.Export.FrameRate);
        Assert.Equal("Ada Lovelace", p.Settings.Export.Author);
        Assert.Equal("AL", prefs.Initials);
        var path = Path.Combine(TestData.TempDir(), "prefs.json");
        prefs.Save(path);
        Assert.Equal("graphite", Preferences.Load(path).DefaultPresetId);
        Assert.Equal(ThemeChoice.Dark, Preferences.Load(Path.Combine(TestData.TempDir(), "missing.json")).Theme);
    }
}
