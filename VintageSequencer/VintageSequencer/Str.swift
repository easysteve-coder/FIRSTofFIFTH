// Str.swift — All user-facing strings, English (default) / German.
//
// Usage in SwiftUI views:
//   @AppStorage("appLanguage") private var lang: String = "en"
//   private var s: Str { Str(lang) }
//
// Usage in non-SwiftUI code (AppDelegate, Engine):
//   let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")

struct Str {
    let de: Bool
    init(_ lang: String = "en") { de = lang == "de" }

    /// Pick English or German string.
    private func e(_ en: String, _ de: String) -> String { self.de ? de : en }

    // MARK: - App / Menus / Alerts

    var viewMenu:            String { e("View",        "Ansicht") }
    var showTooltips:        String { e("Show Tooltips", "Tooltips anzeigen") }
    var languageToggle:      String { de ? "Language: English" : "Sprache: Deutsch" }

    var savePreset:          String { e("Save Preset…",        "Preset speichern…") }
    var openPreset:          String { e("Open Preset…",        "Preset öffnen…") }
    var openRecent:          String { e("Open Recent",         "Zuletzt geöffnet") }
    var clearRecent:         String { e("Clear Recent Files",  "Liste leeren") }
    var newProject:         String { e("New Project",         "Neues Projekt") }
    var newProjectMenuItem: String { e("New",                 "Neu") }
    var saveAsPreset:       String { e("Save As…",            "Speichern unter…") }
    var savePresetInPlace:  String { e("Save",                "Speichern") }
    var copyPattern:         String { e("Copy Pattern",   "Pattern kopieren") }
    var pastePattern:        String { e("Paste Pattern",  "Pattern einfügen") }
    var playMenuItem:        String { e("Play",  "Abspielen") }
    var stopMenuItem:        String { e("Stop",  "Stop") }

    var unsavedTitle:        String { e("Unsaved Changes",
                                        "Ungespeicherte Änderungen") }
    var unsavedMessage:      String { e("Save the current preset before quitting?",
                                        "Soll das aktuelle Preset vor dem Beenden gespeichert werden?") }
    var save:                String { e("Save",    "Speichern") }
    var discard:             String { e("Discard", "Verwerfen") }
    var cancel:              String { e("Cancel",  "Abbrechen") }
    var newProjectUnsavedMessage: String {
        e("Save the current preset before creating a new project?",
          "Soll das aktuelle Preset vor dem Anlegen eines neuen Projekts gespeichert werden?")
    }

    var saveDialogTitle:     String { e("Save Preset", "Preset speichern") }
    var loadDialogTitle:     String { e("Load Preset", "Preset laden") }
    var defaultPreset:       String { "MyPreset.json" }

    func trackName(_ n: Int)    -> String { e("Track \(n)", "Spur \(n)") }
    func padTrackName(_ n: Int) -> String { e("Pad \(n)", "Pad \(n)") }
    func trackDuplName(_ name: String) -> String { name + " 2" }

    func muteMenuItem(_ n: Int, isMuted: Bool) -> String {
        isMuted ? e("Unmute Track \(n)", "Spur \(n) einschalten")
                : e("Mute Track \(n)",   "Spur \(n) stummschalten")
    }
    func patternMenuItem(_ letter: String) -> String { "Pattern \(letter)" }

    // MARK: - Transport

    var playTooltip:         String { e("Play (Space)",  "Abspielen (Leertaste)") }
    var stopTooltip:         String { e("Stop (Space)",  "Stop (Leertaste)") }
    var tapTempoTooltip:     String { e("Tap Tempo: click 2× or more to detect BPM",
                                        "Tap Tempo: 2× oder öfter klicken um BPM zu ermitteln") }
    var swingTooltip:        String { e("Swing: 0% = straight, 100% = maximum swing (odd steps delayed)",
                                        "Swing: 0% = gerade, 100% = maximaler Swing (ungerade Steps werden verzögert)") }
    var intClockTooltip:     String { e("Internal clock — sequencer runs at its own BPM",
                                        "Interner Clock — Sequencer läuft mit eigenem BPM-Takt") }
    var extClockTooltip:     String { e("External MIDI clock — sequencer syncs to incoming clock signal",
                                        "Externer MIDI-Clock — Sequencer synchronisiert sich auf eingehenden Clock-Signal") }
    var learnActiveTooltip:  String { e("MIDI Learn active — assign next incoming note or CC to a parameter · click to deactivate",
                                        "MIDI Learn aktiv — nächste eingehende Note oder CC einem Parameter zuweisen · klicken zum Deaktivieren") }
    var learnInactiveTooltip: String { e("MIDI Learn — assign parameters via incoming MIDI messages",
                                         "MIDI Learn — Parameter per eingehender MIDI-Nachricht belegen") }
    var stepSizeSmall:       String { e("Small (38 px) — more steps visible",
                                        "Klein (38 px) — mehr Steps sichtbar") }
    var stepSizeMedium:      String { e("Medium (46 px)", "Mittel (46 px)") }
    var stepSizeLarge:       String { e("Large (54 px) — easier to click",
                                        "Groß (54 px) — einfacher zu klicken") }
    var settingsTooltip:     String { e("Settings — MIDI output, step size and more",
                                        "Einstellungen — MIDI-Ausgang, Step-Größe und weitere Optionen") }
    func patternQueuedTip(_ letter: String) -> String {
        e("Pattern \(letter) — waiting for Track 1 end (cyan)",
          "Pattern \(letter) — wartet auf Track-1-Ende (cyan)")
    }
    func patternSwitchTip(_ letter: String, _ n: Int) -> String {
        e("Switch to Pattern \(letter) (⌘\(n)) · switches at end of Track 1",
          "Pattern \(letter) wechseln (⌘\(n)) · Wechsel erfolgt am Ende von Track 1")
    }

    // MARK: - Status bar

    var running:             String { e("RUNNING", "LÄUFT") }
    var stopped:             String { e("STOPPED", "GESTOPPT") }
    /// StatusBar: Ticks, die ausgelassen wurden (Snapshot nicht erwerbbar) — seit dem letzten Start.
    func timingDropouts(_ n: Int) -> String { e("TIMING: \(n) dropped", "TAKT: \(n) ausgelassen") }
    func timingDropoutsA11y(_ n: Int) -> String {
        e("Timing dropouts since start: \(n)", "Ausgelassene Takte seit dem Start: \(n)")
    }
    /// Transport: Faderlabel für die Step-Breite (Accessibility).
    var stepWidthLabel: String { e("Step width", "Step-Breite") }
    var noMidiOutput:        String { e("No MIDI output selected", "Kein MIDI-Ausgang ausgewählt") }

    // MARK: - Track Header

    var mutedTooltip:        String { e("Track muted (click to unmute)",    "Track stumm (klicken zum Einschalten)") }
    var muteTooltip:         String { e("Mute this track",                   "Track stummschalten") }
    var soloActiveTooltip:   String { e("Solo active (all others muted)",    "Solo aktiv (alle anderen stumm)") }
    var soloTooltip:         String { e("Solo — mute all other tracks",      "Nur diesen Track Solo spielen") }
    var duplicateTooltip:    String { e("Duplicate track",                   "Track duplizieren") }
    var deleteTooltip:       String { e("Delete track",                      "Track löschen") }
    var feelTooltip:         String { e("Set timing offset (feel)",          "Timing-Versatz (Feel) einstellen") }
    var scaleTooltip:        String { e("Set key and mode",                  "Tonart und Modus einstellen") }
    var randomizeTooltip:    String { e("Randomize steps",                   "Steps zufällig belegen") }
    var clearTooltip:        String { e("Clear all steps in this track",     "Alle Steps dieses Tracks löschen") }
    var midiChannelTooltip:  String { e("MIDI channel · 10 ◆ = GM Drums",   "MIDI-Kanal · 10 ◆ = GM Drums") }

    var forwardDirTip:       String { e("Forward: Step 1 → N",               "Vorwärts: Step 1 → N") }
    var reverseDirTip:       String { e("Reverse: Step N → 1",               "Rückwärts: Step N → 1") }
    var pingPongDirTip:      String { e("Ping-Pong: 1→N→1→N…",              "Ping-Pong: 1→N→1→N…") }
    var randomDirTip:        String { e("Random: steps in random order",     "Zufällig: Steps in zufälliger Reihenfolge") }

    // Context menu
    var insertTrackBelow:    String { e("Insert Track Below",  "Track darunter einfügen") }
    var duplicateTrack:      String { e("Duplicate Track",     "Track duplizieren") }
    var deleteTrack:         String { e("Delete Track",        "Track löschen") }

    // Feel popover
    var feelHeader:          String { "FEEL" }
    var feelReset:           String { e("RESET", "RESET") }
    var pushed:              String { e("− pushed",   "− pushed") }
    var laidBack:            String { e("laid back +", "laid back +") }

    // Scale picker
    var scaleHeader:         String { e("KEY / SCALE",  "TONART / SCALE") }
    var rootNote:            String { e("ROOT NOTE",    "GRUNDTON") }
    var modeLabel:           String { e("MODE",         "MODUS") }
    func scaleHint(_ root: String, _ scale: String) -> String {
        e("Key: \(root) \(scale) — dimmed = out of scale",
          "Tonart: \(root) \(scale) — abgedunkelt = außerhalb")
    }

    // MARK: - Track Row (selection bar)

    func stepsSelected(_ n: Int) -> String { "\(n) STEPS" }
    var editStepsLabel:      String { e("EDIT",  "EDIT") }
    var copyStepsLabel:      String { e("COPY",  "KOP.") }
    var pasteStepsLabel:     String { e("PASTE", "EINF.") }
    var clearStepsLabel:     String { e("CLR",   "LÖS.") }
    var editStepsTip:        String { e("Edit selected steps together",        "Markierte Steps gemeinsam bearbeiten") }
    var copyStepsTip:        String { e("Copy selected steps (⌘C)",            "Markierte Steps kopieren (⌘C)") }
    var pasteStepsTip:       String { e("Paste steps from clipboard (⌘V)",     "Steps aus Zwischenablage einfügen (⌘V)") }
    var clearSelTip:         String { e("Delete selected steps",               "Markierte Steps löschen") }
    var deselectTip:         String { e("Deselect (Esc)",                      "Auswahl aufheben (Esc)") }

    // MARK: - CC Row

    var ccRandomizeLabel:    String { e("RND",  "RND") }
    var ccResetLabel:        String { e("NEU",  "NEU") }
    var ccResetTooltip:      String { e("Reset to 64",                 "Auf 64 zurücksetzen") }
    var ccShowCurveTooltip:  String { e("Show curve",                  "Kurve anzeigen") }
    var ccHideCurveTooltip:  String { e("Hide curve",                  "Kurve ausblenden") }
    var ccDrawModeTooltip:   String { e("Draw mode",                   "Zeichenmodus") }
    var ccDrawModeOnTooltip: String { e("Draw mode ON — drag to draw", "Zeichenmodus AN — ziehen zum Zeichnen") }
    var ccMuteTooltip:       String { e("Mute this CC",                "Diese CC-Reihe stummschalten") }
    var ccMutedTooltip:      String { e("CC muted — tap to unmute",    "CC stumm — antippen zum Einschalten") }

    // MARK: - Undo action names

    var undoRandomize:       String { e("Randomize", "Randomize") }
    var undoClear:           String { e("Clear",      "Leeren") }
    var undoPasteSteps:      String { e("Paste Steps", "Steps einfügen") }
    var undoLearnNote:       String { e("Learn Note",  "Note lernen") }
    var undoStep:            String { e("Step",       "Step") }
    var undoStepEdit:        String { e("Edit Step",  "Step ändern") }
    var undoStepRatio:       String { e("Step Ratio", "Step Ratio") }
    var undoStepCount:       String { e("Step Count", "Step-Anzahl") }
    var undoRename:          String { e("Rename Track",    "Spur umbenennen") }
    var undoMoveStep:        String { e("Move Step",       "Step verschieben") }
    var undoPitchDrag:       String { e("Pitch",           "Tonhöhe") }
    var undoCCDraw:          String { e("Draw CC",         "CC zeichnen") }
    var undoResetCC:         String { e("Reset CC",        "CC zurücksetzen") }
    var undoAddTrack:        String { e("Add Track",       "Spur hinzufügen") }
    var undoDeleteTrack:     String { e("Delete Track",    "Spur löschen") }
    var undoInsertTrack:     String { e("Insert Track",    "Spur einfügen") }
    var undoDuplicateTrack:  String { e("Duplicate Track", "Spur duplizieren") }
    var undoChangeTrackColor: String { e("Change Track Color", "Spurfarbe ändern") }
    var trackColorMenu:       String { e("Track Color",        "Spurfarbe") }

    // CC-Lane Slice 1 (v1.8.0)
    var ccNumberLabel:       String { e("CC#", "CC#") }
    var undoCCLaneDraw:      String { e("Draw CC Lane",  "CC-Lane zeichnen") }
    var undoCCLaneRandomize: String { e("Randomize CC",  "CC randomisieren") }
    var undoCCLaneReset:     String { e("Reset CC Lane", "CC-Lane zurücksetzen") }
    var addStepTrack:        String { e("Add Step Track", "Step-Track hinzufügen") }
    var addCCTrack:          String { e("Add CC Track",   "CC-Track hinzufügen") }
    var addPadTrack:         String { e("Add Pad Track (long steps)", "Pad-Track hinzufügen (lange Steps)") }
    var padLengthHelp:       String { e("Step length of the pad track (4/4 bars).",
                                        "Steplänge des Pad-Tracks (4/4-Takte).") }
    var holdLabel:           String { e("HOLD", "HALTEN") }
    var fixedNoteLabel:      String { e("ONE NOTE", "EIN TON") }
    var fixedNoteHelp:       String { e("One note for the whole track: every step plays this note (e.g. a kick). The steps keep their own notes and get them back when switched off.",
                                        "Ein Ton für die ganze Spur: Jeder Step spielt diesen Ton (z. B. eine Kick). Die Steps behalten ihre eigenen Noten und bekommen sie beim Ausschalten zurück.") }
    var padRandomizeTooltip: String { e("RND: roll chords for this pad track, from the source chosen with ▾.",
                                        "RND: Akkorde für diesen Pad-Track würfeln, aus der mit ▾ gewählten Quelle.") }
    var padChordSourceTooltip: String { e("Chord source for RND: progressions from Lizzio (Chord Progression Codex) and Callipari (Illustrierte Harmonie), a specific progression, or chords from the track's scale.",
                                          "Akkordquelle für RND: Folgen aus Lizzio (Chord Progression Codex) und Callipari (Illustrierte Harmonie), eine bestimmte Folge oder Akkorde aus der Skala des Tracks.") }
    var padChordsBooksAny:   String { e("Progressions from the books (random)", "Folgen aus den Büchern (zufällig)") }
    var padChordsFree:       String { e("Chords from the track's scale", "Akkorde aus der Skala des Tracks") }
    var padChordsBooksHeader: String { e("Lizzio · Callipari", "Lizzio · Callipari") }
    var holdHelp:            String { e("Hold: this step plays no new note but extends the previous step's sound by its length. Several hold steps in a row extend further.",
                                        "Halten: Dieser Step schlägt nichts an, sondern verlängert den Klang des vorherigen Steps um seine Länge. Mehrere Halte-Steps hintereinander verlängern weiter.") }

    // MARK: - Step Button

    var stepTip:             String { e("Click: on/off · Right-click: edit · ⇧+Click: select · Drag ↕: pitch · ⌥+Drag ↕: velocity · Drag ↔: move",
                                        "Klick: an/aus · Rechtsklick: bearbeiten · ⇧+Klick: markieren · Ziehen ↕: Tonhöhe · ⌥+Ziehen ↕: Velocity · Ziehen ↔: verschieben") }
    var droneLabel:          String { e("DRONE", "DRONE") }
    var droneHelp:           String { e("Drone: the note holds for the whole track length and is not re-struck on the next pass. Gate and ratchet do not apply.",
                                        "Drone: Der Ton hält über die ganze Spurlänge und wird im nächsten Durchlauf nicht neu angeschlagen. Gate und Ratchet gelten nicht.") }
    var clearStep:           String { e("Clear Step",    "Step löschen") }

    // MARK: - Step Detail / Multi-Edit

    var active:              String { e("ACTIVE",   "AKTIV") }
    func stepHeader(_ n: Int) -> String { "STEP \(n)" }
    func bulkHeader(_ n: Int) -> String { e("\(n) STEPS — BULK EDIT", "\(n) STEPS — BULK EDIT") }
    var done:                String { e("DONE",      "FERTIG") }
    var allOn:               String { e("ALL ON",    "ALLE AN") }
    var allOff:              String { e("ALL OFF",   "ALLE AUS") }
    var copyBulk:            String { e("COPY",      "KOPIEREN") }
    var clearBulk:           String { e("CLEAR",     "LEEREN") }
    var drumSound:           String { e("DRUM SOUND", "DRUM SOUND") }
    func drumSoundBulk(_ n: Int) -> String {
        e("DRUM SOUND  →  all \(n) selected steps", "DRUM SOUND  →  alle \(n) markierten Steps")
    }
    func noteBulk(_ n: Int) -> String {
        e("NOTE  →  all \(n) selected steps", "NOTE  →  alle \(n) markierten Steps")
    }
    var unison:              String { "UNISON" }
    var noteModeSingle:      String { e("NOTE",  "TON") }
    var noteModeChord:       String { e("CHORD", "AKKORD") }
    var noteModeHelp:        String { e("NOTE: a click replaces the note · CHORD: a click adds or removes a chord note · ⇧-click always adds/removes",
                                        "TON: Klick ersetzt den Ton · AKKORD: Klick fügt einen Akkordton hinzu oder entfernt ihn · ⇧-Klick fügt immer hinzu/entfernt") }
    var undoBulkEdit:        String { e("Edit Steps", "Steps ändern") }
    var drumTrackMenu:       String { e("Drum Track (drum names and drum picker)", "Drum-Spur (Drum-Namen und Drum-Auswahl)") }
    var stepCountHeader:     String { e("STEP COUNT", "STEP-ANZAHL") }

    // MARK: - Mixer / Instrument Rack (v1.13.0, Kanalzüge v1.13.1)

    var rackTooltip:         String { e("Show or hide the mixer — AU instruments, effects, levels",
                                        "Mixer ein-/ausblenden — AU-Instrumente, Effekte, Pegel") }
    var rackAddChannelHelp:  String { e("Add an instrument channel (up to 16)", "Instrumentenkanal hinzufügen (bis zu 16)") }
    var rackRemoveChannel:   String { e("Delete Channel", "Kanal löschen") }
    func rackDefaultChannelName(_ n: Int) -> String { "Inst \(n)" }
    var rackEmptyHint:       String { e("No instrument channels yet.\nAdd a channel with +, pick an AU instrument, then choose the channel as a track's output (CH/AU button in the track header).",
                                        "Noch keine Instrumentenkanäle.\nMit + einen Kanal anlegen, ein AU-Instrument wählen und den Kanal als Ausgang einer Spur einstellen (Taste CH/AU im Spurkopf).") }
    func rackEngineError(_ m: String) -> String { e("Audio output could not be started: \(m)",
                                                    "Audioausgabe konnte nicht gestartet werden: \(m)") }
    var rackVolume:          String { e("Level", "Pegel") }
    var rackMuteHelp:        String { e("Mute channel", "Kanal stummschalten") }
    var rackStatusMissingHelp: String { e("This plug-in is not installed on this Mac. Its saved sound is kept and written back when you save.",
                                          "Dieses Plug-in ist auf diesem Mac nicht installiert. Der gespeicherte Klang bleibt erhalten und wird beim Speichern wieder geschrieben.") }
    var mixerChannel:        String { e("Channel", "Kanal") }
    var mixerSum:            String { e("SUM", "SUMME") }
    func mixerOpenEditorHelp(_ name: String) -> String { e("Open \(name)", "\(name) öffnen") }
    var mixerEmpty:          String { e("Empty", "Leer") }
    func mixerUnavailable(_ name: String) -> String { e("Not installed: \(name)", "Nicht installiert: \(name)") }
    var mixerNoAudioUnits:   String { e("No Audio Units found", "Keine Audio Units gefunden") }
    var mixerSlotOnHelp:     String { e("Turn on", "Einschalten") }
    var mixerSlotOffHelp:    String { e("Turn off", "Ausschalten") }
    func mixerSlotPower(_ name: String) -> String { e("\(name) on/off", "\(name) ein/aus") }
    var mixerChooseHelp:     String { e("Choose an instrument or effect for this slot", "Instrument oder Effekt für diesen Platz wählen") }
    var mixerPanHelp:        String { e("Drag vertically to pan (⌥ fine). Double-click to center.", "Senkrecht ziehen für Panorama (⌥ fein). Doppelklick stellt auf Mitte.") }
    var mixerFaderHelp:      String { e("Level. Drag (⌥ fine, Esc cancels), scroll, or double-click for 0 dB.", "Pegel. Ziehen (⌥ fein, Esc bricht ab), scrollen oder Doppelklick für 0 dB.") }
    var mixerMeterHelp:      String { e("Level after the fader, in dBFS. The red overload field clears itself after 2 s; click to clear it at once.", "Pegel nach dem Fader, in dBFS. Das rote Übersteuerungsfeld erlischt nach 2 s; Klick löscht es sofort.") }
    var mixerRename:         String { e("Rename…", "Umbenennen …") }
    var mixerSoloHelp:       String { e("Solo — only soloed channels are audible", "Solo — nur Kanäle auf Solo sind hörbar") }
    var mixerNameHelp:       String { e("Double-click to rename", "Doppelklick zum Umbenennen") }
    var mixerPanicHelp:      String { e("Release all notes on all instruments and MIDI outputs",
                                        "Alle Noten auf allen Instrumenten und MIDI-Ausgängen beenden") }
    var mixerDuplicateChannel: String { e("Duplicate Channel", "Kanal duplizieren") }
    var mixerDeleteTitle:    String { e("Delete channel?", "Kanal löschen?") }
    func mixerDeleteMessage(_ n: Int) -> String {
        e("\(n) track\(n == 1 ? "" : "s") play this channel and will go back to external MIDI. This cannot be undone.",
          "\(n) Spur\(n == 1 ? " spielt" : "en spielen") diesen Kanal und \(n == 1 ? "geht" : "gehen") zurück auf externes MIDI. Das lässt sich nicht rückgängig machen.")
    }
    var trackOutputMenu:     String { e("Output", "Ausgang") }
    var trackOutputMIDI:     String { e("External MIDI", "Externes MIDI") }
    var ccTargetChooseHelp:  String { e("Target: MIDI CC — click to choose a parameter of the instrument", "Ziel: MIDI-CC — klicken, um einen Parameter des Instruments zu wählen") }
    func ccTargetParameterHelp(_ p: String, _ ch: String) -> String { e("Controls “\(p)” of “\(ch)”", "Steuert „\(p)“ von „\(ch)“") }
    func ccTargetUnresolvedHelp(_ p: String) -> String { e("“\(p)” is not available (instrument loading, replaced, or parameter missing) — the lane sends nothing. Click to choose a target.", "„\(p)“ ist nicht verfügbar (Instrument lädt, wurde getauscht oder der Parameter fehlt) — die Spur sendet nichts. Klicken, um ein Ziel zu wählen.") }
    func ccTargetMIDI(_ n: Int) -> String { e("MIDI CC \(n)", "MIDI-CC \(n)") }
    var ccTargetNoParameters: String { e("No parameters (instrument not loaded)", "Keine Parameter (Instrument nicht geladen)") }
    var trackOutputNewChannel: String { e("New Instrument Channel", "Neuer Instrumentenkanal") }
    var trackOutputChooseHelp: String { e("Output: external MIDI — click to choose an instrument channel", "Ausgang: externes MIDI — klicken, um einen Instrumentenkanal zu wählen") }
    func trackOutputHelp(_ name: String) -> String { e("Plays instrument channel “\(name)”", "Spielt Instrumentenkanal „\(name)“") }

    // Drum groups
    var kickSnare:           String { e("KICK / SNARE", "KICK / SNARE") }
    var hiHat:               String { e("HI-HAT",       "HI-HAT") }
    var toms:                String { e("TOMS",          "TOMS") }
    var cymbal:              String { e("CYMBAL",        "CYMBAL") }

    // MARK: - Stretch Handle / Step Length Popover

    var ratioTapHelp:        String { e("↑↓ drag · click for input",
                                        "↑↓ ziehen · klicken für Eingabe") }
    var ratioStretchHelp:    String { e("↑↓ drag to stretch · click for input",
                                        "↑↓ ziehen zum Strecken · klicken für Eingabe") }
    var stepCountHelp:       String { e("Step count: ↑↓ drag · click for input",
                                        "Step-Anzahl: ↑↓ ziehen · klicken für Eingabe") }
    var ratioHeader:         String { e("STEP LENGTH / RATIO", "STEP-LÄNGE / RATIO") }
    var ratioQuickSelect:    String { e("QUICK SELECT",         "SCHNELLWAHL") }
    var ratioReset:          String { e("RESET 1:1",            "RESET 1:1") }

    // MARK: - Main View / Add Track

    var addTrack:            String { e("ADD TRACK",         "SPUR HINZUFÜGEN") }

    // MARK: - Settings (v1.12.20)

    var settingsTitle:       String { e("SETTINGS", "EINSTELLUNGEN") }
    var close:               String { e("CLOSE", "SCHLIESSEN") }
    var settingsTracks:      String { e("TRACKS", "SPUREN") }
    var settingsTracksHint:  String { e("Use + / × buttons directly in the track list to add or remove tracks.",
                                        "Spuren direkt in der Spurliste über + / × hinzufügen oder entfernen.") }
    var settingsMIDIOutput:  String { e("MIDI OUTPUT", "MIDI-AUSGANG") }
    var settingsDevice:      String { e("Device", "Gerät") }
    var settingsNone:        String { e("None", "Keins") }
    var settingsClock:       String { e("CLOCK", "CLOCK") }
    var settingsClockSource: String { e("Source", "Quelle") }
    var settingsMenuItem:    String { e("Settings…", "Einstellungen …") }
    var diagnosticsRecord:   String { e("Record Audio Diagnostics", "Audio-Diagnose aufzeichnen") }
    var diagnosticsMark:     String { e("Set Diagnostics Marker", "Diagnose-Markierung setzen") }
    var diagnosticsReveal:   String { e("Show Diagnostics Folder", "Diagnose-Ordner zeigen") }
    var settingsMIDIInput:   String { e("MIDI INPUT  (clock sync)", "MIDI-EINGANG  (Clock-Sync)") }
    var settingsSource:      String { e("Source", "Quelle") }
    var settingsRefreshPorts: String { e("Refresh MIDI Ports", "MIDI-Ports aktualisieren") }
    var settingsCCRemote:    String { e("CC REMOTE CONTROL", "CC-FERNSTEUERUNG") }
    var settingsPatternCC:   String { e("Pattern switch CC#", "Pattern-Wechsel CC#") }
    var settingsPatternCCHint: String { e("Values 0–31=A  32–63=B  64–95=C  96–127=D",
                                          "Werte 0–31=A  32–63=B  64–95=C  96–127=D") }
    func settingsMuteCC(_ n: Int) -> String { e("Mute Track \(n) CC#", "Spur \(n) stumm CC#") }
    var settingsOff:         String { e("Off", "Aus") }

    // MARK: - Notes

    var notesTitle:          String { e("NOTES", "NOTIZEN") }
    var notesEmpty:          String { e("No entries yet", "Noch keine Einträge") }
    func notesCreated(_ d: String) -> String { e("Created  \(d)", "Erstellt  \(d)") }
    func notesEdited(_ d: String)  -> String { e("Edited    \(d)", "Geändert  \(d)") }
    var notesDelete:         String { e("DELETE", "LÖSCHEN") }
    var notesUnsaved:        String { e("Unsaved changes", "Ungespeicherte Änderungen") }
    var notesSave:           String { e("SAVE", "SPEICHERN") }
    var notesSelectHint:     String { e("Select an entry to view or edit", "Eintrag zum Ansehen oder Bearbeiten wählen") }
    var quickCaptureTitle:   String { e("QUICK CAPTURE", "SCHNELLNOTIZ") }
    var quickCapturePlaceholder: String { e("Thoughts, ideas, bugs …", "Gedanken, Ideen, Bugs …") }
    var quickCaptureSaveHint: String { e("⌘↩ Save", "⌘↩ Speichern") }

    // MARK: - Track header / colors

    var namePlaceholder:     String { e("Name", "Name") }
    func colorName(_ n: Int) -> String { e("Color \(n)", "Farbe \(n)") }

    // MARK: - Step length quick select (label, tooltip)

    func ratioOption(num: Int, den: Int) -> (label: String, tooltip: String) {
        switch (num, den) {
        case (1, 2): return (e("32nd", "32tel"),
                             e("Thirty-second — half as long as a sixteenth  (1:2)",
                               "Zweiunddreißigstel — halb so lang wie eine Sechzehntel  (1:2)"))
        case (4, 7): return (e("Septuplet÷", "Septole÷"),
                             e("Sixteenth septuplet — 7 notes in the space of 4 sixteenths, shorter step  (4:7)",
                               "Sechzehntelseptole — 7 Noten auf 4 Sechzehntel, Step kürzer  (4:7)"))
        case (2, 3): return (e("16th·Triplet", "16t·Triole"),
                             e("Sixteenth triplet — 3 notes in the space of 2 sixteenths  (2:3)",
                               "Sechzehnteltriole — 3 Noten auf den Raum von 2 Sechzehnteln  (2:3)"))
        case (3, 4): return (e("Quadruplet÷", "Quartole÷"),
                             e("Sixteenth quadruplet — 4 notes in the space of 3 sixteenths  (3:4)",
                               "Sechzehntelquartole — 4 Noten auf den Raum von 3 Sechzehnteln  (3:4)"))
        case (4, 5): return (e("Quintuplet÷", "Quintole÷"),
                             e("Sixteenth quintuplet — 5 notes in the space of 4 sixteenths  (4:5)",
                               "Sechzehntelquintole — 5 Noten auf den Raum von 4 Sechzehnteln  (4:5)"))
        case (8, 9): return (e("Nonuplet÷", "Nonole÷"),
                             e("Sixteenth nonuplet — 9 notes in the space of 8 sixteenths  (8:9)",
                               "Sechzehntelnonole — 9 Noten auf den Raum von 8 Sechzehnteln  (8:9)"))
        case (1, 1): return (e("16th", "16tel"),
                             e("Sixteenth — reference value, normal step  (1:1)",
                               "Sechzehntel — Referenzwert, normaler Step  (1:1)"))
        case (9, 8): return (e("Nonuplet×", "Nonole×"),
                             e("Stretched nonuplet — 8 notes in the space of 9 sixteenths  (9:8)",
                               "Nonole gedehnt — 8 Noten auf den Raum von 9 Sechzehnteln  (9:8)"))
        case (5, 4): return (e("Quintuplet×", "Quintole×"),
                             e("Stretched quintuplet — 4 notes in the space of 5 sixteenths  (5:4)",
                               "Quintole gedehnt — 4 Noten auf den Raum von 5 Sechzehnteln  (5:4)"))
        case (4, 3): return (e("8th·Triplet", "8t·Triole"),
                             e("Eighth triplet — 3 notes in the space of 2 eighths (= 4 sixteenths)  (4:3)",
                               "Achteltriole — 3 Noten auf den Raum von 2 Achteln (= 4 Sechzehntel)  (4:3)"))
        case (3, 2): return (e("dot.16th", "pkt.16tel"),
                             e("Dotted sixteenth — sixteenth plus thirty-second  (3:2)",
                               "Punktierte Sechzehntel — Sechzehntel + Zweiunddreißigstel  (3:2)"))
        case (7, 4): return (e("Septuplet×", "Septole×"),
                             e("Stretched septuplet — 4 notes in the space of 7 sixteenths  (7:4)",
                               "Septole gedehnt — 4 Noten auf den Raum von 7 Sechzehnteln  (7:4)"))
        case (2, 1): return (e("8th", "8tel"),
                             e("Eighth note — twice as long as a sixteenth  (2:1)",
                               "Achtelnote — doppelt so lang wie eine Sechzehntel  (2:1)"))
        default:     return ("\(num):\(den)", "\(num):\(den)")
        }
    }

    // MARK: - Fehlermeldungen (Preset-I/O, MIDI)

    var errorTitle:          String { e("Error", "Fehler") }
    var ok:                  String { e("OK", "OK") }
    func errPresetLoad(_ reason: String) -> String { e("Preset could not be loaded: \(reason)",
                                                       "Preset konnte nicht geladen werden: \(reason)") }
    var errPresetNoPatterns: String { e("no patterns", "keine Patterns enthalten") }
    func errPresetOpen(_ reason: String) -> String { e("Preset could not be opened: \(reason)",
                                                       "Preset konnte nicht geöffnet werden: \(reason)") }
    func errPresetSave(_ reason: String) -> String { e("Preset could not be saved: \(reason)",
                                                       "Preset konnte nicht gespeichert werden: \(reason)") }
    var errPresetEncode:     String { e("Preset could not be encoded", "Preset konnte nicht kodiert werden") }
    var errMIDIOutputGone:   String { e("MIDI output device disconnected.", "MIDI-Ausgabegerät wurde getrennt.") }
}
