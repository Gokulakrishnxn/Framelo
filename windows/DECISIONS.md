# Windows decisions

Decisions specific to the Windows port. The macOS decisions in [../DECISIONS.md](../DECISIONS.md) still apply to the
shared design (JSON project format, one evaluator, command-based undo, manual edits win, verified exports).

**W1. C# / .NET 8 + WinUI 3, unpackaged and self-contained.** Closest equivalent to Swift + SwiftUI with direct
access to WinRT capture APIs. Unpackaged keeps installation to "copy the folder"; self-contained means no runtime
or Windows App SDK installer is needed.

**W2. The engine is a plain `net8.0` library.** `Framelo.Core` and `Framelo.Rendering` have no Windows dependency,
so the model, timeline, motion engine, evaluator, audio mix and compositor are built and tested on every OS —
including the macOS machine the port was written on — and on CI.

**W3. Windows.Graphics.Capture for screen and window capture.** Supported since Windows 10 1903, works for any
window including GPU-composited ones, delivers frames on the GPU, and can exclude the system cursor
(`IsCursorCaptureEnabled = false`). Areas are recorded by capturing the display and cropping on the GPU.

**W4. Fragmented MP4 for video, WAV for audio, plus the journal.** The Media Foundation sink writer writes
fragmented MP4 (`MFTranscodeContainerType_FMPEG4`) with a keyframe every two seconds, so a recording is readable
even if the app is killed. Audio is written as WAV whose header is rewritten on every flush; `WavFile.Repair`
fixes the sizes after a crash. Together with `session.json` this mirrors D5 on macOS.

**W5. Audio is kept on the session clock.** WASAPI loopback delivers nothing while the system is silent.
`AudioTiming` inserts the missing silence so that sample count always equals session time, and only corrects
clock drift within crystal tolerance (±0.3 %), as on macOS.

**W6. The cursor is polled, not hooked.** A 120 Hz poll of `GetCursorInfo` and the button state needs no global
hook, no elevation and no message loop, and gives the same `cursor.jsonl` as macOS.

**W7. Compositing with SkiaSharp instead of Win2D / Direct3D shaders.** The plan was Direct3D 11 / Win2D. The
compositor was written on SkiaSharp instead because it:
- runs headless and identically on every OS, so preview/export pixel equality is tested on CI (CI runners have no
  GPU and Win2D needs the Windows App SDK runtime in the test host);
- gives anti-aliased rounded clips, blurred shadows, gradients, text and image filtering without hand-written
  shaders.
The cost is CPU rendering: 1080p preview and export are fine, 4K export is slower than real time. A GPU backend
(Skia's Direct3D/GL context or a Win2D implementation behind the same `Compositor` API) is the natural next step.
Capture and encoding remain on the GPU / hardware encoder.

**W8. Snapshot undo.** On macOS, commands return their inverse; the Swift value types make that cheap. In C# the
command stack instead stores the serialised project before each command (a few kilobytes of edit decisions). Undo
is therefore exact by construction, coalescing works the same way, and invalid edits never reach the project.

**W9. Project JSON byte-compatibility.** `ProjectJson` reproduces Swift's `JSONEncoder` output: camelCase keys,
`…ID` suffixes, enum raw values, omitted nil optionals, ISO-8601 dates without fractional seconds, upper-case UUIDs,
and Swift's encoding of enums with associated values (`{"display":{"id":1}}`). A real macOS `project.json` is
round-tripped in the tests. Capture geometry is stored in points with the display scale, as on macOS.

**W10. Export verification and metadata.** Exports are reopened with Media Foundation and checked before they are
moved into place. The author is written as an iTunes `©ART` atom by appending to the final `moov` box, which Media
Foundation always writes after the media data, so no sample offsets change.

**W11. CI is the Windows build machine.** Development happened on a Mac without a Windows toolchain. GitHub Actions
(`windows-latest`) builds the WinUI app, runs all three test suites and publishes the app on every push.

**W12. Webcam frames are stamped on arrival.** Camera samples are read with the Media Foundation source reader
and stamped with the host clock when they arrive, rather than with the device's own timestamps, so all tracks share
one session clock. The small capture latency of a webcam is not visible in a picture-in-picture bubble.

**W13. Global shortcuts use Ctrl+Shift+2 and Ctrl+Shift+3.** They mirror ⇧⌘2 on macOS. Ctrl+Shift+P was avoided
because many Windows apps (VS Code, browsers) already use it; RegisterHotKey would take it from them.
