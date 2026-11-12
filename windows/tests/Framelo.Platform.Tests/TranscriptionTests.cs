using System.Speech.Synthesis;
using Framelo.Core;
using Framelo.Platform.Media;
using Xunit;
using Xunit.Abstractions;

namespace Framelo.Platform.Tests;

public class TranscriptionTests(ITestOutputHelper output)
{
    [Fact]
    public async Task TranscribesSynthesisedSpeechWithIncreasingTimes()
    {
        if (SpeechTranscriber.Languages().Count == 0)
        {
            output.WriteLine("No Windows speech recogniser on this machine; transcription is checked manually.");
            return;
        }
        var dir = MediaFoundationTests.TempDir();
        var wav = Path.Combine(dir, "speech.wav");
        using (var voice = new SpeechSynthesizer())
        {
            voice.SetOutputToWaveFile(wav);
            voice.Speak("Hello and welcome. Today I will show you how to record your screen. Then we will export the video.");
        }
        var words = await SpeechTranscriber.TranscribeAsync(wav, dir, null, null, CancellationToken.None);
        output.WriteLine(string.Join(" ", words.Select(w => $"{w.Text}@{w.Start:0.00}")));
        Assert.True(words.Count >= 5, $"only {words.Count} words recognised");
        for (var i = 1; i < words.Count; i++) Assert.True(words[i].Start >= words[i - 1].Start);
        Assert.NotEmpty(CaptionBuilder.Lines(words));
    }
}
