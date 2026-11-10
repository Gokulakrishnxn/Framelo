# Development status

Version **0.1.0**, last updated 2026-11-11.

## Verified

**Automated (62 tests, plus an optional real-recording export check):** timeline engine, undo/redo and validation · recording clock, crash-tolerant writer, journal and crash recovery · motion engine (auto zoom, merging, manual priority, continuous camera) · Metal renderer and compositor (preview and export give the same pixels) · crop, inset and background blur · export (H.264/HEVC, MP4/MOV, 30/60 fps, audio, variable frame rate, cancellation, output checks).

**In the running app, on real hardware:**
- App bundle builds, signs and passes `verify-bundle.sh`; permissions survive rebuilds
- 3-second splash screen and project library
- Live display recording with microphone and system audio through the floating capture bar; the recording controls stay out of the video
- Recording opens in the editor with automatic zooms generated from real clicks
- Editor layout: back navigation, focused editors for selected items, settings panel, timeline
- A real 28-second recording exported at 1080p60 with zooms, the system cursor and audio (checked frame by frame)

## Implemented, not yet confirmed by hand

- Window and Area recording, webcam picture-in-picture (needs Camera permission)
- Pause/resume, countdown and global shortcuts (⇧⌘2, ⇧⌘P) during a live session
- On-device caption transcription
- Export started from the Export window (the same pipeline as the verified export above)

## Known limitations

- No "Device" (iPhone/iPad) capture source
- Device frame is a drawn window frame only
- Noise reduction applies at capture time only
- App icon is Framelo's own mark until custom logo files are supplied in `public/`
