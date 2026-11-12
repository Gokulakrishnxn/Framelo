<p align="center">
  <img src="src/Framelo.App/Assets/Logo.png" width="96" alt="Framelo logo">
</p>

<h1 align="center">Framelo for Windows</h1>

<p align="center">
  <b>A native Windows screen recorder and motion editor.</b><br>
  Record a display, a window or an area with your microphone and system audio, then turn it into a polished
  video with automatic zooms, a smooth cursor and styled backgrounds. Everything stays on your PC.
</p>

<p align="center">
  <img alt="Platform" src="https://img.shields.io/badge/platform-Windows%2010%20%7C%2011-0078D4">
  <img alt=".NET" src="https://img.shields.io/badge/.NET-8-512BD4">
  <img alt="UI" src="https://img.shields.io/badge/UI-WinUI%203-7C5CFF">
  <img alt="Capture" src="https://img.shields.io/badge/capture-Windows.Graphics.Capture-00D1BF">
  <img alt="Version" src="https://img.shields.io/badge/version-0.1.0-green">
</p>

---

## Contents

1. [Overview](#overview)
2. [Features](#features)
3. [Requirements](#requirements)
4. [Building and running](#building-and-running)
5. [Testing](#testing)
6. [Architecture](#architecture)
7. [Project format](#project-format)
8. [Keyboard shortcuts](#keyboard-shortcuts)
9. [Privacy](#privacy)
10. [Status and limitations](#status-and-limitations)

---

## Overview

Framelo for Windows is a port of the macOS app in this repository. It keeps the same architecture — a UI-free
engine and a separate UI — and the same `.framelo` project format, so projects open in either app.

Editing is **non-destructive**. Recordings are never modified: every cut, zoom and style change is stored as JSON
instructions and applied only when the video is rendered.

| | |
|---|---|
| **Platform** | Windows 10 version 2004 (build 19041) or later, Windows 11 |
| **Language** | C# 12 on .NET 8 |
| **UI** | WinUI 3 (Windows App SDK 1.6), unpackaged, self-contained |
| **Capture** | Windows.Graphics.Capture on Direct3D 11, WASAPI (microphone and loopback) |
| **Media** | Media Foundation: H.264 / HEVC + AAC encoding, decoding, fragmented MP4 |
| **Compositing** | SkiaSharp — one compositor shared by preview and export |

## Features

**Recording**
- Record a whole display, a single window, or an area you drag out on screen.
- Microphone, system audio and webcam, each on its own track; a live microphone meter. A device that cannot be
  opened is skipped with a message instead of failing the recording.
- Countdown, pause/resume, stop and discard from a floating capture bar, or from anywhere with the global
  shortcuts Ctrl+Shift+2 (start/stop) and Ctrl+Shift+3 (pause/resume).
- The system cursor is not burned into the video; it is recorded separately (position, clicks, shape) and drawn
  at render time, so it can be resized, smoothed and hidden.
- Framelo's own windows are excluded from the recording.
- Crash-tolerant: video is written as fragmented MP4, audio as WAV with a self-healing header, and a session
  journal is updated every two seconds. Interrupted recordings are rebuilt at the next launch.

**Editing**
- Timeline with the amber clip bar, the purple zoom lane and audio lanes.
- Split (S), trim by dragging clip edges, delete with ripple, change speed, close gaps.
- Automatic zooms generated from your clicks; add, move and resize zooms by hand. Manual zooms always win, and a
  deleted suggestion stays deleted.
- The camera follows the cursor while zoomed, with a critically damped spring and a dead zone.
- Background presets (gradients, solid colours), padding, corner radius, shadow, inset and an optional window frame.
- Cursor size, smoothing, click ripples or rings, hide-when-idle.
- Camera bubble: circle or rounded, size, corner, mirroring, and shrinking while the screen is zoomed.
- Per-track volume and mute, project fade in and fade out.
- Unlimited undo and redo; every edit is validated before it is applied, and the project autosaves.

**Export**
- MP4 with H.264 or HEVC video and AAC audio; 720p, 1080p or 4K; 30 or 60 fps; three quality levels.
- Progress with time remaining, and cancel at any point.
- Each export is checked — duration, size, codec, frame rate, audio — before it is moved to where you asked.
- Your name is written into the file as its author (optional, Settings › Profile).

**App**
- Dark UI with adaptive light theme, the teal monitor logo and a choice of accent colour (purple by default).
- Settings window with Profile, Appearance, Recording, Editing & Export, Storage, Privacy & Data and About pages.
- Import an existing video file; rename, reveal or recycle projects from the dashboard.

## Requirements

**To run:** Windows 10 2004 (19041) or later, or Windows 11, x64. The app is self-contained — no runtime install.
HEVC export needs the *HEVC Video Extensions* from the Microsoft Store; H.264 works everywhere.

**To build:** the .NET 8 SDK. The WinUI app must be built on Windows (its XAML compiler is a Windows program).
`Framelo.Core`, `Framelo.Rendering` and their tests build and run on Windows, macOS and Linux.

## Building and running

```powershell
cd windows
dotnet build src/Framelo.App/Framelo.App.csproj -c Release -p:Platform=x64 -r win-x64
dotnet run --project src/Framelo.App/Framelo.App.csproj -p:Platform=x64 -r win-x64
```

To produce a folder you can copy to another PC:

```powershell
dotnet publish src/Framelo.App/Framelo.App.csproj -c Release -p:Platform=x64 -r win-x64 -o artifacts/Framelo-win-x64
```

Every push that touches `windows/` is built on GitHub Actions (`windows-latest`); the published app is attached to
each run as the **Framelo-win-x64** artifact.

## Testing

```powershell
dotnet test tests/Framelo.Core.Tests        # model, timeline, undo, motion, audio mix, export checks (any OS)
dotnet test tests/Framelo.Rendering.Tests   # compositor pixels, preview = export (any OS)
dotnet test tests/Framelo.Platform.Tests    # Media Foundation encode/decode, end-to-end export, recovery (Windows)
```

| Suite | What it covers |
|---|---|
| Core | Exact time, project JSON compatibility with a real macOS `project.json`, split/trim/ripple, validation, undo coalescing, journal and recovery, audio clock alignment, auto-zoom clustering and merging, manual-wins resolution, camera continuity for every easing, cursor smoothing, frame-state determinism, export planning and verification, MP4 metadata |
| Rendering | Background, card, zoom magnification, cursor and ripple drawing, gaps, and byte-for-byte equality between preview and export compositors |
| Platform | H.264 + AAC MP4 and fragmented MP4 writing, WAV repair, frame-accurate decoding, audio decoding, a full record-files → edit → export → verify run, cancellation clean-up, and recovery from real media files |

Screen capture itself needs an interactive desktop, which CI runners do not have; it is covered by the manual
checklist below.

**Manual checklist (on a Windows PC)**
1. Record a display with microphone and system audio for ~20 s; click a few times; stop. The editor opens with
   suggested zooms on the zoom lane.
2. Record a window (resize it while recording) and an area, one of them with the camera on. Check the cursor lines
   up with what was clicked and the camera bubble appears in the editor.
3. Kill `Framelo.exe` from Task Manager during a recording, start it again: the dashboard reports a recovered
   recording that opens and plays.
4. Split, trim, delete and undo; drag a zoom; change the background; play with audio.
5. Export 1080p60 H.264 and open the file in the Films & TV app.
6. With another app focused, press Ctrl+Shift+2 to start, Ctrl+Shift+3 to pause and resume, Ctrl+Shift+2 to stop.

## Architecture

```
windows/
├── src/
│   ├── Framelo.Core         UI-free engine (net8.0): model, time, timeline, undo, motion, frame state, audio mix,
│   │                         storage, journal and recovery, export planning and verification
│   ├── Framelo.Rendering    The compositor (net8.0, SkiaSharp): FrameState → pixels
│   ├── Framelo.Platform     Windows media layer: Windows.Graphics.Capture, WASAPI, cursor recorder,
│   │                         Media Foundation writer/readers, recording session, export service
│   └── Framelo.App          WinUI 3 app: dashboard, capture bar, area picker, editor, timeline, settings
└── tests/
    ├── Framelo.Core.Tests
    ├── Framelo.Rendering.Tests
    └── Framelo.Platform.Tests
```

```
Capture ─▶ <UUID>.framelo/ media/screen.mp4 (fragmented) · media/*.wav · cursor.jsonl · session.json
Project (JSON) ──EditCommand──▶ validate ──▶ commit + autosave             (undo = previous snapshot)
MotionEngine.Resolve ─▶ CameraPath ─┐
                                    ▼
             FrameStateEvaluator(plan, t) ─▶ FrameState (pure)
                                    ▼
                 Compositor (SkiaSharp) ─▶ BGRA
                   ├─ Preview: editor image, audio via AudioMixer → WASAPI
                   └─ Export:  Media Foundation H.264/HEVC + AAC ─▶ verify ─▶ move into place
```

The pieces that carry the macOS design over unchanged:

- **Exact time.** `MediaTime` is an integer number of ticks at 60 000 per second, divisible by every common frame
  rate, so cuts and frame times never drift.
- **One evaluator.** `FrameStateEvaluator` is the only code that turns a project and a time into what is on screen.
  Preview and export each build their own plan and get identical frames — the rendering tests check the pixels.
- **One audio mix.** `AudioMixer` is used for playback and for export, with the same volumes, mutes, fades, speed
  and drift correction.
- **Command-based undo.** Every edit is applied to a copy, validated, then committed; undo restores the previous
  snapshot of the edit decisions (never media). Slider drags coalesce into one undo step.
- **Manual edits win.** Automatic zooms never replace manual ones, removing a suggestion remembers its range, and
  editing a suggestion makes it manual.
- **Verified exports.** Output is written to a private work folder, reopened and checked, and only then moved.

See [DECISIONS.md](DECISIONS.md) for the Windows-specific choices.

## Project format

Projects live in `%USERPROFILE%\Videos\Framelo\Projects\<UUID>.framelo\` (configurable in Settings › Storage):

| File | Contents |
|---|---|
| `project.json` | The edit — identical schema to macOS (camelCase keys, ISO-8601 dates, upper-case UUIDs, ticks as integers) |
| `session.json` | The recording journal, used for crash recovery |
| `cursor.jsonl` | One JSON object per line: moves, button down/up, cursor shape changes |
| `poster.jpg` | Dashboard thumbnail |
| `media/` | `screen.mp4`, `microphone.wav`, `system-audio.wav` (macOS writes `.mov`; both are read) |

Imported videos are referenced by absolute path and never copied or modified.

## Keyboard shortcuts

| Key | Action |
|---|---|
| Space | Play / pause |
| S | Split at the playhead |
| Z | Add a zoom at the playhead |
| Delete | Delete the selected clip or zoom |
| Ctrl+Z / Ctrl+Shift+Z (Ctrl+Y) | Undo / redo |
| ← / → | Previous / next frame (Shift: one second) |
| Home / End | Start / end |
| Ctrl+Shift+2 (anywhere) | Start or stop a recording |
| Ctrl+Shift+3 (anywhere) | Pause or resume a recording |
| Ctrl + mouse wheel | Zoom the timeline |

## Privacy

- Recordings, projects and exports stay on your PC. Framelo makes no network requests.
- Framelo's own windows are hidden from captures (Settings › Privacy & Data).
- Deleting a project moves it to the Recycle Bin.

## Status and limitations

- Built and unit/integration-tested on GitHub Actions; screen capture, the capture bar and the editor UI still
  need the manual checklist on real hardware.
- Captions and text overlays are rendered and preserved, but there is no caption transcription or text editor UI yet.
- On Windows 10 the yellow capture border cannot be hidden (Windows 11 hides it).
- Compositing runs on the CPU with SkiaSharp; 4K exports are slower than real time.

---

<p align="center">Built by <b>Gokulakrishnan</b> · <a href="https://github.com/Gokulakrishnxn">@Gokulakrishnxn</a></p>
