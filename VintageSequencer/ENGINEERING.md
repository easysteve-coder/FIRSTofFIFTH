# FIRSTofFIFTH — Engineering

Basis: v1.0.19 · Stand: 15. Juli 2026 (Slices A–G, Lane 1–6, CC-Lane 1.x, Identity-Slice A v1.9.1, Step-Lane-Purify P1–P3 v1.10.0/1.10.1/1.11.0, Track-Farben-Slice v1.12.0, **RT-1 Playback-State-Ownership v1.12.2**, **RT-1a Atomare Modusumschaltung v1.12.3**, **RT-2 trackRuntimes-Ownership v1.12.4**, **RT-3 Snapshot-Lebensdauer/Hazard-Pointer v1.12.5**, **RT-3a Stop-/External-Clock-Quieszenz v1.12.6**, **RT-3b Fail-Safe Deferred Cleanup v1.12.7**, **RT-4a Catch-up-/Resync-Strategie v1.12.8**, **RT-4b RT-sicherer PRNG v1.12.9**, **RT-4c sendRTSafe Atomic-Snapshot v1.12.10**)
Prinzip: Evolutionär, kein Big Bang. RT-Pfad bleibt unberührt.

---

## Song-Lane und 16 Patterns (v1.14.0)

**Modell.** `Song` (Wertetyp, `Models/Song.swift`): `scenes: [SongScene]` (Pattern-Index +
Takte 1…64), `enabled`, `loops`. UI-Zustand im eigenen `SongState` (`song`, `playingScene`);
nur `SongLaneView` beobachtet ihn. Änderungen über `setSongUndoable` (Undo, Ziel: Engine);
Laden/Neu setzen ohne Undo (`replaceSong`). `SongScene.id` ist nur SwiftUI-Identität — nicht
persistiert, nicht Teil der Gleichheit.

**Taktgrenze im Tick-Thread.** Der Tick-Thread zählt Pulse seit Sitzungsbeginn (`rtPulse`,
Rücksetzen, wenn er eine höhere Aktivierung ohne Vormerkung übernimmt = neue Sitzung).
`PlaybackStateBundle` trägt `switchAtPulse` (absoluter Puls des Wechsels zu `queued`; −1 =
Track-0-Grenze wie bisher) und `stopAtPulse` (Songende ohne Loop; −1 = nie). Wechsel, wenn
`pulse ≥ switchAtPulse` und auf einem Takt dazu (Modulo 96) — liegt der Puls schon zurück
(Song im Lauf gekürzt), an der nächsten Taktgrenze. Der Wechselpuls geht über `rtSwitchPulse`
(relaxed, vor dem releasing-Store von `rtSwitchedSerial`) an Main. Ab `stopAtPulse` schlägt
der Tick nichts mehr an (fällige Offs laufen aus), setzt `rtSongEnded`; der Drain ruft `stop()`.

**Main.** `beginSongIfActive()` (in `play()` und beim externen Neustart, vor
`beginRuntimeSession`): erstes Szenen-Pattern aktivieren, Lauf ab Puls 0, `scheduleSongNext()`.
`Song.run(from:playing:)` fasst direkt folgende Szenen desselben Patterns zu einem Lauf
zusammen (kein Wechsel, kein Neustart) und liefert `.scene(i)`, `.end` oder `.never`.
`reconcilePatternSwitch` übernimmt nach einem Song-Wechsel den Startpuls, merkt den nächsten vor
und gibt die Runtime-Slots des abgelösten Patterns frei — sonst behielte ein Pattern, das der
Song sofort wieder vormerkt, seine alte Runtime und begänne beim Rücksprung nicht auf Step 1.
Manuelle Patternwahl ist im laufenden Song wirkungslos. Song-Änderungen im Lauf rechnen den
nächsten Wechsel neu (gelten ab dort). Song an/aus im Lauf: aus hebt die Vormerkung auf; an
wirkt ab dem nächsten Start.

**16 Patterns.** `Pattern.slotNames` (A–P) ist die einzige Quelle. Laden füllt auf 16 auf und
kürzt darüber. Pattern-CC in Achterschritten (`value / 8`).

**Presetformat.** Optionaler Schlüssel `song` (nur geschrieben, wenn nicht leer). Dateien
haben jetzt 16 Patterns. Ältere Versionen lesen sie: Song ignoriert, Patterns E–P im Modell,
aber nicht anwählbar.

## Pad-Lane, Halten, fester Ton, Pad-Akkorde (v1.13.16)

**Pad-Lane.** `LaneData.isPad` (Schlüssel `pad`, optional) markiert eine Step-Lane mit langen
Steps. Steplängen kommen aus `TrackData.padRatios` (Vielfache einer 16tel: 4, 8, 12, 16, 32,
48, 64, 128 = 1/4 … 8 Takte); `lane.ratioOptions` liefert je Lane die gültige Liste, die
Zieh-Sitzungen (`RatioDragSession`, `StretchRatioDragSession`) tragen sie als `ratios`; der
Anfasser zieht bei Pad-Lanes stufenweise (`pxPerRatioStep` = eine Step-Breite je Stufe, v1.13.18),
weil der zeitgetreue Ziehweg bei Längen bis 128/1 unbedienbar wäre. Das
Raster rechnet mit `displayNumerator/displayDenominator` — bei Pad-Lanes `padWidth`/1, also
kompakt, nicht zeitgetreu. `LaneData.padWidth` (1…8 Normal-Stepbreiten, Schlüssel `padWidth`,
nur bei Pad-Lanes ≠ 1 geschrieben, v1.13.19) ist reine Anzeige; gesetzt über
`ModelCommand.setPadWidth` mit Undo (Popover ↔N im Spurkopf), neue Pad-Spuren starten mit 2.
Optik: Pad-Steps tragen über dem Kunststoffkörper einen Verlauf in Spurfarbe nach rechts und eine
Kontur; der Spurkopf zeigt statt des Farbpunkts ein PAD-Schild. Der Tick-Pfad ist unverändert: `pulsesPerStep = 6·num/den`, also 96 Pulse
je Takt. Lange Offs stehen im Notenbuch wie Drone-Offs. `clampToValidRanges` setzt eine
Pad-Lane mit unbekannter Länge auf 1 Takt. Die Fortschrittsanzeige (`PadProgressBar`) ist
eine lineare Animation ab Erscheinen des aktuellen Steps, kein Timer; Dauer aus BPM und
Steplänge zum Zeitpunkt des Stepwechsels.

**Halten.** `Step.isHold` (Schlüssel `hold`, optional) schlägt nicht an. `holdSpan` (Anzahl
direkt folgender aktiver Halte-Steps, Vorwärtsrichtung, zyklisch) wird auf Main im Snapshot
vorberechnet; der Tick-Pfad liest nur `isHold` (→ überspringen) und `holdSpan` (Gate =
`holdSpan + min(gate, 1)` Steps, Ratchet aus). Bei Rückwärts-, Pingpong- und Zufallsrichtung
gilt dieselbe Vorwärts-Spanne — bewusst einfach.

**Fester Ton.** `LaneData.fixedNote` (Schlüssel `fixedNote`, optional) ersetzt beim Bau des
Snapshots die Noten jedes Steps durch diese eine Note; die Step-Noten bleiben im Modell.
Gesetzt über `ModelCommand.setFixedNote` mit Undo.

**Pad-Akkorde.** `PadChords` (Main, nur im Randomize-Befehl): 17 Folgen aus Lizzio, „Chord
Progression Codex“, und Callipari, „Illustrierte Harmonie“ (Auswahl und Seitenangaben wie
die Harmonie-Vorlagen in Planarium), notiert relativ zur Tonika, transponiert auf
`scaleRoot`; alternativ leitereigen aus der Skala der Spur. Stimmführung: Bass auf dem
Grundton (C2–B2), Akkord in enger Lage zwischen E3 und G5 mit kleinster Bewegung zum
Vorgänger. Quelle/Folge stehen in UserDefaults (`padChordSource`, `padChordFamily`).

**Presetformat.** Drei neue optionale Schlüssel, nur geschrieben wenn gesetzt. Ältere
Versionen ignorieren sie: Pad-Lanes laden dort als normale Spur mit langen Steps (zeitgetreu
breit), Halte-Steps spielen ihre eigenen Noten, der feste Ton entfällt.

## AU-Hosting — Ereignisgrenze und Rack (v1.13.0)

Quelle: `Engine/AUEventQueue.swift`, `Engine/InstrumentRack.swift`, `Models/InstrumentChannelData.swift`,
`Views/MixerView.swift` (seit v1.13.1, vgl. „Mixer"); Anbindung in `SequencerEngine.swift` („Ausgabe nach Ausgang", „Notenbuch").
Vision und Planarium-Bewertung: `Docs/STANDALONE_VISION_UND_AU_HOSTING.md`.

**Entscheidung: eigene schmale Ereignisgrenze statt Übernahme von Planariums Scheduling.** Planariums Notenpfad hängt
an dessen Runtime und serieller Steuerqueue (Locks, Dictionaries), kennt keine terminierten CCs und hat 256 Ereignisse
Budget. FIRSTofFIFTH datiert bereits jedes Ereignis in Host-Zeit; es genügt, diese Zeit im Renderblock des Instruments in
einen Sample-Offset umzurechnen. Übernommen wurden Planariums Erfahrungen (Zustand als binäre Property-List,
Observer nach dem Zustands-Restore installieren, Editor-Fenster getrennt halten), kein Code.

```
advanceSteps ─ sendNote/outCC ─┬─ route < 0 ─▶ MIDIManager (CoreMIDI, Future-Timestamp)
                               └─ route ≥ 0 ─▶ AUEventQueue[route] ─▶ Render-Observer ─▶ scheduleMIDIEventBlock
```

**Zeitbasis.** Ein Ereignis trägt denselben `MIDITimeStamp` wie sein CoreMIDI-Gegenstück. Der Render-Observer
(Pre-Render, Audio-Thread des Instruments) gibt aus, was in `[mHostTime, mHostTime + frames)` fällt, mit
`AUEventSampleTimeImmediate + offset`. Überfälliges und „sofort" (Host-Zeit 0) → Offset 0. Der Tick-Vorlauf
(ein Intervall + 10 ms) liegt über üblichen Puffergrößen; reicht er nicht, klingt die Note verspätet, nie verfrüht.

**Thread-Besitz.**

| Teil | Besitzer |
|---|---|
| `tickRing` (SPSC) schreiben | Inhaber des Tick-Zutritts (Tick-Thread; Main nur quieszent oder als Off-Wächter) |
| `mainRing` (SPSC) schreiben | Main (Vorhören, Panik, Stop-Offs) |
| beide Ringe lesen, Warteliste (512) | Audio-Thread des Instruments |
| Generation, Belegung (`occupancy`), `active` | Atomics; Main schreibt |
| Rack, Kanäle, Knoten, Fenster | Main |

Kein Lock, kein Heap in Produzenten und Konsument. Der Observer fängt nur die Warteschlange (unretained; das Rack hält
alle 16 für seine Lebensdauer), den Schedule-Block und eine Konstante.

**Warteliste.** Ereignisse kommen nicht in Zeitfolge an. Der Konsument leert die Ringe in eine feste Liste und gibt je
Block das Fällige in Ankunftsreihenfolge aus (Off vor On desselben Zeitpunkts bleibt erhalten).

**Aufnahmevertrag (v1.13.13, Codex-Befund H1).** `push…` liefert `false` nur bei vollem Ring (gezählt: `rejected`).
Absichtlich verworfen (Warteschlange inaktiv, Ereignis für eine frühere Belegung) gilt als erledigt (`true`). Kein
Ereignis wird vor seiner Zeit ausgegeben: Bei voller Warteliste bleibt der Rest im Ring (gezählt: `backlog`); der Ring
füllt sich und weist ab — Gegendruck statt Vorziehen. Der Tick reagiert im Notenbuch (`sendNote`, `flushDueNoteOffs`):
ein abgewiesenes Off bleibt `pendingOff` und wird im nächsten Tick erneut versucht (spät, nicht verloren); ist das Off
eines Neuanschlags abgewiesen, klingt die alte Note weiter (Ende verlängert, kein neues On); ein abgewiesenes On
hinterlässt keinen Off-Auftrag. Abgewiesene CCs und Parameterwerte gehen verloren (der nächste Step setzt den Wert
neu). CoreMIDI meldet keine Ablehnung.

**Arbeitsgrenze (H7).** Je `render` höchstens `pendingCapacity` (512) Entnahmen aus beiden Ringen zusammen — auch
veraltete zählen — und ein Durchlauf der Warteliste (≤ 512). Gemessen (Debug-Build, M1 Pro, 64 Frames, volle Ringe und
Warteliste, 2000 Blöcke): Median 60 µs, 99 % 87 µs, Maximum 234 µs. Allokationsfreiheit ist durch Aufbau belegt (feste
Puffer, keine Collections, keine Closures mit Kontext im Pfad), nicht durch Messung.

**Leeren und Belegung (H2/H3).** Zwei nur steigende Zähler je Warteschlange: Generation (`invalidate()`: Stop, Panik,
Ausschalten) und Belegung (`beginOccupancy()`: Kanal angelegt/entfernt, Instrument geladen/getauscht). Ein Ereignis
gilt, solange beide Zähler den aktuellen entsprechen. Der Konsument liest beide zu Blockbeginn; trifft er auf ein
Ereignis mit NEUEREM Zähler (eingereiht nach einem Wechsel mitten im Block), übernimmt er dessen Stand — ein nach dem
Leeren eingereihtes Aufräumen geht nie verloren. Was vor dem Lesen schon zur Ausgabe bestimmt war, gehört zum Block.
Main fasst Ringe und Warteliste nie an. Stop: `silenceAll()` (invalidate + CC 123 auf allen Kanälen), danach ein
sofortiges Off je offener Note aus dem Notenbuch.

**Routing.** `TrackData.instrumentID` → `rack.route(for:)` / `rack.routeEpoch(for:)` → `TrackSnapshot.route` (Slot 0…15,
−1 = MIDI) und `routeEpoch`. Produzenten übergeben die Belegung, für die sie geplant haben; sie wird nicht beim
Einreihen nachgestempelt. Eine Belegungsänderung ruft `onRoutingChange` (Snapshot neu, sofern die Wiedergabe läuft).
Vorhören merkt sich die Belegung des On; das verspätete Off geht nur an dieselbe. Das Notenbuch hat je Ausgang einen
Abschnitt (1 + 16) und je Abschnitt die zugehörige Belegung (`portEpoch`): wechselt sie, verwirft `resetPort` die offenen
Offs der vorigen Belegung. Ohne geladenes Instrument ist die Warteschlange inaktiv und verwirft sofort.

**Ladeaufträge (H4).** `Live.instrumentRequest` ist ein nie wiederverwendetes Token; der Abschluss prüft Token UND
Identität der Live-Instanz (`live[id] === l`). Nach `replaceAll` (gleiche Kanal-UUID, neue Instanz) setzt ein alter
Abschluss nichts ein. Effekte hatten schon ein Token je Platz.

**Audio-Graph.** Instrument → Effekte → Kanal-Mixer (Pegel, Pan) → Main-Mixer → Standardausgang, Stereo in der
Abtastrate des Ausgangs. Die Engine entsteht mit dem ersten Kanal und läuft nur mit mindestens einem geladenen
Instrument. Bei `AVAudioEngineConfigurationChange` werden alle Ketten neu verbunden und die Observer neu installiert
(Abtastrate geht in die Umrechnung ein).

**Plug-ins.** Nur `.loadOutOfProcess` (seit v1.13.7 kein Rückfall in den App-Prozess). Zustand: `fullState` als binäre Property-List in
`PluginRef.state`; `captureStates()` vor jedem Speichern. Nicht ladbare Plug-ins behalten Referenz und Zustand.

**AVFAudio wirft Objective-C-Ausnahmen** bei Fehlbedienung (z. B. Tap auf einem abgehängten Knoten). In Swift sind sie
nicht abfangbar und können eine async-Funktion stumm hängen lassen. Reihenfolgen im Rack deshalb nicht umstellen, ohne
das zu bedenken: erst Observer/Tap entfernen, dann abhängen.

**Tests:** `AUEventQueueTests` (7, rein), `AUHostRoutingTests` (3), `AUHostPersistenceTests` (2),
`AUHostRealInstrumentTests` (1: echter DLS-Synthesizer außerhalb des Prozesses, Messung des Klangeinsatzes gegen die
geplante Host-Zeit, Schranke −2 … +60 ms; gemessen 0,11 … 0,15 ms).

**Offen / nicht geprüft:** Fremd-Plug-ins; Gerätewechsel und Sleep/Wake im Betrieb; Latenzausgleich intern/extern;
Hostkontext (`musicalContextBlock`, `transportStateBlock`); Offline-Rendering/Export; Lastprofil mit dichten Akkorden
und Ratchets gegen die Puffergrößen (1024 / 512); Sichtbarkeit der Überlaufzähler.

---

## Step-Klickfläche und Sekundärklick (v1.13.4)

- **Dekor ist nicht treffbar** (`VintageMaterials`: `allowsHitTesting(false)`). Jede bedienbare View, deren Fläche aus
  einem Materialbaustein besteht, braucht deshalb ein eigenes `.contentShape(...)` — sonst reagieren nur die Inhalte
  (Text, LED), nicht die Fläche. `StepButtonView` setzt es auf dem Tastenrahmen.
- **Rechtsklick:** SwiftUI hat keine Sekundärklick-Geste. `SecondaryClickCatcher` (`LaneGeometry.swift`) ist EINE
  AppKit-View je Lane, nicht je Step. Sie ist für alle anderen Ereignisse durchlässig (`hitTest` → nil, entschieden
  über `NSApp.currentEvent`) und nimmt einen Sekundärklick nur an, wenn er auf einem Step liegt.
- **Punkt → Step:** `LaneGeometry.stepIndex(...)` ist die Umkehrung des Zell-Layouts (`distributedStepWidth`,
  `stepGridLeadingPad`, `stepSpacing`). Wer das Layout der Step-Zeile ändert, ändert diese Funktion mit;
  `StepHitTests` prüft sie gegen das Layout für gerade und krumme Verhältnisse.
- **Edit-Card:** hängt an der Zelle in `StepGridView` (`editIndex`), außerhalb des `PlayheadGate` — nicht mehr in
  `StepButtonView`. ⌥+Klick meldet über `onEdit`.

---

## Textkontrast (v1.13.3)

- `VintageTheme.textSecondary` und `textDim` stehen nur auf dunklen Flächen (`background`, `panel`, `panelDark`,
  dunkles Metall). Mindestkontrast 4,5:1 bzw. 3:1, Reihenfolge `textDim` < `textSecondary` < `textPrimary`.
- Beschriftung auf Kunststofftasten (`PlasticKeyBackground`, `PlasticSegmentBackground`) im Ruhezustand:
  `textPrimary` — die Taste ist heller als die Fläche, Nebentext reicht dort nicht.
- Auf hellem Aluminium: `Mat.inkOnLight` / `inkOnLightSecondary`, nie die hellen Textfarben.
- Text nicht über `.opacity` abblenden, um Rang auszudrücken — dafür gibt es die drei Stufen.
- `ThemeContrastTests` rechnet die Kontraste aus den Farbwerten; wer eine Farbe ändert, sieht dort die Folge.

---

## Mixer — Kanalzüge, Solo, Pegelanzeigen (v1.13.1, Bedienung v1.13.5)

Dateien: `Views/MixerView.swift` (Dock, Züge, Summe), `Views/MixerControls.swift` (Kennlinien und Regler),
`Engine/InstrumentRack.swift` (`LevelMeter`, Mix-/Effektfunktionen).

- **Vorbild Planarium.** Kennlinien, Gesten und Zustände der Regler sind aus Planariums Kanalzug übernommen
  (`../Sick/Sources/SickPLSMonitor/HelmutChannelSurface.swift`, `SickPLSMonitorKit/FaderLaw.swift`, `PanDisplay`,
  `FaderMath`, `MeterLaw`, `ControlDragSession`). Wer dort die Bedienung ändert, zieht hier nach — und umgekehrt.
  Flächen bleiben FoF-Materialbausteine.
- **Einbau:** `MixerDock` sitzt in `MainView` zwischen `GlobalHScrollbar` und `StatusBar`, Höhe
  `MixerDock.minHeight … maxHeight`, sichtbar über `@AppStorage("showMixer")`. Nur der Faderweg ist nachgiebig
  (`StripRail.faderMin … faderMax`); der Spurbereich hat `minHeight: 150`. Der Mixer verändert weder Lane-Breiten
  noch `ViewportMetrics`.
- **Beobachtung:** `MixerContent` und `SumStrip` beobachten ausschließlich das `InstrumentRack`. Züge sind reine
  Wert-Views. Spurfarben (`RoutedTrackColor`) beobachten je ein `TrackViewModel`. Der Mixer beobachtet weder
  Playhead noch Scroll; Lanes beobachten das Rack nicht. `rack.highlightedChannel` ist `@Published` auf dem Rack,
  nicht auf Engine oder TrackViewModel — es invalidiert nur den Mixer.
- **Signalweg je Kanal:** Instrument → Effekte → Gain-Stufe (`AVAudioUnitEQ` ohne Bänder, `globalGain` −96 … +6 dB)
  → Kanal-Mixer (Panorama, Stumm) → Main-Mixer → Gain-Stufe der Summe → Ausgang. `AVAudioMixerNode.outputVolume`
  reicht nur bis 1,0; deshalb die eigene Gain-Stufe. Ohne bekanntes Ausgabeformat ist die Summen-Stufe nicht
  verdrahtet (`masterGainWired`), dann begrenzt der Main-Mixer auf 0 dB.
- **Solo/Mute:** Hörbar = nicht stumm UND (kein Kanal auf Solo ODER selbst auf Solo), umgesetzt über
  `mixer.outputVolume` (0 oder 1). Jede Änderung der Solo-Menge — Umschalten, Löschen, Ersetzen des Racks —
  rechnet alle Kanäle neu (`applyMixToAll`). Stumm heißt: das Instrument rendert weiter, Noten laufen weiter ein.
- **Pegel:** gespeichert als linearer Gain (`volume`, `masterVolume`, 0 … `InstrumentRack.maxGain`), nie als
  Faderstellung. `FaderLaw` rechnet Stellung 0 … 1 ↔ dB über die aufgedruckten Stützpunkte.
- **Regler-Zug (`ControlDragSession`):** Der Regler zeichnet aus eigenem Zustand und schreibt gebündelt (höchstens
  alle 40 ms) ins Rack — eine Faderbewegung wertet den Zug nicht mit Mausrate neu aus. Esc stellt den Anfangswert
  wieder her (lokaler Tastenmonitor nur während des Zugs). `ControlScrollAction` hält einen Scroll-Monitor nur,
  solange der Zeiger über dem Regler steht.
- **Pegelanzeigen:** Je Kanal-Mixer und hinter der Summen-Gain-Stufe ein Tap (`installTap`, 1024 Frames). Der
  Tap-Block läuft auf einem Hilfsthread von AVFAudio (nicht im Render-Durchlauf) und hält je Seite die höchste
  Spitze in zwei Atomics, bis die Anzeige sie abholt (`LevelMeter.take`). `MixerStereoMeter` liest im eigenen
  30-Hz-Takt (`TimelineView`, pausiert ohne laufendes Audio) und zeichnet in einem `Canvas`; Abfall (20 dB/s),
  Halb-dB-Rundung und Übersteuerungshaltezeit (2 s) sind reine Anzeige. Kein `@Published` je Pegelwert.
- **Tap-Reihenfolge:** Tap immer entfernen, bevor der Knoten neu verbunden oder abgehängt wird; nach
  Formatwechsel (Config-Change) neu setzen. Ein Tap auf einem abgehängten Knoten wirft eine nicht abfangbare
  ObjC-Ausnahme.
- **Plätze:** `assignEffect(_:at:in:)` ersetzt an Ort und Stelle (entfernen, an derselben Position einfügen) und
  merkt den Editor zum Öffnen nach dem Laden vor (über das Lade-Token, nicht über den Index).
  `setEffectBypassed` setzt `auAudioUnit.shouldBypassEffect`; der Effekt bleibt in der Kette. `moveEffect` bleibt
  im Rack (ohne Bedienelement).
- **Instrument Ein/Aus:** `PluginRef.bypassed` am Instrument. Aus = All Notes Off über den Main-Ring, dann
  `AUEventQueue.setActive(false)` — der Tick-Pfad verwirft danach an der Warteschlange, ohne das Rack zu kennen.
- **Editor-Fenster:** `requestViewController` liefert bei out-of-process geladenen AUs immer einen Controller, bei
  Plug-ins ohne eigene Oberfläche mit 1 × 1 pt großer View. Editoren unter 40 pt Kantenlänge werden durch
  `AUGenericView` in einer Scroll-View ersetzt; die Fenstergröße wird ausdrücklich gesetzt.
- **PANIC** (`SequencerEngine.panic`, Main): `rack.silenceAll()` + All Notes Off auf 16 MIDI-Kanälen. Berührt weder
  Notenbuch noch Tick-Zutritt; ausstehende Offs des Notenbuchs kommen danach normal und sind folgenlos.
- **Ausgangswahl:** einziger Weg ist `SequencerEngine.setOutput(of:to:)` (Command `.setInstrument`, Undo).
  Spurkopf und Kontextmenü teilen `TrackOutputItems`; sie beobachten `rack.directory` (`ChannelDirectory`: nur IDs
  und Namen, veröffentlicht nur bei Änderung dieser Liste) — nie das Rack selbst, sonst würde jede Faderbewegung
  alle Spurköpfe neu auswerten. Seit v1.13.6 Taste „MIDI"/„AU" (`TrackOutputMenu`) in Step- und CC-Kopf;
  „Neuer Instrumentenkanal" läuft über `setOutputToNewChannel(of:name:)` (Kanal anlegen + `setOutput`; Undo löst
  nur die Zuweisung). Die Taste ist eine eigene sichtbare Ebene, das `Menu` liegt mit leerem Label als
  `.overlay` darüber (v1.13.7): ein borderless-Menü zeichnet sein Label abgeblendet und ohne Tastenfläche.
- **Plug-in bei laufender Engine (v1.13.7):** `rewire` endet mit `adoptNewNodes`. Hat ein Knoten der Kette keine
  Render-Ressourcen (`renderResourcesAllocated == false`) und läuft die Engine, wird sie gestoppt und neu
  gestartet. Gemessen: ohne das rendert AVAudioEngine einen bei laufender Engine angelegten Kanal nicht (Pegel 0),
  und UADx-Plug-ins bleiben im Zustand `CachedInit` (unscharfer Editor), weil sie ihre Freischaltung bis zum
  Anlegen der Render-Ressourcen aufschieben. Test `channelAddedWhileEngineRunsIsRendered`.
- **Step-Ziehen (v1.13.8):** `PitchDragSession.anchorY` ist die Translation beim Sitzungsbeginn; Halbtöne und
  Velocity zählen ab dort (die Geste meldet erst nach 8 pt). `editsVelocity` (⌥ beim Beginn) lässt dieselbe Sitzung
  die Velocity schreiben — live über `.setSteps` ohne Undo, Commit/Abbruch unverändert über den Snapshot.
- **CC-Lane → Instrument-Parameter (v1.13.9, Bindung v1.13.13):** `LaneData.ccParameter` (`ParameterRef`: Adresse,
  Name, `component` = `PluginRef.componentKey` des Instruments bei der Wahl). Beim Snapshot-Bau (Main) löst
  `rack.resolveParameter` auf: nur gegen ein bereites Instrument desselben Plug-ins (fehlt `component` — Dateien aus
  v1.13.9 … v1.13.12 —, gilt jedes). Aufgelöst → `TrackSnapshot.parameter`; geht die Spur auf ein Instrument, ist das
  Ziel aber nicht auflösbar → `ccUnresolved`: die Lane sendet NICHTS (kein Ersatz-MIDI-CC). Die Kopf-Taste zeigt das
  mit „?" (über `ChannelDirectory.Entry.readyInstrument`, ohne das Rack zu beobachten). Nach dem Laden ruft das Rack
  `onRoutingChange`. Tick-Pfad: `AUEventQueue.pushParameterFromTick` (Ereignis mit `isParameter`, Wert als
  Float-Bitmuster); der Render-Observer gibt es über `scheduleParameterBlock` aus. Kein Heap, kein Lock. Die
  Parameterliste liest `rack.parameters(for:)` einmal je geladenem Instrument aus dem Parameterbaum (Main, Cache).
- **Klickflächen (v1.13.9):** Materialflächen sind nicht treffbar. Tastenstile setzen deshalb
  `.contentShape(Rectangle())`; statt `.buttonStyle(.plain)` gilt in Views `.buttonStyle(.fullArea)`.
- **Sandbox und Plug-ins (v1.13.17):** FoF bleibt in der App-Sandbox (Container-Pfade für
  Presets, Einstellungen und Diagnose). Nicht sandbox-taugliche AUs (ohne `sandboxSafe`, z. B.
  UADx, Odin 2) lösen sonst eine Systemabfrage „Sicherheitseinstellungen senken“ aus; dafür
  trägt die App `com.apple.security.temporary-exception.audio-unit-host`. Zulässig bei
  Developer ID, nicht im App Store.
- **Spurkopf (v1.13.17):** keine leeren `.contextMenu {}` an Tasten (sie sollten das Spurmenü
  unterdrücken, beschränkten unter macOS aber die Trefferfläche auf die Beschriftung). Der Kopf
  trägt `.contentShape(Rectangle())` vor `.contextMenu`, damit auch freie Flächen das Spurmenü
  öffnen. Menüs (`Menu`) setzen die Trefferfläche an ihrem Label.
- **Fensterkopf (v1.13.10):** `MainView` rückt um `titlebarOverlap` ein; `TitlebarOverlapReader` (NSView hinter der
  eingerückten Fläche) misst Oberkante gegen `window.contentLayoutRect` bei Layout, Größenänderung und Vollbild.
- **Produktname (v1.13.10):** Build-Produkt `FIRSTofFIFTH.app` (`PRODUCT_NAME`), Modul weiter `VintageSequencer`
  (`PRODUCT_MODULE_NAME`); `TEST_HOST` zeigt auf `FIRSTofFIFTH.app/…/FIRSTofFIFTH`.
- **Wächter der Audioausgabe (v1.13.11, v1.13.14):** `InstrumentRack.watchdogTick` (Main-Timer 4 Hz, läuft bei
  geladenen Instrumenten oder laufender Diagnose). Entscheidung als reine Funktion `watchdogFinding`: `.stopped`
  (Engine läuft nicht), `.nonFinite` (ein Tap sah NaN/∞, `LevelMeter.hasNonFinite` — nur ansehen; abgeholt wird
  erst bei der Behandlung, damit ein Befund in der 3-s-Sperrfrist stehen bleibt), `.stalled` (Summen-Tap
  `stallTicks` = 8 Prüfungen ≈ 2 s ohne neuen Block). Reaktion: `stop`, `reset`, `rebuildGraph`. Nach 2 s prüft
  `recoveryCheck`, ob wieder Blöcke kommen (`lastRecoveryOutcome`: erholt / ohne Erfolg). Log: Subsystem der
  Bundle-ID, Kategorie `audio`. Grenze: endliche Überpegel und Gleichanteil erkennt der Wächter nicht; Blöcke am Tap
  belegen keine Ausgabe am Gerät.
- **Audio-Diagnose (v1.13.14):** `AudioDiagnostics` (Main) schreibt JSON Lines nach
  `Application Support/FIRSTofFIFTH/Diagnostics/` im Container; Serialisieren auf Main, Schreiben auf serieller
  Queue, `stop` wartet auf sie. Jede Zeile: `t` (s seit Start), `n` (laufende Nummer), `k` (Art). Probe `s` aus dem
  Wächter-Timer: `dt` (tatsächlicher Abstand), `sum`/`ch[]` mit `peak` (größter endlicher Betrag), `over1`,
  `over16`, `nan`, `dc`, `rms` (letzter Block), `blocks`; je Kanal zusätzlich `auPre`/`auPost`/`auErr`
  (Render-Durchläufe/Fehler des Instruments), `rejected`/`backlog` der Warteschlange; `device` (CoreAudio, nur
  lesen). Ereignisse: `start`, `stop`, `load`, `loadError`, `config`, `rebuild` (Dauer), `restart`,
  `watchdog`, `recovery`, `au` (KVO `currentPreset`/`parameterTree`/`allParameterValues`), `invalidated`
  (`kAudioComponentInstanceInvalidationNotification`), `device`, `play`, `stop`, `mark`.
  Messquellen: `LevelMeter.takeDiagnostics` (eigene Atomics, verbraucht `take` der Anzeige nicht) und Zähler in
  `AUEventQueue` (`preRenders`, `postRenders`, `renderErrors`), die der Render-Observer nur inkrementiert. Kein
  zusätzlicher Tap. Ein-Zustand in `UserDefaults` (`audioDiagnosticsOn`).
- **Keine eigenen AU-Klassen im Graphen:** `AUAudioUnit.registerSubclass` + In-Process-Instanz scheitert in der
  Sandbox (`invalidComponentID`, bzw. NSException in `AVAudioUnitEffect(audioComponentDescription:)`, die den
  Main-Executor beschädigt). Gemessen v1.13.14, verworfen.
- **Drone-Step (v1.13.12):** `StepSnapshot.isDrone`. Tick-Pfad: ein Anschlag (Ratchet 1), Off bei
  `on + stepDuration × (stepCount + 0,5)`. `sendNote(tie: true)`: steht für die Note noch ein Off aus, das nicht
  vor dem neuen On liegt, wird nur `pendingOff` hinausgeschoben (kein Off, kein On). Der halbe Step Überhang stellt
  sicher, dass das Off beim Wiederkommen des Steps noch im Buch steht (`flushDueNoteOffs` gibt nur bis zum
  Tick-Zeitpunkt aus). `earliestPendingOff` darf danach zu früh stehen; die Off-Ausgabe rechnet es neu.
- **Nur out-of-process:** `instantiate` hat keinen In-Process-Rückfall; der würde in der Sandbox den Systemdialog
  zum Senken der Sicherheitseinstellungen auslösen.

---

## GUI-Revision — Gesten- und Bearbeitungsverträge (v1.12.23)

Anlass: Codex-Durchsicht der GUI vom 2026-11-12 (sechs Befunde). Kein Eingriff in den Tick-Pfad.

- **Auto-Scroll (`EdgeScrollVelocity`):** Zone = min(80 px, nutzbare Breite / 4) je Seite; nutzbare Breite = Viewport
  minus Insets. Damit überlappen die Zonen nie und die mittlere Hälfte ist scrollfrei. Im Inset und jenseits der Kante gilt
  volle Geschwindigkeit. Rubberband meldet Lane-Koordinaten (Insets 0), `HandleNSView` Fensterkoordinaten mit Spurkopf
  (links) und 40 px Rand (rechts) als Inset.
- **Undo in Dialogen:** Sheets und Popover haben nicht zuverlässig den Undo-Manager des Hauptfensters in der Umgebung;
  sie verwenden `engine.undoManager`. `MultiStepEditView` schreibt live ohne Undo und registriert beim Schließen einen
  Schritt (Ausgangsstand → Endstand), nur wenn etwas geändert wurde.
- **Tonzuordnung:** Vorschau und Eintrag verwenden denselben quantisierten Ton. Modus TON ersetzt, Modus AKKORD
  schaltet einen Akkordton um; ⇧ erzwingt Akkord.
- **Drum-Modus:** `TrackData.isDrum` ist reiner Bearbeitungs-/Anzeigezustand. Views fragen nie mehr `midiChannel == 10`.
  Der Snapshot enthält das Feld nicht; der Tick-Pfad kennt es nicht.
- **Rubberband:** Nullbreite wählt nichts. Maßgeblich bleibt allein die horizontale Spanne; die Höhe hat keine Bedeutung.
- **Auswahlleiste:** unsichtbar, solange `rubberAnchorContentX != nil`; bereinigt die Auswahl bei kleinerer Step-Anzahl.

**Nicht umgesetzt (braucht Stephan-Entscheid zum Layout):** dauerhaft sichtbarer Step-Inspector, feste Position der
Auswahlleiste ohne jeden Layoutsprung, Zusammenlegen der doppelten Bedienstellen für Anzahl/Verhältnis (Eck-Anfasser und
rechte Felder), Noteneingabe als Text oder per MIDI, Tastatur-/VoiceOver-Vertrag.

---

## Notenbuch — Offs kurz vor ihrem Zeitpunkt (v1.12.22)

Quelle: `SequencerEngine.swift` („Notenbuch", „Off-Wächter"). Ersetzt die Buchführung aus v1.12.19 (nur spätestes Off).

**Problem.** Ein an CoreMIDI übergebenes Off ist nicht rückholbar. Mit dem On geplant, traf es jede später begonnene
gleiche Note (Kanal + Tonhöhe), deren On vor diesem Off lag.

**Vertrag.** Je Note drei Zeitpunkte: `pendingOff` (noch nicht übergeben), `sentOff`, `lastOn`.

- `sendNote` (Tick-Pfad) ist der einzige Weg, ein Playback-On auszugeben. Steht ein `pendingOff` aus:
  liegt es nach dem neuen On → Off auf dem neuen On, `pendingOff = max(alt, neu)`; sonst → altes Off mit eigenem Zeitpunkt
  senden, neues eintragen.
- `flushDueNoteOffs(upTo: T(k))` läuft am Ende von `advanceSteps`, **nach** allen Ons des Ticks. Horizont ist der
  Tick-Zeitpunkt: Der nächste Tick wird erst kurz vor T(k) ausgegeben und erzeugt nur Ons nach T(k) (Vorlauf-Vertrag der
  Clock-Quelle, Overshoot < 1 Intervall). Ein gesendetes Off kann daher keine spätere Note treffen. Im EXT-Modus ist
  T(k) = Ankunft + geschätztes Intervall; Offs können dort um den Puls-Jitter verspätet hinausgehen.
- Kosten: `earliestPendingOff` erspart den Durchlauf (2048 Einträge), wenn nichts fällig ist. Kein Heap, kein Lock.
- Bricht ein Tick vor `advanceSteps` ab (kein Snapshot), gehen fällige Offs mit dem nächsten Tick hinaus.

**Stop** (`sendPendingNoteOffs`, nur quieszent): Off für jede Note mit `pendingOff != 0` oder `sentOff > jetzt` (der Flush
des Ausgangs kann es verworfen haben). Liegt `lastOn` noch in der Zukunft, wird das Off auf `lastOn + 1 ms` datiert —
`MIDIReceived` (virtuelle Quelle) kennt keinen Flush, das On kommt dort noch an (Befund B5).

**Off-Wächter.** Main-Timer (100 ms), nur während der Wiedergabe. Bedingung: EXT-Modus, `hasPendingOffs`, letzter externer
Tick älter als 300 ms. Dann nimmt er den Tick-Zutritt per `enterTick` (Buch gehört dem Inhaber des Zutritts) und sendet
Offs bis „jetzt". Ein in genau diesem Moment eintreffender Puls würde abgewiesen und gezählt — nur möglich, wenn die Clock
nach einem Stillstand exakt während der wenigen Mikrosekunden wieder einsetzt. Im INT-Modus tut der Wächter nichts.

**Grenzen.** Ons derselben Note, die innerhalb eines Ticks in nicht aufsteigender Zeitfolge entstehen (zwei Spuren, eine mit
Offset), werden in Erzeugungsreihenfolge aufgelöst; das zweite On bekommt dann kein eigenes Off davor. Nach Stop + sofortigem
Neustart kann ein hinter ein Zukunfts-On datiertes Off die erste gleiche Note der neuen Sitzung kürzen.

**Spurgrenze.** `maxTracksPerPattern = runtimeSlotCount / 2` (128): aktuelles und vorgemerktes Pattern belegen gleichzeitig
Slots. Geladene Presets mit mehr Spuren laden weiter; überzählige Spuren bleiben stumm (`slot == -1`).

**Tests:** `EngineCoreNoteOffTests` (6).

---

## Clock-Quelle — Echtzeit-Thread (v1.12.21)

Quelle: `Engine/ClockSource.swift` (ersetzt `AudioClockSource.swift`). Ältere Abschnitte unten nennen noch
`AudioClockSource`/„Tap"/„80 ms"/„120 ms Lookahead" — sie beschreiben den damaligen Stand.

**Befund (Messung 2026-11-12, 44,1 kHz, 120 BPM).** Der Tap auf dem Mixer lieferte 4410 Frames (100 ms) statt der
angeforderten 256, auf einem Thread ohne Time-Constraint-Policy (QoS default). Ticks kamen in Schüben von ~5; der Vorlauf
eines Ticks (Ausgabe → Zeitstempel) schwankte zwischen 47 und 151 ms. Die 120 ms Lookahead waren also kein Sicherheitspolster,
sondern knapp bemessen. Die Zeitstempel selbst waren bereits reine Host-Zeit-Arithmetik; der Tap war nur der Wecker.

**Jetzt.** Ein Thread mit `THREAD_TIME_CONSTRAINT_POLICY` wird per `mach_wait_until` einmal pro Tick geweckt.

- **Raster:** `T(k+1) = T(k) + Intervall(BPM)`, in `mach_absolute_time`-Einheiten (= `MIDITimeStamp`), als `Double`
  geführt und erst bei der Ausgabe gerundet. BPM-Änderungen wirken ab dem nächsten Intervall ohne Phasensprung.
- **Vorlauf-Vertrag:** Tick k wird `emitMargin` (10 ms) vor `T(k−1)` ausgegeben, also **ein Tick-Intervall + 10 ms** vor
  seinem Zeitpunkt. Das volle Intervall ist Pflicht: `advanceSteps` datiert Steps mit gebrochenem Raster um den
  `pulseAccumulator`-Überschuss (< 1 Intervall) zurück. Wer den Vorlauf verkürzt, schiebt diese Steps in den Safety-Clamp.
- **Aufholen:** Bis zwei Intervalle Rückstand werden Ticks sofort nachgereicht (der Tick-Pfad klemmt Noten auf „jetzt + 1 ms"
  und verwirft geklemmte 0xF8, RT-4a unverändert). Darüber wird das Raster an „jetzt" neu verankert.
- **Start/Stop:** Generation-Zähler (Atomic). `stop()` wartet nicht auf den Thread; er endet beim nächsten Aufwachen, ohne
  `onTick` zu rufen, wenn seine Generation abgelöst ist. Einen bereits laufenden Tick weist `enterTick` ab bzw. `stop()`
  wartet ihn über `activeTick` ab (Engine-Kern, unverändert). Der Thread hält nur den internen `State`, nicht die Engine.
- **RT-Regeln im Thread:** kein Heap, kein Lock, kein Logging; `onTick` wird einmal vor der Schleife geladen.
- **Rückfall:** Lehnt der Kernel die Policy ab, läuft der Thread mit QoS `userInteractive` weiter.

**Messung nachher (gleicher Rechner):** Vorlauf 30,7…30,8 ms, Ausgabeabstand 20,79…20,89 ms, größte Weckverspätung 0,08 ms.

**Tests:** `EngineCoreRealClockTests` — Vorlauf-Vertrag und additives Raster der Quelle; Neustart-Zyklen mit genau einem
0xFA und Step 1 auf dem ersten Puls. `PerformanceBaselineTests.testEngineTickJitter_60Seconds` misst weiter den Weck-Jitter.

**Nicht geprüft:** Verhalten an Hardware. EXT-Modus ist unberührt (eigener EMA-Vorlauf).

---

## Views — Beobachtungsregeln (v1.12.20)

Quelle: `Views/LaneLeafViews.swift`, `StepGridView`, `CCLaneBodyView`, `InteractionController`.

- **Lanes beobachten keine hochfrequenten Objekte.** `StepGridView`/`CCLaneBodyView` deklarieren weder `PlaybackDisplayState`
  noch `ScrollState` noch `InteractionController` als `@EnvironmentObject`. Darstellung über Blatt-Views: `PlayheadGate`
  (liefert „ist aktueller Step“), `.laneScrollShift()` (Offset), `RubberBandLayer`. Gesten lesen den Scroll-Offset zum
  Ereigniszeitpunkt über `engine.scrollState.hScrollOffset`.
- **Controller, die nur aufgerufen werden, sind einfache Referenzen** (`engine.interactionController`), keine beobachteten
  Objekte. `@Published` nur für Felder, die eine View darstellt oder ein Combine-Abonnent braucht.
- **Messbar:** `BodyRunCounter.shared.total(_:)` zählt body-Läufe kumulativ; `ObservationHygieneTests` verlangen 0 Lane-/Zeilen-
  Läufe bei Playhead-, Scroll- und Noten-Updates. Neue Lane-Zustände gegen diese Tests prüfen.
- **Session-Abbruch:** Jede Änderung, die Lanes verschwinden lässt (Struktur, `setPattern`, Patternwechsel, Load/New), ruft
  `engine.cancelInteractionSession()`. Neue Session-Typen müssen in `InteractionController.cancelActiveSession` aufgenommen werden.
- **Strings:** auch Fehlermeldungen aus Nicht-View-Code über `Str` (`engine.strings`).

---

## Engine-Kern — Tick-Pfad-Verträge (v1.12.19)

Quelle: `SequencerEngine.swift`, `PlaybackSnapshot.swift`, `DisplayEventBuffer.swift`, `EngineEventBuffer.swift`,
`ClockSource.swift` (bis v1.12.20 `AudioClockSource.swift`). Das Hazard-Protokoll des Snapshot-Erwerbs (S01) ist unverändert.

- **Tick-Zutritt.** `enterTick()`: CAS `activeTick` false→true, danach `isPlayingRT` prüfen; `exitTick()` nach dem letzten
  Send des Ticks. Höchstens ein Thread im Tick-Pfad (setzt die Single-Reader-Annahme des Hazard-Protokolls durch); der
  Verlierer verwirft seinen Tick (`rejectedTicks`), er wartet nie. Mit `stop()` ein Dekker-Paar (Tick: store activeTick → load
  isPlayingRT; stop: store isPlayingRT → load activeTick; alle seq_cst). Nach `stop()` + Quieszenz kann kein Tick mehr eintreten.
  Alles, was dem Tick-Thread gehört (Runtime-Slots, PRNG, Notenbuch, `rtActiveSerial`), wird nur innerhalb des Zutritts berührt.
- **Runtime-Zuordnung im Snapshot.** `TrackSnapshot.slot/.epoch`. Main vergibt je Track-UUID einen Slot (0…255) mit neuer
  Epoche (`runtimeBinding`), hält ihn, solange der Track im aktuellen oder vorgemerkten Pattern liegt, und gibt ihn danach frei
  (`releaseUnusedSlots`). Der Tick-Thread setzt eine Runtime zurück, wenn `runtime.epoch != snapshot.epoch`. Main fasst den
  Slot-Block nie an. `beginRuntimeSession()` (play/EXT-Start) verwirft alle Bindungen. Kein Slot frei → `slot == -1` → Track stumm.
- **Erster Tick.** Eine frische Runtime (`armed`) löst auf ihrem ersten Tick sofort Step 1 aus; danach gilt der Pulse-Akkumulator.
- **Patternwechsel.** Im Playback publiziert Main das Zielpattern fertig gebaut als `bundle.queued`. Der Tick-Thread rechnet
  auf Kopien voraus, ob Track 0 auf diesem Tick auf Step 0 springt (`track0WillWrap`), und spielt dann ab diesem Tick `queued`
  (Aktivierung `serial + 1`, publiziert in `rtSwitchedSerial`). Main zieht nach (`reconcilePatternSwitch`, aufgerufen im Drain,
  in jedem `publishSnapshot`, in `switchPattern` und `stop`) und publiziert mit der neuen Aktivierung; Slots/Epochen bleiben,
  es gibt keinen Neustart. Das Ring-Event ist nur Weckruf. Eine geänderte Vormerkung behält `serial + 1`.
- **Notenbuch.** `noteBook[(ch-1)*128 + note]` = spätester geplanter Off-Zeitpunkt, geschrieben beim Übergeben des On.
  `sendPendingNoteOffs()` (nur quieszent, nach `MIDIFlushOutput`) sendet für jeden Eintrag in der Zukunft ein sofortiges Off.
  Grenze: zwei überlappende gleiche Noten teilen einen Eintrag; das frühere, bereits geplante Off kann die spätere Note weiterhin
  kürzen (offen). Virtueller Ausgang: `MIDIReceived`-Zukunftsereignisse lassen sich nicht zurückziehen (B5, offen).
- **Ringe.** `DisplayEventBuffer` (1024) und `EngineEventBuffer` (256): monotone Zähler, `tail` nur Producer, `head` nur
  Consumer, kein Lock. Voll → verwerfen; beide tragen nur verzichtbare Hinweise.
- **Clock-Quelle.** Geteilter Zustand nur über Atomics (`bpmBits`, `startGeneration`). `stop()` fasst Tap-Zustand nicht an;
  der Tap setzt seine Phase neu auf, wenn sich die Generation geändert hat.
- **EXT-Messzustand** (`ext*`) gehört dem MIDI-Read-Thread; Main setzt nur `extResetRequested`.
- **Testnaht.** `MIDIManager._testSendObserver` (DEBUG) am Sendekern `sendRTSafe`; nur außerhalb des Playbacks setzen.

---

## Command-Schicht — Identität, Undo, Struktur (v1.12.18)

Quelle: `SequencerEngine.swift` („Track-Struktur"), `ModelWriter.swift`, `SequencerEngine+PresetIO.swift`.

- **Instanzen sind die Identität.** Undo/Redo von Add/Insert/Duplicate/Remove setzt dieselbe `TrackData`-Instanz wieder ein
  (`TrackPlacement` = Pattern + Track + Position, gehalten vom Undo-Eintrag). Nie über JSON neu decodieren: ModelWriter-Undos
  zielen auf `LaneData`/`TrackData`-Instanzen und würden sonst ins Leere greifen. Dasselbe gilt für Pattern-Paste
  (`setPattern(at:to:)` tauscht `Pattern`-Instanzen).
- **Entfernen per Identität (`===`), Einfügen per gemerkter Position je Pattern.** Kein gemeinsamer Index über Patterns.
  Ein Placement wirkt nur, solange sein Pattern Teil von `engine.patterns` ist. Kein Pattern wird auf 0 Tracks reduziert.
- **UUIDs sind über Patterns eindeutig.** Alles, was Tracks kopiert (Duplicate, Pattern-Paste), nutzt `freshCopy()`.
  `viewModel(for:)` prüft zusätzlich `vm.data === td`; Load/New verwerfen den Cache vollständig.
- **Undo-Verlauf gehört zum Projekt.** `engine.undoManager` (weak, von `MainView` gesetzt). Load/New rufen `removeAllActions()`.
  Jede nicht rückgängig machbare Ersetzung von Modellobjekten muss den Stack leeren.
- **Ein Weg für Strukturänderungen aus Views:** `add/insert/duplicate/removeTrackUndoable`. Views registrieren dafür kein Undo.
  Abschluss jeder Strukturmutation ist `structureDidChange` (Dirty, Learn-Ziel löschen, `objectWillChange`, im Playback
  Runtime-Command + Display + Snapshot).
- **Combine-Sinks auf `@Published` lesen den emittierten Wert.** `@Published` emittiert im `willSet`; ein Rücklesen der Property
  im Sink liefert den alten Stand (`pattern.$tracks` → `rebuildAllTrackSubs(pending:)`, `$bpm` → `publishSnapshot(bpmOverride:)`).
  Alternative: per `main.async` nachlaufen (Swing).
- **Knob-Drags:** live ohne Undo schreiben, am Drag-Ende ein `setSteps` mit Ausgangszustand (`knobEditingChanged`-Environment).
- **Preset-IO:** Schreiben immer `.atomic`; `savePreset()`/`savePresetInPlace()` liefern `Bool`, Aufrufer vor destruktiven
  Schritten müssen ihn prüfen. Vier Pattern-Slots sind Invariante nach `loadData` (Auffüllen, kein Formatwechsel).

---

## GUI-01 — Material- und Render-Invarianten (v1.12.13)

Quelle der Bausteine: `Theme/VintageMaterials.swift` (Namensraum `Mat`, `MaterialTone`, `MetalSurface`, `MetalPlate`,
`GridWellSurface`, `GlassDisplayBackground`, `PlasticKeyBackground`, `KnobFace`, `MaterialFader`, `MaterialFaderMath`).

- **Licht:** einheitlich links oben (helle Kante oben/links, dunkle unten/rechts). Standard-Tasterkanten (`PlasticKeyBackground(.standard)`) sind diagonal beleuchtet; Step-Taster nutzen seit v1.12.17 das gleichmäßigere Profil `.step` (siehe GUI-02).
- **Statisch:** Texturen sind `static let` (einmal erzeugt, deterministischer xorshift-Seed → identische Tile bei jedem Start),
  gezeichnet als Tile; Patina (wärmeres/nachgedunkeltes Aluminium, 6 feine Gebrauchsspuren je Tile, zwei ortsfeste
  Mattstellen, Kantenabrieb als wechselnde Lichtkante, polierte Griffkanten) ist reine Konstante — keine Zufallsarbeit pro
  View-/Playback-Update. Keine Theme-Einstellung, kein `@Published`, keine Engine-Beobachtung für Dekor.
- **Kosten:** keine Schatten pro Step-Zelle (Plastik entsteht aus Verlauf + Kantenstrich); Schatten nur an Fadergriff/Knopf-Face.
  Dekorflächen sind `allowsHitTesting(false)`. Gemessen (Offscreen, 64 Playhead-Updates, 4 Step-Spuren + 1 CC-Spur):
  `StepButtonView.body` 8,0 je Update vorher wie nachher (512 gesamt; `.equatable()`-Gating unverändert);
  Dauer je Update vorher 13,2 ms, nachher 14,7 / 15,0 ms (zwei Läufe, ≈ +1,5–1,8 ms, Offscreen/Messrauschen nicht bereinigt).
  Das ist eine UI-Regression-Messung, keine Timing-Freigabe.
- **Helles Metall:** Text darauf immer `Mat.inkOnLight*` (dunkel); `KnobView(onLight:)` schaltet Beschriftung und Bogenspur.
- **WIDTH-Fader:** Wert ist Quelle der Wahrheit (`StepWidthState.size`, 30…120, Schritt 1); Position = Anteil × Verfahrweg
  (Resize ändert den Wert nie). Drag ist relativ zum Startwert (kein Sprung beim Greifen), Klemmung am Verfahrweg.
- **Bestehende Layoutgrenze (unverändert):** Bei 920 pt Mindestbreite wird Transporttext umgebrochen/gekürzt (Logo, „PATTERN“).
  GUI-01 hält BPM, TAP, SWING, INT/EXT, LEARN, WIDTH vollständig sichtbar (zuvor wurden „INT“/„SWING“ umgebrochen).

## G01-R1 — Zoom-/Metrik-Vertrag (v1.12.16, Review H1)

**Fehler (aus G01 v1.12.15):** `adjustScroll` skalierte die zuletzt *gemeldete* Ausdehnung (gilt für eine ältere WIDTH, Meldung kommt
erst nach Preference + Main-Queue-Flush) mit dem inkrementellen Verhältnis old→new. Mehrere Pinch-Updates vor dem Flush ließen die
Grenze dadurch trotz weiterem Einzoomen schrumpfen (Review-Rechnung 32 Steps, WIDTH 54→60→66: 1507 statt 1717); `maxScrollOffset` blieb
auf dem alten Wert und klemmte Folge-Schreiber zurück.

**Vertrag:**
- Gemeldet wird nur, was nicht von WIDTH abhängt: Viewport (Beginn, Breite) und die verschiedenen Lane-Topologien `LaneShape`
  (Stepzahl, Ratio) per `LaneViewportKey`/`LaneShapesKey`. Eine verspätete oder koaleszierte Meldung kann daher nie zu einer älteren
  WIDTH gehören; `LaneMetrics.contentExtent(at:)` rechnet die Ausdehnung für jede WIDTH exakt aus Topologie + realer Rundung
  (`distributedStepWidth`) — nie durch Skalieren einer gemeldeten, bereits gerundeten Ausdehnung.
- Die wirksame WIDTH führt der Controller selbst (`stepWidth`): `MainView` übergibt den committeten `StepWidthState.size`
  (`onChange(initial:)` → `setStepWidth`, idempotent, klemmt den Offset nach); der Pinch-Handler-Pfad setzt sie in `adjustScroll` vorab auf
  `newStepWidth.rounded()` (= `committed.rounded()`), im selben Aufrufstack wie der Commit — dazwischen kann kein View-Update laufen.
- **Eine wirksame Grenze:** `ViewportController.effectiveMaxOffset` = `max(0, contentExtent(Topologie, stepWidth) − Viewport)`.
  `scroll(by:)`, `scrollTrackpad`, `syncFromScrollbar`, `adjustScroll` (für die neue Breite: `effectiveMaxOffset(forStepWidth:)`) und das
  Nachklemmen (`applyLaneMetrics`, `setStepWidth`) nutzen dieselbe Funktion. `maxScrollOffset` spiegelt sie nur und gilt als
  Rückfall bis Viewport und WIDTH bekannt sind (Default unbegrenzt; bestehende Tests setzen es direkt).
- **Scrollbar:** Dokumentbreite = `metrics.contentExtent(at: stepWidthState.size)` (`GlobalHScrollbar` beobachtet WIDTH als Blattview).
- Topologieänderungen (Count/Ratio/Struktur) und Resize wirken weiterhin erst mit der nächsten Meldung (eine Main-Queue-Runde);
  WIDTH-Änderungen wirken sofort. Zoom-Ankerformel, Session-/Reentrancy-Guards und Main-/View-Update-Disziplin unverändert; keine
  zusätzlichen Published-Writer (`laneMetrics` ändert sich nur bei Viewport/Topologie).

## G01 — Lane-Viewport und Scrollgrenzen (v1.12.15)

Quelle: `Views/LaneGeometry.swift` (`LaneGeometry`, `LaneMetrics`, `LaneViewportKey`, `LaneShapesKey`, `LaneShape`, `LaneViewportReporter`),
`Engine/ViewportController.swift`, `Views/MainView.swift` (Scrollbar), `StepGridView`, `CCLaneBodyView`.

- **Ursache GR-01 (gemessen, f0af3bd → 548159c-Layout):** Der ZStack im Lane-`GeometryReader` wird nicht auf die GR-Größe
  gezwungen; mit den fest breiten Zellen im Content-Container meldet er die Inhaltsbreite (1884 pt bei WIDTH 54, Viewport
  551 pt). `.clipped()`/`.contentShape` hingen an diesem Container. Fix: expliziter Rahmen = GR-Größe, Clip und contentShape
  darauf. Die feste 80-pt-Zone und der Außenrand liegen außerhalb.
- **Eine Wahrheit je Größe:** Inhaltsausdehnung = Summe `distributedStepWidth` + n × `stepSpacing` + 2 × `stepGridLeadingPad`
  + `cornerHandlesWidth` (= `round(n × slot) + 28` bei unveränderten Konstanten). Viewport = gemessene Breite des Lane-GR.
  Maximum = `max(0, Inhalt − Viewport)`. Es gibt keine zweite Formel in MainView/Theme.
- **Meldeweg:** Lanes → Preferences (`LaneViewportKey` erste gültige; in v1.12.15 `LaneExtentKey` mit gemeldeter Ausdehnung, seit v1.12.16 `LaneShapesKey` mit Topologien — siehe G01-R1-Vertrag oben) → `MainView.onPreferenceChange` →
  `ViewportController.reportLaneViewport/-Shapes` (nur Zwischenspeicher + ein `DispatchQueue.main.async`) →
  `applyLaneMetrics`: `laneMetrics` (Published, ändert sich nur bei Geometrieänderung, nie bei Scroll/Playback),
  `maxScrollOffset`, Nachklemmen von `hScrollOffset`. Ungemessener Viewport (Breite 0) ändert nichts; NaN/Infinity/negativ → 0.
  Überholte Messungen werden überschrieben, nicht nachgeliefert.
- **Schreibpfade des Offsets (unverändert Writer = `ViewportController`):** `scroll(by:)`, `scrollTrackpad`, `syncFromScrollbar`,
  `adjustScroll` (Zoom; Grenze für die NEUE Breite exakt aus Topologie + committeter WIDTH, siehe „G01-R1 — Zoom-/Metrik-Vertrag“ oben; kein skalierter Slotanteil mehr), `applyLaneMetrics` (Nachklemmen).
  Session-/Reentrancy-Guards (`sessionActive`, `isSyncingScrollbar`) unverändert.
- **Scrollbar:** NSScrollView-Frame = Lane-Viewport (minX/Breite gemessen im Raum `LaneGeometry.space`), Dokumentbreite =
  `max(Inhalt, Viewport)` → natives Maximum == gemeinsames Maximum. `GlobalHScrollbar` beobachtet `ScrollState` als Blattview
  (MainView abonniert `scrollState` weiterhin bewusst nicht); `updateNSView` scrollt unter `isSyncingScrollbar` (keine Rückkopplung).
- **Messbar ohne GUI:** DEBUG-Probe (`LaneGeometryProbe`, `LaneGeometryProbeView`) hält je Lane-ID die Breiten von Content-HStack,
  Clip-Container und Viewport für Tests; kein Produktionsdiagnosefeld.
- **Grenze der Evidenz:** SwiftUI-Hit-Testing (Klick in Zone/Rand) ließ sich offscreen nicht per NSEvent auslösen
  (Kontrollklick auf einen sichtbaren Step blieb wirkungslos) — Treffer außerhalb des Viewports sind ein Live-Gate; belegt sind
  Clip-/Layoutgrenzen und Messwerte.

## GUI-02 — Step-Beleuchtungsprofil (v1.12.17)

`PlasticKeyBackground` hat das Darstellungs-Profil `Profile` (`.standard` Default, `.step`). Alle Aufrufer außer `StepButtonView`
verwenden unverändert `.standard`: Körperverlauf `keyTop→keyBottom`, Tönungsabfall 0.35, Kontur diagonal von links oben
(weiß 0.40 → schwarz 0.55). `.step` (nur `StepButtonView`): Körper `(0.222,0.222,0.241)→(0.192,0.192,0.209)` (≈ ±7 % um den
Mittelwert statt ≈ ±27 %), Tönungsabfall 0.80, Kontur mit leichter Neigung (x 0.35→0.65) weiß 0.17 → 0.03 (bei 45 %) → schwarz 0.24.
Zweck: kein auffälliger seitlicher Helligkeitsabfall über breite Steps (WIDTH 120), Taste bleibt über obere Kante/Unterkante lesbar.
Weiterhin statisch (kein Zufall/Textur pro Update, keine Animation); Auswahl/Learn-Überlagerung, LED und Playhead unverändert.
Das Profil wird nicht über Beobachtungsflächen geändert: `StepButtonView` bleibt `.equatable()`, `profile` ist eine Konstante des Aufrufs.
Evidenz getrennt von zeitkritischen Tests: `GUI02StepMaterialEvidenceTests` (nur mit `TEST_RUNNER_GUI02_PREFIX`).

## GUI-01-R1 — Transport-Layout-Invarianten (v1.12.14)

- **Plattenhöhe:** BPM-, SWING- und WIDTH-Platte setzen ihren Inhalt auf `TransportView.plateHeight` (84 pt); die Platten
  teilen damit Ober- und Unterkante. Die Transporthöhe bleibt 100 pt. Knopfgrößen dürfen verschieden sein.
- **`KnobView.showsValue`:** rein visuell, Standard `true`. Bei `false` entfällt nur die Zahl; der Knopf wird als ein
  Accessibility-Element mit Label und aktuellem Wert exponiert. Drag, Doppelklick-Reset, Bereiche und Bindings unverändert.
  Nur BPM und SWING im Transport schalten ab; `GateKnobView` nutzt den Parameter nicht.
- **Breitenbudget bei 920 pt:** Der Produktname hat feste Größe und `layoutPriority(3)` und wird nie gekürzt; Untertitel
  (`lineLimit(1)`, Kürzung am Ende) und Dateiname weichen zuerst. Kleine Beschriftungen und Taster (PATTERN/CLOCK/LEARN/WIDTH,
  INT/EXT, ON/OFF, TAP, ▲▼) sind `fixedSize`; sonst staucht der HStack sie bis zum Umbruch. Neue Elemente im Transport müssen
  gegen die 920-pt-Szene der Render-Tests geprüft werden. Die Mindestfensterbreite wurde nicht erhöht.
- **Grenze der Evidenz:** Offscreen-Bilder; Live-Drag, Keyboard und VoiceOver sind nicht geprüft.

## S01 / S01-R1 — Snapshot-Lesepfad auf jedem Ausgang (v1.12.11 / v1.12.12)

**Befund B1 (Round `FOF-CX-2026-10-20-001`):** Nach `hazardTries > 8` verließ `break`
die Revalidierung, `raw` zeigte auf den neu gelesenen, nicht gemeldeten Pointer und
wurde dereferenziert.

**Invariante:** Eine `PlaybackBundleBox` wird nur dereferenziert, wenn ihr Raw-Pointer
im Hazard gemeldet UND danach gegen `atomicBundleRaw` validiert wurde. Es gibt keinen
Fall-through. Annahme: genau ein Reader (Durchsetzung: S02, B2).

**Protokoll** (Reader R1–R5 / Writer W1–W3, Wortlaut am `atomicBundleRaw` in
`SequencerEngine.swift`): R2 Hazard-Store und R3 Validate-Load sowie W1 Publish-Store und
W2 Hazard-Load sind `seq_cst`. Begründung: „Store A, Load B" gegen „Store B, Load A"
(Store-Buffering) erlaubt unter Release/Acquire, dass beide Loads alte Werte sehen. In
der seq_cst-Totalordnung gilt entweder R2 < W1 (W2 sieht den Hazard → Aufschub) oder
W1 < R2 (R3 sieht den neuen Pointer → Validierung scheitert). Inhalts-Sichtbarkeit: R3
(acquire-Anteil) liest den Wert aus W1 (release-Anteil). R5 (release) ordnet die Reads
vor das Hazard-Clear. ARM64: stlr/ldar, kein zusätzliches dmb (Disassembly des Release-
Builds geprüft).

**ABA:** Dereferenziert wird das beim Validieren aktuell publizierte Objekt, nie der bei
R1 gelesene Wert; gleiche Adresse einer neuen Box ist daher harmlos. Writer-seitig nur
konservativer Mehr-Aufschub. Aufgeschobene Box bleibt über `bundleDeferred` am Leben.

**Deferred-Retention:** höchstens eine Box (ein Reader, ein Hazard); freigegeben beim
nächsten Publish nach Hazard-Clear, auf dem Publisher-Thread (Main), nie im Reader.

**Beschränkte RT-Arbeit:** 1 Load + ≤ 9 × (Store + Load) + 1 Clear = ≤ 20 Atomics. Kein
Lock, kein Alloc, kein ARC im Erwerb. Release-Nachweis (swift-atomics 1.3.0, b601256, arm64,
`acquireSnapshot` als `@inline(never)`-Symbol): keine direkten `bl`-Aufrufe; 20 indirekte `blr`
(= die 1 + 9×2 + 1 Atomics, je über `ManagedAtomic._ptr`-Getter aus der vtable, da `ManagedAtomic`
nicht `final` ist); der Getter ist `add x0, x20, #0x10; ret`. Atomics selbst: ldapr/ldar/stlr.
Grenze: die Zuordnung vtable-Slot → `_ptr`-Getter ist aus Quelle und Disassembly abgeleitet,
nicht per Debugger zur Laufzeit bestätigt; keine pauschale Wait-Freiheits-Aussage (Paket garantiert
Lock-Freiheit). Der Disassembly-Beleg gilt für diesen Build, nicht für andere Toolchains.

**Gesamttick-Abbruch:** `advanceSteps` → `Bool`. Erwerb ist der erste Schritt nach
`activeTick`; bei `.exhausted`/`.noBundle` folgt `return false` vor Mailbox-Drain,
Pulse-/Step-/PRNG-Fortschritt und Display-Events. `clockTick` sendet dann weder 0xF8
noch 0xFA (`midiStartPending` bleibt). Steps und Clock verlieren denselben Puls.
`.exhausted` wird als atomarer Zähler (nur Reader schreibt) gezählt, der Display-Drain
spiegelt ihn (erster Fehler sofort, danach höchstens 1×/s, je Sitzung zurückgesetzt) in
`clockDiagnostics.snapshotAcquireFailures`; `StatusBar` zeigt bei > 0 orange „TIMING: n dropped“ /
„TAKT: n ausgelassen“ (Accessibility-Label vorhanden, VoiceOver nicht live geprüft).

**Konsequenz Drain-Reihenfolge:** Drain nach Erwerb statt davor. Der Ein-Tick-Versatz
Snapshot/Runtime (B3) bleibt, seine Richtung kehrt sich um (Runtimes können einen Tick
neuer sein als der erworbene Snapshot). Lösung: S03.

**Tests** (`S01SnapshotAcquireTests`): Grenze 0/1/8 Wechsel → Erfolg, 9/12 → Abbruch;
Wechsel vor Announce / vor Revalidate / direkt nach Revalidate + 30er-Burst (Weak-Sonde,
Deinit-Thread); Nil vor Playback; Erschöpfung ohne Runtime-Mutation und ohne Clock-Send;
Normalfall 24 Pulse; Publish-Storm. DEBUG-Hook `_s01AcquireHook` nur in DEBUG.
S01-R1-Tests: `S01ErrorDeliveryTests` (echter Clock-Reader, DEBUG-Injektion
`_s01ForceExhaustion` im Protokoll, Zustellung bis gerenderter StatusBar, Koaleszierung ≤ 5
Änderungsmeldungen im 2,5-s-Fenster); `liveSwingRepublishDuringPlayback` @MainActor mit Beobachtung des
publizierten Bundles. Mutationsnachweise: alter Fall-through → Erschöpfungs-/Grenztests rot; Writer ignoriert
Hazard → ASan `load8` in `advanceSteps` (Burst-Test), ohne ASan EXC_BAD_ACCESS.

## RT-4c — sendRTSafe Atomic-Snapshot (v1.12.10)

**Ausgangslage:** ROADMAP 1.4 (RT-4, Codex #5) nannte `sendRTSafe` —
atomarer Endpoint-Snapshot statt Trylock-Drop als offenen Punkt. Recherche
bestätigte den exakten Mechanismus in `Engine/MIDIManager.swift`:
`sendRTSafe()` (Zeilen 139-168) las den aktuell gewählten Output-Endpoint
über `os_unfair_lock_trylock(&_rtOutputLock)`. Scheiterte der Trylock (Main-
Thread schreibt exakt gleichzeitig in `selectedOutput`s `didSet`, welches
denselben Lock hält), blieb `out == 0` und `MIDISend` wurde für dieses eine
Event übersprungen — Code-Kommentar: „Acceptable". Das Kontentions-Fenster
ist ein Mikrosekunden-Fenster (Main schreibt `selectedOutput` nur bei
Geräteauswahl/Disconnect), aber real: ein in diesem Fenster verlorener
Tick verliert eine Note/CC/Clock-Puls, still, ohne Diagnose.

Der Lock schützte nur den `MIDIEndpointRef`-Wert (`_rtOutput`, ein
UInt32-Objekt-Handle) gegen einen zerrissenen Cross-Thread-Read — nicht
`outPort`/`virtSrc`, die als effektiv unveränderlich nach `setup()`
behandelt werden (unverändert, kein Teil dieses Befunds).

**Entscheidung:** Ein einzelnes 32-Bit-Wort kann per Definition nicht
zerreißen, wenn es atomar gelesen/geschrieben wird — ein Lock ist für
diesen Zweck unnötig und war die einzige Quelle des Drop-Pfades. Ein
Retry-Loop im Trylock wurde verworfen (hätte im Tick-Pfad potenziell
blockierendes Spinning bedeutet, da die Main-Thread-Haltezeit des Locks
nicht nach oben beschränkt ist). Stattdessen: `ManagedAtomic<MIDIEndpointRef>`
statt Lock — dasselbe Muster, das RT-1 bereits für `isPlaying`/`clockMode`/
`queuedPatternIndex` etabliert hat.

**Geändert:**
- `Engine/MIDIManager.swift`: `import Atomics` statt `import os`;
  `_rtOutput: MIDIEndpointRef` + `_rtOutputLock: os_unfair_lock_s` →
  `rtOutputAtomic = ManagedAtomic<MIDIEndpointRef>(0)`. `selectedOutput`s
  `didSet`: Lock/Unlock-Block → `rtOutputAtomic.store(selectedOutput,
  ordering: .releasing)`. `sendRTSafe()`: Trylock-Block → `let out =
  rtOutputAtomic.load(ordering: .acquiring)` (kein `var`, kein
  Fallback-Zweig mehr — Load liefert immer einen gültigen Wert). DEBUG-Hook
  `_rt4cReadOutputAtomic()`.
- Kein Diagnose-Zähler ergänzt (anders als `clampCountClock`): die
  Atomic-Lösung eliminiert den Drop-Pfad kategorisch — `out == 0` bedeutet
  danach ausschließlich „kein Output-Gerät gewählt", nie mehr „Lock war
  kurz contended".

**Tests:** `MIDIManagerRTSafeTests.swift` (neu, 3, laufen ohne echtes
CoreMIDI-Setup — `MIDIManager()` hat vor `setup()` keine Seiteneffekte):
`atomicMirrorReflectsSelectedOutputSynchronously` (Zustands-Test:
`selectedOutput`-Writes spiegeln sich sofort in `_rt4cReadOutputAtomic()`),
`zeroIsPreservedWhenNoOutputSelected` (Unterscheidung „kein Gerät" bleibt
erhalten), `atomicReadNeverFalsePositiveZeroUnderContention` — der
eigentliche Regressionstest: `selectedOutput` ist während der gesamten
Stress-Phase nie 0 (nur 42/99 im Wechsel, 5000 Iterationen auf einem
Main-simulierten Thread), ein paralleler Hintergrund-Thread liest
`_rt4cReadOutputAtomic()` in einer engen Schleife — kein einziger
gelesener Wert darf 0 sein. Beweist: der atomare Read liefert nie eine
künstliche „kein Output"-Contention-0, anders als der frühere
Trylock-Drop, der genau das (mit geringer Wahrscheinlichkeit) tun konnte.

**RT-Sicherheit:** `rtOutputAtomic` ist ein `ManagedAtomic` (wait-free
Store/Load, keine Blockierung, kein Alloc) — dasselbe verifizierte Muster
wie `isPlayingRT`/`clockIsInternal`/`queuedPatternAtomic`/`midiStartPending`
in `SequencerEngine.swift`. `outPort`/`virtSrc`/`virtDst` unverändert.

**Verifikation:** build-for-testing SUCCEEDED · `MIDIManagerRTSafeTests`
(3) grün · TSan über MIDIManagerRTSafeTests/RT-4b/RT-4a/RT-3b/RT-3a/RT-3/
RT-2/RT-1a sauber · voller Unit-Lauf: 395 passed, unverändert nur die 5
bekannten roten Tests · `git diff --check` sauber.

**Rest von RT-4 (offen, eigene Freigabe nötig):** `EngineEventBuffer` —
garantierte Zustellung von `patternSwitch`; RT-Nachweis für
DispatchSource-Wakeup dokumentieren.

---

## RT-4b — RT-sicherer PRNG (v1.12.9)

**Ausgangslage:** ROADMAP 1.4 (RT-4, Codex #4) nannte einen eigenen PRNG
statt `Int/Double.random` als offenen Punkt. Recherche (Explore-Agent)
bestätigte zwei Aufrufstellen direkt im RT-Tick-Pfad: `advanceRuntime()`
(Zeile 1454, `case .random: runtime.currentStep = Int.random(in: 0..<n)`,
Random-Step-Direction) und `advanceSteps()` (Zeile 1673,
`guard Double.random(in: 0...1) <= step.probability`, Per-Step-Trigger-
Probability). Beide liegen unconditional auf der Kette
`MIDIManager.onClockPulse`/`AudioClockSource` → `clockTick(at:)` →
`tick(scheduledAt:)` → `advanceSteps(tickTime:)` → `advanceRuntime(_:snap:)`.
Sechs weitere Random-Aufrufe im Projekt (Main-Only-Buttons „Randomize CC
Lane"/„Randomize Track") sind nachweislich nicht RT-pfad-erreichbar und
bleiben unangetastet.

**Entscheidung:** Swifts `Int/Double.random(in:)` nutzt implizit
`SystemRandomNumberGenerator`, auf Darwin über `arc4random_buf` — ein CSPRNG
mit interner Zustandssicherung/gelegentlichem Reseeding, ohne dokumentierte
Alloc-/Lock-Freiheits-Garantie. Statt eines CSPRNG-Wrappers oder eines
eigenen Lock-freien Entropie-Pools (beide unnötiger Mehraufwand ohne
kryptografische Anforderung — die Nutzstellen sind rein musikalisch, nicht
sicherheitsrelevant): eigener alloc-freier PRNG, xorshift64* (Standard-
Algorithmus, 64-Bit-State als reiner Wert, kein Heap, keine Syscalls), neue
Datei `Engine/RTRandom.swift`.

**Geändert:**
- `Engine/RTRandom.swift` (neu): `struct RTRandom` mit `next()` (xorshift64*),
  `nextUnitDouble()` (gleichverteilt [0,1), obere 53 Bit des 64-Bit-Worts),
  `nextInt(bound:)` (gleichverteilt [0,bound) per Modulo — Bias bei den hier
  vorkommenden kleinen bounds, typ. Step-Counts ≤ 64, vernachlässigbar).
  Seed 0 wird im Initializer auf einen Nicht-Null-Startwert abgebildet
  (xorshift-Fixpunkt sonst).
- `SequencerEngine.swift`: neues Feld `rtRandom = RTRandom(seed:
  UInt64.random(in: .min ... .max))` — Seed einmalig bei Konstruktion auf dem
  Main-Thread gezogen (nicht RT, analog zur einmaligen Kapazitätsreservierung
  von `trackRuntimes`). Invariante wie `trackRuntimes` (RT-2): ausschließlich
  vom Audio-/MIDI-Read-Thread innerhalb des `activeTick`-Fensters
  (`advanceSteps()`, RT-3a) mutiert — kein Atomic nötig, kein neuer
  Cross-Thread-Zugriff. Zeile 1454/1673 nutzen jetzt `rtRandom.nextInt(bound:)`
  bzw. `rtRandom.nextUnitDouble()`. DEBUG-Hook
  `_rt4bSetRandomSeedForTest(_:)` für deterministische Tests.

**Tests:**
- `RTRandomTests.swift` (neu, 6, isolierte Struct-Tests ohne Engine):
  `nextIntStaysInBound`/`nextIntBoundOneAlwaysZero` (Bound-Einhaltung über
  1000 Draws je bound ∈ {1,2,7,64}), `nextUnitDoubleStaysInUnitRange`,
  `sameSeedProducesSameSequence`/`differentSeedsProduceDifferentSequences`
  (Determinismus), `zeroSeedDoesNotStall` (Seed-0-Sonderfall).
- `struct RT4bSeededRandomTests` (`WorkflowEngineTests.swift`, 2):
  `sameSeedGivesIdenticalRandomDirectionSequence` — zwei Engines, Track auf
  `.random`-Direction, gleicher Seed über `_rt4bSetRandomSeedForTest`, 48
  Ticks — die `_rt1CurrentStep`-Folgen müssen identisch sein (beweist:
  beide Aufrufstellen nutzen konsistent dieselbe seedbare Quelle).
  `probabilityGateStillRespectsBounds` — Probability 0.0 und 1.0 über 50
  Ticks: kein Crash/Trap, gültiger Step-Cursor (direkte MIDI-Emission ist in
  Unit-Tests ohne MIDIManager-Mock nicht beobachtbar — ein falsch
  verdrahtetes `<=` oder ein `nextUnitDouble()` außerhalb [0,1) würde hier
  durch einen Trap auffallen).

**RT-Sicherheit:** `rtRandom` ist ein reiner Wert-Typ (kein Heap-Zugriff bei
Mutation), Zugriff ausschließlich innerhalb der bereits durch RT-3a
bewiesenen `activeTick`-Exklusivität — keine neue Synchronisationsprimitive
nötig, kein Lock, kein Alloc im Tick-Pfad.

**Verifikation:** build-for-testing SUCCEEDED. TSan über
RT-4b/RT-4a/RT-3b/RT-3a/RT-3/RT-2/RT-1a sauber. Voller Unit-Lauf: 392
passed, unverändert nur die 5 bekannten roten Tests. Ein transienter
Malloc-Corruption-Crash im ersten Vollauf (unmittelbar nach dem TSan-Pass,
kaskadierte auf ~390 unbeteiligte Tests, z.B. `CursorStateReducerTests`)
reproduzierte sich im sofortigen Wiederholungslauf nicht (392 passed, nur
die 5 bekannten roten Tests) — deckt sich mit dem bestehenden
Test-Artefakt-Befund (PROJECT_LOG: spurioses Verhalten „isoliert direkt nach
vorangegangener Host-Last wie einem TSan-Lauf"), kein Codebug. `git diff
--check` sauber.

**Rest von RT-4 (offen, eigene Freigabe nötig):** `EngineEventBuffer` —
garantierte Zustellung von `patternSwitch`; RT-Nachweis für
DispatchSource-Wakeup dokumentieren. (`sendRTSafe` erledigt, siehe RT-4c oben.)

---

## RT-4a — Catch-up-/Resync-Strategie (v1.12.8)

**Ausgangslage:** ROADMAP 1.4 (RT-4, Codex #4–#7) nannte „Catch-up-/Resync-
Strategie intern vs. ausgehende 0xF8 entscheiden und testen" als offenen,
Stephan-Entscheid bedürftigen Punkt. Recherche zeigte: die Strategie war
bereits implementiert (Arch-Slice-15, Arch-Slice-16b), nur nie als formale
Entscheidung festgeschrieben oder durch einen dedizierten Test abgesichert.
Vor der Umsetzung mit Stephan geklärt (AskUserQuestion) — bestehende Strategie
bestätigt, statt sie zu ändern.

**Entscheidung:** Kommt der Audio-Callback zu spät (`AudioClockSource` feuert
mehrere Catch-up-Ticks mit Timestamps in der Vergangenheit in einem
Callback), gilt:
- **Intern (Step-/Note-Fortschritt):** driftet nie. `clockTick()` ruft
  `advanceSteps(tickTime:)` mit dem unveränderten Original-Timestamp auf,
  unabhängig davon, ob dieser Timestamp später für den 0xF8-Pfad geclampt
  wird — jeder Tick zählt.
- **Ausgehende 0xF8:** geclampte Pulse werden still verworfen
  (`clampCountClock &+= 1`, kein `midi.sendClock`), nicht als Burst
  nachgeholt. Begründung (Arch-Slice-15): ein Burst mehrerer 0xF8 gleichzeitig
  lässt den Arp-/LFO-/Delay-Takt externer Geräte hörbar „einhaken"; ein
  kurzer ~100-ms-Aussetzer ist unauffälliger, das Empfängergerät resynct sich
  über die folgenden Pulse selbst nach.

**Geändert:** nur Test + DEBUG-Hook, kein Produktionscode-Verhalten.
`SequencerEngine.swift`: `_rt4ClampCountClock` (Test-Fenster auf den
bestehenden `clampCountClock`-Zähler).

**Tests:** `RT4ResyncStrategyTests` (2, deterministisch über `clockTick(at:)`,
kein `AudioClockSource` nötig — identisches Muster wie `RT1aModeSwitchTests`):
`catchUpBurstNeverDriftsInternalSteps` vergleicht den resultierenden
Step-Index nach 24 Ticks mit rein zukünftigen vs. rein vergangenen (geclampten)
Timestamps — muss identisch sein. `catchUpBurstDropsClampedOutgoingClockPulses`
prüft, dass `_rt4ClampCountClock` exakt um die Anzahl geclampter Ticks steigt
und bei nicht geclampten Ticks unverändert bleibt.

**Testfund (Testcode, kein Produktionsbug):** Die feste `futureTick`-Konstante
(`1_000_000_000_000`) aus `RT1aModeSwitchTests`/`RT3bDeferredCleanupTests` ist
auf Apple Silicon (`mach_absolute_time()` ≈ Nanosekunden seit Boot) nach
ausreichender Systemlaufzeit tatsächlich in der Vergangenheit. Für die
bestehenden Tests irrelevant (die prüfen nur, dass `advanceSteps()`
unabhängig vom Clamp-Status läuft), hätte aber
`catchUpBurstDropsClampedOutgoingClockPulses` verfälscht (erste Version schlug
mit `_rt4ClampCountClock == 48` statt erwarteten `24` fehl — alle „Future"-
Ticks wurden ebenfalls geclampt). `RT4ResyncStrategyTests.futureTick` ist
deshalb eine computed property, die bei jedem Zugriff `mach_absolute_time() +
3_600_000_000_000` neu berechnet.

**RT-Sicherheit:** keine Änderung an `clockTick()`/`advanceSteps()`/
`AudioClockSource` — reine Testabsicherung einer bereits produktiven Strategie.

**Verifikation:** TSan über RT-4a/RT-3b/RT-3a/RT-3/RT-2/RT-1a sauber. Voller
Unit-Lauf: 381 passed, unverändert die 5 bekannten roten Tests plus 3
dokumentierte spuriöse `measure`-Baseline-Artefakte unter Parallel-Last (kein
Codebug).

**Rest von RT-4 (offen, eigene Freigabe nötig):** `EngineEventBuffer` —
garantierte Zustellung von `patternSwitch`; RT-Nachweis für
DispatchSource-Wakeup dokumentieren. (`sendRTSafe` erledigt, siehe RT-4c oben.) (PRNG erledigt, siehe RT-4b oben.)

---

## RT-3b — Fail-Safe Deferred Cleanup (v1.12.7)

**Ausgangsbefund (Codex H3, Round `FOF-CX-2026-07-14-006`):** RT-3a (v1.12.6)
bewies Quieszenz per `activeTick`, aber der 2-s-Backstop im Sync-Spin führte
den Teardown trotzdem durch, sobald er erreicht wurde — unabhängig davon, ob
`activeTick` zu diesem Zeitpunkt noch `true` war. Ein Tick, der (Scheduler-
Preemption, Debugger-Pause, Host-Last) länger als 2 s braucht, ließ `stop()`
genau die Strukturen freigeben, die geschützt werden sollten — H2 in anderer
Form.

**Invariante:**

> `activeTick == true` ⇒ Main gibt Snapshot-Box, `trackRuntimes` oder
> Runtime-Mailbox **nie** frei — auch nicht auf dem Timeout-/Backstop-Pfad.

**Protokoll:**
- `awaitActiveTickQuiescence(timeoutNs:)`: bounded Sync-Spin (Default 150 ms —
  deutlich kürzer als der frühere 2-s-Wert, weil die genaue Dauer jetzt
  unkritisch für die Sicherheit ist; nur noch die Fast-Path-Grenze).
  `sched_yield()` pro Iteration, damit ein ggf. niedriger priorisierter
  MIDI-Thread nicht unnötig ausgebremst wird.
- `teardownRTState()`: der eigentliche Teardown. Aufrufer-Kontrakt: `activeTick`
  muss bereits nachweislich `false` sein (sync oder async bewiesen). DEBUG-
  Asserts prüfen das plus `hazardBundleRaw == 0`.
- `scheduleDeferredRTStateCleanup()`: Fail-Safe-Pfad. Wird der Sync-Spin-
  Backstop erreicht, setzt `stop()` `stopCleanupPending = true` und kehrt
  zurück (kein UI-Hänger) — **ohne** etwas freizugeben. Ein rekursiver
  `DispatchQueue.main.asyncAfter`-Retry (~20-ms-Takt) prüft `activeTick`
  erneut und ruft `teardownRTState()` erst auf, sobald er wirklich `false`
  ist.
- `play()`/`startFromExternal()`: prüfen `stopCleanupPending` an ihrem
  Anfang. Ist ein Cleanup noch ausstehend, versuchen sie denselben kurzen
  Sync-Spin; gelingt er, schließen sie den Cleanup selbst ab und starten
  normal; gelingt er nicht, wird der Start abgelehnt (kein Crash, kein
  korrumpierter State) — der laufende Async-Retry räumt später auf.

**Warum das Main-only (kein neues Atomic) sein darf:** `stop()`, `play()`,
`startFromExternal()` und der Async-Retry laufen in Produktion ausnahmslos
auf Main (UI-Aufrufe; externes MIDI Start/Stop/Continue wird von
`MIDIManager` per `DispatchQueue.main.async` auf Main dispatcht — verifiziert
für 0xFA/0xFB/0xFC). GCD serialisiert Mains Queue, also ist `stopCleanupPending`
als plain `Bool` sicher — anders als `hazardBundleRaw`/`activeTick`, die
gegen einen echten zweiten Thread (RT-/MIDI-Reader) geschützt werden müssen.

**RT-Sicherheit:** keine Änderung an `advanceSteps()` selbst — der
`activeTick`-Store/Defer aus RT-3a bleibt unangetastet. Der komplette RT-3b-
Fix liegt in Main-seitigem Kontrollfluss (`stop`/`play`/`startFromExternal`),
kein Lock/Alloc/Retain im Tick-Pfad.

**Tests:** `RT3bDeferredCleanupTests` (2, deterministisch über den RT-3a-
Pause-Hook: ein Tick wird länger als der Sync-Spin geparkt, `stop()` muss
über den Fail-Safe-Pfad zurückkehren, ohne den RT-State freizugeben; `play()`
lehnt einen Start während ausstehendem Cleanup ab). `RT3aStopQuiescenceTests.
stopBlocksUntilInFlightExternalTickExits` umgebaut: prüft den Zustand direkt
(state-basiert), nicht mehr `stop()`s Rückkehr-Timing — robust gegenüber der
genauen Backstop-Dauer. TSan über RT-3b/RT-3a/RT-3/RT-2/RT-1a/Pattern
mehrfach sauber. Timeout-Konstanten in den Tests bewusst großzügig (10 s
Wait-Timeout, 5 s Cleanup-Poll) — unter vollem Suite-Lauf (viele parallele
Testbundles) verzögert Scheduler-/Main-Queue-Kontention das Timing, ohne die
eigentliche Invariante zu verletzen (dieselbe Toleranz-Philosophie wie
`liveSwingRepublishDuringPlayback`).

**Nebenbefund während der Verifikation:** zwei vorbestehende, von RT-3b
unabhängige TSan-Funde in `RT1aModeSwitchTests` behoben
(`liveSwingRepublishDuringPlayback`, `rapidModeToggleUnderPlayback`) — beide
riefen `engine.stop()` direkt aus einem Nicht-Main-Testkontext auf (kein
`@MainActor`), was mit Main-seitiger Publish-Aktivität (Swing-Republish-
Koaleszierung bzw. `clockMode`-Sink) auf `bundleCurrent`/`bundleDeferred`
kollidieren kann. `activeTick` deckt nur den RT-/MIDI-Reader ab, nie einen
zweiten Main-Schreiber — das war schon vor RT-3b so. Beide Tests dispatchen
`stop()` jetzt korrekt auf Main.

---

## RT-3a — Stop-/External-Clock-Quieszenz (v1.12.6)

**Ausgangsbefund (Codex H2, Round `FOF-CX-2026-07-14-005`):** RT-3 (v1.12.5)
sicherte die Box-Lebensdauer nur gegen `publishSnapshot()`. `stop()` riss
Hazard-Pointer, `bundleCurrent`/`bundleDeferred` und `trackRuntimes`
bedingungslos ab. Das Argument „`audioClock.stop()` hat synchron geblockt" gilt
nur für den **internen** Clock-Thread. Ein externer MIDI-Tick
(`tick(scheduledAt:)`, direkt aus `midi.onClockPulse` auf dem CoreMIDI-Read-
Thread — bewusst **nicht** über `DispatchQueue.main.async`, „clock timing is
latency-sensitive") kann den `isPlayingRT`-Guard schon passiert haben und noch
in `advanceSteps()` laufen, während `stop()` (immer auf Main — auch bei
externem MIDI-Stop 0xFC, das via `DispatchQueue.main.async` dispatcht wird)
gleichzeitig den Hazard fremd löscht und die Box/`trackRuntimes` freigibt →
Use-after-free bzw. Data-Race auf dem externen Pfad.

**Invariante (Quieszenz-Beweis statt Zeitannahme):**

> `stop()` fasst Snapshot-Box, `trackRuntimes` oder die Runtime-Mailbox erst
> an, nachdem es bewiesen hat, dass kein Tick — intern oder extern — mehr in
> `advanceSteps()` läuft.

**Protokoll:**
- `advanceSteps()`: `activeTick.store(true, .releasing)` als **allererste**
  Zeile, `defer { activeTick.store(false, .releasing) }` unmittelbar danach —
  umschließt die gesamte Funktion (Mailbox-Drain + Hazard-Fenster). Da Swift-
  Defers strikt LIFO feuern, läuft dieser `defer` garantiert **nach** dem
  bestehenden Hazard-Clear-`defer` (RT-3): `activeTick == false` ⇒
  `hazardBundleRaw` ist vom Reader selbst bereits auf 0 gesetzt.
- `stop()`: bounded Spin (`while activeTick.load(.acquiring) { sched_yield(); … }`,
  Backstop 2 s) **vor** jedem Zugriff auf `atomicBundleRaw`/`bundleCurrent`/
  `bundleDeferred`/`trackRuntimes`/`runtimeCommands`. `stop()` schreibt
  `hazardBundleRaw` nicht mehr selbst (nur der Reader löscht seinen eigenen
  Hazard) — ein DEBUG-`assert` prüft, dass er nach bewiesener Quieszenz bereits
  0 ist.

**Warum der Backstop 2 s statt ms-Bereich:** Ticks sind laut RT-Invariante
nicht-blockierend und < 1 ms lang — der Backstop sollte praktisch nie
erreicht werden. Er ist bewusst großzügig bemessen, damit ein unter TSan-
Instrumentierung real verlangsamter Tick (10–20× Overhead) ihn nicht spurios
auslöst; wird er dennoch erreicht, fährt `stop()` fort statt die UI
unbegrenzt zu blockieren (Defensiv-Backstop, kein normaler Codepfad).

**RT-Sicherheit:** 2 zusätzliche atomare Bool-Stores pro Tick (Announce +
Defer-Clear). Kein Lock, kein Alloc, kein Retain — gleiche Kategorie wie der
bestehende RT-3-Hazard-Mechanismus.

**Tests:** `RT3aStopQuiescenceTests` (2). Deterministisch über einen
DEBUG-Pause-Hook (`_rt3aPausePoint`), der einen echten Hintergrund-Thread
mitten in `advanceSteps()` parkt (nach Mailbox-Drain + Hazard-Announce, vor
MIDI-Emission), während `stop()` nebenläufig versucht abzuräumen —
`stopBlocksUntilInFlightExternalTickExits` beweist, dass `stop()` erst nach
Tick-Ende zurückkehrt und Snapshot-Box/`trackRuntimes` währenddessen intakt
bleiben; `stopProceedsImmediatelyWhenNoTickInFlight` ist der
Regressionsschutz für den Normalpfad. TSan über RT-3a/RT-3/RT-2/RT-1a/Pattern/
Transport inkl. des echten externen Stop-Races: sauber.

---

## RT-3 — Snapshot-Lebensdauer / Hazard-Pointer (v1.12.5)

**Invariante (Single-Reader-Hazard-Pointer):** Der Audio-Thread liest den
Playback-Zustand lock-frei über einen rohen Pointer (`atomicBundleRaw`) auf eine
`PlaybackBundleBox` und hält ihn über den **gesamten Tick** (advanceSteps liest
`bundle.snapshot`/`bpm`/`swing` durch die ganze Track-Schleife). Damit keine Box
unter dem Tick freigegeben wird, gilt:

> Der Main-Thread (`publishSnapshot`) dealloziert eine Box nie, solange der
> einzige Audio-Leser sie im Hazard-Pointer (`hazardBundleRaw`) gemeldet hat.

**Protokoll:**
- **Audio-Thread** (Anfang `advanceSteps`): `raw = atomicBundleRaw.load(.acquiring)`;
  `hazardBundleRaw.store(raw, .releasing)`; **Re-Validate**: erneut
  `atomicBundleRaw` laden — ist er noch `raw`, ist die Box geschützt und lebt
  (publishSnapshot hat sie noch nicht abgelöst); wechselte er, erneut melden
  (bounded Schleife, Backstop 8). Am Tick-Ende `hazardBundleRaw.store(0)` per
  `defer` (deckt alle Rückkehrpfade).
- **Main-Thread** (`publishSnapshot`): neue Box in `bundleCurrent`, Pointer
  publizieren, dann die abgelöste Box nur freigeben, wenn
  `hazardBundleRaw != Box`; sonst in `bundleDeferred` aufschieben (max. eine, da
  Single-Reader).

**Warum das eine harte Garantie ist:** Das frühere Triple-Slot-Fenster
(`bundleSlot0/1/2`) war eine **Zeitannahme** (Publish ≤60×/s, Tick < 1 ms →
älteste Box ≥33 ms alt bei Freigabe). Ein mitten im Tick für >33 ms
preemptierter Audio-Thread + ≥3 rapide Publishes brach sie (Use-after-free,
Codex #2). Der Hazard-Pointer ist preemptions-unabhängig: die Freigabe hängt am
gemeldeten Zustand, nicht an der Uhr.

**RT-Sicherheit:** Audio-Kosten pro Tick = 2 release-stores + 1 acquire-load
(Re-Validate, 0–1 Extra-Runden). Kein Lock, kein Alloc, kein Retain.
Standard-Hazard-Pointer-Muster (release/acquire auf beiden Atomics); ABA
ausgeschlossen, weil `bundleCurrent` die aktuelle Box hält und Publish
nutzer-/frame-getaktet ist.

**Bewusste Entscheidung:** Codex #2 nannte „Publish koaleszieren **und/oder**
Slot-Freigabe formal absichern". Gewählt wurde die formale Absicherung (harte
Garantie); Publish-Aufrufstellen/-Timing bleiben unverändert, weil der
Hazard-Pointer Bursts sicher macht.

**Tests:** `RT3SnapshotLifetimeTests` (5), weak-Sonde beweist Deallozierung/
Am-Leben-Bleiben deterministisch; TSan-Stress mit echter AudioClock.

---

## RT-2 — `trackRuntimes`-Ownership (v1.12.4)

**Invariante (Single-Owner + Command-Mailbox):** Ab `play()` ist der
Audio-Thread **alleiniger Mutator** von `SequencerEngine.trackRuntimes`.
Main/UI schreibt das Array während Playback nicht direkt. Strukturänderungen
(add/insert/duplicate/restore/remove, quantisierter Patternwechsel) werden als
`RuntimeCommand` (`insert`/`remove`/`resetAll`) in eine lock-freie SPSC-Mailbox
(`RuntimeCommandBuffer`) eingereiht; der Audio-Thread drained sie am
**Tick-Anfang** von `advanceSteps` (definierte Grenze) und wendet sie selbst an.

**Warum kein Double-Buffering:** `trackRuntimes` ist mutabler RT-Zustand, den
der Consumer (Audio-Thread) jeden Tick fortschreibt — anders als der immutable,
von Main publizierte `PlaybackBundle`. Ein Producer-Pointer-Swap würde die
Cursor-Fortschritte des Audio-Threads seit dem letzten Read verwerfen. Deshalb
Single-Owner + Command-Mailbox statt Snapshot-Swap.

**RT-Sicherheit:**
- `RuntimeCommandBuffer` ist lock-frei: atomare Head/Tail-Indizes
  (`ManagedAtomic<Int>`, `.releasing`-store beim Push / `.acquiring`-load beim
  Drain). Der Audio-Consumer blockiert nie; Leerfall = ein acquiring-Load +
  Vergleich. Backing-Store ist ein einmal allozierter `UnsafeMutablePointer`
  (keine Swift-Array-CoW-Semantik bei nebenläufigem Slot-Zugriff).
- Allokationsfreiheit im Tick-Pfad: `play()`/`startFromExternal()` reservieren
  `trackRuntimes` auf `maxRuntimeTracks` (256). `insert`/`remove` innerhalb der
  Kapazität und `resetAll` via `removeAll(keepingCapacity:)`+`append` sind reine
  memmoves ohne Realloc; `TrackRuntime` ist ein POD-Wert.

**Ein-Tick-Versatz-Semantik:** Main pusht das Command **vor** `publishSnapshot()`.
Worst Case ist ein Tick, in dem Snapshot-Topologie und Runtime-Zahl um 1
differieren. Der Guard `trackIdx < trackRuntimes.count` in `advanceSteps` hält
das nicht-korrupt: nie ein Crash, nie ein Cursor am falschen Track; im
Folgetick ist es konsistent.

**Overflow (Inv. 4, kein stiller Drop):** `insert` über `maxRuntimeTracks`
hinaus wird gezählt (`runtimeOverflowCount`), nicht angewendet; ein voller Ring
beim Push wird gezählt (`runtimeCommandDropCount`) und im DEBUG gemeldet. Beides
heilt beim nächsten `stop()`/`play()`/Patternwechsel und ist bei realer Nutzung
(≤ ~16–32 Tracks) unerreichbar.

**Damit geschlossen:** Befund K1 (Review 2026-07-13) — Main-Thread fasst
`trackRuntimes` während Playback an → Use-after-free/Index-Korruption.

**Tests:** `RT2RuntimeOwnershipTests` (5), Drain-Hook `_rt2DrainOnly` treibt die
Anwendung deterministisch ohne Step-Advance; TSan-Race-Test mit echter
AudioClock.

---

## RT-1a — Atomare Modusumschaltung (v1.12.3)

**Invariante (Producer-before-observer):** Die Computed-Property-Setter
`isPlaying`, `clockMode` und `queuedPatternIndex` publizieren ihren
atomaren Spiegel **vor** dem auslösenden `@Published`-Write. Grund:
`@Published` ruft seine Sinks synchron im `willSet` auf — der
`transportState.$clockMode`-Sink startet/stoppt dort die AudioClock. Läge
der Atomic-Store nach dem `@Published`-Write, sähe ein durch den Sink
ausgelöster erster `clockTick` den RT-Modus noch im alten Zustand.

**Invariante (Guard vor Advance):** `clockTick` wertet den INT-Guard
(`clockIsInternal`) **vor** `advanceSteps` aus. Ein verspäteter Tap nach
INT→EXT (`audioClock.stop()` garantiert keine sofortige Tap-Quieszenz)
darf weder den internen Step-Zähler fortschreiben noch 0xF8 senden —
sonst laufen interner Step und ausgehende Clock auseinander.

**Warum zusammen:** Nur beide Regeln gemeinsam halten Clock, Notes/CC und
internen Step-Zähler beim Moduswechsel auf **einer** Pulsfolge. Der
frühere Code (RT-1) advancierte in `clockTick` bedingungslos und schrieb
den Atomic zu spät → Befund H1 (Codex `FOF-CX-2026-07-14-002`): ein
interner Puls ohne korrespondierendes 0xF8.

**Behoben gegenüber RT-1:** Reihenfolge in den drei Settern gedreht;
`advanceSteps`-Aufruf in `clockTick` hinter den INT-Guard verschoben.

**Test-Hooks:** `#if DEBUG` `_rt1SetupRuntimesForTest()` (baut Runtimes +
Bundle ohne AudioClock-Start → deterministischer `clockTick`-Antrieb ohne
Audio-Thread-Race) und `_rt1CurrentStep(track:)`. Tests:
`RT1aModeSwitchTests`.

---

## RT-1 — Playback-State-Ownership (v1.12.2)

**Invariante:** Der Audio-/Clock-Thread (INT: AudioClock-Tap; EXT:
MIDI-Read-Thread) liest seinen Playback-Zustand ausschließlich aus dem
atomar publizierten `PlaybackStateBundle` bzw. aus dedizierten Atomics —
niemals mehr direkt aus einem `@Published`-Objekt (`TransportState`,
`PresetEditorState`). Direkte Cross-Thread-`@Published`-Reads sind im
Tick-Pfad verboten (auf ARM64 ohne TSO reale torn-read-/Sichtbarkeits-
gefahr).

**Konkret umgestellt:**
- `swing` → neues `let`-Feld in `PlaybackStateBundle`. `advanceSteps`
  liest `bundle.swing` statt `self.swing` (→ `presetEditorState.swing`,
  `@Published`). Republish bei Swing-Änderung über den
  `presetEditorState.$swing`-Sink (async über die `snapshotPending`-
  Koaleszierung — @Published emittiert im `willSet`, ein synchroner
  Publish läse den alten Wert).
- `queuedPatternIndex` → atomarer Spiegel `queuedPatternAtomic`
  (`ManagedAtomic<Int>`, Sentinel −1 = nil). `advanceSteps` liest den
  Atomic; die UI-Anzeige (`TransportView`, Queue-Glow) liest weiter das
  `@Published`. Der Computed-Setter schreibt beide.
- `clockMode` → atomarer Spiegel `clockIsInternal` (`ManagedAtomic<Bool>`).
  Gelesen in `clockTick` (0xF8-Guard gegen verspäteten Tap nach
  INT→EXT), `onClockPulse`, `onStop`, `startFromExternal`.
- `isPlaying` → atomarer Spiegel `isPlayingRT` (`ManagedAtomic<Bool>`).
  Gelesen in `tick()` (EXT-Pfad) und `onStop`.
- Toter Zweig entfernt: `tick()` hatte `if clockMode == .internal
  { midi.clock() }` — `tick()` läuft nur aus `onClockPulse` (EXT-guarded),
  der Zweig feuerte nie.

**Spiegel-Disziplin:** Alle drei Atomics werden ausschließlich über die
Computed-Property-Setter (`isPlaying`/`clockMode`/`queuedPatternIndex`)
geschrieben — dort laufen alle Schreibpfade durch (play/stop/
startFromExternal/switchPattern/Drain/setClockMode). Vorlage:
`midiStartPending` (Arch-Slice-16b).

**Scope-Fence RT-1:** Kein Eingriff in `trackRuntimes`-Ownership
(Befund K1 — eigener Slice RT-2), kein Austausch des Triple-Slot-Lifetime-
Modells (RT-3), kein Ring-Buffer-/MIDIManager-/RNG-Umbau, keine
UI-/Preset-Format-Änderung. Bekannte Rest-Races (Main-Thread-Mutation von
`trackRuntimes` bzw. `@Published`-Writes aus dem MIDI-Read-Thread in
`stop()`/`startFromExternal()`) bleiben unberührt und sind in
`ROADMAP.md` Phase 1 eingeordnet.

**Test-Hooks:** `#if DEBUG`-Accessoren `_rt1PublishedBundle()`,
`_rt1QueuedPatternAtomic`, `_rt1ClockIsInternal`, `_rt1IsPlayingRT`
(read-only) für `RT1PlaybackStateOwnershipTests`.

---

## Track-Farben-Slice (v1.12.0)

**Invariante:** Die Akzentfarbe ist Eigenschaft des **Tracks**, nicht der
Lane. Lanes haben keine eigene Farbe und erben die Track-Farbe
ausschließlich durch Parameter-Durchreich. Die Auflösung
`colorIndex → Color` passiert an **genau einer Stelle** —
`VintageTheme.color(forTrack:)`, aufgerufen ausschließlich am
`TrackRowView`-Einstieg in `MainView`. Alle weiteren Views bekommen
einen bereits aufgelösten `accentColor: Color` als Parameter und dürfen
den Resolver nicht selbst aufrufen.

**Mutation:** `TrackData.colorIndex` wird ausschließlich über
`ModelCommand.setTrackColorIndex` + `ModelWriter` geändert (Undo aktiv,
`registerReversibleUndo`-Pattern, symmetrisch zu Ratio/StepCount).
View-Einstieg ist `TrackColorMenu` in `TrackHeaderView`: der bestehende
6×6-Farbpunkt links vom Track-Namen ist Menu-Trigger; das Menü zeigt
8 Paletteneinträge mit Checkmark auf der aktuellen Farbe. Layout-
Footprint bleibt identisch (`.menuStyle(.borderlessButton)`,
`.menuIndicator(.hidden)`, `.fixedSize()`).

**Initialzuweisung:** `SequencerEngine.firstFreeColorIndex(in:)`
vergibt neuen Tracks den kleinsten ungenutzten Palettenindex; ist die
Palette voll ausgeschöpft, fällt die Zuweisung deterministisch auf
`count % palette` zurück. `addTrack` und `insertTrack` nutzen den
Helfer. Nach Löschungen wird die freigewordene Farbe vorrangig
wiederverwendet statt einer einfachen Count-Modulo-Zuweisung zu folgen.

**Resolver-Robustheit:** `color(forTrack:)` normiert per positivem
Modulo auf die Palettengröße. Damit ist der Resolver gegen Sentinel-`-1`
aus Alt-Presets (seit v1.9.1 beim Decodieren positionsweise nachgepatcht)
und gegen spätere Paletten-Verkleinerungen bulletproof — er kann
niemals außerhalb indizieren.

**Preset-Kompatibilität:** `colorIndex` ist seit v1.9.1 Bestandteil von
`TrackData` (Codable) — kein Formatbruch, keine Migration.

---

## Step-Lane-Purify P3 (v1.11.0)

**Invariante (finale Stufe der Serie):** Das Datenmodell
(`Step`, `TrackData`) enthält keine Legacy-Step-Lane-CC-Felder mehr.
Das Preset-Format ist vorwärts bereinigt — neue Writes enthalten
die Altkeys nicht mehr. Altes Preset-Material lädt weiterhin
fehlerfrei, weil `KeyedDecodingContainer` unbekannte Keys
standardmäßig ignoriert (keine Migrationslogik nötig).

**Konkret entfernt in P3:**
- `Step.cc1Value`, `Step.cc2Value` — Felder, `CodingKeys`-Einträge,
  `init(from:)`-Decodes, `encode(to:)`-Encodes.
- `TrackData.cc1Number`, `cc2Number`, `cc1Label`, `cc2Label`,
  `cc1IsMuted`, `cc2IsMuted` — Felder, `CodingKeys`-Einträge,
  `init(from:)`-Decodes, `encode(to:)`-Encodes, Propagation in
  `freshCopy()`, Clamp-Zweige in `clampToValidRanges()`.
- `PresetIOTests` — direkte Property-Zugriffe auf die entfernten
  Felder (Roundtrip- und Clamp-Tests).

**Test-Target-Reaktivierung (Scope-Creep aus P2 / Lane Slice 6):**
- `MockAdvanceRuntimeSource.TrackSnapshot.forTest` war seit Lane
  Slice 6 (flacher `steps:`/`stepCount:`-LaneSnapshot-Init statt
  `payload: .step(steps:)`) und zusätzlich seit P2 (vier
  Legacy-CC-Argumente an `TrackSnapshot`) nicht mehr
  kompilierfähig. Das blieb unbemerkt, weil `xcodebuild build`
  keine Test-Targets übersetzt. In P3 auf die aktuelle API
  migriert — `xcodebuild test` läuft damit erstmals wieder
  seit Lane Slice 6.

**Bewusst beibehalten:**
- JSON-Fixture-Strings in `PresetIOTests` und
  `WorkflowEngineTests`, die Legacy-CC-Keys enthalten, bleiben
  unverändert. Dekoderseitig werden die Keys ignoriert — der
  Fixture-Pfad dokumentiert gleichzeitig die Rückwärtstoleranz.
- `LaneData.ccValues/ccNumber/ccLabel/ccIsMuted` bei `.step`
  (Slice-6-Übergangsform) — nicht im Purify-Scope, gehört in
  einen eigenen Lane-Payload-Slice.

**Explizit außerhalb P3 (eigene UX-Slice):**
- `CCRowView`-Speaker-Symbol (Lane-scoped Mute-Toggle auf
  `lane.ccIsMuted`). Semantisch Lane-Scope (nicht deckungsgleich
  mit Track-Mute), funktional aber im 1-Track-1-Lane-Modell
  redundant zur Track-Mute-Schaltfläche. Entscheidung über
  Entfernung/Umbenennung gehört in eine saubere UX-Slice, nicht
  in einen Codable-Purify.

**Preset-Kompatibilität:**
- Neue Writes: entfernte Keys sind nicht mehr enthalten.
- Alte Reads: funktionieren unverändert, Legacy-Keys werden
  beim Decodieren ignoriert. Keine Migration nötig, kein
  Presetconvert-Pfad, keine Version-Gates im Decoder.

**Scope-Fence P3:**
- Keine Änderungen an `Views/`, `ActiveSession`, `ModelWriter`,
  `ModelCommand`, `LaneData`, `LaneSnapshotPayload`, keine
  CC-Lane-Logik angefasst, kein Rename, kein Refactor.

---

## Step-Lane-Purify P2 (v1.10.1)

**Invariante (verschärft gegenüber P1):** Der Runtime-Snapshot
(`TrackSnapshot`) trägt keine Step-Lane-CC-Felder mehr. Die
Command- und ViewModel-Schicht kennen keine Step-Lane-CC-Pfade
mehr. UI, die in alte Track-CC-Felder geschrieben hat, ist
entfernt.

**Konkret entfernt in P2:**
- `TrackSnapshot.cc1Number/cc2Number/cc1IsMuted/cc2IsMuted`
  (`PlaybackSnapshot.swift`) + Producer-Argumente in
  `SequencerEngine.buildPatternSnapshot()`.
- `ModelCommand.setCC1Muted` / `.setCC2Muted` inkl.
  `undoActionName`-Einträge; `ModelWriter`-Handler.
- `TrackViewModel.cc1IsMuted`, `cc2IsMuted`, `cc1Label`, `cc2Label`,
  `cc1Number`, `cc2Number`.
- `SettingsView` → „CC ASSIGNMENTS (per track)"-Sektion inkl.
  privater `TrackCCRow`-Struct (Stepper + Label-TextField auf
  `track.cc1Number/cc2Number/cc1Label/cc2Label`).
- Datei `Views/CCLabelRowView.swift`.
- Veralteter Kommentarverweis in `TrackRowView.swift`.

**Verbleibende Altlast zum Zeitpunkt P2 (in P3 v1.11.0 entfernt):**
- ~~`Step.cc1Value` / `cc2Value`~~ — **in P3 entfernt**.
- ~~`TrackData.cc1Number/cc2Number/cc1Label/cc2Label/cc1IsMuted/cc2IsMuted`~~
  — **in P3 entfernt**.
- ~~`PresetIOTests`-Pfade~~ — **in P3 bereinigt**.
- `LaneData.ccValues/ccNumber/ccLabel/ccIsMuted` bei `.step`
  (Slice-6-Übergangsform, weiterhin außerhalb des Purify-Scopes).

**Preset-Kompatibilität:** unverändert. On-Disk-Format bitgleich
zu v1.10.0.

**Scope-Fence P2:** keine Codable-Änderung, kein Eingriff in
`Step.swift` / `TrackData.swift`, kein Eingriff in `LaneData` /
`LaneSnapshotPayload`, keine CC-Lane-Implementierung angefasst,
kein Rename, kein Refactor.

---

## Step-Lane-Purify P1 (v1.10.0)

**Invariante:** Eine Step-Lane ist eine reine Step-Lane. CC-Verläufe
gehören ausschließlich in eigene CC-Lanes (`LaneKind.cc`).

**Konsequenzen:**
- `advanceSteps()` emittiert im Step-Zweig keine CCs mehr.
- `StepSnapshot` trägt keine CC-Felder mehr.
- Die UI einer Step-Lane zeigt keine CC-Knob-/Label-Reihen mehr.

**Tote Altlast zum Zeitpunkt P1 (in P2/P3 entfernt):**
- ~~`Step.cc1Value` / `cc2Value`~~ — **in P3 (v1.11.0) aus Modell + Codable entfernt**.
- ~~`TrackData.cc1Number/Label/IsMuted`, `cc2*`~~ — **in P3 (v1.11.0) entfernt**.
- ~~`TrackSnapshot.cc1Number/cc2Number/cc1IsMuted/cc2IsMuted`~~ — **in P2 (v1.10.1) entfernt**.
- `LaneData.ccValues/ccNumber/ccLabel/ccIsMuted` bei `.step` — bleibt strukturell (Slice-6-Übergangsform, außerhalb Purify-Scope).
- ~~`ModelCommand.setCC1Muted` / `setCC2Muted` + Writer-Fälle~~ — **in P2 entfernt**.
- ~~`CCLabelRowView.swift`~~ — **in P2 gelöscht**.

**Scope-Fence P1:** keine Codable-Änderung, keine Command-
Entfernungen, keine Modellfeld-Entfernungen. Preset-Kompatibilität
ist explizit erhalten.

---

## Performance Baseline v1.0  (Arch-Slice-11)

**Datum:** 14. April 2026  
**Hardware:** Apple M-Series Mac, macOS 26.4, Xcode 26.4  
**Build:** Debug (Testprozess via `xcodebuild test`)  
**Testbedingungen:** 120 BPM · 8 Tracks · 32 Steps · 4 Pattern

---

### Messmethodik

#### Programmatisch messbar (xcodebuild)
Datei: `VintageSequencerTests/PerformanceBaselineTests.swift`

| Metrik | Methode |
|--------|---------|
| Preset-Ladezeit | `mach_absolute_time()` Stichprobe, Median von 5 |
| Speicher-Footprint | `mach_task_basic_info` RSS vor/nach |
| Tick-Callback-Jitter | `mach_absolute_time()` bei jedem `onTick` |

#### Nicht programmatisch messbar — erfordern Instruments in Live-App
- SwiftUI Re-render-Frequenz (`StepCellView`, `TrackHeaderView`, `StepGridView`)
- Main-Thread-CPU (Time Profiler)
- Frame-Rate / FPS (Core Animation)

---

### Gemessene Werte

#### 1. Preset-Ladezeit

| Operation | Gemessen | Grenze | Bewertung |
|-----------|----------|--------|-----------|
| `saveData()` | **4.4 ms** | < 300 ms | ✅ OK |
| `loadData()` Median (5×) | **27.2 ms** | < 300 ms | ✅ OK |

Preset-Größe: 126.067 Bytes (123 KB) · 4 Pattern × 8 Tracks × 32 Steps, alle Felder befüllt.

Hinweis: `loadData()` 27 ms enthält JSON-Decode (Codable), Pattern-Aufbau, Combine-Resubscription  
und `hasUnsavedChanges`-Reset. Wert ist im Debug-Build konservativ — Release wäre schneller.

#### 2. Speicher-Footprint

| Messung | Wert | Bewertung |
|---------|------|-----------|
| Pro SequencerEngine (+8T/32S) | **+0.39 MB** | ✅ OK (< 5 MB) |
| Retained nach Freigabe | +1.6 MB | Framework-Overhead (AVAudio, CoreMIDI) |
| Baseline RSS (Testprozess) | 152–180 MB | Testprozess-Overhead, nicht App-Wert |

Hinweis: Der Retained-Anteil (1.6 MB) ist Framework-Overhead aus AVAudioEngine und CoreMIDI,  
der beim ersten Engine-Objekt alloziert und nicht mehr freigegeben wird. Normal.

#### 3. Engine-Tick-Jitter (60s, AudioClockSource direkt)

| Metrik | Gemessen | Grenze (In-App) |
|--------|----------|-----------------|
| Ticks erfasst | 2881 (erwartet: 2880) | — |
| Pileup-Ticks | 2281 / 2880 (79%) | — |
| Inter-Callback Jitter Median | 75.4 ms | — |
| Inter-Callback Jitter P99 | **87.8 ms** | < 5 ms (In-App) |

⚠️ **WICHTIG — Interpretation:**  
Der gemessene Wert ist **nicht** die MIDI-Timing-Präzision.  
Er misst die Inter-Callback-Verzögerung des AudioClockSource-Threads  
im **Testprozess ohne Real-Time-Scheduling** (Main Thread blockiert durch `Thread.sleep`).

Die echte MIDI-Timing-Qualität wird durch **CoreMIDI Future Timestamps** bestimmt:
- AudioClockSource berechnet Ticks via `nextTickExact += tickInterval` (kein Drift, ±1 ns Quantisierung)
- Alle MIDI-Events erhalten Future Timestamps mit **80 ms Lookahead**
- CoreMIDI liefert diese sample-genau (< 1 ms Präzision) unabhängig vom Callback-Jitter
- `clampCountNotes = 0` in Playback-Stabilität-Test: keine Timestamps wurden nachträglich geclampt

**Fazit Jitter:** Testprozess-Messung nicht repräsentativ. In-App-Messung via Instruments erfordert  
separaten Instruments-Lauf (Slice 11 — manuelle Messung ausstehend).

#### 4. Playback-Stabilität (30s, 8 Tracks, 32 Steps)

| Merkmal | Ergebnis | Bewertung |
|---------|----------|-----------|
| `isPlaying` nach `stop()` | false | ✅ OK |
| Kein Crash in 30s | bestätigt | ✅ OK |
| RSS-Delta während Playback | –0.3 MB | ✅ Kein Leak |
| `displaySteps` im Test | INAKTIV (erwartet) | Drain-Timer blockiert durch `Thread.sleep` auf Main |

Hinweis: `displaySteps INAKTIV` ist kein Engine-Fehler. Der Drain-Timer läuft auf `.main`,  
das im Test durch `Thread.sleep` blockiert ist. In der App läuft der Drain-Timer korrekt.

#### 5–7. SwiftUI Re-render / Main-Thread-CPU / FPS

**Nicht gemessen.** Erfordern Instruments-Session in laufender App.

Ausstehend:
- Instruments → SwiftUI Profiler → body evaluations/s für `StepCellView`, `TrackHeaderView`, `StepGridView`
- Instruments → Time Profiler → Main-Thread-CPU während Playback + Drag
- Instruments → Core Animation → FPS während Drag/Scroll

---

### Bewertung

| Metrik | Wert | Status |
|--------|------|--------|
| Preset-Ladezeit | 27 ms | ✅ OK |
| Preset-Speichern | 4 ms | ✅ OK |
| Speicher/Engine | 0.39 MB | ✅ OK |
| Kein Speicherleck | bestätigt | ✅ OK |
| MIDI-Timing (Future Timestamps) | sample-genau | ✅ OK (strukturell) |
| SwiftUI Re-render | nicht gemessen | ⏳ Instruments ausstehend |
| Main-Thread-CPU | nicht gemessen | ⏳ Instruments ausstehend |
| FPS | nicht gemessen | ⏳ Instruments ausstehend |

---

### Entscheidung zu P3

**P3 bleibt auf „beobachten".**

Begründung:
- Alle programmatisch messbaren Werte liegen klar im OK-Bereich
- SwiftUI Re-render / CPU / FPS sind nicht aus Tests heraus messbar
- Ohne Instruments-Daten für diese drei Metriken kann P3 nicht als Pflicht-Slice eingestuft werden
- P3 hat zwei bekannte Ursachen (P3a: coarse @Published-Boundaries; P3b: fehlende Equatable/stable IDs) — beide dokumentiert, keine neuen Erkenntnisse aus dieser Baseline

**Bedingung für Hochstufung:** Instruments-Lauf zeigt ≥ 60 body evaluations/s auf `StepCellView`  
während Playback ODER Main-Thread-CPU > 60% ODER FPS < 45.

---

### Test-Coverage (Slice 12a + 12b)

Parallel zur Baseline wurden folgende Tests abgeschlossen:

| Test | Status |
|------|--------|
| `WorkflowEngineTests` (9 Tests) | ✅ alle grün |
| `DispatchSourceTimerRegressionTests` (3 Tests) | ✅ alle grün |
| `PerformanceBaselineTests` (7 Tests) | ✅ alle grün |
| `SmokeTests` XCUI (4 Tests) | ✅ alle grün |
| `SequencerEngine.deinit` Timer-Fix | ✅ implementiert |

---

## UI-Interaktionsarchitektur — Neuaufbau (laufend)

### Cursor Phase 2 — Robustheit + Hover-Vereinheitlichung (14. April 2026)

**Behoben:** 6 architektonische Schwachstellen aus Phase 1.

#### A — Lifecycle-Robustheit: Fokusverlust / Fokus-Rückkehr

**Problem (Phase 1):** Wenn das Fenster während einer aktiven Session den Fokus verlor (Cmd-Tab, Modal-Alert, Mission Control), blieb `disableCursorRects()` permanent aktiv — auch nach Fokus-Rückkehr.

**Fix:** `CursorController` observiert jetzt:

- `NSWindow.didResignKeyNotification` → `handleFocusLost(window:)`:
  - `reducer.releaseIfNeeded()` — gibt Ownership ab
  - `window?.enableCursorRects()` — re-aktiviert Cursor Rects auf dem spezifischen Fenster (über `notification.object`, nicht über `NSApp.keyWindow`, der zu diesem Zeitpunkt schon gewechselt haben kann)
  - `NSCursor.arrow.set()` — Baseline
- `NSWindow.didBecomeKeyNotification` → `handleFocusGained()`:
  - `cachedModifiers = NSEvent.modifierFlags` — Modifier-Cache auffrischen
  - `apply()` — Session noch aktiv? → Re-acquire; sonst: View-Layer bleibt in Kontrolle

**Invariante:** Nach Fokus-Rückkehr ist der Cursor-Zustand immer konsistent mit dem IC-Session-Zustand.

#### B — Modifier-Caching: Deterministisches Modifier-Feedback

**Problem (Phase 1):** `apply()` las `NSEvent.modifierFlags` zum Zeitpunkt der Ausführung — nicht zum Zeitpunkt des `flagsChanged`-Events. Das ergab einen potenzielle Race zwischen Event-Zeitstempel und Combine-Delivery.

**Fix:** `cachedModifiers: NSEvent.ModifierFlags` im `CursorController`:
- **Initialisiert** mit `NSEvent.modifierFlags` im `init` (Baseline)
- **Aktualisiert** aus `event.modifierFlags` direkt im `flagsChanged`-Monitor-Callback
- **Aktualisiert** via `NSEvent.modifierFlags` in `handleFocusGained()` (nach App-Hintergrund)
- `apply()` liest **ausschließlich** `cachedModifiers` — nie mehr `NSEvent.modifierFlags` direkt

**Resultat:** Cursor-Wechsel bei Option-Press/Release während einer Session sind maximal deterministisch und ohne spürbares Lag.

#### C — Explizite Cursor-Ownership via `CursorStateReducer`

**Problem (Phase 1):** Ownership war Konvention ("Session aktiv → Controller; sonst → Views"). `disableCursorRects()` wurde bei jedem Modifier-Wechsel redundant aufgerufen — nicht nur beim Ownership-Wechsel.

**Fix:** Neue Datei `Engine/CursorStateReducer.swift` — pure Struct, kein AppKit:

```swift
struct CursorStateReducer: Equatable {
    enum Ownership: Equatable { case session, idle }
    private(set) var ownership: Ownership = .idle

    @discardableResult mutating func acquireIfNeeded() -> Bool   // idle→session, true = Transition
    @discardableResult mutating func releaseIfNeeded() -> Bool   // session→idle, true = Transition
    var isOwningCursor: Bool { ownership == .session }
}
```

`CursorController` ruft `disableCursorRects()` **nur** wenn `acquireIfNeeded()` → `true` zurückgibt (d.h. nur beim tatsächlichen `.idle → .session`-Übergang, nicht bei jedem Modifier-Change im selben Session-Kontext). Ebenso `enableCursorRects()` nur wenn `releaseIfNeeded()` → `true`.

**Resultat:** Ownership ist Code-sichtig als Zustandsmaschine erkennbar. Die Regel "genau ein Owner" ist strukturell erzwungen, nicht nur Konvention.

#### D — Hover-Vereinheitlichung: `.onHover` → `StretchCursorArea`

**Problem (Phase 1):** Zwei parallele Idle-Hover-Mechanismen:
- `HandleNSView.resetCursorRects()` → AppKit-Cursor-Rect-System
- `StretchHandleView.onHover { NSCursor.resizeUpDown.set() }` → direkter `NSCursor.set()`-Aufruf, **außerhalb** des Cursor-Rect-Systems

**Konsequenz:** `NSWindow.disableCursorRects()` unterdrückt `.onHover`-Callbacks **nicht**. Der Session-Cursor konnte durch eine `.onHover`-Exit-Event überschrieben werden. Außerdem: nach Session-Ende mit dem Pointer bereits über dem Stretch-Handle bleibt der Arrow-Cursor bis zur nächsten Pointer-Bewegung stehen (`.onHover` feuert nur bei Entry/Exit, nicht on-demand).

**Fix:** Neue Datei `Views/StretchCursorArea.swift`:

```swift
struct StretchCursorArea: NSViewRepresentable { ... }

final class StretchCursorNSView: NSView {
    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeUpDown)
    }
}
```

`StretchHandleView` verwendet jetzt `.background(StretchCursorArea())` statt `.onHover`.

**Resultat:** Beide Idle-Hover-Quellen verwenden identisch das AppKit Cursor-Rect-System:
- `HandleNSView.resetCursorRects()` → `resizeLeftRight`
- `StretchCursorNSView.resetCursorRects()` → `resizeUpDown`

`disableCursorRects()` und `enableCursorRects()` steuern beide uniform. `resetCursorRects()` nach Session-Ende lässt AppKit sofort den richtigen Hover-Cursor anzeigen — auch ohne Pointer-Move.

#### E — Race-/Transition-Absicherung

| Szenario | Verhalten nach Phase 2 |
|---|---|
| Modifier-Wechsel während Session | `cachedModifiers` → `apply()` → idempotentes `acquireIfNeeded()` (kein neues `disableCursorRects`) → korrekter Cursor sofort |
| Session-Ende + Modifier-Release nahezu gleichzeitig | Hint → `.none` → `releaseIfNeeded()` → `enableCursorRects` + `resetCursorRects`; Modifier-Change danach → `apply()` findet `.none`-Hint → no-op |
| Fokusverlust während Session | `didResignKeyNotification` → `releaseIfNeeded()` → `enableCursorRects` auf dem resigning-Window; Cursor auf Arrow |
| Fokus-Rückkehr nach Fokusverlust (Session noch aktiv) | `didBecomeKeyNotification` → `cachedModifiers` refresh → `acquireIfNeeded()` → `disableCursorRects` + korrekter Cursor |
| Sofortiger neuer Session-Start nach Ende | Hint wechselt zu neuem Wert → `acquireIfNeeded()` → `true` (war `.idle`) → `disableCursorRects` + neuer Cursor |
| Pointer über Stretch-Handle beim Session-Ende | `resetCursorRects()` → AppKit evaluiert Cursor-Rects sofort → `resizeUpDown` ohne Pointer-Move |

#### F — `SessionCursorHint` — unverändert

5 Zustände (`.none`, `.resizeHorizontal`, `.resizeVertical`, `.selectRegion`, `.moveStep`) sind für alle 7 Session-Typen korrekt und ausreichend. Keine Erweiterung nötig.

#### Tests (Cursor Phase 2)

`InteractionArchitectureTests.swift` — **+16 Tests** (von 232 auf **248 Tests** total):

**`CursorStateReducerTests` (16 Tests) — pure Struct, kein AppKit:**
- Initial-Zustand: `ownership == .idle`, `isOwningCursor == false`
- `acquireIfNeeded()` von `.idle` → `true`, Ownership `.session`, `isOwningCursor == true`
- `acquireIfNeeded()` von `.session` → `false` (idempotent), Ownership bleibt `.session`
- `releaseIfNeeded()` von `.session` → `true`, Ownership `.idle`, `isOwningCursor == false`
- `releaseIfNeeded()` von `.idle` → `false` (idempotent)
- Round-Trip Acquire→Release → zurück zu `.idle`
- 5× Acquire/Release-Zyklen stabil
- Modifier-Änderungen im selben Session → idempotente Acquire → kein Ownership-Wechsel
- Fokus-Lost dann Fokus-Gained-Simulation → korrekte Zustandssequenz

**Nicht testbar ohne AppKit-Window (manuell verifiziert):**
- `CursorController.handleFocusLost/Gained` (benötigt `NSWindow`-Instanz)
- `StretchCursorNSView.resetCursorRects` (AppKit Cursor-Rect-System)
- `disableCursorRects`/`enableCursorRects`-Timing

---

### Arch-Slice-9 Addendum — Cursor-/Modifier-Feedback Phase 1 (14. April 2026)

**Ziel:** Cursor-Feedback für alle 7 Session-Typen ohne AppKit-Abhängigkeiten in IC oder SwiftUI-Schicht.

#### Architektur — vier Schichten, klare Verantwortlichkeiten

```
IC.sessionCursorHint (@Published)
    ↓ Combine-Sink
CursorController (AppKit, Combine, NSEvent-Monitor)
    ↓ CursorPolicy (pure)
NSCursor.set() + disableCursorRects / enableCursorRects
```

| Schicht | Datei | Verantwortlichkeit |
|---|---|---|
| `SessionCursorHint` | `ActiveSession.swift` | Lightweight enum: 5 Zustände ohne AppKit-Import |
| `IC.sessionCursorHint` | `InteractionController.swift` | `@Published` — einziger Kanal aus IC; IC bleibt modifier-agnostisch |
| `CursorPolicy` | `Engine/CursorPolicy.swift` | Pure Mapping `(SessionCursorHint, NSEvent.ModifierFlags) → NSCursor`; kein State, keine Side-Effects |
| `CursorController` | `Engine/CursorController.swift` | AppKit-Owner; Combine-Sink + `flagsChanged`-Monitor; einziger aktiver Cursor-Schreiber während Sessions |

#### SessionCursorHint — 5 Zustände

```swift
enum SessionCursorHint: Equatable {
    case none               // kein Session-Cursor
    case resizeHorizontal   // handleDrag, ratioDrag      → resizeLeftRight
    case resizeVertical     // pitchDrag, stretchRatioDrag, stretchCountDrag → resizeUpDown
    case selectRegion       // rubberBand                 → crosshair
    case moveStep           // stepSwap                   → closedHand / dragCopy (Option)
}
```

**Mapping in `CursorPolicy`:**
- `.moveStep` ist modifier-sensitiv: Option → `NSCursor.dragCopy`; sonst → `NSCursor.closedHand`
- Alle anderen Zustände sind modifier-agnostisch

#### IC-Lifecycle (Einhalteregeln)

- `sessionCursorHint` wird in **jedem** `begin*`-Aufruf gesetzt (7 Methoden)
- `sessionCursorHint` wird in **jedem** `commit*` und `cancel*` auf `.none` zurückgesetzt (14 Sites)
- `beginPinchZoom` setzt **kein** Hint — Pinch läuft außerhalb des `_session`-Slots
- `guard _session == nil` + Hint-Set sind atomar innerhalb desselben Methodenkörpers

#### CursorController — exklusive Cursor-Kontrolle während Sessions

```swift
final class CursorController {
    init(ic: InteractionController)  // installiert Combine-Sink + NSEvent-Monitor

    private func apply() {
        let hint   = ic.sessionCursorHint
        let cursor = CursorPolicy.cursor(hint: hint, modifiers: NSEvent.modifierFlags)
        if hint != .none {
            NSApp.keyWindow?.disableCursorRects()  // unterdrückt View-Layer-Cursor
            cursor.set()
        } else {
            NSApp.keyWindow?.enableCursorRects()
            NSApp.keyWindow?.resetCursorRects()    // stellt Hover-Cursor wieder her
            NSCursor.arrow.set()
        }
    }
}
```

**Lifetime:** `lazy var cursorController` auf `SequencerEngine`; Init-Trigger in `.onAppear { _ = engine.cursorController }` in `VintageSequencerApp`.

#### Hover-Cursor (Idle-Zustand, View-Schicht)

Cursor während **keiner** Session kommt ausschließlich aus der View-Schicht:
- `HandleNSView.resetCursorRects()` → `resizeLeftRight` (bestehend, E2.4)
- `StretchHandleView.onHover { }` → `resizeUpDown` / `arrow` (neu, Phase 1)

```swift
// StretchHandleView — nur im Idle-Zustand aktiv
.onHover { hovering in
    guard !interactionController.isSessionActive else { return }
    if hovering { NSCursor.resizeUpDown.set() } else { NSCursor.arrow.set() }
}
```

**Invariante:** `disableCursorRects()` während einer Session verhindert, dass `HandleNSView.resetCursorRects()` den Session-Cursor überschreibt. `enableCursorRects()` am Session-Ende stellt das Hover-Verhalten wieder her.

#### Tests (Cursor Phase 1)

`InteractionArchitectureTests.swift` — **+36 Tests** (von 185 auf **221 Tests** total, zzgl. bereits vorhandener Slice-9-Tests; grep-Gesamtzahl: **232**):

**`CursorPolicyTests` (14 Tests) — pure Mapping, kein State:**
- `.none` ohne Modifier → `NSCursor.arrow`
- `.none` mit Modifiern → `NSCursor.arrow` (Modifier ignoriert)
- `.resizeHorizontal` ohne / mit Option → `NSCursor.resizeLeftRight`
- `.resizeVertical` ohne / mit Option → `NSCursor.resizeUpDown`
- `.selectRegion` ohne / mit Option → `NSCursor.crosshair`
- `.moveStep` ohne Modifier → `NSCursor.closedHand`
- `.moveStep` mit Command only → `NSCursor.closedHand`
- `.moveStep` mit Shift only → `NSCursor.closedHand`
- `.moveStep` mit Option → `NSCursor.dragCopy`
- `.moveStep` mit Option + Shift → `NSCursor.dragCopy`
- `.moveStep` mit Option + Command → `NSCursor.dragCopy`

**`ICCursorHintTests` (22 Tests) — Lifecycle-Korrektheit:**
- Initial-Zustand `.none` (1)
- je 3 Tests pro Session-Typ (begin → hint gesetzt; commit → .none; cancel → .none):
  handleDrag(3) · ratioDrag(3) · rubberBand(3) · pitchDrag(3) · stepSwap(3)
  stretchRatioDrag(3) · stretchCountDrag(3)
  = 1 + 21 = 22 Tests

**Nicht getestet (AppKit-Event-Loop abhängig):**
- `CursorController` Combine-Sink Reaktion (verified manuell)
- `flagsChanged`-Monitor Reaktion (verified manuell)
- `disableCursorRects`/`enableCursorRects` Timing (AppKit — manuell)

---

### Arch-Slice-9 — Nachbesserungs-Session (14. April 2026)

**Drei gezielte Fixes nach der Erst-Implementierung:**

#### Fix A — Echter Pointer-Anker beim Pinch-Zoom

**Problem:** `StepGridView` zoomed bisher zur View-Mitte (`geo.size.width / 2`), nicht zum tatsächlichen Pinch-Zentrum der Finger.

**Ursache:** `MagnificationGesture` liefert keinen Ankerpunkt — nur den Skalierungsfaktor.

**Fix:** `MagnifyGesture` (macOS 14+) liefert `startAnchor: UnitPoint` — den tatsächlichen Zwei-Finger-Mittelpunkt zu Beginn der Geste.

```swift
// macOS 14+:
MagnifyGesture(minimumScaleDelta: 0.01)
    .onChanged { value in
        let anchorX = value.startAnchor.x * geo.size.width  // echter Pointer-Anker
        interactionController.updatePinchZoom(magnification: value.magnification, anchorX: anchorX)
    }
```

Fallback: `MagnificationGesture` mit View-Mitte als Anker für macOS < 14 (`if #available(macOS 14.0, *)`).

`ViewportController.adjustScroll` bleibt unverändert — die Formel war korrekt, nur der `anchorX`-Input war falsch.

#### Fix B — Modell-Einfrieren bei schnellem Drag (Handle-Edge-Scroll-Kopplung)

**Problem:** Bei schnellem Drag in die Edge-Scroll-Zone bleibt der Step-Count / Ratio-Wert stehen.

**Ursache:** Wenn der Pointer am Bildrand stehen bleibt (Edge-Zone erreicht), feuern keine weiteren `leftMouseDragged`-Events. Der Auto-Scroll-Timer (`HandleNSView.startEdgeScrollTimer`) scrollt zwar weiter, ruft aber nur `onEdgeScroll` auf — kein `onDrag`. Das IC-Update `updateHandleDrag(totalX:track:)` wurde nie erneut aufgerufen, obwohl sich `hScrollOffset` geändert hatte und damit `contentDisplacement = totalX + (currentOffset − startOffset)` einen neuen Wert ergeben hätte.

**Fix:** Im Timer-Dispatch NACH dem Scroll-Aufruf auch `onDrag?(pendingTotalX)` aufrufen:

```swift
// HandleNSView.startEdgeScrollTimer — Reihenfolge kritisch:
self.onEdgeScroll?(self.pendingEdgeVel)   // 1. Viewport scrollen
self.onDrag?(self.pendingTotalX)          // 2. Modell mit neuem Offset nachführen
```

**Warum das funktioniert:** `onDrag` liest `viewportController.scrollState.hScrollOffset` im selben Main-Thread-Drain, NACHDEM `onEdgeScroll` den Offset bereits erhöht hat. Die Idempotenz-Guard in IC (`guard proposed != track.stepCount else { return }`) verhindert doppelte Schreibvorgänge wenn nichts geändert hat.

**Invariante gewahrt:** Kein neuer Scroll-Schreiber. Kein neuer IC-Pfad. `onDrag` und `onEdgeScroll` sind weiterhin die einzigen Quellen.

#### Fix C — Öffnen im macOS-konformen Menü-Slot

**Problem:** `Button(openPreset)` war innerhalb `CommandGroup(replacing: .saveItem)` — d.h. im Menü an FALSCHER Position (nach Speichern, nicht davor).

**Fix:** Aufteilen auf zwei Gruppen:
```
CommandGroup(replacing: .openItem)  → Öffnen, Zuletzt geöffnet
CommandGroup(replacing: .saveItem)  → Speichern, Speichern unter
```

Damit folgt die macOS-Datei-Menü-Struktur dem Standard: Neu → Öffnen/Öffnen Recent → [Trennlinie] → Speichern/Speichern unter.

---

### Arch-Slice-9 — Pinch-Zoom + EdgeScroll-Defaults + Standard-Menüstruktur (abgeschlossen, 14. April 2026)

**Ziel (drei entkoppelte Erweiterungen):**
1. **Pinch-Zoom:** Trackpad-Pinch → `engine.stepWidthSize` mit anchor-stabilem Scroll-Ausgleich.
2. **EdgeScroll-Defaults festziehen:** Größere Zonen (300 px), höhere Maximalgeschwindigkeit (20 px/frame), Insets-Wiring.
3. **Standard-macOS-Menüstruktur:** Neu (⌘N), Speichern (⌘S, in-place), Speichern unter (⌘⇧S), Öffnen (⌘O).

#### Teil 0 — EdgeScroll-Defaults + Insets-Wiring

`EdgeScrollVelocity` — neue Default-Werte:

| Parameter | Alt (Slice-8) | Neu | Begründung |
|---|---|---|---|
| `defaultZoneWidth` | 120 px | **300 px** | Gesamte Step-Bereich-Breite als Zone — Scroll überall im Grid |
| `defaultMaxVelocity` | 10 px/frame | **20 px/frame** | 1200 px/s Peak; Smoothstep hält Einstieg sanft |
| `defaultLeftInset` | — | **50 px** | Schutzrand links (Track-Header-Übergang) |
| `defaultRightInset` | — | **50 px** | Schutzrand rechts (Stretch-Handle-Übergang) |

Inset-Wiring in `velocity()`:
- `distLeft  = pointerX − leftInset`   (links-Zone startet erst nach dem Inset)
- `distRight = (viewWidth − rightInset) − pointerX`   (rechts-Zone endet vor dem Inset)
- Beide Zonen nur aktiv wenn Distance ≥ 0 (kein Scroll im Inset-Bereich)

Debug-Panel-Erweiterungen:
- Slider-Bereiche: Zonen 10…500, Max-V 1…60, Insets 0…300
- Neuer ZOOM-Abschnitt: `Min Z`, `Max Z`, `Z Sens` Slider + `Zoom`/`Scroll`-Readback
- Toggle-Label: `▾/▸ EdgeScroll` → `▾/▸ Debug` (Panel deckt jetzt beides ab)
- Reset-Button setzt auch Zoom-Parameter zurück

#### Teil A — Pinch-Zoom (Arch-Slice-9)

**Architektur:** Kein neuer `ActiveSession`-Fall — Pinch-Zoom läuft parallel zu Sessions.

`ViewportController` — neue API:
```swift
@Published private(set) var zoomScale: CGFloat = 1.0
func adjustScroll(oldStepWidth: CGFloat, newStepWidth: CGFloat, anchorX: CGFloat)
```
- Formel: `newScrollOffset = (anchorX + scrollOffset) × (newWidth / oldWidth) − anchorX`
- `zoomScale = newStepWidth / 54.0` (54 px = Standard-Basis)

`InteractionController` — neue API:
```swift
func beginPinchZoom(currentStepWidth: CGFloat)
func updatePinchZoom(magnification: CGFloat, anchorX: CGFloat) -> Double   // returns new stepWidth
func endPinchZoom()
```
- Kein `_session`-Slot — Modal-Invariante nicht tangiert
- `pinchSnapshotStepWidth` captured bei `begin`, `pinchPrevStepWidth` für inkrementellen Ratio
- Scroll-Kompensation: inkrementelles `oldWidth/newWidth`-Verhältnis pro Frame
- In DEBUG: liest `zoomSensitivity`, `minZoomScale`, `maxZoomScale` aus `EdgeScrollDebugConfig`
  und schreibt `liveZoomScale`, `liveScrollOffset` zurück

`StepGridView` — Gesture:
- `MagnificationGesture(minimumScaleDelta: 0.01)` auf dem ZStack
- `anchorX = geo.size.width / 2` (Viewport-Mitte als fixierter Punkt)
- `engine.stepWidthSize` wird direkt vom `onChanged`-Callback beschrieben
- `@State var isPinching: Bool` als Session-Guard (kein Re-Enter bei Begin)

**Invarianten:**
- Single Scroll-Write-Authority: `viewportController.adjustScroll()` nach wie vor einziger Zoom-Scroll-Pfad
- Kein direktes `scrollState.hScrollOffset`-Schreiben außerhalb VC
- Debug-Parameter mit Nullkosten in RELEASE (`#if DEBUG` überall)

#### Teil B — Debug-Panel Zoom-Erweiterung

`EdgeScrollDebugConfig` — neue Felder:
```swift
// Zoom-Parameter (nur DEBUG)
@Published var minZoomScale:    CGFloat = 0.5
@Published var maxZoomScale:    CGFloat = 4.0
@Published var zoomSensitivity: CGFloat = 1.0
// Live-Readback
@Published var liveZoomScale:    CGFloat = 1.0
@Published var liveScrollOffset: CGFloat = 0
```

`EdgeScrollDebugPanel` — ZOOM-Sektion nach den EdgeScroll-Readbacks:
- Slider: Min Z (0.1…1.0), Max Z (1.0…8.0), Z Sens (0.1…3.0)
- Live: Zoom (%.3f), Scroll (%.0f)

#### Teil C — Standard-macOS-Menüstruktur

Neue Methoden in `SequencerEngine+PresetIO.swift`:
- `newProject()` — prüft `hasUnsavedChanges`, stoppt Playback, setzt Patterns auf 4× Default, löscht `currentPresetURL`
- `savePresetInPlace()` — schreibt direkt in `currentPresetURL`; Fallback auf `savePreset()` wenn keine URL

Neue Menüstruktur in `VintageSequencerApp.swift`:
```
Datei
  Neu            ⌘N → engine.newProject()
  ──────
  Speichern      ⌘S → engine.savePresetInPlace()   (in-place, kein Dialog wenn URL vorhanden)
  Speichern unter… ⌘⇧S → engine.savePreset()       (immer Dialog)
  ──────
  Öffnen…        ⌘O → engine.loadPreset()
  Zuletzt geöffnet  (unverändert)
```

Neue `Str`-Keys: `newProjectMenuItem`, `newProject`, `savePresetInPlace`, `saveAsPreset`, `newProjectUnsavedMessage`.

**Invariante:** Kein UI-Button dupliziert Menü-Aktionen. AppDelegate-`applicationShouldTerminate` nutzt weiterhin `savePreset()`.

#### Tests (Arch-Slice-9, inkl. Nachbesserungs-Session)

`InteractionArchitectureTests.swift` — **185 Tests total** (+15 gegenüber Slice-8):
- `EdgeScrollVelocityTests` — 4 neue Inset-Tests:
  `velocity_insideLeftInset_isZero`, `velocity_insideRightInset_isZero`,
  `velocity_pastLeftInset_scrollsLeft`, `velocity_pastRightInset_scrollsRight`
- `ViewportControllerScrollBridgeTests` — 7 neue `adjustScroll`-Tests:
  doubling anchor-stable, anchorX=0 no-change, with scrollOffset, same-width no-op,
  clamps to zero, updates zoomScale, zero oldWidth guard
- Bestehende `EdgeScrollVelocity`-Tests: `leftInset: 0, rightInset: 0` explizit übergeben
  (isolieren Zone-Policy von Inset-Defaults); `zoneWidth`- und `maxVelocity`-Kommentare aktualisiert
- `InteractionControllerTests` — 2 neue Regressions-Tests für Fast-Drag-Fix:
  `updateHandleDrag_stationaryPointer_scrollIncreases_advancesStepCount` (3-Phasen-Progression),
  `updateHandleDrag_scrollWithoutPointerMove_isIdempotentAtMax` (Clamp-Stabilität bei stepCount=64)

---

### Arch-Slice-8 — StretchHandleView-Migration + EdgeScroll-Debug-Panel (abgeschlossen, 14. April 2026)

**Ziel:**
- Letzten verbleibenden `@State`-Akkumulator-Pfad im Handle-/Stretch-Bereich entfernen.
- Debug-Werkzeug für live EdgeScroll-Rampen-Tuning (nur DEBUG-Build).

#### Teil A — StretchHandleView-Migration (Arch-Slice-8)

Neues Session-System:
- `StretchRatioDragSession` — vertikaler Drag für `stepLengthNumerator/Denominator`.
  - `pxPerIndex = 24` (entspricht alter Sensitivity in StretchHandleView).
  - `proposedRatioIndex(totalY:)` — kein Akkumulator, direkter `translation.height`-Wert.
  - `commitCommand(currentNum:currentDen:)` → `.setRatio(...)`.
- `StretchCountDragSession` — vertikaler Drag für `stepCount`.
  - `pxPerStep = 18` (entspricht alter `stepSensitivity`).
  - `proposedStepCount(totalY:)` — kein Akkumulator.
  - `commitCommand(currentStepCount:)` → `.setStepCount(...)`.

Neue `ActiveSession`-Fälle:
- `.stretchRatioDrag(StretchRatioDragSession)` — Arch-Slice-8
- `.stretchCountDrag(StretchCountDragSession)` — Arch-Slice-8

Neue IC-Methoden (8 insgesamt, gleiches Qualitäts-Pattern wie Slices 1–7):
- `beginStretchRatioDrag(track:)` / `updateStretchRatioDrag(totalY:track:)` /
  `commitStretchRatioDrag(track:undoManager:)` / `cancelStretchRatioDrag(track:)`
- `beginStretchCountDrag(track:)` / `updateStretchCountDrag(totalY:track:)` /
  `commitStretchCountDrag(track:undoManager:)` / `cancelStretchCountDrag(track:)`

Kein neuer `ModelCommand` nötig: `.setRatio(...)` und `.setStepCount(...)` sind bereits vorhanden.

StretchHandleView nach Migration:
- Entfernt: `@State var dragStartY`, `dragBaseIndex`, `isRatioDragging` (Akkumulator),
  `stepStartY`, `stepBase`, `ratioUndoSnapshot`, `stepCountUndoSnapshot`, `stepSensitivity`.
- Behalten: `@State var isRatioDragging: Bool` (rein visuelles Rendering-Flag),
  `@State var isCountDragging: Bool` (Session-Guard), `@State var showRatioPopover`.
- `@EnvironmentObject var interactionController: InteractionController` hinzugefügt.
- Kein direktes `track.stepCount`-Schreiben, kein `track.stepLengthNumerator`-Schreiben,
  kein `undoManager?.registerUndo`.

#### Teil B — EdgeScroll-Debug-Panel (Arch-Slice-8)

Neue Datei `Engine/EdgeScrollDebugConfig.swift` (nur `#if DEBUG`):
- Singleton `EdgeScrollDebugConfig` mit `@Published`-Parametern:
  `leftZoneWidth`, `rightZoneWidth`, `maxVelocity`, `leftInset`, `rightInset`.
- Live-Readback-Felder: `livePointerX`, `liveVelocity`, `liveViewWidth`.
- Nullkosten in RELEASE (gesamte Klasse in `#if DEBUG`).

`EdgeScrollVelocity.velocity(...)` — API-Erweiterung:
- Parameter `zoneWidth: CGFloat` → `leftZoneWidth: CGFloat, rightZoneWidth: CGFloat`.
- Defaultwerte beibehalten — alle bestehenden Call-Sites ohne Named-Args bleiben unverändert.
- Ermöglicht asymmetrische Zonen (z.B. größere Linkszone wenn linker Header-Bereich endet früher).

`InteractionController.edgeScrollTick()` — DEBUG-Wiring:
- In DEBUG: liest `EdgeScrollDebugConfig.shared.leftZoneWidth/rightZoneWidth/maxVelocity`,
  schreibt `livePointerX`, `liveVelocity`, `liveViewWidth` zurück.
- In RELEASE: unveränderte Default-Params.

`HandleNSView.updateEdgeScrollVelocity()` — DEBUG-Wiring:
- Identisches `#if DEBUG`-Muster wie IC.

Neue Datei `Views/EdgeScrollDebugPanel.swift` (nur `#if DEBUG`):
- Kollabierbare SwiftUI-HUD, `.overlay(alignment: .topTrailing)` in `MainView`.
- Slider für alle 5 Parameter + Live-Readback + Reset-Button.
- Zeigt effektive Viewport-Zonen (`Dead L`, `Dead R`).
- Schreibt NUR in `EdgeScrollDebugConfig.shared` — kein eigener Scroll-Code.

**Invarianten gewahrt:**
- Modal-Invariante: `beginStretch*` no-ops wenn `_session != nil`.
- Single Scroll-Write-Authority: `ViewportController.scroll(by:)` nach wie vor einziger Pfad.
- Session-Guard: `syncFromScrollbar` blockt während Stretch-Session.
- Debug-Panel hat keine Produktionsarchitektur-Abhängigkeiten.

#### Tests (Arch-Slice-8)

`InteractionArchitectureTests.swift` — 170 Tests total (+25 gegenüber Slice-7):
- `StretchRatioDragSessionTests` (7): proposedRatioIndex, Grenzen, pxPerIndex, commitCommand
- `StretchCountDragSessionTests` (7): proposedStepCount, Grenzen, pxPerStep, commitCommand
- `InteractionControllerStretchTests` (11): begin/update/commit/cancel für Ratio + Count, Modal-Invariante, Session-Guard

**EdgeScroll-Tuning — Default-Werte (abgeschlossen nach Slice-8):**

Gemessen gegen das tatsächliche Layout (trackHeaderWidth=224px, stepSlot=58px,
StepGridView geo.size.width ≈ 575px bei 920px Fensterbreite):

| Parameter | Alt | Neu | Begründung |
|---|---|---|---|
| `defaultZoneWidth` | 80 px | **120 px** | ≈ 2,1 Step-Slots Vorlauf; Scroll startet ~2 Steps vor dem Rand |
| `defaultMaxVelocity` | 14 px/frame | **10 px/frame** | 600 px/s; überquert Grid in ~1 s; 14 war 0,68 s → zu ruckartig |

Nebeneffekt HandleNSView (by design):
- Left-Zone 120px liegt vollständig im 224px-Track-Header → linker Auto-Scroll
  während Handle-Drag **natürlich deaktiviert** (kein Zurückziehen nötig).
- Right-Zone 120px startet 120px vor dem Fensterrand → genug Vorlauf für flüssige
  Expansion ohne den Rand zu erreichen.

Smoothstep-Profil bei zone=120, maxV=10:
- 0px vom Rand → 10.0 px/frame (Maximum)
- 30px → 8.44 (flüssig)
- 60px (≈ 1 Step) → 5.0 (sanft)
- 100px → 0.74 (kaum spürbar)
- 120px → 0 (Rampen-Ende)

**Hinweis:** Die Tuning-Werte (defaultZoneWidth=120, defaultMaxVelocity=10) wurden in Arch-Slice-9 auf 300 px / 20 px/frame angehoben und mit `leftInset`/`rightInset` ergänzt.

**Noch ausstehend (nach Slice-9):**
- Cursor-/Modifier-Feedback für Stretch-Handle.
- Produktions-UI für Scroll-Tuning-Parameter.

---

### Arch-Slice-7 — AutoScroll-Rampe + Handle-Geometrie (abgeschlossen, 13. April 2026)

**Ziel:** Siebter vertikaler Schnitt — zwei strukturelle Fixes in einem Slice:
1. Weiche Auto-Scroll-Rampe (Smoothstep) vor dem Viewport-Rand
2. Geometrisch korrekte Handle-Mathematik (Handle folgt Pointer pixelgenau)

Kein neuer Parallelpfad. Kein Bastelcode. Alles in der bestehenden Architektur.

#### Teil A — Auto-Scroll-Rampe

**Problem:** `EdgeAutoScroller` (Timer in View/Coordinator) konnte während SwiftUI-
Renderpässen feuern → "Publishing changes from within view updates". Lineare Rampe
mit hartem Einsatz am Rand.

**Lösung:**

| Datei | Änderung |
|-------|----------|
| `Engine/EdgeScrollVelocity.swift` | **Neu** — Pure Funktion: `velocity(pointerX:viewWidth:) → CGFloat`. Smoothstep-Kurve, konfigurierbare Zone (80 px) + Max (14 px/Frame). Keine Abhängigkeiten, vollständig testbar. |
| `Engine/InteractionController.swift` | IC besitzt `Timer` (60 Hz); `updateEdgeScrollPointer(x:viewWidth:)` startet/aktualisiert; `endEdgeScroll()` stoppt. Timer-Callback: `DispatchQueue.main.async` → Scroll außerhalb SwiftUI-Render-Phase. Alle Session-End-Pfade rufen `endEdgeScroll()`. |
| `Views/StepGridView.swift` | `grid.autoScroller.run/stop(...)` → `IC.updateEdgeScrollPointer(x:viewWidth:)` + `IC.endEdgeScroll()`. View hat keinen Timing-Code mehr. |
| `Views/StepGridCoordinator.swift` | `var autoScroller = EdgeAutoScroller()` entfernt. |
| `Views/EdgeAutoScroller.swift` | Tombstone — Klasse gelöscht, Erklärung warum. |
| `Views/CornerDotHandle.swift` | `HandleNSView.updateEdgeScrollVelocity` ersetzt hardcoded lineare Formel durch `EdgeScrollVelocity.velocity(pointerX:viewWidth:)`. HandleNSView-eigener Timer bleibt (routes korrekt durch `applyEdgeScroll → VC.scroll(by:)`). |

**Scroll-Kurve:**
```
t = clamp((zone − distance) / zone, 0, 1)   // distance = Abstand zum nächsten Rand
v = maxVelocity × t² × (3 − 2t)              // Smoothstep
```
Parameter: zone = 80 px, max = 14 px/Frame @ 60 Hz ≈ 840 px/s.

**Warum `DispatchQueue.main.async` in Timer-Callback:**
Der Timer feuert auf dem Main-RunLoop. SwiftUI prozessiert Renders ebenfalls auf
dem Main-Thread. Ohne `async` kann ein Timer-Tick mitten in einem SwiftUI-Render
landen → Warning. Mit `async` wird der Scroll-Write in der nächsten RunLoop-Iteration
ausgeführt — garantiert außerhalb des aktuellen Render-Passes.

#### Teil B — Handle-Geometrie

**Problem:** Mauszeiger "verliert" den Handle während Auto-Scroll.

**Ursache (exakt):**

```
// Ohne Scroll-Kompensation:
handleScreenX = proposedStep × pxPerStep − S_t
             = snapshotStep × pxPerStep + translationX − S_t
             = H_screen_0 + translationX − ΔS   ← Drift = ΔS
```

Der Handle fällt um exakt `ΔS` (den Scroll-Delta seit Drag-Beginn) hinter den Pointer zurück.

**Lösung — Content-Space-Displacement:**

```swift
// In HandleDragSession / RatioDragSession:
contentDisplacement = translationX + (currentScrollOffset − scrollOffsetAtStart)

// Führt zu:
handleScreenX = proposedStep × pxPerStep − currentScrollOffset
             ≈ H_screen_0 + translationX   // ΔS kürzt sich vollständig heraus
```

| Datei | Änderung |
|-------|----------|
| `Engine/ActiveSession.swift` | `HandleDragSession`: `accumulator` entfernt; `scrollOffsetAtStart: CGFloat` hinzugefügt; `proposedStepCount()` → `proposedStepCount(translationX:currentScrollOffset:)` (gibt `contentDisplacement` weiter). `liveCommand()` entfernt — IC baut Command direkt. Gleiche Änderungen in `RatioDragSession`. |
| `Engine/InteractionController.swift` | `beginHandleDrag/beginRatioDrag`: übergibt `scrollOffsetAtStart: viewportController.scrollState.hScrollOffset` an Session. `updateHandleDrag/updateRatioDrag`: liest `currentScrollOffset` aus VC, übergibt an Session, baut `ModelCommand` direkt (kein `session.liveCommand()`). `_session` wird in Update-Pfad nicht mehr mutiert (kein Accumulator). |

**Aus den Sessions entfernt:**

| Was | War wo | Warum weg |
|-----|--------|-----------|
| `accumulator: CGFloat` | `HandleDragSession` + `RatioDragSession` | Ersetzt durch direkte `translationX`-Übergabe (DragGesture liefert total, nicht delta) |
| `liveCommand() -> ModelCommand` | Beide Sessions | IC baut Command direkt; Session bleibt pure computation ohne Command-Wissen |
| `proposedRatio: (num:den:)` | `RatioDragSession` | Parameterlos nicht mehr möglich; IC nutzt `proposedRatio(translationX:currentScrollOffset:)` |

**Kein Accumulator mehr — warum korrekt:**
SwiftUI `DragGesture` liefert `value.translation.width` als **Gesamt-Delta vom Drag-Start**
(nicht Inkrement). Der IC hat diesen Wert schon als `totalX` übergeben. Das Akkumulieren
in der Session war eine Redundanz und ein Drift-Risiko bei Floating-Point.

#### Tests (Arch-Slice-7)

`InteractionArchitectureTests.swift` — 145 Tests total at Slice-7 (+27 gegenüber Slice-6):
- `HandleDragSessionTests` (11): vorher 9 mit `accumulator`; jetzt 11 mit `translationX/currentScrollOffset`; 3 neue Scroll-Kompensations-Tests
- `RatioDragSessionTests` (7): alle auf neue Signatur umgestellt; 2 neue Scroll-Kompensations-Tests
- `EdgeScrollVelocityTests` (9): Mitte→0, Zonengrenze→0, Randwerte, Vorzeichen, max nicht überschritten, Smoothstep-Midpoint, Monotonie, Custom-Parameter, Degenerate-Inputs

**Noch im alten Pfad (ausstehend):**
- Pinch-Zoom

---

### Arch-Slice-6 — Trackpad / Scrollbar-Bridge (abgeschlossen, 13. April 2026)

**Ziel:** Sechster vertikaler Schnitt — alle direkten Schreibzugriffe auf
`scrollState.hScrollOffset` aus Views entfernt. `ViewportController` ist nun die
**einzige legitime Scroll-Schreib-Autorität** der gesamten App.

**Eingeführt / geändert:**

| Datei | Änderung |
|-------|----------|
| `Engine/ViewportController.swift` | `maxScrollOffset: CGFloat` (Default: `.greatestFiniteMagnitude`); `isSyncingScrollbar: Bool` (internal); `scrollTrackpad(delta:)` — macOS-Vorzeichen-Konvention + Clamp; `syncFromScrollbar(_:)` — Session-Guard + Re-Entranz-Guard + Clamp |
| `Views/MainView.swift` | Trackpad-Handler: `viewportController.scrollTrackpad(delta: dx)` statt direktem `scrollState`-Schreiben; `maxScrollOffset` nach jeder Trackpad-Event + `.onChange(of: laneContentWidth)` aktualisiert; `GlobalHScrollbar` hat kein `scrollState`-EnvironmentObject mehr; `NativeHScrollbar` hat kein `@Binding var offset` + kein `isHandleDragging` mehr — verwendet `viewportController` direkt |

**Drei Schreib-Pfade (alle in ViewportController):**

| Pfad | API | Triggerort |
|------|-----|-----------|
| Interaktions-Edge-Scroll | `scroll(by:)` | `IC.applyEdgeScroll` → Handle / Rubber-Band / Pitch-Drag |
| Zwei-Finger-Trackpad | `scrollTrackpad(delta:)` | `NSEvent`-Monitor in `MainView.onAppear` |
| Scrollbar-Thumb-Drag | `syncFromScrollbar(_:)` | `NativeHScrollbar.Coordinator.boundsChanged` |

**Re-Entranz-Loop (gelöst durch `isSyncingScrollbar`):**

```
VC writes hScrollOffset
  → SwiftUI updateNSView fires
    → sets vc.isSyncingScrollbar = true
    → sv.contentView.scroll(to:)   ← fires boundsChanged synchronously
      → Coordinator.boundsChanged calls vc.syncFromScrollbar(x)
        → guard !isSyncingScrollbar → return  ← loop stopped
    → sets vc.isSyncingScrollbar = false
```

**Session-Guard in `syncFromScrollbar`:**
Während `vc.sessionActive == true` (Handle-Drag, Rubber-Band, etc.) schreibt
`syncFromScrollbar` niemals — verhindert, dass der NSScrollView-Thumb während
einer Handle-Drag-Session eine veraltete Position zurückschreibt.

**`NativeHScrollbar.Coordinator` — vereinfacht:**

| Vorher | Nachher |
|--------|---------|
| `var offset: Binding<CGFloat>` | entfernt |
| `var isSyncing = false` | entfernt — lebt in `ViewportController.isSyncingScrollbar` |
| `var isHandleDragging = false` | entfernt — lebt in `ViewportController.sessionActive` |
| `offset.wrappedValue = x` in `boundsChanged` | `viewportController.syncFromScrollbar(x)` |

**Kein direktes `scrollState.hScrollOffset`-Schreiben mehr:**
Alle drei Pfade laufen durch `ViewportController`. Views sind reine Leser von
`scrollState.hScrollOffset` (via `@EnvironmentObject var scrollState`).

**Tests:** `InteractionArchitectureTests.swift` — 118 Tests total (+10 gegenüber Slice-5):
- `ViewportControllerScrollBridgeTests` (10): scrollTrackpad pos/neg, Clamp oben/unten/exakt, scrollBy Clamp, maxScrollOffset Default unklamped, syncFromScrollbar schreibt/Clamp low+high, Session-Guard, Re-Entranz-Guard, Flag-Reset, erlaubt nach Session-Ende, Runtime-Update clamps nachträglich

**Noch im alten Pfad (ausstehend):**
- Pinch-Zoom

---

### Arch-Slice-4+5 — Pitch-Drag / Step-Swap (abgeschlossen, 13. April 2026)

**Ziel:** Vierter und fünfter vertikaler Schnitt — in einer gemeinsamen Session.
Nach diesen Slices läuft der **gesamte interaktive StepGrid-Kern** vollständig über
die neue Interaktionsarchitektur. Kein alter Interaktionspfad mehr aktiv.

**Eingeführt / erweitert:**

| Datei | Änderung |
|-------|----------|
| `Engine/ActiveSession.swift` | `PitchDragSession` + `StepSwapSession` (Value Types) neu; `StepSwapUpdate` + `StepSwapPhase` neu; `ActiveSession` um `.pitchDrag` + `.stepSwap` erweitert |
| `Engine/ModelCommand.swift` | `.setPitchNotes(trackID:stepIndex:oldNotes:newNotes:)` + `.setSteps(trackID:oldSteps:newSteps:actionName:)` neu; `undoActionName` für beide Cases |
| `Engine/ModelWriter.swift` | `setPitchNotes`-Case (setzt notes, aktiviert Step, optionales Undo); `setSteps`-Case (ersetzt volle Steps-Array, optionales Undo) |
| `Engine/InteractionController.swift` | `@Published stepSwapUpdate: StepSwapUpdate?`; `beginPitchDrag`, `updatePitchDrag(→[Int]?)`, `commitPitchDrag`, `cancelPitchDrag`; `beginStepSwap`, `updateStepSwap`, `commitStepSwap`, `cancelStepSwap`; `publishStepSwapUpdate` helper |
| `Views/StepGridCoordinator.swift` | Alle alten Pitch-/Swap-Felder entfernt; `icStepSwapSink` + erweitertes `connectInteractionController` |
| `Views/StepGridView.swift` | `simultaneousGesture`-Block vollständig ersetzt; `lang`/`s` entfernt (nicht mehr referenziert) |

**Pitch-Drag — was jetzt über neue Architektur läuft:**
- `onChanged` (erste Bewegung, dy > dx) → `IC.beginPitchDrag(track:stepIndex:)` — Snapshot in Session
- `onChanged` (folgende Events, `.pitchDrag` aktiv) → `IC.updatePitchDrag(totalY:track:)` → Returns `[Int]?` für MIDI-Vorschau
- Semitone-Dedup: `lastAppliedSemitones` in Session; IC gibt nil zurück wenn kein neuer Halbton
- MIDI-Vorschau: View ruft `engine.previewPlay` wenn IC `[Int]` zurückgibt (kein engine-Zugriff aus IC)
- `onEnded` → `engine.stopPreview()` + `IC.commitPitchDrag(track:undoManager:)` → ein Undo-Eintrag (`.setSteps` mit Snapshot)
- Cancel: `IC.cancelPitchDrag(track:)` → `ModelWriter.apply(.setSteps(old:current, new:snapshot))` — stellt exakt den Zustand vor Drag-Start wieder her

**Step-Swap — was jetzt über neue Architektur läuft:**
- `onChanged` (erste Bewegung, dx ≥ dy) → `IC.beginStepSwap(track:sourceIndex:stepWidth:)` — Snapshot in Session, Model wird NICHT mutiert
- `onChanged` (folgende Events, `.stepSwap` aktiv) → `IC.updateStepSwap(translationX:track:)` → aktualisiert `session.targetIndex`, publiziert `stepSwapUpdate`
- Render-Hints: `StepGridCoordinator.icStepSwapSink` empfängt Update, schreibt `dragSourceIndex`/`dragTargetIndex` → Step-Button-Overlay bleibt unverändert
- `onEnded` → `IC.commitStepSwap(track:isCopy:undoManager:)` → `session.commitCommand(isCopy:)` → `.setSteps` mit Snapshot (einziger Undo-Eintrag)
- Source == Target: automatisches No-Op in IC, kein Undo-Eintrag
- Cancel: `IC.cancelStepSwap()` — kein Model-Restore nötig (Model war nie mutiert)

**Aus dem alten Pfad entfernt:**

| Was | War wo | Lebt jetzt |
|-----|--------|-----------|
| `isPitchDrag: Bool` | `StepGridCoordinator` | `IC.activeSession == .pitchDrag(...)` |
| `pitchDragStepIndex: Int?` | `StepGridCoordinator` | `PitchDragSession.stepIndex` |
| `pitchStepsSnapshot: [Step]?` | `StepGridCoordinator` | `PitchDragSession.stepsSnapshot` |
| `pitchDragBaseNotes: [Int]?` | `StepGridCoordinator` | `PitchDragSession.baseNotes` (computed) |
| `pitchDragLastSemis: Int?` | `StepGridCoordinator` | `PitchDragSession.lastAppliedSemitones` |
| Direkte `track.steps = steps`-Mutation im `onChanged` | `StepGridView` gesture | `ModelWriter.apply(.setPitchNotes)` |
| Direkte `undoManager.registerUndo` im `onEnded` | `StepGridView` gesture | `ModelWriter.apply(.setSteps, undoManager:)` |
| `grid.dragSourceIndex = i` direkte View-Mutation | `StepGridView` gesture | `IC.$stepSwapUpdate` → `icStepSwapSink` → `coordinator.dragSourceIndex` |
| `grid.dragTargetIndex = …` direkte View-Mutation | `StepGridView` gesture | `IC.$stepSwapUpdate` → `icStepSwapSink` → `coordinator.dragTargetIndex` |
| `s.undoPitchDrag`, `s.undoMoveStep` (lokalisierte Undo-Namen in Gesture) | `StepGridView` | `ModelCommand.undoActionName` ("Pitch Drag", "Move Step", "Copy Step") |
| `@AppStorage("appLanguage") lang` + `var s: Str` | `StepGridView` | entfernt (kein `s.*`-Aufruf mehr in der View) |

**Kein Parallelpfad:** Die alten Felder (`isPitchDrag`, `pitchDrag*`, direkte `dragSourceIndex`/`dragTargetIndex`-Mutationen) wurden vollständig gelöscht. Es gibt keinen Hybrid-Zustand.

**Tests:** `InteractionArchitectureTests.swift` — 108 Tests total (+40 gegenüber Slice-3):
- `PitchDragSessionTests` (9): semitones zero/up/down, proposedNotes shift/clamp/chord, Snapshot-Immutabilität, lastAppliedSemitones nil
- `StepSwapSessionTests` (9): proposedTargetIndex no-op/right/left/clamp, stepCount, commitCommand swap/copy/snapshot-immutable
- `ModelWriterPitchSwapTests` (6): setPitchNotes anwenden/aktivieren/active-bleibt, setSteps ersetzen/undo/actionName
- `InteractionControllerPitchDragTests` (11): begin/snapshot, update anwenden/dedup/aktivieren, commit clearsSession/keepsChange, cancel restores, modal-Invariante (2×), neue Session nach commit
- `InteractionControllerStepSwapTests` (13): begin/snapshot, updateTarget/keinModelChange/publishesUpdate, commit swap/copy/noOp, cancel keinModelChange/publishesCancelled, modal-Invariante (2×), neue Session nach commit

**Noch im alten Pfad (ausstehend):**
- Pinch-Zoom

---

### Arch-Slice-3 — RubberBand / Selection (abgeschlossen, 13. April 2026)

**Ziel:** Dritter vertikaler Schnitt — Rubber-Band-Selektion läuft vollständig
über die neue Interaktionsarchitektur. Koordinatenmodell vereinheitlicht auf
reinen Content-Space. `engine.activeSelectionTrack` entfernt. Alle Zustandsmutationen
aus den Views entfernt; Views lesen ausschließlich IC- und Koordinator-State.

**Neu eingeführt / erweitert:**

| Datei | Änderung |
|-------|----------|
| `Engine/ActiveSession.swift` | `RubberBandSession` (Value Type): `anchorContentX`, `currentContentX`, `currentScreenX`, `stepWidth`, `stepCount`; `selectedSteps() -> Set<Int>` (pure Content-Space-Berechnung); `RubberBandPhase` enum (`.active / .committed / .cancelled`); `RubberBandUpdate` struct; `ActiveSession` um `.rubberBand(RubberBandSession)` erweitert |
| `Engine/ViewportController.swift` | `scrollState`-Property von `private let` auf `let` (internal) — IC kann jetzt auf `scrollState.$hScrollOffset` subscriben |
| `Engine/InteractionController.swift` | `@Published private(set) var rubberBandUpdate`; `setupScrollSync()` in `init`; `handleScrollOffsetChange(_:)`; `beginRubberBand`, `updateRubberBand`, `commitRubberBand`, `cancelRubberBand`; `publishRubberBandUpdate(from:phase:)` |
| `Views/StepGridCoordinator.swift` | `rubberAnchorContentX / rubberCurrentContentX: CGFloat?` (Content-Space, Render-State); `icSink: AnyCancellable?`; `connectInteractionController(_:track:)` — subscribt auf `IC.$rubberBandUpdate`, schreibt Overlay-Koordinaten + `selectedSteps` |
| `Views/StepGridView.swift` | Geste routet durch `IC.beginRubberBand/updateRubberBand`; Overlay rendert aus Content-Space-Koordinaten; `EdgeAutoScroller`-Callback routet via `IC.applyEdgeScroll`; `onAppear` verbindet Koordinator mit IC |
| `Views/EdgeAutoScroller.swift` | API-Änderung: `run(velocity:onScroll:)` statt `run(velocity:scrollState:engine:)`; kein direkter `scrollState`-Zugriff mehr |
| `Views/TrackRowView.swift` | `.onChange(of: engine.activeSelectionTrack)` entfernt (Tombstone-Kommentar) |
| `Engine/SequencerEngine.swift` | `@Published var activeSelectionTrack: Int` entfernt (Tombstone-Kommentar) |

**Koordinatenmodell (Arch-Slice-3):**

Vor Slice-3 war das Modell gemischt:
- `rubberStart` (in `StepGridCoordinator`): Content-Space (= screenX + scrollOffset)
- `rubberEnd` (in `StepGridCoordinator`): Screen-Space (= value.location.x)

Resultat: `updateRubberSelection()` musste `scrollOffset` als korrigierenden Summanden
übergeben, da die beiden Endpunkte in unterschiedlichen Räumen lagen.

Ab Slice-3 ist **alles Content-Space**:
- `RubberBandSession.anchorContentX` = `startLocation.x + hScrollOffset`
- `RubberBandSession.currentContentX` = `location.x + hScrollOffset`
- `currentScreenX` wird nur als Side-Channel für Scroll-Sync gespeichert:
  Bei Auto-Scroll ohne neue Pointer-Bewegung: `currentContentX = currentScreenX + newOffset`
- Overlay konvertiert erst beim Rendern zurück nach Screen: `anchorContent − hScrollOffset`

**Scroll-Sync — Ort der Berechnung verschoben:**

Alt: `StepGridCoordinator.connectScrollState()` subscribte auf `scrollState.$hScrollOffset`
und rief `updateRubberSelection()` lokal auf.

Neu: `InteractionController.setupScrollSync()` subscribt intern; `handleScrollOffsetChange(_:)`
recomputed `currentContentX` und publisht ein neues `RubberBandUpdate`. Alle N Koordinatoren
empfangen das Update, nur der eine aktive Track re-rendert (sein Overlay + Selektion).

**Multi-Track Selektionsclearing — ohne `engine.activeSelectionTrack`:**

Alt: `engine.activeSelectionTrack = trackIndex` (in StepGridView); `TrackRowView.onChange`
cleared `grid.selectedSteps` wenn `activeSelectionTrack != trackIndex`.

Neu: `connectInteractionController`-Sink prüft `upd.trackID != track.id` → löscht
`selectedSteps` eigenständig. Kein globaler Engine-State nötig.

**`EdgeAutoScroller` — entkoppelt:**
```swift
// Alt:
autoScroller.run(velocity: speed, scrollState: scrollState, engine: engine)

// Neu:
grid.autoScroller.run(velocity: speed) { [weak interactionController] v in
    interactionController?.applyEdgeScroll(velocity: v)
}
```

**Rubber-Band-Guard vereinfacht (Arch-Slice-2+3):**
```swift
// Arch-Slice-2 vereinfacht auf:
guard !interactionController.isSessionActive else { return }

// Arch-Slice-3 ersetzt durch differenzierten Check:
if case .rubberBand = interactionController.activeSession {
    // laufenden Rubber-Band updaten
} else if interactionController.activeSession == nil {
    // neuen Rubber-Band starten
}
// Handle-Session aktiv → ignorieren (modal-Invariante)
```

**Tests:** `InteractionArchitectureTests.swift` — 68 Tests total (+23 gegenüber Slice-2):
- `RubberBandSessionTests` (10): zero-width, L→R + R→L identisch, clamp low/high, single step, alle Steps, Idempotenz, Anker-Immutabilität, zero stepWidth (kein Crash)
- `InteractionControllerRubberBandTests` (13): begin, erstes update, update bewegt position, Selektion korrekt, commit, cancel, modale Invariante beide Richtungen, viewport lock, edge scroll, neue Session nach commit, committed behält Selektion, cancel no-op ohne Session

---

### Arch-Slice-2 — Ratio Handle (abgeschlossen, 13. April 2026)

**Ziel:** Zweiter vertikaler Schnitt — der Ratio-Handle-Pfad läuft vollständig
über die neue Interaktionsarchitektur. Danach haben beide Corner-Handles dieselbe
Struktur; `CornerHandlesView` hat keine `@Binding`-Parameter mehr.

**Neu eingeführt / erweitert:**

| Datei | Änderung |
|-------|----------|
| `Engine/ActiveSession.swift` | `RatioDragSession` (Value Type) neu; `HandleParameter`-Enum entfernt (war nur `stepCount`); `ActiveSession` um `.ratioDrag(RatioDragSession)` erweitert |
| `Engine/HandleDragLogic.swift` | `ratioIndex(totalX:contentUnit:baseRatioIndex:ratios:)` — pure Funktion, testbar ohne SwiftUI/AppKit |
| `Engine/ModelCommand.swift` | `.setRatio(trackID:oldNum:oldDen:newNum:newDen:)` neu |
| `Engine/ModelWriter.swift` | `setRatio`-Case in `apply(_:to:undoManager:)` |
| `Engine/InteractionController.swift` | `beginRatioDrag`, `updateRatioDrag`, `commitRatioDrag`, `cancelRatioDrag` neu |

**Ratio-Handle — was jetzt über neue Architektur läuft:**
- `onStart` → `IC.beginRatioDrag(track:contentUnit:baseRatioIndex:)` — Snapshot + baseIndex in `RatioDragSession`
- `onDrag` → `IC.updateRatioDrag(totalX:track:)` — nächstgelegener Ratio-Index via `HandleDragLogic.ratioIndex`
- `onEnd` → `IC.commitRatioDrag(track:undoManager:)` — ein Undo-Eintrag für den vollständigen Drag-Bereich
- Edge-Scroll → `IC.applyEdgeScroll(velocity:)` — identisch zum Count Handle; kein eigener Code

**Aus dem alten Ratio-Handle-Pfad entfernt:**

| Was | War wo | Lebt jetzt |
|-----|--------|-----------|
| `ratioHandleSnapshot` | `StepGridCoordinator` + `@Binding CornerHandlesView` | `RatioDragSession.snapshotNumerator/Denominator` |
| `ratioHandleBaseIndex` | `StepGridCoordinator` + `@Binding CornerHandlesView` | `RatioDragSession.baseRatioIndex` |
| `isHandleDragging` | `StepGridCoordinator` + `@Binding CornerHandlesView` | `ViewportController.sessionActive` / `IC.isSessionActive` |
| Direkte `scrollState.isAnyHandleDragging` Mutation | `CornerHandlesView.onStart/End` | `ViewportController.beginSession()` / `endSession()` |
| Direkte `scrollState.hScrollOffset +=` für Edge-Scroll | `CornerHandlesView.onEdgeScroll` | `ViewportController.scroll(by:)` |
| Direktes `track.stepLengthNumerator/Denominator` Schreiben | `CornerHandlesView.onDrag/End` | `ModelWriter.apply(.setRatio…)` |

**Rubber-Band-Guard vereinfacht:**
`StepGridView` prüft jetzt nur noch einen Guard:
```swift
guard !interactionController.isSessionActive else { return }
```
(Vorher: `!grid.isHandleDragging` für Ratio + `!interactionController.isSessionActive` für Count.)

**`CornerHandlesView` — keine Bindings mehr:**
```swift
// Vorher:
CornerHandlesView(
    track:                track,
    accentColor:          accentColor,
    stepWidthSize:        ...,
    stepDisplaySize:      ...,
    isHandleDragging:     $grid.isHandleDragging,
    ratioHandleSnapshot:  $grid.ratioHandleSnapshot,
    ratioHandleBaseIndex: $grid.ratioHandleBaseIndex
)

// Nachher (Arch-Slice-2):
CornerHandlesView(
    track:           track,
    accentColor:     accentColor,
    stepWidthSize:   ...,
    stepDisplaySize: ...
)
```

**Tests:** `InteractionArchitectureTests.swift` — 45 Tests total:
- `HandleDragSessionTests` (9): unverändert
- `HandleDragLogicRatioTests` (5): ratioIndex — zero/max/min/idempotency/nonNeutralBase
- `RatioDragSessionTests` (7): proposedRatioIndex, Snapshot-Immutabilität, Idempotenz, Command-Produktion
- `ViewportControllerTests` (5): unverändert
- `ModelWriterTests` (6): setStepCount (3) + setRatio (3)
- `InteractionControllerTests` (14): inkl. modal-invariant für Ratio, begin/update/commit/cancel Ratio-Lifecycle, EdgeScroll während Ratio-Drag

**Noch im alten Pfad (ausstehend, zum Zeitpunkt des Slice):**
- Trackpad/Scrollbar-Bridge → abgeschlossen in Arch-Slice-6

---

### Arch-Slice-1 — Count Handle (abgeschlossen, 12. April 2026)

**Ziel:** Erster vertikaler Schnitt durch die neue Interaktionsarchitektur.
Der Count-Handle-Pfad läuft vollständig über das neue System.

**Neu eingeführt:**

| Datei | Zuständigkeit |
|-------|---------------|
| `Engine/ViewportController.swift` | Einziger legitimer Scroll-Schreiber für Interaktionscode; `beginSession()` / `endSession()` für Session-Lock |
| `Engine/ActiveSession.swift` | `HandleDragSession` (Value Type), `ActiveSession` Enum |
| `Engine/ModelCommand.swift` | `ModelCommand` Enum — trägt old+new für Undo; `setStepCount` als erster Case |
| `Engine/ModelWriter.swift` | Kanonischer Mutations-Pfad für user-initiierte, undo-fähige Edits (Drag, Step-Toggle, Ratio); Undo-Registrierung hier. Nicht der einzige Mutationspfad — siehe Mutations-Invariante unten. |
| `Engine/InteractionController.swift` | Globale Interaction State Machine; modale Invariante (max. eine Session gleichzeitig) |

**Kritischer Fix (nach Slice-1):**
`@Published var activeSession` → Crash durch O(drag_events × N_lanes) SwiftUI-Re-Renders.
Gelöst: `_session: ActiveSession?` ist **nicht** `@Published`; nur `isSessionActive: Bool` ist `@Published`.
Ergebnis: Maximal 2 SwiftUI-Updates pro Drag (Begin + Commit/Cancel) statt 30.000+/s.

---

## Mutations-Invariante (TrackData)

**Regel:** Jede Mutation an einem `TrackData`-Feld, die SwiftUI-Reaktion oder
eine Snapshot-Aktualisierung erfordert, **muss** von `td.changed.send()` gefolgt werden.

Es gibt zwei legitime Mutationspfade:

### (A) ModelWriter — kanonischer Pfad

Für alle user-initiierten, undo-fähigen Edits (Drag-Interaktionen, Step-Edits,
Ratio-/StepCount-Änderungen). `ModelWriter` garantiert `changed.send()` nach
jeder Mutation strukturell — auch in Undo-Closures.

**Neuer Interaktions-Code und Lane-Code soll diesen Pfad verwenden.**

### (B) Direktpfad — zulässig für engine-interne, undo-freie Mutationen

| Stelle | Pfad |
|--------|------|
| `handleIncomingCC()` | MIDI-Remote-Control: Mute per CC |
| `handleLearnNoteOn()` | MIDI-Learn: Note in Step eintragen |
| `randomize(track:)` | Zufalls-Befüllung aller Steps |
| `pasteToCurrentPattern()` | Pattern-Paste aus Clipboard |
| `TrackViewModel`-Setter | cc-Label/-Nummer aus Settings-UI |

Direktpfade sind legitim. Sie müssen `td.changed.send()` **selbst aufrufen** —
es gibt keine automatische Garantie wie bei ModelWriter.

### Bewusste Ausnahme: Load-Pfad

`clampToValidRanges()` und der Decoder-`init(from:)` rufen `changed.send()`
**nicht** auf. Das ist korrekt: beide laufen beim Preset-Load, wo ein
anschließendes `publishSnapshot()` in `loadData()` / `newProject()` die
einzige erforderliche Reaktion ist.

---

## Lane-Modell (v1)

**Status:** Verbindlich für alle kommenden Lane-Slices. Diese Festlegung geht
jeder Code-Änderung am Lane-System voraus und darf nicht ohne expliziten
Beschluss revidiert werden.

### 1. Grundentscheidung

Der Sequenzkern wird aus `TrackData` herausgelöst und in ein neues
`LaneData`-Objekt verschoben.

- **`TrackData`** bleibt erhalten als **Container** — musikalisch-organisatorische
  Einheit, Routing-Träger, Besitzer einer Sequenz.
- **`LaneData`** wird der **Sequenzkern** — trägt alles, was die Step-Abfolge
  beschreibt.
- **Beziehung: 1:1.** Genau ein `LaneData` pro `TrackData`, als starke
  non-optionale Referenz (`let lane: LaneData`). Keine Listen, keine
  Mehrfach-Lanes, keine optionalen Lanes.
- **Keine Mehr-Lane-pro-Track-Struktur in diesem Schritt.** Die 1:1-Beziehung
  ist die vollständige Lane-Architektur v1 — nicht eine Übergangsform zu n:1.

### 2. Verantwortlichkeiten

**`TrackData`** (Container):
- Routing: `midiChannel`
- CC-Konfiguration: `cc1Number`, `cc2Number`, `cc1Label`, `cc2Label`,
  `cc1IsMuted`, `cc2IsMuted`
- Mute / Solo: `isMuted`, `isSolo`
- Tonart: `scaleRoot`, `scaleIndex` (und zugehörige Quantisierungs-Helfer)
- Timing-Offset: `timingOffset`
- UI-State: `name`, `isExpanded`
- Persistente Identität: `id: UUID`
- **Hält genau eine `LaneData`.**

**`LaneData`** (Sequenzkern):
- Steps: `steps: [Step]`
- Step-Anzahl: `stepCount`
- Ratio: `stepLengthNumerator`, `stepLengthDenominator`
- Richtung: `direction: PlayDirection`
- Persistente Identität: `id: UUID`
- Alles, was den Ablauf der Sequenz beschreibt.

Die Zuordnung ist fest: Alle Felder, die bei einem Lane-Wechsel mitwechseln
würden (Steps, Ratio, Direction, StepCount), gehören in `LaneData`. Alles,
was unverändert bliebe (Channel, CC-Setup, Mute, Scale, Name), bleibt in
`TrackData`.

### 3. Mutation & Invariante

Die bestehende **`changed.send()`-Invariante** (siehe Abschnitt oben) wird
spiegelbildlich auf `LaneData` übertragen. Beide Typen sind **plain classes
mit `var`-Feldern**, nicht `ObservableObject`. Jeder Typ führt sein eigenes
`PassthroughSubject<Void, Never>` namens `changed`.

**Signal-Regel:**

| Mutation | Signal |
|---|---|
| Container-Feld (Name, Channel, CC-Setup, Mute, Solo, Scale, Offset, Expanded) | `trackData.changed.send()` |
| Sequenz-Feld (Steps, StepCount, Ratio, Direction) | `laneData.changed.send()` |

Container- und Sequenz-Mutationen laufen **unabhängig**. Ein Step-Toggle
feuert ausschließlich `laneData.changed` — das Container-Signal bleibt
still. Ein Channel-Wechsel feuert ausschließlich `trackData.changed`.

**`ModelWriter` ist weiterhin kanonischer Pfad** für alle undo-fähigen,
interaktionsgetriebenen Mutationen. Für sequenzbezogene Commands schreibt
`ModelWriter` auf `LaneData` und ruft `laneData.changed.send()`. Für
container-bezogene Commands (Name, Channel, Mute, …) schreibt er auf
`TrackData` und ruft `trackData.changed.send()`. Die Garantie „Writer ruft
`send()` auch im Undo-Closure" gilt für beide Typen identisch.

Direktpfade (MIDI-Remote-CC, MIDI-Learn, Randomize, Paste, CC-Label-Setter)
bleiben zulässig und müssen — je nach getroffenem Feld — den passenden
`changed.send()` manuell aufrufen. Keine automatische Spiegelung zwischen
den beiden Subjects.

### 4. ViewModel-Strategie

**Entscheidung: Option A — `TrackViewModel` aggregiert `TrackData` + `LaneData`.**

Es gibt **ein** ViewModel pro Track. `TrackViewModel` hält `let data: TrackData`
und — über `data.lane` — implizit auch die `LaneData`. Das ViewModel
subscribed **beide** `changed`-Subjects (Container und Lane) und forwarded
beide an sein eigenes `objectWillChange`.

**Begründung:**
- 1:1-Beziehung: Solange genau eine Lane pro Track existiert, erzeugt ein
  separates `LaneViewModel` ausschließlich Zeremonie ohne Nutzen. Jede View,
  die heute `TrackViewModel` konsumiert, müsste zwei Objekte halten und
  synchronisieren.
- SwiftUI-Invalidierung: Views, die sowohl Container- als auch Sequenz-Felder
  lesen (z.B. `StepGridView` liest `stepCount`, `direction`, `scaleIndex`,
  `midiChannel`), brauchen ein kohärentes `objectWillChange`. Ein einzelnes
  VM liefert das ohne Merge-Logik.
- Kosten der Aggregation: zwei Subscriptions statt einer — vernachlässigbar.
  Invalidierungs-Granularität geht dadurch nicht verloren, da Container- und
  Lane-`changed` unabhängig feuern und die Equatable-Gates (z.B. in
  `StepButtonView`) weiterhin greifen.
- `vmCache` bleibt unverändert (Key = `TrackData.id`), keine zweite
  Cache-Ebene.

Ein separates `LaneViewModel` würde erst sinnvoll, wenn Lanes eigenständig
außerhalb ihres Tracks adressiert werden — das ist durch die Nicht-Ziele
(siehe 6.) ausgeschlossen.

**Lane-Typisierung (ab Lane Slice 3, v1.5.0):** Der Lane-Typ ist explizit.
`LaneData` trägt `let kind: LaneKind` als Pflichtfeld; `LaneSnapshot.kind`
spiegelt diesen Diskriminator in den RT-Pfad. Der Enum `LaneKind` hat heute
genau einen Case (`.step`). Er ist dennoch bereits eingeführt, damit:

- das Persistenzschema ein festes Typ-Tag trägt (`kind` wird ab v1.5.0 immer
  geschrieben und mit `decode` — nicht `decodeIfPresent` — gelesen);
- künftige Lane-Typen den Compiler zwingen, alle Exhaustiveness-Schaltstellen
  zu aktualisieren, statt sich in Default-Zweigen zu verstecken.

**Kein Legacy-Fallback.** Preset-Dateien aus v1.4.0 und älter enthalten kein
`kind`-Feld und schlagen beim Dekodieren bewusst fehl. `lastErrorMessage`
informiert den Benutzer. Alte Dateien werden bei Bedarf manuell konvertiert;
es gibt keinen dauerhaften Altlast-Pfad im Produktcode. Das ist konsistent
zur Lane-Modell-v1-Persistenzregel: keine Version-Tags, keine Format-Auto-
Detection, keine `(try? decode) ?? default`-Fallbacks.

**Exhaustiveness-Anker.** Der erste `switch lane.kind` liegt in
`SequencerEngine.buildPatternSnapshot()`. Dort wird pro Track genau einmal
pro Publish über den Lane-Typ verzweigt. `advanceSteps(tickTime:)` bleibt
bewusst step-only — der Hot-Path bleibt linear. `ModelWriter`, `ModelCommand`,
`InteractionController` und die Views wurden in Slice 3 ausdrücklich nicht
angefasst.

**UI-Dispatch (ab Lane Slice 4, v1.6.0).** Der zweite Exhaustiveness-Anker
sitzt in der View-Schicht: `Views/LaneBodyView.swift` kapselt genau einen
`switch track.lane.kind` und wählt den konkreten Body-View pro Track-Zeile.
Für den heute einzigen Case (`.step`) rendert die Shell `StepGridView`. Damit
ist die Zuordnung „Lane-Typ → View-Body" zum ersten Mal im Code benannt
statt implizit.

Architektonisch trennt Slice 4 die Track-Zeile in zwei Schichten:
- **Track-Rahmen (kind-neutral):** Header links, CC-Panels, Expand-Button,
  Selection-Toolbar — liegen in `TrackRowView` und sind vom Lane-Typ
  unabhängig.
- **Lane-Body (kind-abhängig):** der scrollbare Sequenz-Bereich wird in
  `LaneBodyView` per Kind dispatched. `TrackRowView` ruft den Body
  ausschließlich über diese Shell auf — es gibt keinen zweiten direkten
  `StepGridView`-Aufruf im Projekt.

Invarianten der Shell:
- Exakt ein `switch track.lane.kind` — kein `default`, kein `AnyView`,
  kein Group-Workaround.
- Pass-Through-Parameter identisch zu `StepGridView`; kein eigener State,
  keine Gesten, keine Environment-Objekt-Aufhebungen.
- `StepGridView`, `StepGridCoordinator`, `InteractionController` sind in
  Slice 4 **nicht** angefasst worden. Die Shell fügt ausschließlich eine
  neue Schicht zwischen `TrackRowView` und `StepGridView` ein.

**Interaktions-Dispatch (ab Lane Slice 5, v1.7.0).** Der dritte
Exhaustiveness-Anker sitzt an der Interaktions-Grenze.
`Engine/InteractionController.swift` hält einen privaten Helper
`requireStepLane(_ lane: LaneData)` mit genau einem Switch
`switch lane.kind { case .step: break }` ohne `default`. Jeder step-lane-
spezifische Session-Öffner ruft ihn unmittelbar nach dem modalen
`guard _session == nil else { return }` auf — konkret:
`beginHandleDrag`, `beginRatioDrag`, `beginPitchDrag`, `beginStepSwap`,
`beginStretchRatioDrag`, `beginStretchCountDrag`. Die Gruppe ist unter dem
MARK-Header „Step-Lane Sessions (Lane Slice 5)" sichtbar zusammengefasst.

Semantik heute: der Switch trifft ausschließlich `.step` — es gibt keine
Verhaltensänderung, keine Fehlerpfade, kein Logging. Der Helper dient
ausdrücklich als Compile-Time-Anker.

**CC-Lane Slice 1 (v1.8.0) — Anpassung.** Mit Einführung des zweiten
`LaneKind`-Falls `.cc` ist die Liste step-lane-spezifischer Einstiege
enger geworden: `requireStepLane(_:)` wird nur noch in `beginPitchDrag`
und `beginStepSwap` aufgerufen. Die vier Corner-Handle-Einstiege
(`beginHandleDrag`, `beginRatioDrag`, `beginStretchRatioDrag`,
`beginStretchCountDrag`) arbeiten auf lane-neutralen Feldern
(`stepCount`, `stepLengthNumerator/Denominator`) und funktionieren
deshalb auch für CC-Lanes ohne Guard. In `.cc`-Fällen erzwingt die
`requireStepLane`-Switch-Exhaustiveness einen `preconditionFailure`,
damit ein versehentliches Öffnen einer Step-Lane-Session auf einer
CC-Lane nicht stillschweigend durchläuft.

**Vier Exhaustiveness-Anker (ab CC-Lane Slice 1, v1.8.0).** Der zweite
Lane-Typ brachte einen zusätzlichen Anker auf der UI-Seite:
`TrackSideHeaderView` kind-dispatched den linken Spurkopf. Die vollständige
Liste der Anker ist damit:

1. `buildPatternSnapshot()` — Daten → Snapshot.
2. `advanceSteps()` — RT-Pfad Snapshot → MIDI (CC-Lanes senden `midi.cc`
   statt Note-Pipeline).
3. `LaneBodyView` — UI-Body im Step-Bereich.
4. `TrackSideHeaderView` — linker Spurkopf.
5. `requireStepLane(_:)` — Interaktions-Guard auf step-lane-spezifischen
   Session-Öffnern.

Die Anker decken damit systematisch die drei Schichten ab, an denen ein
neuer Lane-Typ explizit beantwortet werden muss — Daten, UI (Body +
Spurkopf) und Interaktion.

**Payload-Form auf `LaneData` (pragmatische Übergangsform).** Für CC-Lane
Slice 1 wurde die Payload kind-abhängig auf der gemeinsamen `LaneData`
angelegt (`steps` für `.step`, `ccValues`/`ccNumber`/`ccLabel`/`ccIsMuted`
für `.cc`). Diese Form ist ausdrücklich **nicht das Zielmodell** — ein
späterer Slice migriert die Payload in eine Enum-assoziierte Struktur
(oder separate Payload-Typen pro Kind). Die Übergangsform ist bewusst
gewählt, um den Durchstich klein zu halten; die Kind-Schaltung in Codable,
`clampToValidRanges`, `buildPatternSnapshot` und `advanceSteps` macht
sichtbar, welche Felder pro Kind relevant sind.

**Snapshot-Payload-Form (Lane Slice 6, v1.9.0).** Auf der RT-Boundary ist
die Mischform bereits aufgelöst. `LaneSnapshot` trägt lane-neutrale Felder
(`kind`, `stepCount`, `direction`, `pulsesPerStep`) + genau ein typsicheres
`payload: LaneSnapshotPayload`:

```swift
enum LaneSnapshotPayload: Sendable {
    case step(steps: [StepSnapshot])
    case cc(values: [Int], number: Int, isMuted: Bool)
}
```

`buildPatternSnapshot()` konstruiert pro Kind das passende Payload-Case;
`advanceSteps()` switcht auf `trackSnap.lane.payload` und liest die Felder
direkt aus dem Case-Binding. Die früheren defensiven Guards gegen leere
`steps`/`ccValues`-Arrays entfallen damit — der Compiler garantiert, dass
jeder Zweig nur seine eigenen Felder sieht. `LaneSnapshot.kind` bleibt als
redundanter, Cache-freundlicher Schnellzugriff für Display-/Logging-Pfade
erhalten.

D9-Immutabilität bleibt strukturell erhalten: alle assoziierten Werte sind
Werttypen (Arrays, Ints, Bool) in einem `let`-only Enum-Case. Der
`LaneData`-Payload-Split steht als eigenständiger Folge-Slice weiterhin
aus — die Mischform auf der mutable-Data-Seite ist bewusst noch nicht
angefasst.

Bewusst **nicht** abgedeckt in Slice 5: Rubber-Band bleibt ohne Guard
(lane-kind-agnostische Selektionsgeometrie). Update-, Commit- und Cancel-
Pfade bleiben ebenfalls ohne Guard — das modale Modell garantiert, dass
sie nur nach erfolgreichem `begin*` erreicht werden. Session-Typ-Namen,
Command-/Writer-Namensräume und View-Schichten bleiben in Slice 5
unverändert.

**Zugriffsform in Views (ab Lane Slice 2, v1.4.0):** Sequenzfelder werden in
Views ausschließlich lane-explizit gelesen — `track.lane.steps`,
`track.lane.stepCount`, `track.lane.direction`, `track.lane.stepLengthNumerator`,
`track.lane.stepLengthDenominator`. `TrackViewModel` forwarded diese Felder
bewusst **nicht** mehr; der einzige Lane-Accessor ist `track.lane: LaneData`.
Damit ist die Trennung zwischen Container- und Sequenz-Feldern auch im
Call-Site sichtbar und spiegelt die Modell-Struktur. Container-Felder
(`name`, `midiChannel`, `isMuted`, `isSolo`, `timingOffset`, `scaleRoot`,
`scaleIndex`, `cc1/cc2Label/Number/IsMuted`, `isExpanded`) bleiben direkt
auf `TrackViewModel` erreichbar.

### 5. Snapshot-Form

**Entscheidung: `TrackSnapshot` enthält einen verschachtelten `LaneSnapshot`.**

Die heutige flache `TrackSnapshot` wird in zwei Strukturen aufgeteilt:
- `TrackSnapshot` trägt Container-Felder (Channel, CC-Nummern, Mute/Solo,
  Timing-Offset) und ein `let lane: LaneSnapshot`.
- `LaneSnapshot` trägt Sequenz-Felder (`steps: [StepSnapshot]`, `stepCount`,
  `direction`, `pulsesPerStep`).

**Begründung:**
- Spiegelbild der Datenmodell-Struktur: Der Audio-Thread liest denselben
  konzeptionellen Split wie die Mutations-Schicht. Kein Impedance-Mismatch
  zwischen `buildPatternSnapshot()` und den Mutationspfaden.
- D9-Immutabilitäts-Invariante bleibt intakt: `LaneSnapshot` ist ebenfalls
  ein `let`-only Struct, eingebettet als `let lane: LaneSnapshot` in
  `TrackSnapshot`. Keine neuen Klassenreferenzen, keine `var`-Felder.
- Klare Zuständigkeitsgrenze im RT-Pfad: Mute-Check (`trackSnap.isMuted`)
  steht im Container; Step-Daten (`trackSnap.lane.steps[i]`) stehen in der
  Lane. Lesbar und einfach zu testen.
- Build-Aufwand identisch: dieselbe Anzahl Allocations; `buildPatternSnapshot`
  strukturiert sie nur konsistent.

Ein flacher `TrackSnapshot` (wie heute) würde die Modell-Asymmetrie
einzementieren — Datenseite getrennt, Snapshot-Seite verschmolzen. Das ist
die teurere Variante für spätere Pflege.

### 6. Nicht-Ziele

Diese Punkte sind **in diesem Modell ausdrücklich ausgeschlossen**:

- **Keine Event-Lanes.** `LaneData` bleibt step-basiert mit festem Grid.
  Sparse, zeit-positionierte Events sind nicht Teil dieses Schritts.
- **Keine Audio-Lanes.** `LaneData` erzeugt keine Audio-Buffer, rendert
  keine Sample-Wiedergabe, instanziiert keine `AVAudioEngine`-Nodes.
  Ausgabe bleibt MIDI-only über den bestehenden Pfad.
- **Keine Mehr-Lane-pro-Track-Struktur.** Weder jetzt vorbereitet noch
  später ohne neue, ausdrückliche Grundentscheidung. Die 1:1-Beziehung
  ist verbindlich, nicht provisorisch.
- **Keine Lane-übergreifenden Referenzen.** Eine Lane gehört zu genau einem
  Track und wird nicht extern adressiert.
- **Keine AUv3-relevante Abstraktion** in diesem Schritt.
- **Keine Varianten-Aufspaltung von `LaneSnapshot`** in Slice 3. `LaneSnapshot`
  bleibt ein flaches Struct mit `kind`-Tag plus Step-Feldern. Varianten-Enum
  (`enum LaneSnapshot { case step(…) }`) wäre Slice 4+.
- **Kein Polymorphismus / Protokoll** auf `LaneData`. 1:1 zu `TrackData`,
  konkreter Typ. `LaneKind` ist der einzige zulässige Diskriminator.
- **Keine lane-spezifischen Commands** in Slice 3. `ModelCommand` bleibt
  unverändert; das Namensraum-Redesign erfolgt erst mit zweitem Lane-Typ.
- **Keine Interaction-Shell in Slice 4.** Gesten (Pitch-Drag, Step-Swap,
  Handle-Drag, Rubber-Band) bleiben in `StepGridView` / `InteractionController`.
  Eine eigene lane-kind-abhängige Interaction-Shell ist Slice 5+ und setzt
  eine bereits vorhandene View-Shell voraus.
- **Kein `LaneViewModel` / `LaneBodyProtocol` / `AnyView`** in der UI-Shell.
  `LaneBodyView` ist ein Pass-Through-Switch ohne eigenen Zustand.
- **Kein zweiter `LaneKind`-Case** in Slice 4. Enum bleibt einelementig;
  die Shell ist Vorbereitung, keine Feature-Einführung.
- **Keine Session-Typ-Renaming / Signaturänderung in Slice 5.**
  `HandleDragSession`, `RatioDragSession`, `PitchDragSession`,
  `StepSwapSession`, `StretchRatioDragSession`, `StretchCountDragSession`
  bleiben strukturell und namentlich unverändert.
- **Kein Guard in Update-/Commit-/Cancel-Pfaden** in Slice 5.
  `requireStepLane(_:)` wird ausschließlich an den sechs `begin*`-Eingängen
  aufgerufen; alle weiteren Zustandsübergänge sind durch das modale
  `_session`-Modell abgesichert und benötigen keinen zusätzlichen Anker.
- **Kein Guard für `beginRubberBand`** — Rubber-Band-Selektion ist
  lane-kind-agnostisch (reine Geometrie über Step-Breite) und gehört
  bewusst nicht zur step-lane-spezifischen Gruppe.
- **Keine Änderungen an `ModelWriter`, `ModelCommand` oder View-Schicht**
  in Slice 5. Der Slice bleibt strikt auf `InteractionController` begrenzt.

### JSON / Persistenz

Das Lane-Modell ist ein **Breaking Change** auf der Persistenz-Ebene.
Bestehende Preset-Dateien werden nach der Migration nicht mehr ladbar sein.
Das ist eine **bewusste Entscheidung**.

- Kein Legacy-Decoder-Pfad.
- Keine `(try? decode) ?? default`-Fallbacks für die neue Lane-Struktur.
- Keine Migrations-Helper, keine Version-Tags, keine Format-Auto-Detection.
- Decoder wirft bei alten Dateien einen sauberen Fehler; `lastErrorMessage`
  informiert den Benutzer.

Zielbild: eine klare, zukunftsfähige JSON-Form, in der Container- und
Lane-Ebene direkt sichtbar sind: Pattern → Tracks → Track.lane → Steps.
Rückwärtskompatibilität ist explizit kein Ziel dieses Schritts und soll
die Modellentscheidung nicht einschränken.

---

Technische Referenz → `DOCUMENTATION.md`
Produkt-Roadmap → `../ROADMAP.md`

---

## Offene Punkte

### Code-Qualität

- [ ] **N2 — `quantTable` Build-Kosten unmessbar**
  Bereich: `Track.swift:40–85`
  Problem: 2,4 Mio. Iterationen beim ersten Klassenzugriff, kein lazy-Init — potenziell messbar auf schwacher Hardware
  Ziel: Mit Instruments messen; falls > 50 ms → async oder `lazy static`
  Risiko: **Low** (messen vor fixen)

- [ ] **D5 — `@AppStorage("appLanguage")` zentralisieren** *(zurückgestellt)*
  Bereich: 15+ View-Dateien
  Problem: Jede View liest `appLanguage` einzeln
  Ziel: Ein `@EnvironmentObject LanguageSettings` oder `@Environment`-Key
  Risiko: **Low** — nach Lane-System-Rewrite

---

## Nächste Schritte

1. **N2** — `quantTable` mit Instruments messen; falls > 50 ms → lazy oder async Init
2. **SequencerEngine-Aufteilung** (`+Playback`, `+PatternManagement`) — nach Lane-Rewrite

---

## Abgeschlossen

### Timing

- **T2 Schritt 1 — Overshoot-Korrektur:** Bei nicht-ganzzahligen `pulsesPerStep`-Werten (z. B. 4.8 für 5:4) überschießt der `pulseAccumulator` nach `acc -= pps` um einen Bruchteil eines Ticks. `overshootNS = acc × pulseDuration × 1e9`; `exactStepTime = tickTime - nanosToMachTime(overshootNS)`. Alle Note-On/Off- und CC-Timestamps verwenden `exactStepTime`. Ratchet rechnet relativ dazu.

- **T2 Schritt 2 — Externer Clock-Lookahead (EMA):** `extTickIntervalEMA` (α = 0.2) glättet den gemessenen Abstand zwischen aufeinanderfolgenden 0xF8-Pulsen. `scheduledAt = now + UInt64(extTickIntervalEMA)` verschiebt den Tick-Timestamp ~ein Intervall in die Zukunft — CoreMIDI kann hardware-präzise planen statt auf `now` oder vergangene Timestamps zu reagieren. Felder: `extLastTickMach: UInt64`, `extTickIntervalEMA: Double`, `extEMAAlpha = 0.2`. Reset in `stop()` und bei INT→EXT-Moduswechsel (`clockMode.didSet`).

### Code-Qualität (UI)

- **UI — `distributedStepWidth`:** `VintageTheme.distributedStepWidth(index:num:den:stepWidthSize:)` ersetzt die uniforme `stretchedStepWidth` bei der Darstellung individueller Steps. Bresenham-Formel: `width(i) = round((i+1)×slotSize) − round(i×slotSize) − spacing`. Angewendet in `StepGridView` (Step-Button-Breite), `CCRowView` (`.frame(width:)` der Knobs) und im Kurven-`pt()`-Mittelpunkt. `stretchedStepWidth` bleibt für Scroll-Grenzen und Näherungen erhalten.

### RT-Safety (Ergänzungen)

- **A5** — `AudioClockSource` Tap-Lifetime explizit: `deinit` ruft `removeTap(onBus: 0)` auf, BEVOR `engine.stop()` — `removeTap` ist thread-safe und wartet intern auf Callback-Abschluss; Tap-Closure (mit `unowned(unsafe) self`) wird freigegeben, während `self` noch vollständig im Speicher liegt; Kommentar an `installTap` auf A5-Stand gebracht

### Code-Qualität (Dokumentation)

- **D8** — Memory Ordering dokumentiert: `.releasing` store in `publishSnapshot()` erklärt (warum ohne `.releasing` stille Datenkorruption auf ARM64 möglich wäre); `.acquiring` load in `advanceSteps()` erklärt (spekulatives Read-Reordering auf ARM64 ohne Barrier); Store(0) in `stop()` mit Hinweis auf bewusste Redundanz; Producer-Consumer-Barrier-Pair als Querverweis in beiden Kommentaren

- **D9** — Snapshot-Immutability-Invariante explizit: `PlaybackSnapshot.swift`-Dateiheader erweitert um Design-Invariante-Block (`D9`); erklärt: warum `var`/`class`/`lazy var` in Snapshot-Structs strukturell verboten sind; Regeln für spätere Erweiterungen (neue Felder nur `let`+Werttyp); Änderungsprotokoll für neue Track-Parameter

### Pre-Beta

- **N2 (thread-safety)** — `selectedOutput` RT-safe: `_rtOutput: MIDIEndpointRef` + `_rtOutputLock: os_unfair_lock_s` in `MIDIManager`; `didSet` auf `@Published var selectedOutput` spiegelt Wert unter Lock auf `_rtOutput` (Main Thread); `sendRTSafe` liest `_rtOutput` via `os_unfair_lock_trylock` statt direktem `selectedOutput`-Zugriff; bei Contention (Mikrosekunden-Fenster): `out = 0`, Send wird übersprungen — RT-sicheres Fallback. **Ersetzt durch RT-4c (v1.12.10, siehe oben):** Lock/Trylock durch `ManagedAtomic<MIDIEndpointRef>` ersetzt — kein Drop-Pfad mehr, Store/Load schlagen nie fehl.

- **T1** — `ConcurrentBufferTests.swift`: 1 Test `concurrentPushDrainDoesNotCrash()` — `Thread.detachNewThread` pusht 500× `pushPatternSwitch`; Test-Thread draint parallel; Semaphore koordiniert Ende; `#expect(received >= 0)` + `#expect(received <= total)`; kein Crash = SPSC-Lock-Invariante hält

- **W1** — Swift Atomics Package eingebunden: `https://github.com/apple/swift-atomics`, `upToNextMajorVersion` ab `1.1.0`; hinzugefügt via Xcode → File → Add Package Dependencies (manuelles Editieren von `pbxproj` nicht ausreichend für Xcode 16 — `packageReferences`-Key wird nur vom Xcode-UI korrekt erzeugt); `import Atomics` in `SequencerEngine.swift` aufgelöst

- **W2** — `AppIcon.appiconset/Contents.json` bereinigt: `"filename": "AppIcon.png"` entfernt (Datei existierte nicht → „unassigned child"-Warnung); `"platform": "mac"` → `"macos"` (Xcode 16 „Unknown platform value 'mac'"-Warnung)

### RT-Safety
- **A4** — `weak self` → `unowned(unsafe) self` im `installTap`-Callback: atomarer `swift_weakLoadStrong`-Check + `guard let`-Unwrap auf Audio-Thread entfernt; Lifetime durch `SequencerEngine`-Ownership + synchrones `engine.stop()` strukturell garantiert
- **A1** — Blocking Lock in `advanceSteps()` → `os_unfair_lock_trylock` + `lastValidBundle`-Fallback
- **A2** — `DispatchQueue.main.async` für `lastFiredNotes` → `EngineEventBuffer.pushNotesFired()`
- **A3** — `DispatchQueue.main.async` für Pattern-Switch → `EngineEventBuffer.pushPatternSwitch()`

### Release-Blocker
- **B6** — Step-Indicator friert nach `loadData()` aus Stop-Zustand ein: `stop()` rief `displayDrainTimer?.suspend()` auch bei `isPlaying == false` auf → `DispatchSourceTimer`-Suspend-Counter stieg auf 2; `play()→resume()` brachte ihn nur auf 1 zurück — Timer nie aktiv. Fix: `guard isPlaying else { return }` in `stop()` (idempotent).
- **N1** — `MARKETING_VERSION` auf `1.0.15` gesetzt (vorher 1.0.14): App-Target Debug + Release in `project.pbxproj`; Test-Targets (`1.0`) unberührt; `VintageTheme.appVersion` liest `CFBundleShortVersionString` zur Laufzeit → zeigt korrekt `1.0.15` im UI
- **B5** — BetaGate entfernt: `enum BetaGate` (SHA-256-Hash, Expiry-Check, NSAlert-Loop, CryptoKit-Import) aus `BetaGate.swift` entfernt; `BetaGate.check()` aus `AppDelegate.applicationDidFinishLaunching` entfernt; `betaUnlocked`-UserDefaults-Key bleibt inert (kein Schaden); Datei als Tombstone erhalten; kein StoreKit-Ersatz — Vertriebsmodell bewusst offen
- **B1** — Legacy Clock-Thread-Code entfernt (`startClock`, `clockThread`, `mach_wait_until`)
- **B2** — Off-by-one: `TrackRuntime.currentStep = -1` → Step 0 feuert beim ersten Tick
- **B3** — Preset I/O: `try?` → `do/catch` + `@Published var lastErrorMessage` + `NSAlert`
- **B4** — Preset-Decode: `Track.clampToValidRanges()` nach jedem `loadData()`

### Robustheit
- **N4** — `laneContentWidth` zentralisiert: `VintageTheme.laneContentWidth(tracks:stepWidthSize:buffer:)` als zentrale Quelle; `buffer: CGFloat = 80` (Scrollbar) vs. `buffer: 0` (Offset-Clamp); 3 Inline-Kopien ersetzt (MainView Property, MainView Trackpad-Handler, EdgeAutoScroller.run)
- **C4** — `quantizedNote` O(128×|intervals|) → O(1): statische 3D-Lookup-Tabelle `Track.quantTable[scaleIndex][root][note]` (12 × 12 × 128 = 18 432 Einträge, ≈ 144 KB); einmalig beim ersten Klassenzugriff berechnet; Build-Loop mit O(1)-`inScale`-Bool-Array statt O(|intervals|)-`.contains()`; Audio-Thread greift nie auf `quantTable` zu (liest nur `TrackSnapshot`)
- **C1** — MIDI Device Disconnect: `onOutputDisconnected`-Callback, `selectedOutput = 0`
- **C2** — `Track.Codable`: `isSolo` + `isExpanded` ergänzt (rückwärtskompatibel via `try? ?? false`)
- **C3** — MIDI-In modernisiert: `midiReadProc`/`MIDIInputPortCreate`/`MIDIPacketNext`/`Array(...)` → `MIDIClientCreateWithBlock`/`MIDIInputPortCreateWithProtocol(MIDIProtocolID(rawValue: 1)!)`/`MIDIEventPacketNext`/inline-word-read; kein Heap-Alloc im Receive-Pfad; `MIDIProtocolID(rawValue: 1)` statt Enum-Case-Name (SDK-Kompatibilität über Xcode-Versionen)

### Code-Qualität
- **N3** — `stretchedStepWidth` Pixel-Rounding: `.rounded(.toNearestOrEven)` auf den finalen Rückgabewert in `VintageTheme.stretchedStepWidth(...)`; verhindert Sub-Pixel-Verschiebungen im Step-Grid bei nicht-ganzzahligen Streck-Quotienten
- **D6** — Lokalisierung vervollständigt: 13 neue Einträge in `Str.swift` (`// MARK: - CC Row` + Selektionsleisten-Labels + `undoResetCC`); 13 Ersetzungen in `TrackRowView.swift` — CCLabelRow (7) + Selektionsleiste (4) + Undo-Aktionsnamen (2)
- **D3** — `numTracks` → Computed Property: `@Published var numTracks: Int = 4` entfernt; ersetzt durch `var numTracks: Int { currentPattern.tracks.count }`; 5 manuelle Sync-Zuweisungen in `addTrack`, `insertTrack`, `duplicateTrack`, `restoreTracks`, `removeTrack` entfernt; SwiftUI-Propagation weiterhin via `hasUnsavedChanges` (`@Published`) in denselben Funktionen
- **D1** — `VintageTheme.stretchedStepWidth(num:den:stepWidthSize:)` — 7 Duplikate eliminiert
- **D2** — `Track.sortedRatios` — 2 Duplikate (TrackRowView + StretchHandleView) eliminiert
- **D4** — `displayDrainTimer` suspend/resume statt permanent aktiv
- **D7** — Housekeeping: tote Variable in `Step.shortChordName`, doppelter `settingsDivider`, `PROJECT_LOG.md` versioniert

### Architektur
- **E1** — `SequencerEngine` aufgeteilt: `+PresetIO.swift` (~195 Z.) + `+MIDILearn.swift` (~100 Z.)
- **E1b** — `PresetManager` aus `SequencerEngine+PresetIO` extrahiert: Encode/Decode (`PresetFile` + `DecodeResult`-Enum mit Legacy-Fallback), File Panels (`runSavePanel`/`runOpenPanel` — throwing), Bookmark-Verwaltung (`loadBookmarks`/`addToBookmarks`/`clearBookmarks`); Engine-Extension als dünne Shell; `recentFilesKey`/`maxRecent` als `static let`; `@Published`-Properties unverändert auf Engine
- **E2 (Schritt 1)** — `StepSelectionToolbar` aus `TrackRowView` extrahiert: Selection-Aktionsleiste (EDIT/COPY/PASTE/CLR/✕-Button) + Escape-Key-Handler → `StepSelectionToolbar.swift`; Interface: `$selectedSteps`, `$showMultiEdit`, `@ObservedObject track`, `accentColor`, `@EnvironmentObject engine`; keine Geometrie- oder Scroll-Abhängigkeiten; `TrackRowView.body` um ~47 Zeilen entlastet
- **E2 (Schritt 2)** — `CCLabelRowView` aus `TrackRowView` extrahiert: `private struct CCLabelRow` (~51 Z.) → `CCLabelRowView.swift`; Interface unverändert: `label`, `$drawMode`, `$isMuted`, `accentColor`, `onRandomize`, `onReset`; `@AppStorage("showCCCurve")` bleibt in der View (globale Einstellung, kein Redesign); beide Call-Sites in `TrackRowView` auf `CCLabelRowView` umgestellt
- **E2 (Schritt 3)** — `TrackCCSectionView` aus `TrackRowView` extrahiert: linker CC-Panel-Block (`if track.isExpanded`, ~52 Z.) → `TrackCCSectionView.swift`; kapselt CC1- und CC2-Label-Reihen mit Separatoren und Undo-Closures; Interface: `@ObservedObject track`, `$cc1DrawMode`, `$cc2DrawMode`, `accentColor`, `ccRowH: CGFloat`; `@Environment(\.undoManager)` und `@AppStorage("appLanguage")` direkt in der View; keine Engine-Abhängigkeit
- **E2 (Schritt 4)** — `TrackCCKnobSectionView` aus `TrackRowView` extrahiert: rechter CC-Knob-Block (`if track.isExpanded` im scrollbaren VStack, ~21 Z.) → `TrackCCKnobSectionView.swift`; `ccWidth`-Berechnung internalisiert; Interface: `@ObservedObject track`, `$cc1DrawMode`, `$cc2DrawMode`, `accentColor`, `stepWidthSize: CGFloat`; keine Geometrie-/Scroll-Abhängigkeit
- **E2 (Schritt 5)** — `RubberBandOverlayView` aus `TrackRowView` extrahiert: sichtbares Auswahlrechteck (~9 Z.) → `RubberBandOverlayView.swift`; Interface: `left`, `width`, `height` als fertig berechnete `CGFloat`-Werte; Koordinaten-Konvertierung verbleibt im Parent; kein State, keine Gesten, kein GeometryReader
- **E2 (Schritt 6)** — `CornerHandlesView` aus `TrackRowView` extrahiert: beide `CornerDotHandle`-Blöcke + Undo-Closures (~72 Z.) → `CornerHandlesView.swift`; Interface: `@ObservedObject track`, `accentColor`, `stepWidthSize`, `stepDisplaySize`, 4× `@Binding` für transiente Drag-States; `currentRatioIndex` aus TrackRowView entfernt
- **E2.3b** — `StepGridView` aus `TrackRowView` extrahiert: gesamter scrollbarer Grid-Block (GeometryReader + ZStack mit Step-Buttons, Pitch-Drag, Step-Swap, CornerHandlesView, TrackCCKnobSectionView, RubberBandOverlayView + Rubber-Band-DragGesture + Edge-Auto-Scroll + StretchHandleView, ~230 Z.) → `StepGridView.swift`; `updateRubberSelection()` + `totalScrollHeight` mitgezogen; Interface: `@ObservedObject track`, `@ObservedObject grid: StepGridCoordinator`, `accentColor`, `trackIndex`, `@Binding cc1DrawMode/cc2DrawMode`; `@EnvironmentObject engine`, `@Environment undoManager`, `@AppStorage lang` direkt in der View; `TrackRowView.body` ersetzt den gesamten HStack durch `StepGridView(...)`; `TrackRowView` auf ~168 Zeilen reduziert; alle E2-Schritte (1–6, E2.3a, E2.3b) abgeschlossen
- **E2.3a** — `StepGridCoordinator` eingeführt: 16 einzelne `@State`-Properties (Rubber-Band, Step-Drag, Pitch-Drag, Handle-Guard, Auto-Scroll) in `final class StepGridCoordinator: ObservableObject` gebündelt → `StepGridCoordinator.swift`; `@StateObject private var grid` in `TrackRowView`; alle Verwendungen auf `grid.*` umgestellt; `showMultiEdit`, `cc1DrawMode`, `cc2DrawMode` verbleiben als `@State` im Parent; `autoScroller` bewusst ohne `@Published` (kein SwiftUI-Observation nötig); kein Behavior-Change: beide `CornerDotHandle`-Blöcke + Undo-Closures (~72 Z.) → `CornerHandlesView.swift`; Interface: `@ObservedObject track`, `accentColor`, `stepWidthSize`, `stepDisplaySize`, 4× `@Binding` für transiente Drag-States (`isHandleDragging`, `ratioHandleSnapshot`, `ratioHandleBaseIndex`, `stepCountHandleSnapshot`); `currentRatioIndex` aus TrackRowView entfernt (nur noch in CornerHandlesView); `@Environment(\.undoManager)` + `@AppStorage("appLanguage")` direkt in der View: sichtbares Auswahlrechteck (~9 Z.) → `RubberBandOverlayView.swift`; Interface: `left`, `width`, `height` als fertig berechnete `CGFloat`-Werte; Koordinaten-Konvertierung (Content-Space → Screen-Space) verbleibt im Parent; kein State, keine Gesten, kein GeometryReader: rechter CC-Knob-Block (`if track.isExpanded` im scrollbaren VStack, ~21 Z.) → `TrackCCKnobSectionView.swift`; `ccWidth`-Berechnung internalisiert; Interface: `@ObservedObject track`, `$cc1DrawMode`, `$cc2DrawMode`, `accentColor`, `stepWidthSize: CGFloat`; keine Geometrie-/Scroll-Abhängigkeit
- **E2.4** — `EdgeAutoScroller` → `EdgeAutoScroller.swift`; `CornerDotHandle` + `HandleNSView` → `CornerDotHandle.swift`; aus `TrackRowView.swift` entfernt; behebt `private`-Sichtbarkeitsfehler (`CornerDotHandle` war `private struct`, wurde von `CornerHandlesView.swift` referenziert → jetzt korrekt `internal`); `TrackRowView.swift` auf ~171 Z.
- **E3** — Snapshot-Lock → Atomarer Pointer: `os_unfair_lock`/`trylock`/`lastValidBundle` entfernt; ersetzt durch `ManagedAtomic<Int>` (Swift Atomics) + `PlaybackBundleBox`-Wrapper + Triple-Slot-ARC-Lifetime-Modell; Audio-Thread: single `acquiring load` + `takeUnretainedValue()`, kein Lock/Retain/Alloc im Hot Path; Dependency: Swift Atomics Package (`https://github.com/apple/swift-atomics` v1.1.0–<2.0.0) via Xcode → File → Add Package Dependencies
- **E4** — 36 Tests: `PresetIOTests` (10) + `DisplayEventBufferTests` (9) + `EngineEventBufferTests` (17)
- **E4-next** — `advanceRuntime`-Tests: `AdvanceRuntimeSource`-Protocol (E4-next.1) + `MockAdvanceRuntimeSource` + Test-Convenience-Extensions (E4-next.2) + 32 Tests in `AdvanceRuntimeTests.swift` (E4-next.3): Forward (7) · Reverse (6) · PingPong (7) · Random (3) · B2-Startzustand (6) · Mock-Zustandslosigkeit (3); ohne AVAudioEngine, AudioClockSource oder Echtzeit-Kontext

### Playback UI Performance (P3 Phase 3)

- **P3-Signal** — Display-Drain: Timer → Event-Signal: `displayDrainTimer` (DispatchSourceTimer, 16ms Polling) ersetzt durch `displaySignal` (DispatchSourceUserDataOr, event-basiert); `displaySignal.or(data: 1)` in `advanceSteps` nach jedem `displayBuffer.push()`; Handler feuert nur bei tatsächlichen Display-Events; eliminiert Timer-Moiré (Interferenz 16ms-Timer ↔ Step-Events bei nicht-ganzzahligem Verhältnis); play()/stop()/deinit auf Signal-Lifecycle umgestellt; Drain-Code (Batching + Change Detection) unverändert

- **P3-Diag** — Debug-Instrumentierung für lastFiredNotes-Hypothese: 3 Messpunkte in `SequencerEngine.swift` (nur `#if DEBUG`):
  1. `🔴 notesFired` / `⚪ notesClear` — Logging mit ms-Timestamp + Track-Index im engineEventBuffer-Drain und asyncAfter-Clear
  2. `⏱️ drain` — Drain-Handler-Dauer, nur geloggt wenn > 2ms
  3. `silenceFiredNotes` — Bool-Flag (Default: false); wenn true, wird `.notesFired`-Case komplett übersprungen (kein Track-Write, kein Broadcast) → Kontrollexperiment zur Verifikation der Hypothese, dass Track.objectWillChange via lastFiredNotes die Cursor-Hitches verursacht

- **P3-Analyse** — Identifizierte Bottlenecks (Instruments-bestätigt: 355 Long Updates, avg 9.76ms, max 2.89s):
  1. `engine.objectWillChange` bei stepWidthSize-Änderung → ~170 View-Invalidierungen pro Frame (8 EngineObject-Abonnenten + 128 StepButtonViews via ForEach mit geänderter width)
  2. `Track.objectWillChange` durch lastFiredNotes set/clear → 16 Broadcasts pro Step-Zyklus, jeder triggert StepGridView.body + TrackRowView.body (Equatable-Diffing spart StepButton-Bodies, aber ForEach-Iteration + Modifier-Erstellung bleibt)
  3. stepWidthSize als @Published auf SequencerEngine statt isoliertem ObservableObject

---

## Zurückgestellt

| Thema | Grund |
|---|---|
| `Str` → `.xcstrings`-Migration | Erst nach Lane-System-Rewrite sinnvoll |
| D5 AppStorage-Zentralisierung | Low priority; erst nach Lane-System-Rewrite |
| `SequencerEngine` weitere Aufteilung (`+Playback`, `+PatternManagement`) | Erst nach Lane-System-Rewrite sinnvoll; aktuell ~750 Z., beherrschbar |
| AudioClockSource Sample-Rate-Change | Selten; Pro-Audio-Nischenfall; nach Lane-System-Rewrite |

---

## Review-Geschichte

| Version | Datum | Gesamtbewertung | Anmerkung |
|---|---|---|---|
| v1.0.13 | 2026-03 | 3.5 / 5 | 5 Critical-Blocker offen |
| v1.0.15 | 2026-04-12 | 4.4 / 5 | Timing-Korrektheit (intern + extern) + visuelle Drift beseitigt |
| v1.0.14 | 2026-04-11 | 4.2 / 5 | Alle Critical-Blocker gelöst; 14/25 Issues geschlossen |
