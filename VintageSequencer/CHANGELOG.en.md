# Changelog (English)

Notable changes per version. The detailed German changelog, including technical notes, is
[`CHANGELOG.md`](CHANGELOG.md). Versioning: [Semantic Versioning](https://semver.org/).

---

## [1.13.17] — 2026-11-14

### Track header: whole buttons clickable, right-click anywhere

**Fixed**
- Buttons in the track header only reacted to clicks on their label. The whole button now
  responds.
- Right-click opened the track menu only on buttons. It now opens anywhere on the track header,
  including empty areas; the same applies to CC tracks.
- Loading some instruments (e.g. UADx Opal, Odin 2) made macOS ask whether to lower the security
  settings for FIRSTofFIFTH. Cause: FoF runs in the App Sandbox and these plug-ins do not declare
  themselves sandbox-safe. FoF now carries the entitlement Apple provides for plug-in hosts
  (`temporary-exception.audio-unit-host`).

**Changed**
- Pad tracks: RND rolls chords immediately; the small ▾ button next to it selects the chord
  source (previously: press and hold RND).

---

## [1.13.16] — 2026-11-14

### Pad tracks for pads and drones, chord rolling, hold, one note per track

**New**
- **Pad track** ("Add Pad Track" in the plus menu and in the track context menu): steps from a
  quarter note up to 8 bars (1/4, 1/2, 3/4, 1, 2, 3, 4, 8 bars), legato, for pads, drones and
  ambient sounds. Polyrhythms still work, e.g. 3 steps of 3 bars against 4 bars. Steps are shown
  compactly in the grid; a bar shows the progress of the playing step. A new pad track has 4
  steps of 1 bar.
- **Roll chords:** RND on a pad track rolls chords in the track's key (SCL root), with a bass
  note and smooth voice leading. The source can be a random progression from the books by
  Lizzio (*Chord Progression Codex*) and Callipari (*Illustrierte Harmonie*), a specific
  progression (e.g. pop net, Andalusian, epic, "god chords", spooky, line cliché, falling
  fifths, Neapolitan, hexatonic, twelve-bar blues; source and page in the tooltip), or chords
  from the track's scale.
- **Hold** (step edit card): the step plays no new note but extends the previous step's sound
  by its length. Works on all step tracks.
- **One note** (step edit card): every step of the track plays the same note, e.g. a kick. The
  steps keep their own notes and get them back when switched off.

**Preset format:** three new optional keys (`pad`, `hold`, `fixedNote`). Older versions still
load such files but play pad tracks as normal tracks with long steps, hold steps with their own
notes, and ignore the fixed note.

---

## [1.13.15] — 2026-11-13

First public release (GPL-3.0).

**Changed**
- **App icon:** shows the sequencer itself — three tracks of step pads in amber, blue and
  magenta with 4, 5 and 3 steps across the same width.

---

## Earlier versions (summary)

### 1.13.0 – 1.13.14 (November 2026): Audio Unit hosting

- **1.13.14** Audio diagnostics recorder (Help menu), output watchdog at 4 Hz, narrower step
  length/count column.
- **1.13.13** Hardened event hand-over to hosted instruments (scheduling contract, work limit,
  occupancy epochs, load tokens, parameter binding).
- **1.13.12** Drone steps: a note holds for the whole track length.
- **1.13.11** Watchdog for the audio output (stopped engine, missing blocks, NaN).
- **1.13.10** Window header and transport bar tidied up; app menu and program name.
- **1.13.9** CC tracks can drive instrument parameters; buttons with full click area.
- **1.13.8** Pitch drag without jumps; ⌥-drag edits velocity.
- **1.13.7** Fixed a silent second instrument channel and blurry UADx editors; output button.
- **1.13.6** Output selection visible in the track header.
- **1.13.5** Channel strip operation as in Planarium; editors of Apple effects.
- **1.13.4** Whole step pad clickable; right-click opens the step edit card.
- **1.13.3** Better text contrast on dark surfaces.
- **1.13.2** App icon.
- **1.13.1** Mixer with channel strips, master bus, meters, solo; output selection per track.
- **1.13.0** Audio Unit hosting: instrument rack with effect chain per channel.

### 1.12 (July – November 2026): real-time engine and interface

Clock on a dedicated real-time thread instead of an AVAudioEngine tap; lock-free playback
snapshot with hazard pointers; real-time-safe random numbers and MIDI sending; deferred
note-offs; command layer with identity-preserving undo; GUI revisions (step lighting, lane
viewport, zoom limits, material design); track colours.

### 1.0 – 1.11 (March – July 2026): foundations

Polyrhythmic step sequencer with per-track step count and step length, patterns A–D, chords,
velocity, gate, probability, ratchets, scale quantisation, internal and external MIDI clock,
MIDI learn, presets as JSON, lane model with CC lanes, English/German interface.
