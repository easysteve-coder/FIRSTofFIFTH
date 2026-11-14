# FIRSTofFIFTH

A polyphonic, polyrhythmic MIDI step sequencer for macOS.

Every track runs with its own step count and its own step length, so patterns
drift against each other and meet again: 5 against 4, 16 against 15, 7/8
against straight time. Tracks play external MIDI gear or Audio Unit
instruments hosted inside the app.

*Deutsch: Polyphoner, polyrhythmischer MIDI-Step-Sequencer für macOS. Die
Oberfläche ist auf Englisch und Deutsch verfügbar.*

## What's new

**1.13.17** — Pad tracks with steps up to 8 bars for pads and drones; chord rolling with
progressions from Lizzio and Callipari or from the track's scale; *hold* steps; one note for a
whole track (e.g. a kick); track header fixes; no more security prompt when loading certain
Audio Units. Download: [latest release](https://github.com/easysteve-coder/FIRSTofFIFTH/releases/latest).

All changes: [`CHANGELOG.en.md`](VintageSequencer/CHANGELOG.en.md) (English) ·
[`CHANGELOG.md`](VintageSequencer/CHANGELOG.md) (German, detailed).

## Features

- **Polyrhythm per track:** 1–64 steps, step length as a musical ratio,
  play direction, timing offset.
- **Steps:** chords, velocity, gate, probability, ratchets, drone steps that
  hold across the whole track length, hold steps, scale quantisation.
- **Pad tracks:** steps from a quarter note to 8 bars for pads and drones;
  RND rolls chord progressions (from Lizzio's *Chord Progression Codex* and
  Callipari's *Illustrierte Harmonie*, or from the track's scale).
- **Lanes:** note lanes and CC lanes; a CC lane can drive an instrument
  parameter directly.
- **Patterns A–D**, switched quantised while playing.
- **Clock:** internal clock on a dedicated real-time thread, or external
  MIDI clock (24 PPQN). All events are scheduled ahead with CoreMIDI host
  timestamps.
- **Audio Unit hosting:** instrument rack with effect chain per channel,
  mixer with channel strips, solo, meters and master bus; plug-in editors in
  their own windows.
- **MIDI Learn**, undo/redo for sequencer edits, presets as JSON.

## Requirements

- macOS 14.6 or later
- Xcode 26 or later
- Dependency: [swift-atomics](https://github.com/apple/swift-atomics),
  resolved automatically by Swift Package Manager

## Building

```bash
git clone https://github.com/easysteve-coder/FIRSTofFIFTH.git
cd FIRSTofFIFTH
open VintageSequencer/FIRSTofFIFTH.xcodeproj
```

Select the `VintageSequencer` scheme and run. The project is set up for
local ad-hoc signing, so no Apple developer account is needed.

Not a developer? A notarised installer (`.dmg`) is attached to each
[release](https://github.com/easysteve-coder/FIRSTofFIFTH/releases): open it
and drag FIRSTofFIFTH into *Applications*.

Tests:

```bash
xcodebuild -project VintageSequencer/FIRSTofFIFTH.xcodeproj \
  -scheme VintageSequencer -destination 'platform=macOS' \
  -only-testing:VintageSequencerTests test
```

## Architecture in brief

Timing is the product. The tick path (clock thread → step advance → MIDI
send) never allocates, never locks and never reads UI state. It reads the
model only through an atomically published, immutable playback snapshot and
reports back through lock-free single-producer/single-consumer rings. The
render observer of hosted instruments follows the same rules. All model
edits from the UI go through one command layer with undo.

Details: [`VintageSequencer/ENGINEERING.md`](VintageSequencer/ENGINEERING.md)
(German).
User manual: [`Docs/USER_MANUAL.md`](Docs/USER_MANUAL.md).

## Status

A personal project under active development. The app target is still called `VintageSequencer`
for historical reasons.

## License

Copyright © 2026 Stephan Schmitt

FIRSTofFIFTH is free software: you can redistribute it and/or modify it under
the terms of the GNU General Public License as published by the Free Software
Foundation, version 3. See [`LICENSE`](LICENSE).
