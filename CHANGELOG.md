# Changelog

## 1.0.0 — 2026-10-19

First stable release.

### Added
- Menu bar panel listing every app that's playing sound, live, with
  "Not playing" apps in a collapsible section.
- Per-app volume slider (0–100%) and mute (click the app's icon), using Core
  Audio process taps. Apps at 100% are left untouched.
- Sound card with master volume and mute for the current output device, kept
  in sync with the volume keys and Control Center, with the device's name and
  icon.
- Per-app settings saved between launches and re-applied when an app starts
  playing.
- Follows the default output device: taps are rebuilt for the new device
  without the app jumping to full volume.
- Open at Login switch.
- App icon.

### Fixed during development
- Chrome's slider did nothing: taps now include only the app's processes that
  are actually playing (Chrome's video-capture helper never plays, which kept
  the tap from starting).
- The panel could freeze for seconds while a tap was created; tap work now
  runs in the background.
- Cleanup on quit, `kill` (SIGTERM) and Ctrl-C (SIGINT), so no app is ever
  left silenced.
