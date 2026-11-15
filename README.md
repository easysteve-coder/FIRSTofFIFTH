# FIRSTofFIFTH

A polyphonic, polyrhythmic MIDI step sequencer for macOS.

Every track runs with its own step count and its own step length, so patterns
drift against each other and meet again: 5 against 4, 16 against 15, 7/8
against straight time. Tracks play external MIDI gear or Audio Unit
instruments hosted inside the app.

*Deutsch: Polyphoner, polyrhythmischer MIDI-Step-Sequencer für macOS. Die
Oberfläche ist auf Englisch und Deutsch verfügbar.*

### ⬇ [Download for macOS / Für macOS herunterladen](https://github.com/easysteve-coder/FIRSTofFIFTH/releases/latest)

On the release page, click the `.dmg` file under **Assets**, open it and drag
FIRSTofFIFTH into *Applications*. *Auf der Release-Seite unter **Assets** die
`.dmg`-Datei anklicken, öffnen und FIRSTofFIFTH in den Programme-Ordner ziehen.*

## What's new

**1.18.38** — FoF survives crashing plug-ins (crashed plug-ins are removed at once and reloaded together; no more crash when a plug-in host dies); instruments always play MIDI channel 1, one output menu per track; no note burst after solo or kit loading.

**1.18.32** — Since 1.14: audio loop tracks with time-stretching; time signature per pattern
and free grouping of odd meters (7/8 as 3+4 …), per pattern or per track; step lengths as note
values and long steps on every track; Apple Sampler (EXS/SoundFont/DLS) with drum choke groups;
channel EQ; plug-ins follow FoF's clock; crashed plug-ins are reloaded automatically. Presets
from before 1.16.0 no longer load. Download: [latest release](https://github.com/easysteve-coder/FIRSTofFIFTH/releases/latest).

All changes: [`CHANGELOG.en.md`](VintageSequencer/CHANGELOG.en.md) (English) ·
[`CHANGELOG.md`](VintageSequencer/CHANGELOG.md) (German, detailed).

## Features

- **Polyrhythm per track:** 1–64 steps, step length as a musical ratio,
  play direction, timing offset.
- **Steps:** chords, velocity, gate, probability, ratchets, drone steps that
  hold across the whole track length, hold steps, scale quantisation.
- **Long steps** on every track, from a beat to 8 bars, for pads and drones; RND rolls single
  notes or chord progressions (from Lizzio's *Chord Progression Codex* and Callipari's
  *Illustrierte Harmonie*, or from the track's scale).
- **Time signatures:** per pattern, odd meters grouped freely (per pattern or per track).
- **Lanes:** note lanes and CC lanes; a CC lane can drive an instrument or
  effect parameter directly.
- **Audio loop tracks:** record loops from the audio input, locked to the bar, with overdub and
  time-stretching.
- **16 patterns (A–P)**, switched quantised while playing.
- **Song lane:** a sequence of scenes (pattern + bars) above all tracks; patterns change exactly on
  the bar line, loop or stop at the end.
- **Clock:** internal clock on a dedicated real-time thread, or external
  MIDI clock (24 PPQN). All events are scheduled ahead with CoreMIDI host
  timestamps.
- **Audio Unit hosting:** instrument rack with effect chain per channel,
  mixer with channel strips, channel EQ, solo, meters and master bus; plug-in editors in
  their own windows; Apple Sampler with EXS, SoundFont and DLS.
- **MIDI Learn**, undo/redo for sequencer edits, presets as JSON.

## Requirements

- macOS 12 or later (Intel and Apple silicon)
- Xcode 16 or later to build (project format 77; developed with Xcode 27)
- Dependency: [swift-atomics](https://github.com/apple/swift-atomics),
  resolved automatically by Swift Package Manager. Signalsmith Stretch and
  Signalsmith Linear (MIT) are included as headers in `ThirdParty/`.

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
Foundation, either version 3 of the License, or (at your option) any later
version (GPL-3.0-or-later). See [`LICENSE`](LICENSE).

Third-party components (swift-atomics, Apache 2.0 with Runtime Library
Exception; Signalsmith Stretch and Signalsmith Linear, MIT) and their notices:
[`VintageSequencer/VintageSequencer/Licenses/THIRD_PARTY_NOTICES.md`](VintageSequencer/VintageSequencer/Licenses/THIRD_PARTY_NOTICES.md).
Audio Unit plug-ins and sample libraries you use with FIRSTofFIFTH are not part
of it and keep their own licenses.
