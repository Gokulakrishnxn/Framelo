using Framelo.Core;
using Xunit;

namespace Framelo.Core.Tests;

public class CaptionTests
{
    private static TranscribedSegment W(string text, double start, double end) => new(text, start, end);

    [Fact]
    public void GroupsWordsIntoLinesAtPausesSentencesAndLength()
    {
        var words = new[]
        {
            W("hello", 0, 0.3), W("there.", 0.35, 0.7), W("this", 0.8, 1.0), W("is", 1.05, 1.2), W("framelo", 1.25, 1.7),
            W("after", 3.0, 3.3), W("a", 3.35, 3.4), W("pause", 3.45, 3.8),
        };
        var lines = CaptionBuilder.Lines(words);
        Assert.Equal(new[] { "Hello there.", "This is framelo", "After a pause" }, lines.Select(l => l.Text));
        Assert.Equal(0.8, lines[1].Start);
        var many = Enumerable.Range(0, 20).Select(i => W("w", i * 0.2, i * 0.2 + 0.15));
        Assert.All(CaptionBuilder.Lines(many), l => Assert.True(l.Text.Split(' ').Length <= 8));
    }

    [Fact]
    public void PlacesLinesThroughTheEditAndDropsCutSpeech()
    {
        var p = TestData.Project(10);
        var mic = p.Sources[0].Microphone!;
        mic.StartOffset = 0.5;
        TimelineEditor.DeleteRange(p.Timeline, MediaRange.FromBounds(MediaTime.FromSeconds(2), MediaTime.FromSeconds(4)));
        var lines = new[] { W("One", 0, 1), W("Two", 2, 3), W("Three", 5, 6) };   // session 0.5, 2.5 (cut), 5.5
        var captions = CaptionBuilder.Place(lines, mic, p.Sources[0].Id, new TimeMap(p));
        Assert.Equal(new[] { "One", "Three" }, captions.Select(c => c.Text));
        Assert.Equal(MediaTime.FromSeconds(0.5), captions[0].StartTime);
        Assert.Equal(MediaTime.FromSeconds(3.5), captions[1].StartTime);
        p = new CommandStack().Perform(TextEdits.SetCaptions(captions), p);
        TimelineValidator.Validate(p);
        Assert.Equal(2, p.Timeline.Captions.Count);
    }

    [Fact]
    public void TextEditsAreUndoableAndValidated()
    {
        var stack = new CommandStack();
        var p = TestData.Project(10);
        var text = new TextOverlay { Text = "Title", StartTime = MediaTime.FromSeconds(1), EndTime = MediaTime.FromSeconds(3) };
        p = stack.Perform(TextEdits.AddText(text), p);
        text.Text = "Changed";
        p = stack.Perform(TextEdits.UpdateText(text), p);
        Assert.Equal("Changed", p.Timeline.TextOverlays[0].Text);
        var bad = TextEdits.Copy(text);
        bad.EndTime = MediaTime.Zero;
        Assert.Throws<TimelineValidationException>(() => stack.Perform(TextEdits.UpdateText(bad, key: "x"), p));
        p = stack.Undo(p);
        p = stack.Undo(p);
        Assert.Empty(p.Timeline.TextOverlays);
    }

    [Fact]
    public void ChoosesTheMicrophoneForTranscription()
    {
        var p = TestData.Project();
        Assert.Same(p.Sources[0].Microphone, CaptionBuilder.SpeechFile(p)!.Value.File);
        p.Sources[0].Microphone = null;
        Assert.Null(CaptionBuilder.SpeechFile(p));
    }
}
