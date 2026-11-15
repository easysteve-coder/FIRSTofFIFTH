# Changelog (English)

Notable changes per version. The detailed German changelog, including technical notes, is
[`CHANGELOG.md`](CHANGELOG.md). Versioning: [Semantic Versioning](https://semver.org/).

---

## [1.18.38] — 2026-11-15

- A second safeguard against crashes caused by dead plug-ins: if connecting a channel or starting
  the audio engine fails because a plug-in has died, FoF disconnects that channel and reloads its
  plug-ins instead of quitting. If even the cleanup fails, FoF switches audio off and shows the
  error in the mixer; FoF stays usable and audio returns after a restart.

## [1.18.37] — 2026-11-15

- FoF no longer crashes when a plug-in process crashes: each crashed plug-in is removed from the
  audio engine as soon as macOS reports it, and the affected channels are reconnected and
  reloaded together once all reports are in. Healthy plug-ins are left alone.

## [1.18.36] — 2026-11-15

- No more burst of notes after solo, mute or loading a kit: when an instrument was not rendered
  for a while (another channel soloed, or a plug-in busy loading), the queued notes played all at
  once. Note-ons more than about 85 ms late are now dropped; note-offs, CCs and parameters still
  go out.

## [1.18.35] — 2026-11-15

- Swing is a knob again, but small and without the aluminium plate. Double-click resets it to 0%.

## [1.18.34] — 2026-11-15

- Swing is now a small value field in the transport bar instead of a knob on an aluminium plate:
  drag up or down (Shift: fine), double-click to type.

## [1.18.33] — 2026-11-15

- Tracks playing an instrument channel now always send on MIDI channel 1; the track's MIDI
  channel only applies to external MIDI. Before, an instrument listening on channel 1 stayed
  silent for tracks on other channels, and hi-hat choke groups failed when open and closed
  hi-hat were on tracks with different channels.
- One output menu in the track header: "External MIDI ▸ Channel 01 … 16", the instrument
  channels, and "New Instrument Channel…". The button shows "MIDI 05" or the channel name; the
  separate channel picker is gone.

## [1.18.32] — 2026-11-15

- If a plug-in crashes its out-of-process host, FoF reloads every instrument and effect that was
  running in that process, with its last loaded or saved sound. Before, those channels stayed
  silent until the preset was reloaded. If the same slot crashes again within 10 seconds, FoF
  gives up on it and marks it.

## [1.18.31] — 2026-11-15

- Groupings can now be set per track: in the step-length popover, "Group" takes the track's own
  split in eighths (e.g. 3+3+2 in 4/4); empty means the pattern's grouping. The sum is free, and
  FoF tells you whether it fits the bar or runs against it.
- Step lengths are shown and chosen as note values (1/16, 1/8., 1/12 …) in rows for straight,
  dotted, triplet, quintuplet and septuplet values, bars, group, and a custom fraction field.

## [1.18.30] — 2026-11-15

- Odd time signatures can be grouped freely per pattern, e.g. 7/8 as 3+4, 4+3, 5+2 or 2+2+3
  (common groupings in the time-signature menu, or "Custom…"). The grid shows the groups, and the
  new step length "Group" makes steps follow the grouping in turn (3/8, 4/8, 3/8 …).

## [1.18.29] — 2026-11-15

- Every track can now use long steps (1–3 beats, 1/2/3/4/8 bars in the pattern's time
  signature) from the step-length popover or by dragging the lower handle. Long steps get their
  own display width (automatic or 1–8). Separate pad tracks are gone; existing pad tracks load as
  normal tracks with long steps and sound the same. RND notes (single/chords/mixed) are now set
  per track.

## [1.18.28] — 2026-11-15

- EXS drum kits in the Apple Sampler now honor their exclusive groups and one-shot zones:
  closed and pedal hi-hat cut off the open hi-hat, and one-shot sounds play out regardless of
  the step gate. Reload kits that were loaded before. Loading several EXS kits in quick
  succession no longer crashes.

## [1.18.27] — 2026-11-15

- Audio loop track: the waveform is scaled up (normalized to its loudest point, quiet parts
  lifted) and the input level is shown as a meter with peak hold in the loop area — active while
  monitoring, armed or recording.

## [1.18.26] — 2026-11-15

- New pad tracks (and "Reset" in the step-length popover) are now one bar long in the pattern's
  time signature — in 7/8 a pad step lasts seven eighths instead of a 4/4 bar.

## [1.18.25] — 2026-11-15

- Fixed choosing a track color: the new color now shows right away, and the menu shows the real
  colors. 16 colors instead of 8, plus "Color Wheel…" for any color. Active steps and the lane
  handle take the new color immediately.
- Lane handles swapped: the top handle sets the step count, the bottom one the step length —
  matching the labels at the right edge of the lane.

## [1.18.24] — 2026-11-15

- Each pattern now has its own time signature. Changing it for the playing pattern is queued
  ("4/4 ▸ 7/8") and applies when that pattern starts again. Song scenes count bars in their
  pattern's time signature.
- New option at "PATTERN": switch patterns at the next bar line (default for new projects) or at
  the end of track 1 (as before; older projects keep this).

## [1.18.23] — 2026-11-15

- The position display shows the playing pattern and, when a change is planned, the next pattern
  and the bars until it ("▸ B · 2").
- Groundwork for a time signature per pattern; playback is unchanged.

## [1.18.22] — 2026-11-15

- Tempo and time signature now live in the position display; the BPM knob is gone. Drag the
  tempo up or down (Shift: fine), double-click to type it, or use ▲▼ and TAP.

## [1.18.21] — 2026-11-15

- Position display next to Play/Stop, as in Logic: bar . beat . division . tick, or elapsed time
  (click to switch). Shows the time signature and tempo of what is playing.
- The step-length popover now shows the note value with its duration (e.g. "1/24 · 83.3 ms") and
  the track length in bars, beats and seconds at the current tempo.

## [1.18.20] — 2026-11-15

- Fixed a hang (spinning wheel) when replacing an instrument whose plug-in crashes while being
  unloaded. FoF now survives the plug-in process going away.

## [1.18.19] — 2026-11-15

- Internal checks: measured memory peak of loop pre-stretching, step lengths verified with the
  real clock (16th at 120 BPM = 125 ms).

## [1.18.18] — 2026-11-15

- SoundFont and DLS files now load in the Apple Sampler (they were wrongly reported as missing
  samples); no sample folder is needed for them.

## [1.18.17] — 2026-11-15

- Robustness fixes from a second review: the loop memory budget is enforced atomically, sample
  paths from another Mac are only remapped when the match is unambiguous, and pre-stretched loops
  are discarded if a recording wrote during their computation (also with external clock).

## [1.18.16] — 2026-11-15

- Apple Sampler as instrument: “Apple Sampler: load instrument…” in a channel’s instrument menu
  loads EXS, SoundFont, DLS or aupreset files; the instrument is saved with the project.
- Share sample folders once per Mac (sandbox); projects from another Mac find their samples in
  the shared folders automatically.
- The Apple Sampler has one stereo output (no multi-out).

## [1.18.15] — 2026-11-14

- Audio loops are pre-stretched in high quality while stopped and then play back sample-exact
  without real-time stretching; tempo changes during playback fall back to real-time stretching and
  swap back on the next bar line.
- The clock lead now uses the buffer of the device the audio engine actually plays on.
- The late first note after loading Decent Sampler (4.5 ms) comes from the plug-in itself
  (measured without FIRSTofFIFTH).
- License: GPL-3.0-or-later.

## [1.18.14] — 2026-11-14

- Rolled chords stay within the selected scale: book progressions are used only when all their
  chords fit, colour chords only when they fit, and pentatonic/blues/whole-tone scales get chords
  built from their own notes. Chromatic behaves as before.
- License notices: `LICENSE` (GPLv3) in the repository, and a `Licenses` folder in the app with
  the GPL text, the swift-atomics license (Apache 2.0 with Runtime Library Exception) and third-party
  notices (Signalsmith Stretch/Linear, MIT). Plug-ins and sample content are not part of FIRSTofFIFTH.

## [1.18.13] — 2026-11-14

- Audio loops follow the tempo without changing pitch (time-stretching), also when the time
  signature differs from the recording. The read position is derived from the musical position
  in every audio block, so loops don't drift, even across tempo ramps (measured within 0.9 ms of
  the bar). At the recording tempo, playback stays sample-exact as before.
- Overdubbing is only possible at the loop's own tempo and time signature.
- Uses Signalsmith Stretch (MIT), bundled under `ThirdParty/`.

---

## [1.18.12] — 2026-11-14

- Project time signature (transport bar, below TAP): 2/4 to 7/4, 3/8 to 13/8 and 15/16; change it
  while stopped, with undo.
- Song scenes, audio-loop bar anchors and loop length, the plug-in transport (numerator,
  denominator, bar start), pad-track lengths and the grid's bar lines follow it. Pad lengths keep
  whole bars as whole bars when you switch.
- Pad lengths are labelled in beats and bars of the time signature.
- Projects store the time signature only when it isn't 4/4; older projects load in 4/4.

---

## [1.18.11] — 2026-11-14

- Channel EQ on every channel strip, modelled on Logic's Channel EQ: low cut, low shelf, four
  bell bands, high shelf and high cut. A small curve above the pan knob opens the editor.
- In the editor, drag a point for frequency and gain, ⌘-drag for Q, hold ⌥ for fine control,
  double-click toggles a band, ⌥-click resets it. Per-band values below the curve can be dragged
  or scrolled; cut slopes are 12–48 dB/oct.
- The displayed curve matches what the channel actually sounds like (measured within 0.5 dB).
- Projects store the EQ only when it differs from the default; older projects load with a flat EQ.

---

## [1.18.10] — 2026-11-14

- No more stutter when loading during playback: loading an instrument, inserting or swapping an
  effect, or adding a channel or audio-loop track no longer restarts the audio engine. Only the
  affected channel is rebuilt; all other channels keep playing without a gap.

---

## [1.18.9] — 2026-11-14

- Fixed a crash when switching effects during playback (macOS 12): the plug-in host process could
  crash while FoF re-attached tempo/transport information to a rendering instrument.
- Plug-in sample rate per channel (right-click the channel strip): render an instrument at
  44.1/48/88.2/96 kHz with clean conversion to the output device. Use 44.1 kHz for Decent Sampler
  with 44.1 kHz samples on a 48 kHz device — its own resampling is coarse (measured).

## [1.18.8] — 2026-11-14

- RND on single-note tracks now respects the track's scale (only in-scale notes).

## [1.18.7] — 2026-11-14

- Audio loop track: the track header shows the device being recorded from (or "input off");
  the input popover shows input and output separately with device name, state, channels,
  sample rate and the selected channel (mono/stereo). Always the device the running audio
  actually uses, updated on device changes; warns if the system default now differs or the
  selected channel does not exist on the device.
- Latency compensation uses the latency of the devices actually in use.

## [1.18.6] — 2026-11-14

- Tracks keep a fixed row across all patterns: moving, collapsing, deleting, duplicating and
  inserting affect the same track in every pattern, even when patterns are arranged
  differently. Older projects load unchanged (rows assigned by position); new key `row`.

## [1.18.5] — 2026-11-14

- Plug-in editors: removing a channel or effect while its editor is opening no longer leaves an
  orphaned window; a quick double click opens only one window.
- Internal restructuring (plug-in lifecycle as its own component).

## [1.18.4] — 2026-11-14

- Internal restructuring (audio loop control as its own component). No visible change.

## [1.18.3] — 2026-11-14

- Internal restructuring (audio engine and master bus as their own component). No visible change.

## [1.18.2] — 2026-11-14

- Dropping a dragged track: it now slides straight into the open gap instead of swapping places.

## [1.18.1] — 2026-11-14

- Internal restructuring (audio diagnostics as its own component). No visible change.

## [1.18.0] — 2026-11-14

- Internal restructuring (plug-in parameter catalog as its own component). No visible change.

## [1.17.10] — 2026-11-14

- Reordering tracks works on macOS 12 and is animated: the dragged track follows the pointer,
  the others slide aside to open the gap.
- Plug-in editors open above FoF in full screen on macOS 12 instead of on a new desktop.
- Hosted instruments no longer lose tempo/transport after the audio engine restarts.

## [1.17.9] — 2026-11-14

- Documentation: current write/undo contract per action, updated onboarding notes.

## [1.17.8] — 2026-11-14

- CC targets on effects stay with the chosen effect instance when effects are reordered; if it
  is removed, the target stays open instead of controlling another identical effect. Parameter
  lists refresh when a plug-in changes its parameter tree. Older projects are mapped once on load.

## [1.17.7] — 2026-11-14

- Undo of moving and collapsing tracks restores the exact previous state in every pattern.
- Lower memory use: per-channel buffers are only committed when a channel is created.

## [1.17.6] — 2026-11-14

- Plug-in transport stops exactly at song end (also when the UI is busy); sample position is
  real elapsed time and no longer jumps on tempo changes; pre-scheduled tempo changes apply at
  their boundary. Host callbacks are verified by call counters instead of a periodic repair.

## [1.17.5] — 2026-11-14

- Collapsed tracks show a LED per step like the full grid (active steps lit, playing step
  bright) instead of a frame.

## [1.17.4] — 2026-11-14

- **Collapsed tracks show their steps** in a slim strip aligned with the grid (active steps,
  velocity, playhead; CC values as bars).
- Collapse arrow and drag grip no longer cut off in collapsed rows.
- **Reordering** shows an insertion line in the gap between tracks instead of framing a track;
  no more "+" badge while dragging.

## [1.17.3] — 2026-11-14

- **Rename audio loop tracks** like every other track.
- **Reorder tracks:** drag the grip (≡) at the right edge of a track onto another track, or use
  "Move Up"/"Move Down" in the track menu. Applies to all patterns, undoable.
- **Collapse tracks:** arrow at the right edge or track menu; a collapsed track is a slim bar
  with name and mute/solo and keeps playing. Saved in the preset (optional key `collapsed`;
  older presets load unchanged).
- **64 instrument channels** instead of 16, so more tracks can play hosted instruments and
  audio loops.

## [1.17.2] — 2026-11-14

- **Plug-ins follow FoF's clock:** AU instruments and effects now get tempo, time signature,
  position and play/stop from FoF (like in Logic). Tempo-synced LFOs, delays, arpeggiators and
  sequencers inside plug-ins follow the sequencer, also with external clock.

## [1.17.1] — 2026-11-14

- **CC track target picker:** choose MIDI CC, or first the plug-in (instrument or one of the
  channel's effects) and then the parameter — sorted alphabetically, with a search field.
- **Effects as CC targets:** a CC track can now control effect parameters, sample-accurate.
- **Fix:** the gate knob shows real note lengths; on pad tracks (and other step lengths than
  1/16) it showed wrong values. Stored values are unchanged.

## [1.17.0] — 2026-11-14

- **RND rolls single notes, chords or mixed** on normal and pad tracks. Choose with ▾ next to
  RND (now on all step tracks except drum tracks). Chords come from the same sources as pad
  chords: progressions from Lizzio/Callipari or chords from the track's scale.
- **Editing several steps** now offers the keyboard with single note/chord mode.
- **Fixed chord:** "FIXED" (formerly "ONE NOTE") can hold a whole chord for the track.
- The small duplicate button in the track header is gone; use the track's context menu.
- Preset files: a fixed chord is stored under a new key; versions before 1.17.0 ignore it.

## [1.16.2] — 2026-11-14

- The step width slider in the transport bar now starts in the middle (50 %) on every launch
  instead of restoring the last value.
- All buttons that open a menu now respond on their whole area, not only on their label:
  "MIDI"/"AU" output, chord source "▾", the mixer slot chooser, "+ track", loop bar count.

## [1.16.1] — 2026-11-14

### Review follow-up for 1.16.0

- **Song end without the UI:** at the end of a song all held notes (MIDI and instruments, also
  long gates and drones) end exactly at the planned time and MIDI Stop follows immediately —
  even if the UI is busy.
- **Saving without hangs:** audio loop material is encoded in the background. The state at the
  moment you save is written; edits made meanwhile stay marked as unsaved.
- **External clock:** negative track offsets down to −50 ms now work fully with external clock.
  Track offsets are limited to ±50 ms.
- **Fix:** the audio loop playhead now also moves during playback, not only while recording.
- Internal: more precise render cost measurement, fixed cause of unreliable tests, smaller
  interface between tick path and instrument rack.

## [1.16.0] — 2026-11-14

### New preset format, internal restructuring, macOS 12

- **Preset format changed:** a track's output is now exactly one of MIDI, instrument channel or
  audio loop channel; a channel's source is either an instrument or an audio loop. Invalid
  combinations can no longer be stored. **Presets and projects from before 1.16.0 no longer
  load.**
- **Internal restructuring:** the sequencer engine and the instrument rack are split into
  smaller parts (tick path, snapshot publishing, note output, song planning, output watchdog).
  No change in behaviour.
- **macOS 12** remains the minimum system version.

## [1.15.2] — 2026-11-14

### Review follow-up

- **Transport and song:** every start is its own session (pulse 0, fresh bar grid), even if
  the song had already advanced without the UI; scene changes are matched to the plan that was
  actually played; songs without loop are planned to their end; the song end stops MIDI,
  instruments and loops together at the planned time. External MIDI Start now starts directly
  on the MIDI thread — the first clock pulse plays pulse 0 even if the UI is busy.
- **Timing:** one rule for late ticks across notes, CCs, MIDI clock and loops (clock pulses are
  no longer dropped); negative track offsets work; clock lead covers output buffer, negative
  offsets and plug-in latency and follows device changes.
- **Plug-in latency compensation** per channel (instrument, effects, gate; up to 100 ms).
- **Clock drift:** loop recording and playback follow the real device clock; drift is corrected
  one sample at a time without doubled or empty samples; monitoring keeps its buffer level.
- **Measure latency** (loop input popover → MEASURE): a click through a cable from output to
  input sets the recording offset.
- **Loops:** rows only watch their own channel and do no polling when idle; errors show on the
  affected channel only; erasing a loop and undoing a pass are undoable via Edit → Undo;
  damaged/contradictory loop files are rejected; the memory budget is checked before every
  allocation; saving no longer encodes audio on the main thread.
- **UI:** shared mute/solo buttons on all track heads; pad lengths read "2 bars" in English.

---

## [1.15.1] — 2026-11-14

### Consolidation after the architecture review

No new features. Incorporates a critical review of architecture and timing.

- **Audio loops are safer:** recorded audio is never freed while an audio thread still reads it;
  monitoring no longer overwrites unread samples; undo and clear swap the material instead of
  writing into what is playing; undo after an input dropout no longer copies or restores the gap.
- **Tighter timing:** loops stop exactly on the pulse of a mute, pattern change or song end; the
  song plans up to eight scene changes ahead and keeps switching even if the UI is busy; MIDI
  Start from an external master starts the song like Play and resets the loop bar grid.
- **External clock:** timing now follows the MIDI packet timestamps with a constant lead
  (10 ms + one output buffer), including the very first pulse.
- **Devices:** the audio input restarts after device/format changes; a late microphone
  permission no longer starts the input when it is not needed anymore; loops are converted when
  the output sample rate changes.
- **Projects:** damaged or oversized loop data no longer crashes or allocates huge memory;
  1 GB loop memory budget per project; saving fails visibly if loop audio cannot be encoded;
  loop material that cannot be restored is kept and saved back unchanged; overdubs above full
  scale are stored without clipping.
- **Undo** of "Add Audio Loop Track" also removes the created channel; redo brings it back with
  its audio.
- Measured: 16 loops recording at once, 512 frames at 48 kHz — 0.44 ms median, 0.67 ms p99 per
  block (10.7 ms available).

## [1.15.0] — 2026-11-14

### Audio loop track

**New**
- **Audio loop track** ("Add Audio Loop Track" in the plus menu and the track menu): records a
  loop of fixed length (1, 2, 4, 8 or 16 bars) from the audio input, locked to the sequencer.
  Each audio loop track gets its own mixer channel with effects, fader, pan, solo and meter; the
  loop is shared by all patterns and can be muted per pattern.
- **Record while playing:** REC or the **R** key arms the track; recording starts on the next
  bar and keeps overdubbing every pass until you end it — REC/R again stops at the end of the
  current pass. Short fades at the edges, no clicks.
- **UNDO** removes the last pass (again: redo), **CLR** erases the loop.
- **Input:** one channel (mono) or a channel pair (stereo) of the audio device, **MON** to
  monitor through the channel strip, latency compensation (device latency automatically, plus a
  fine offset in ms).
- **Gate** against noise, at the input (before monitoring and recording), before or after the
  fader; threshold, release and hold adjustable.
- The microphone is only active while a track is armed, recording or monitoring. macOS asks for
  permission the first time.

**Limits**
- No time-stretching: if the sequencer runs slower than when recorded, the rest of each bar is
  silent; faster, the end of each bar is cut. At most 120 s.
- Input and output must run at the same sample rate.

**Preset format:** new optional keys `audioLoop` (track, channel settings) and `audioLoops`
(audio, Apple Lossless 24-bit as Base64). Older versions load such files; the audio loop track
appears there as an empty step track, its channel without an instrument.

---

## [1.14.0] — 2026-11-14

### Song lane and 16 patterns

**New**
- **Song lane** above the tracks: chain scenes, each a pattern and a length in bars (1–64).
  Click a scene to choose its pattern and length; right-click to duplicate, move or delete; all
  with undo. The playing scene lights up.
- **Song mode** (ON/OFF): Play starts with the first scene; patterns change exactly on the bar
  line, regardless of how long track 1 is. Two scenes in a row with the same pattern play
  through without restarting it. **LOOP/END** per song: start again or stop at the end.
- **16 patterns (A–P)** instead of 4, in two rows in the transport bar. ⌘1 … ⌘9 select A … I;
  J … P are in the *Sequencer* menu.

**Changed**
- Pattern switching via CC now uses steps of 8: 0–7 = A, 8–15 = B … 120–127 = P (previously
  0–31 = A … 96–127 = D). If you switch A–D from a controller, adjust its values.
- While the song plays, the pattern buttons have no effect — the scenes choose the pattern.

**Preset format:** new optional key `song`; files now contain 16 patterns. Older versions load
them, ignore the song and show only A–D.

---

## [1.13.19] — 2026-11-14

### Pad tracks: own width, own look

**New**
- Pad tracks have their own grid width: the ↔ button in the track header sets 1 to 8 step widths
  per pad step, with undo. The width only affects the display — the step length stays as it is.
  New pad tracks start at double width.
- Pad tracks look different from step tracks: a PAD badge in the track header, pad steps with a
  gradient in the track colour fading to the right (the sound sustains) and a coloured outline.

**Preset format:** new optional key `padWidth` (only on pad tracks with a width other than 1).
Older versions ignore it.

---

## [1.13.18] — 2026-11-14

### Drag pad step length with visual feedback

**Fixed**
- Pad tracks: the step length could not be dragged with the top handle (dot) — the drag
  distance was computed in real time and was unreachably long for 1 → 2 bars. Now each step
  width of drag changes one length level (1/4 … 8 bars).

**New**
- Every pad step shows its length ("2 T" = 2 bars) in the top right corner, updated live while
  dragging. While dragging the handle, the length is also shown large next to it.

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
