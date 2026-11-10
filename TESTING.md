# Testing

```bash
Scripts/test.sh                       # all suites
Scripts/test.sh --filter ExportTests  # one suite
FRAMELO_TEST_OUTPUT=/some/dir Scripts/test.sh --filter RendererTests   # also writes rendered PNGs
```

## Synthetic fixtures (`Tests/FrameloTests/Fixtures`)

Generated in the test, deterministic:
- Video frames that **encode their own index** as a bit strip. Tests read back exactly which source frame appears at each output time.
- Constant and **variable frame-rate** timings from a fixed seed.
- Audio with clicks at known times.
- Cursor tracks with clicks.

## Coverage

| Area | Tests |
|---|---|
| Time and timeline | exact tick math; split loses and duplicates no frame; speed; gaps; round-trip source ↔ timeline; 36-clip, 1-hour mixed-speed timeline |
| Commands | apply then undo is identity; invalid edits leave the project untouched; slider coalescing |
| Recording | clock pause math; drift detection; cursor log with a truncated tail; fragmented writer offsets |
| Crash recovery | file copied mid-write is recovered without touching media; garbage is quarantined; empty files and temp files are cleaned |
| Motion | clustering, merging, manual priority, suppression; viewport never leaves the picture; camera never jumps (all easings); keyframes |
| Rendering | background, card and padding pixels; zoom magnification; styled frame; **preview path = export path pixels** |
| Export | frame-accurate cut/split/speed; HEVC MOV with audio at 60 fps; VFR to CFR; 60 s, 30-clip edit; cancellation leaves no files; actionable errors |

## Manual checks (need real hardware and permissions)

1. `Scripts/build-app.sh`, then open the app. The splash shows for 3 s, then the dashboard.
2. Grant Screen Recording, Microphone and Camera.
3. Record a display with mic and system audio. Stop with ⇧⌘2. The editor opens with suggested zooms.
4. Split, trim and delete, then export. The file plays in QuickTime.
5. Force-quit during a recording and relaunch. A "Recovered" project appears.
