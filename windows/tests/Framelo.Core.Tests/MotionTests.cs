using Framelo.Core;
using Xunit;

namespace Framelo.Core.Tests;

public class MotionTests
{
    private static TimelineCursor Cursor(Project p, params (double T, double X, double Y)[] clicks)
    {
        var track = new CursorTrack();
        for (var t = 0.0; t <= p.Duration.Seconds; t += 0.05) track.Samples.Add(new CursorSample(t, 0.5, 0.5));
        foreach (var c in clicks) track.Clicks.Add(new ClickEvent(c.T, c.X, c.Y));
        return new TimelineCursor(new TimeMap(p), new Dictionary<Guid, CursorTrack> { [p.Sources[0].Id] = track });
    }

    private static readonly MotionSettings Settings = new();

    [Fact]
    public void ClustersNearbyClicksAndSeparatesDistantOnes()
    {
        var p = TestData.Project(60);
        var events = AutoZoomGenerator.Generate(Cursor(p, (5, 0.2, 0.2), (6, 0.3, 0.3), (30, 0.8, 0.8)).Clicks, 60, Settings);
        Assert.Equal(2, events.Count);
        Assert.Equal(0.2, events[0].TargetX);
        Assert.True(events.All(e => e.IsAutomatic));
        Assert.True(events[0].StartTime.Seconds < 5);
    }

    [Fact]
    public void MergesEventsThatWouldBounce()
    {
        var p = TestData.Project(60);
        var events = AutoZoomGenerator.Generate(Cursor(p, (5, 0.2, 0.2), (8.9, 0.5, 0.5)).Clicks, 60, Settings);
        Assert.Single(events);
    }

    [Fact]
    public void IgnoresClicksOutsideThePictureAndTheTimeline()
    {
        var p = TestData.Project(20);
        Assert.Empty(AutoZoomGenerator.Generate(Cursor(p, (5, 1.5, 0.2), (30, 0.5, 0.5)).Clicks, 20, Settings));
    }

    [Fact]
    public void RegenerationPreservesManualEventsAndSuppressedRanges()
    {
        var p = TestData.Project(60);
        var manual = new ZoomEvent { StartTime = MediaTime.FromSeconds(4), EndTime = MediaTime.FromSeconds(8) };
        p.Timeline.ZoomEvents.Add(manual);
        p.Timeline.SuppressedAutoZoomRanges.Add(MediaRange.FromBounds(MediaTime.FromSeconds(28), MediaTime.FromSeconds(33)));
        MotionEngine.RegenerateAutomaticZooms(p.Timeline, Cursor(p, (5, 0.2, 0.2), (30, 0.8, 0.8), (50, 0.4, 0.4)), Settings);
        Assert.Contains(p.Timeline.ZoomEvents, z => z.Id == manual.Id);
        Assert.Equal(2, p.Timeline.ZoomEvents.Count);           // the 5 s click is under the manual zoom, 30 s was deleted
        Assert.True(p.Timeline.ZoomEvents[1].IsAutomatic);
        Assert.InRange(p.Timeline.ZoomEvents[1].StartTime.Seconds, 48, 50);
    }

    [Fact]
    public void ClicksFollowTheEdit()
    {
        var p = TestData.Project(60);
        TimelineEditor.DeleteRange(p.Timeline, MediaRange.FromBounds(MediaTime.FromSeconds(10), MediaTime.FromSeconds(20)));
        var clicks = Cursor(p, (5, 0.2, 0.2), (15, 0.3, 0.3), (30, 0.8, 0.8)).Clicks;
        Assert.Equal(new[] { 5.0, 20.0 }, clicks.Select(c => Math.Round(c.Time, 6)));
    }

    [Fact]
    public void ManualWinsOverOverlappingAutomatic()
    {
        var p = TestData.Project(30);
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(5), EndTime = MediaTime.FromSeconds(10), IsAutomatic = true });
        var manual = new ZoomEvent { StartTime = MediaTime.FromSeconds(8), EndTime = MediaTime.FromSeconds(12), Scale = 3 };
        p.Timeline.ZoomEvents.Add(manual);
        var resolved = MotionEngine.Resolve(p.Timeline, TimelineCursor.Empty);
        Assert.Single(resolved.Events);
        Assert.Equal(manual.Id, resolved.Events[0].Id);
    }

    [Fact]
    public void OverlappingManualEventsAreSequenced()
    {
        var p = TestData.Project(30);
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(5), EndTime = MediaTime.FromSeconds(10) });
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(8), EndTime = MediaTime.FromSeconds(14) });
        var resolved = MotionEngine.Resolve(p.Timeline, TimelineCursor.Empty);
        Assert.Equal(2, resolved.Events.Count);
        Assert.Equal(resolved.Events[0].EndTime, resolved.Events[1].StartTime);
    }

    [Fact]
    public void ViewportNeverLeavesTheContent()
    {
        var p = TestData.Project(30);
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(2), EndTime = MediaTime.FromSeconds(8), Scale = 4, TargetX = 0, TargetY = 1, FollowsCursor = false });
        var path = MotionEngine.Resolve(p.Timeline, TimelineCursor.Empty).Path;
        for (var t = 0.0; t < 10; t += 0.01)
        {
            var s = path.State(t);
            var half = 0.5 / s.Scale;
            Assert.InRange(s.CenterX, half - 1e-9, 1 - half + 1e-9);
            Assert.InRange(s.CenterY, half - 1e-9, 1 - half + 1e-9);
        }
    }

    [Theory]
    [InlineData(Easing.Linear)]
    [InlineData(Easing.EaseIn)]
    [InlineData(Easing.EaseOut)]
    [InlineData(Easing.EaseInOut)]
    [InlineData(Easing.Spring)]
    public void CameraNeverJumps(Easing easing)
    {
        var p = TestData.Project(30);
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(2), EndTime = MediaTime.FromSeconds(6), Scale = 3, Easing = easing, TransitionIn = 0.01, TransitionOut = 0.01 });
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(6), EndTime = MediaTime.FromSeconds(9), Scale = 2, TargetX = 0.9, Easing = easing });
        var path = MotionEngine.Resolve(p.Timeline, Cursor(p)).Path;
        var previous = path.State(0);
        for (var t = 1.0 / 240; t < 12; t += 1.0 / 240)
        {
            var s = path.State(t);
            Assert.True(Math.Abs(s.Viewport - previous.Viewport) < 0.03, $"viewport jumped at {t:0.000}");
            Assert.True(Math.Abs(s.CenterX - previous.CenterX) < 0.03, $"x jumped at {t:0.000}");
            previous = s;
        }
    }

    [Fact]
    public void KeyframesOverrideZoomsAndBlendInAndOut()
    {
        var p = TestData.Project(30);
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(4), EndTime = MediaTime.FromSeconds(8) });
        p.Timeline.Keyframes.Add(new MotionKeyframe { Timestamp = MediaTime.FromSeconds(5), Scale = 2, PositionX = 0.3 });
        p.Timeline.Keyframes.Add(new MotionKeyframe { Timestamp = MediaTime.FromSeconds(7), Scale = 3, PositionX = 0.7 });
        var path = MotionEngine.Resolve(p.Timeline, TimelineCursor.Empty).Path;
        Assert.Equal(1, path.State(4).Scale, 6);
        Assert.Equal(2, path.State(5).Scale, 6);
        Assert.Equal(3, path.State(7).Scale, 6);
        Assert.Equal(1, path.State(7.6).Scale, 6);
    }

    [Fact]
    public void FollowStartsAtRestOnTheEventTarget()
    {
        var p = TestData.Project(30);
        var zoom = new ZoomEvent { StartTime = MediaTime.FromSeconds(2), EndTime = MediaTime.FromSeconds(8), TargetX = 0.3, TargetY = 0.4 };
        var targets = MotionEngine.FollowTargets(zoom, 2, 8, 2, Cursor(p));
        Assert.Equal(0.3, targets[0].X, 6);
        Assert.Equal(0.4, targets[0].Y, 6);
        Assert.True(Math.Abs(targets[^1].X - 0.5) < 0.05, "camera should settle on the cursor");
    }

    [Fact]
    public void SmoothingAddsNoLagAndRestsOnClickTargets()
    {
        var track = new CursorTrack();
        for (var t = 0.0; t <= 2; t += 1.0 / 120) track.Samples.Add(new CursorSample(t, t < 1 ? t * 0.5 : 0.5, 0.5));
        var at = CursorSmoother.Position(track, 1.5, 1)!.Value;
        Assert.Equal(0.5, at.X, 6);
        var mid = CursorSmoother.Position(track, 0.5, 1)!.Value;
        Assert.Equal(0.25, mid.X, 3);   // symmetric window on a straight line: no lag
    }

    [Fact]
    public void SmoothingReducesJitter()
    {
        var track = new CursorTrack();
        var rng = new Random(4);
        for (var t = 0.0; t <= 2; t += 1.0 / 120) track.Samples.Add(new CursorSample(t, 0.5 + (rng.NextDouble() - 0.5) * 0.02, 0.5));
        double Roughness(double smoothing)
        {
            var sum = 0.0;
            for (var t = 0.2; t < 1.8; t += 1.0 / 60)
                sum += Math.Abs(CursorSmoother.Position(track, t + 1.0 / 60, smoothing)!.Value.X - CursorSmoother.Position(track, t, smoothing)!.Value.X);
            return sum;
        }
        Assert.True(Roughness(1) < Roughness(0) / 3);
    }
}

public class FrameStateTests
{
    private static RenderPlan Plan()
    {
        var p = TestData.Project(20);
        p.Timeline.ZoomEvents.Add(new ZoomEvent { StartTime = MediaTime.FromSeconds(2), EndTime = MediaTime.FromSeconds(6), Scale = 2 });
        p.Timeline.TextOverlays.Add(new TextOverlay { Text = "Hi", StartTime = MediaTime.FromSeconds(1), EndTime = MediaTime.FromSeconds(3) });
        var track = new CursorTrack();
        for (var t = 0.0; t <= 20; t += 0.05) track.Samples.Add(new CursorSample(t, 0.4, 0.6));
        track.Clicks.Add(new ClickEvent(4, 0.4, 0.6) { ReleaseTime = 4.1 });
        return new RenderPlan(p, new Dictionary<Guid, CursorTrack> { [p.Sources[0].Id] = track });
    }

    [Fact]
    public void DescribesScreenCursorRipplesCameraAndOverlays()
    {
        var plan = Plan();
        var state = plan.Evaluator.Evaluate(MediaTime.FromSeconds(4.2));
        Assert.NotNull(state.Screen);
        Assert.Equal(MediaTime.FromSeconds(4.2), state.Screen!.SourceTime);
        Assert.NotNull(state.Cursor);
        Assert.Equal(0.4, state.Cursor!.X, 6);
        Assert.Single(state.Ripples);
        Assert.Equal(2, state.Camera.Scale, 6);
        Assert.Empty(state.Overlays);
        Assert.Single(plan.Evaluator.Evaluate(MediaTime.FromSeconds(2)).Overlays);
    }

    [Fact]
    public void EvaluationIsDeterministicAcrossPlans()
    {
        // Preview and export each build their own plan; they must agree at every frame.
        var a = Plan();
        var b = new RenderPlan(ProjectJson.Deserialize(ProjectJson.Serialize(a.Project)), a.Cursor.Tracks);
        for (var f = 0; f < 20 * 30; f += 7)
        {
            var t = new MediaTime(f * MediaTime.Timescale / 30);
            Assert.True(a.Evaluator.Evaluate(t).SameAs(b.Evaluator.Evaluate(t)), $"frame {f} differs");
        }
    }

    [Fact]
    public void LayoutKeepsTheCardInsideThePadding()
    {
        var p = TestData.Project();
        p.Settings.Screen.Padding = 0.1;
        var layout = new FrameLayout(p, 1920, 1080);
        Assert.True(layout.Card.X >= 108 - 1e-6 && layout.Card.Y >= 108 - 1e-6);
        Assert.Equal(16.0 / 9, layout.Content.Width / layout.Content.Height, 3);
        var centre = layout.CameraCentre(CameraState.Identity);
        Assert.Equal((960.0, 540.0), centre);
    }
}
