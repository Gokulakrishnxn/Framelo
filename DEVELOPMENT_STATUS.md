# Development status

Last updated: 2026-11-10.

## Verified by automated tests (59 passing)

Timeline engine, undo/redo, validation · recording clock, writer, journal, crash recovery · motion engine · Metal renderer and compositor · composition with cuts, speed and gaps · export (H.264/HEVC, MP4/MOV, 30/60 fps, audio, VFR, cancellation, verification).

## Verified by running the app

- App bundle builds, signs and passes `verify-bundle.sh`
- 3-second splash screen, then the dashboard with permissions, settings and quick actions

## Implemented, not yet verified end to end on real capture

These need Screen Recording, Microphone and Camera permission granted to Framelo:
- Live display, window and region recording; system audio; microphone; webcam
- Floating controls, countdown, menu bar timer, global shortcuts
- Editor interaction (timeline dragging, inspector), preview playback, export from the UI
- On-device caption transcription

## Known limitations

- Ad-hoc signing: macOS may ask for permissions again after a rebuild
- Device frame is a drawn window frame only
- Noise reduction applies only at capture time
