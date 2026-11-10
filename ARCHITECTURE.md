# Architecture

Two modules: **FrameloCore** (engine, no UI, fully tested) and **Framelo** (SwiftUI app).

## Data flow

```
Capture ──▶ <id>.framelo/ media/*.mov (fragmented) · session.json (journal) · cursor.jsonl · project.json
Project (Codable value) ──commands──▶ TimelineValidator ──▶ CompositionBuilder ──▶ AVComposition + AVAudioMix
                                                                   │
MotionEngine.resolve ──▶ CameraPath ─┐                             │
                                     ▼                             ▼
                   FrameStateEvaluator(project, t) ──▶ FrameState (pure, Equatable)
                                     ▼
              FrameloCompositor (AVVideoCompositing) ──▶ MetalRenderer
                 ├─ Preview: AVPlayer + AVPlayerLayer
                 └─ Export:  AVAssetReader ▶ AVAssetWriter ▶ verify ▶ move into place
```

Preview and export use **the same compositor and the same evaluator**. A test checks that they produce the same pixels.

## Modules (FrameloCore)

| Folder | Responsibility |
|---|---|
| `Models` | Codable project model; `MediaTime` is integer ticks at 60 000/s, so timing math is exact |
| `Timeline` | `TimeMap` (timeline ↔ source time, gaps, speed), `TimelineEditor` (pure edits), `TimelineValidator`, `CommandStack` (undo/redo, coalescing) |
| `RecordingEngine` | `RecordingSession` actor, screen/mic/camera/cursor recorders, `RecordingClock`, journal, `RecoveryService` |
| `MotionEngine` | Auto-zoom generation and merging, conflict resolution (manual wins), continuous `CameraPath`, cursor smoothing |
| `RenderingEngine` | `FrameState`, layout, runtime-compiled Metal shaders, renderer, compositor |
| `MediaEngine` | Composition building, inspection, thumbnails, import, waveforms |
| `Services` | `ProjectStore` (atomic saves), `ExportService`, `TranscriptionService` |

## Concurrency (Swift 6 strict mode)

| Component | Isolation |
|---|---|
| Views, `AppState`, `EditorModel`, `RecordingController` | `@MainActor` |
| `RecordingSession`, `ProjectStore` | `actor` |
| Screen/Mic/Camera/Cursor recorders | Each one runs on its own serial queue, which is also its delegate queue. It owns its `AVAssetWriter`. |
| `MetalRenderer` | One per consumer; pipelines are shared and cached per device |
| `FrameloCompositor` | One per AVFoundation consumer, serialised by a lock |
| Models, `TimeMap`, `CameraPath`, `FrameState`, `RenderPlan` | `Sendable` values |

Export runs in a cancellable `Task`. Cancelling it stops reading and writing and deletes the export's own work folder.

## Recording timebase

All tracks share the host clock. `RecordingClock` turns host time into session time and removes paused intervals. Each file stores its first-sample offset. The microphone is placed by sample count, and the drift against the clock is measured. Drift is corrected only when it is within real crystal tolerance.

## Package format

`~/Movies/Framelo/Projects/<uuid>.framelo/`: `project.json`, `session.json`, `cursor.jsonl`, `poster.jpg`, `media/`. Imported files are referenced by absolute path and are never copied or modified.
