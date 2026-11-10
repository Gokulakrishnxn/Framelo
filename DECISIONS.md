# Decisions

**D1. Swift package plus a bundling script, not an .xcodeproj.** Xcode is not installed on the build machine. `Scripts/build-app.sh` assembles and ad-hoc signs the `.app`. The package opens in Xcode unchanged.

**D2. Codable JSON instead of SwiftData.** SwiftData's `@Model` macro plugin ships only with Xcode. JSON in a per-project package is also easier to diff, back up and recover.

**D3. Metal shaders compiled at runtime.** There is no offline `metal` compiler without Xcode. Shaders are compiled once per device and failures report the compiler log.

**D4. macOS 26.5 SDK under Command Line Tools.** In the macOS 27 SDK, SwiftUI's `@State` is a macro whose plugin ships only with Xcode. The 26.5 SDK compiles the same code, and the binary runs on macOS 27. `Scripts/toolchain.sh` picks the SDK automatically and does nothing when Xcode is selected.

**D5. Fragmented movie writing and a session journal.** If the app is killed, a normal `.mov` has no index and cannot be read. Fragments are flushed every 2 s, and `RecoveryService` rebuilds the project at the next launch. Files that can't be recovered are quarantined, never deleted.

**D6. Cursor recorded separately and drawn by the renderer.** This makes smoothing, resizing, click effects and hiding possible. It uses Quartz event state, so it needs no Accessibility permission.

**D7. Command-based undo.** Every command is applied to a copy, validated, then committed, so an invalid edit cannot corrupt a project. Slider drags coalesce into one undo step.

**D8. One evaluator for preview and export.** `FrameStateEvaluator` is pure, so preview and export can't drift apart.

**D9. Manual edits always win.** Automatic zooms never replace manual ones. Deleting a suggestion remembers its range. Editing a suggestion makes it manual.

**D10. Export verifies before publishing.** Output is written to a private work folder, then reopened and checked for duration, size, codec, frame rate and audio, and only then moved to the destination.

**D11. `@unchecked Sendable` uses.** Recorders (confined to a queue), `RecordingClock` and `RenderContext` (lock), `BuiltComposition` (immutable after build), compositor (lock), `RenderDevice` (immutable plus a locked cache).

**Known limits.** The device frame is a drawn window frame, not Apple device artwork. Noise reduction is Apple voice processing at capture time. Transitions are fade and zoom-fade only.
