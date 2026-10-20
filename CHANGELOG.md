# Changelog

## 1.1.0 — unreleased

Performance and responsiveness.

### Changed
- An app that starts playing now shows under Playing within a few hundred
  milliseconds. Before, an app that started playing the instant it appeared
  could stay under Not playing until something else changed.
- Refreshing the app list is about 25× cheaper (≈2 ms instead of ≈45 ms):
  each process is looked up once, only processes that changed are asked
  about, and bursts of Core Audio notifications cause one refresh.
- About 9× less CPU when apps start and stop playing: the menu bar icon is no
  longer redrawn on every change. Memory stays flat instead of creeping up.
- The app list is only republished (and redrawn) when something visible
  changed.
- App icons are kept as small 64 × 64 px images instead of full-size icons.
- The 0.2 s "is it playing" check on turned-down apps only runs while the
  panel is open. Opening the panel refreshes everything at once.

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
