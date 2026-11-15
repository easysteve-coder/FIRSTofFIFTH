// Str.swift — All user-facing strings, English (default) / German.
//
// Usage in SwiftUI views:
//   @AppStorage("appLanguage") private var lang: String = "en"
//   private var s: Str { Str(lang) }
//
// Usage in non-SwiftUI code (AppDelegate, Engine):
//   let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")

import Foundation

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
    func audioLoopTrackName(_ n: Int) -> String { e("Loop \(n)", "Loop \(n)") }

    // Audio-Loop (v1.15.0)
    var addAudioLoopTrack:   String { e("Add Audio Loop Track", "Audio-Loop-Spur hinzufügen") }
    var mixerAudioLoopSource: String { "AUDIO-LOOP" }
    var loopBadge:           String { "LOOP" }
    var loopRecLabel:        String { "REC" }
    var loopArmLabel:        String { "ARM" }
    var loopEndLabel:        String { e("END", "ENDE") }
    var loopUndoLabel:       String { "UNDO" }
    var loopRedoLabel:       String { "REDO" }
    var loopClearLabel:      String { "CLR" }
    var loopMonLabel:        String { "MON" }
    var loopGateLabel:       String { "GATE" }
    var loopRecTip:          String { e("Arm recording (R): starts on the next bar and keeps overdubbing every pass",
                                        "Aufnahme scharf schalten (R): beginnt am nächsten Takt und schichtet in jedem Durchlauf weiter") }
    var loopArmedTip:        String { e("Armed — recording starts on the next bar. Click (R): cancel",
                                        "Scharf — die Aufnahme beginnt am nächsten Takt. Klick (R): abbrechen") }
    var loopRecordingTip:    String { e("Recording (overdub). Click (R): stop at the end of this pass",
                                        "Nimmt auf (Overdub). Klick (R): am Ende dieses Durchlaufs beenden") }
    var loopFinishingTip:    String { e("Stops at the end of this pass. Click (R): keep recording",
                                        "Endet am Ende dieses Durchlaufs. Klick (R): weiter aufnehmen") }
    var loopUndoTip:         String { e("Undo the last pass (click again: redo)",
                                        "Letzten Durchlauf rückgängig (erneut: wiederherstellen)") }
    var loopClearTip:        String { e("Erase the loop", "Loop löschen") }
    var loopBarsTip:         String { e("Loop length in bars", "Loop-Länge in Takten") }
    var loopBarsLockedTip:   String { e("Loop length — erase the loop to change it",
                                        "Loop-Länge — zum Ändern erst den Loop löschen") }
    var loopMonitorTip:      String { e("Monitor the input through this channel",
                                        "Eingang über diesen Kanal mithören") }
    var loopInputTip:        String { e("Audio input, channels and latency", "Audioeingang, Kanäle und Latenz") }
    var loopInputLevelTip:   String { e("Input level (dBFS, peak hold). Active while monitoring, armed or recording",
                                        "Eingangspegel (dBFS, Spitze gehalten). Aktiv beim Mithören, scharf oder bei der Aufnahme") }
    var loopGateTip:         String { e("Noise gate: at the input, before or after the fader",
                                        "Rauschgate: am Eingang, vor oder nach dem Fader") }
    var loopInputHeader:     String { e("INPUT", "EINGANG") }
    func loopInputChannel(_ c: Int, stereo: Bool) -> String { stereo ? "IN \(c + 1)-\(c + 2)" : "IN \(c + 1)" }
    var loopStereo:          String { "Stereo" }
    // Abtastrate des Instruments (v1.18.9)
    var renderRateMenu: String { e("Plug-in sample rate", "Abtastrate des Plug-ins") }

    // Kanal-EQ (v1.18.11)
    var eqTitle:        String { e("Channel EQ", "Kanal-EQ") }
    var eqOpenHelp:     String { e("Channel EQ — click to edit", "Kanal-EQ — Klick zum Bearbeiten") }
    var eqFlat:         String { e("flat", "neutral") }
    var eqOnHelp:       String { e("Turn the EQ on", "EQ einschalten") }
    var eqOffHelp:      String { e("Turn the EQ off (bypass)", "EQ ausschalten (überbrücken)") }
    var eqReset:        String { e("Reset", "Zurücksetzen") }
    var eqResetHelp:    String { e("Reset all bands to their defaults", "Alle Bänder auf Grundeinstellung") }
    var eqBandOnHelp:   String { e("Turn band on", "Band einschalten") }
    var eqBandOffHelp:  String { e("Turn band off", "Band ausschalten") }
    var eqFrequencyHelp: String { e("Frequency — drag or scroll (⌥ fine), double-click resets",
                                    "Frequenz — ziehen oder scrollen (⌥ fein), Doppelklick setzt zurück") }
    var eqGainHelp:     String { e("Gain — drag or scroll (⌥ fine), double-click = 0 dB",
                                   "Pegel — ziehen oder scrollen (⌥ fein), Doppelklick = 0 dB") }
    var eqQHelp:        String { e("Q (bandwidth) — drag or scroll (⌥ fine), double-click resets",
                                   "Güte (Bandbreite) — ziehen oder scrollen (⌥ fein), Doppelklick setzt zurück") }
    var eqSlopeHelp:    String { e("Slope", "Flankensteilheit") }
    var eqGestureHint:  String { e("Drag a point: frequency/gain · ⌘-drag: Q · ⌥: fine · double-click: band on/off · ⌥-click: reset band",
                                   "Punkt ziehen: Frequenz/Pegel · ⌘-Ziehen: Güte · ⌥: fein · Doppelklick: Band ein/aus · ⌥-Klick: Band zurücksetzen") }
    func eqBandShort(_ kind: ChannelEQ.Kind, index: Int) -> String {
        switch kind {
        case .lowCut: return e("Low Cut", "Low Cut")
        case .lowShelf: return e("Low Shelf", "Low Shelf")
        case .bell: return "\(index - 1)"
        case .highShelf: return e("High Shelf", "High Shelf")
        case .highCut: return e("High Cut", "High Cut")
        }
    }
    private func decimal(_ v: Double, digits: Int) -> String {
        let p: Double = digits >= 2 ? 100 : (digits == 1 ? 10 : 1)
        let r = (abs(v) * p).rounded()
        let whole = Int(r / p), frac = Int(r) % Int(p)
        let body = digits == 0 ? "\(whole)" : "\(whole)\(de ? "," : ".")" + String(repeating: "0", count: max(0, digits - String(frac).count)) + "\(frac)"
        return (v < 0 && r > 0 ? "−" : "") + body
    }
    func eqFrequency(_ f: Double) -> String {
        f >= 1000 ? decimal(f / 1000, digits: f >= 10_000 ? 1 : 2) + " kHz" : decimal(f, digits: 0) + " Hz"
    }
    func eqFrequencyShort(_ f: Double) -> String { f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))" }
    func eqGain(_ g: Double) -> String { (g > 0.04 ? "+" : "") + decimal(g, digits: 1) + " dB" }
    func eqQ(_ q: Double) -> String { "Q " + decimal(q, digits: 2) }
    func eqSlope(_ s: Int) -> String { e("\(s) dB/oct", "\(s) dB/Okt.") }
    func kHz(_ rate: Double) -> String {
        let tenths = Int((rate / 100).rounded())
        let v = tenths % 10 == 0 ? "\(tenths / 10)" : (de ? "\(tenths / 10),\(tenths % 10)" : "\(tenths / 10).\(tenths % 10)")
        return "\(v) kHz"
    }
    func renderRateDevice(_ rate: Double?) -> String {
        let r = rate.map { " (\(kHz($0)))" } ?? ""
        return e("Device rate\(r)", "Geräterate\(r)")
    }
    // Geräte von Aufnahme und Wiedergabe (v1.18.7)
    var deviceInputRole:     String { e("RECORDING FROM (input)", "AUFNAHME VON (Eingang)") }
    var deviceOutputRole:    String { e("PLAYBACK TO (output)", "WIEDERGABE ÜBER (Ausgang)") }
    var deviceActive:        String { e("active", "aktiv") }
    var deviceUnknown:       String { e("unknown device", "unbekanntes Gerät") }
    var deviceNone:          String { e("no device", "kein Gerät") }
    func deviceFormat(channels: Int, sampleRate: Double) -> String {
        let tenths = Int((sampleRate / 100).rounded())
        let khz = tenths % 10 == 0 ? "\(tenths / 10)" : "\(tenths / 10).\(tenths % 10)"
        let sr = sampleRate > 0 ? " · \(khz) kHz" : ""
        return e("\(channels) ch\(sr)", "\(channels) Kan.\(sr)")
    }
    func deviceInputOff(defaultName: String?) -> String {
        let d = defaultName ?? deviceNone
        return e("Input off — starts when a loop is armed, monitored or measured. It will then use the system default input: \(d).",
                 "Eingang aus — startet beim Scharfschalten, Mithören oder Messen. Er nimmt dann vom Systemstandard-Eingang auf: \(d).")
    }
    func deviceOutputOff(defaultName: String?) -> String {
        let d = defaultName ?? deviceNone
        return e("Output off — starts when an instrument or loop is loaded. It will then use the system default output: \(d).",
                 "Ausgang aus — startet, sobald ein Instrument oder Loop geladen ist. Er spielt dann über den Systemstandard-Ausgang: \(d).")
    }
    func deviceDiffers(defaultName: String?) -> String {
        e("System default is now \(defaultName ?? deviceNone) — still running on the device above until the audio restarts.",
          "Systemstandard ist jetzt \(defaultName ?? deviceNone) — läuft bis zum Neustart des Audios weiter über das Gerät oben.")
    }
    func loopChannelSelection(_ c: Int, stereo: Bool) -> String {
        stereo ? e("Channels \(c + 1)–\(c + 2) · stereo", "Kanäle \(c + 1)–\(c + 2) · Stereo")
               : e("Channel \(c + 1) · mono", "Kanal \(c + 1) · Mono")
    }
    func loopChannelMissing(_ c: Int, stereo: Bool, available: Int) -> String {
        let need = stereo ? c + 2 : c + 1
        return e("This device has \(available) input channel(s) — channel \(need) does not exist; the loop records silence.",
                 "Dieses Gerät hat \(available) Eingangskanal/-kanäle — Kanal \(need) gibt es nicht; der Loop nimmt Stille auf.")
    }
    var deviceInputOffShort: String { e("input off", "Eingang aus") }
    func deviceHeaderTip(input: String, output: String) -> String {
        e("Input: \(input) · Output: \(output)", "Eingang: \(input) · Ausgang: \(output)")
    }
    var loopLatency:         String { e("Latency offset", "Latenzausgleich") }
    var loopLatencyHelp:     String { e("Device latency is compensated automatically. If recordings land late, raise the value; early, lower it.",
                                        "Die Gerätelatenz wird automatisch ausgeglichen. Liegt Aufgenommenes zu spät, Wert erhöhen; zu früh, verringern.") }
    // Latenzmessung per Loopback (v1.15.2)
    var loopMeasureLabel:    String { e("MEASURE", "MESSEN") }
    var loopMeasureRunning:  String { e("measuring…", "misst…") }
    var loopMeasureFailed:   String { e("no click received", "kein Klick empfangen") }
    func loopMeasureResult(roundTripMs: Double, offsetMs: Double, clamped: Bool) -> String {
        let rt = "\((roundTripMs * 10).rounded() / 10)"
        let o = Int(offsetMs.rounded()), off = o >= 0 ? "+\(o)" : "\(o)"
        return clamped ? e("\(rt) ms — offset limited to \(off) ms", "\(rt) ms — Ausgleich begrenzt auf \(off) ms")
                       : e("\(rt) ms → offset \(off) ms", "\(rt) ms → Ausgleich \(off) ms")
    }
    var loopMeasureHelp:     String { e("Connect this channel's output to the selected input with a cable (channel not muted), then measure. The offset is set so recordings land on the beat.",
                                        "Ausgang dieses Kanals per Kabel mit dem gewählten Eingang verbinden (Kanal nicht stumm), dann messen. Der Ausgleich wird so gesetzt, dass Aufnahmen auf dem Schlag liegen.") }
    var gateHeader:          String { "GATE" }
    func gatePosition(_ p: GatePosition) -> String {
        switch p {
        case .off:       return e("Off", "Aus")
        case .input:     return e("Input", "Eingang")
        case .preFader:  return "Pre-Fader"
        case .postFader: return "Post-Fader"
        }
    }
    var gateThreshold:       String { e("Threshold", "Schwelle") }
    var gateRelease:         String { e("Release", "Ausklingen") }
    var gateHold:            String { e("Hold", "Halten") }
    var gateHelp:            String { e("Input: noise never reaches the loop. Pre-fader: after the effects. Post-fader: after the fader.",
                                        "Eingang: Störgeräusche gelangen gar nicht in den Loop. Pre-Fader: nach den Effekten. Post-Fader: nach dem Fader.") }
    var loopEmptyHint:       String { e("Empty — REC or R: recording starts on the next bar",
                                        "Leer — REC oder R: die Aufnahme beginnt am nächsten Takt") }
    var loopNoChannel:       String { e("No audio loop channel — choose one with the output button",
                                        "Kein Audio-Loop-Kanal — über die Ausgangstaste zuweisen") }
    func loopError(_ code: String) -> String {
        switch code {
        case "denied":  return e("Microphone access denied — allow FIRSTofFIFTH in System Settings › Privacy & Security › Microphone.",
                                 "Mikrofonzugriff verweigert — FIRSTofFIFTH in Systemeinstellungen › Datenschutz & Sicherheit › Mikrofon erlauben.")
        case "noInput": return e("No audio input available.", "Kein Audioeingang verfügbar.")
        case "stretched": return e("Overdub only at the loop's own tempo and time signature — it is time-stretched now.",
                                   "Overdub nur im Tempo und in der Taktart des Loops — er wird gerade gedehnt.")
        case "tooLong": return e("Loop too long at this tempo (max. 120 s).", "Loop bei diesem Tempo zu lang (höchstens 120 s).")
        case "budget":  return e("Audio loop memory budget reached (1 GB for all loops of the project).",
                                 "Speicherbudget der Audio-Loops erreicht (1 GB für alle Loops des Projekts).")
        case "noOutput": return e("No audio output — the audio engine is not running.", "Kein Audioausgang — die Audio-Engine läuft nicht.")
        default:        return code
        }
    }
    var loopRateMismatch:    String { e("Input and output run at different sample rates — set both devices to the same rate (Audio MIDI Setup).",
                                        "Ein- und Ausgang laufen mit verschiedenen Abtastraten — beide Geräte auf dieselbe Rate stellen (Audio-MIDI-Setup).") }
    var loopRecordMenuItem:  String { e("Audio Loop: Record / Stop", "Audio-Loop: Aufnahme / Ende") }
    func trackDuplName(_ name: String) -> String { name + " 2" }

    func muteMenuItem(_ n: Int, isMuted: Bool) -> String {
        isMuted ? e("Unmute Track \(n)", "Spur \(n) einschalten")
                : e("Mute Track \(n)",   "Spur \(n) stummschalten")
    }
    func patternMenuItem(_ letter: String) -> String { "Pattern \(letter)" }
    var patternMenuMore: String { e("Patterns J–P", "Patterns J–P") }

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
    var deleteTooltip:       String { e("Delete track",                      "Track löschen") }
    var feelTooltip:         String { e("Set timing offset (feel)",          "Timing-Versatz (Feel) einstellen") }
    var scaleTooltip:        String { e("Set key and mode",                  "Tonart und Modus einstellen") }
    var randomizeTooltip:    String { e("Randomize steps (single notes, chords or mixed, as chosen with ▾)",
                                        "Steps zufällig belegen (Einzeltöne, Akkorde oder gemischt, wie mit ▾ gewählt)") }
    var clearTooltip:        String { e("Clear all steps in this track",     "Alle Steps dieses Tracks löschen") }
    var midiChannelTooltip:  String { e("MIDI channel · 10 ◆ = GM Drums",   "MIDI-Kanal · 10 ◆ = GM Drums") }

    var forwardDirTip:       String { e("Forward: Step 1 → N",               "Vorwärts: Step 1 → N") }
    var reverseDirTip:       String { e("Reverse: Step N → 1",               "Rückwärts: Step N → 1") }
    var pingPongDirTip:      String { e("Ping-Pong: 1→N→1→N…",              "Ping-Pong: 1→N→1→N…") }
    var randomDirTip:        String { e("Random: steps in random order",     "Zufällig: Steps in zufälliger Reihenfolge") }

    // Context menu
    var insertTrackBelow:    String { e("Insert Track Below",  "Track darunter einfügen") }
    var duplicateTrack:      String { e("Duplicate Track",     "Track duplizieren") }
    var moveTrackUp:         String { e("Move Up",             "Nach oben") }
    var moveTrackDown:       String { e("Move Down",           "Nach unten") }
    var collapseTrack:       String { e("Collapse Track",      "Spur einklappen") }
    var expandTrack:         String { e("Expand Track",        "Spur aufklappen") }
    var undoMoveTrack:       String { e("Move Track",          "Spur verschieben") }
    var collapseTrackTip:    String { e("Collapse or expand this track (keeps playing)",
                                        "Spur ein- oder aufklappen (spielt weiter)") }
    var dragTrackTip:        String { e("Drag to move the track", "Ziehen verschiebt die Spur") }
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
    var undoLoopPass:        String { e("Loop Pass", "Loop-Durchlauf") }
    var undoLoopClear:       String { e("Erase Loop", "Loop löschen") }
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
    var padLengthHelp:       String { e("Long step: beats and bars of the pattern's time signature. Every step sounds legato with RND.",
                                        "Langer Step: Schläge und Takte der Taktart des Patterns. RND lässt jeden Step legato klingen.") }
    var ratioLongHeader:     String { e("LONG STEPS", "LANGE STEPS") }
    var stepWidthAuto:       String { e("Auto", "Auto") }
    var holdLabel:           String { e("HOLD", "HALTEN") }
    var padWidthHeader:      String { e("STEP WIDTH", "STEP-BREITE") }
    // Song (v1.14.0)
    var songHeader:          String { "SONG" }
    var songLoopLabel:       String { "LOOP" }
    var songEndLabel:        String { e("END", "ENDE") }
    var songPatternHeader:   String { "PATTERN" }
    var songBarsHeader:      String { e("BARS", "TAKTE") }
    func songBars(_ n: Int) -> String { barsShort(n) }
    /// Kurze Taktangabe (Song, Loop-Länge, Pad-Länge).
    func barsShort(_ n: Int) -> String { de ? "\(n) T" : (n == 1 ? "1 bar" : "\(n) bars") }
    /// Anzeige einer Pad-Steplänge in Takten und Schlägen der Taktart (v1.18.12), sonst
    /// „n/d" (Codex N2: Darstellung gehört nicht ins Modell).
    func stepLength(num: Int, den: Int, meter: TimeSignature) -> String {
        guard den == 1 else { return "\(num)/\(den)" }
        let bar = meter.sixteenthsPerBar, beat = meter.sixteenthsPerBeat
        guard num % beat == 0 else { return "\(num)/16" }
        let bars = num / bar, beats = (num % bar) / beat
        if beats == 0 { return barsShort(bars) }
        let b = de ? "\(beats) Sl." : (beats == 1 ? "1 beat" : "\(beats) beats")
        return bars == 0 ? b : barsShort(bars) + " " + b
    }
    // Positionsanzeige und Spurangaben (v1.18.21)
    var positionBarsHelp:  String { e("Position: bar . beat . sixteenth . tick (240 per sixteenth) of what FoF is playing now — click: show time",
                                      "Position: Takt . Schlag . Sechzehntel . Tick (240 je Sechzehntel) dessen, was FoF gerade ausgibt — Klick: Zeit anzeigen") }
    var positionTimeHelp:  String { e("Time since play — click: show bars and beats",
                                      "Zeit seit Start — Klick: Takte und Schläge anzeigen") }
    var tempoFieldHelp:    String { e("Tempo — drag up/down (⇧: fine), double-click to type",
                                      "Tempo — nach oben/unten ziehen (⇧: fein), Doppelklick zum Eintippen") }
    var positionPatternLegend: String { e("PATTERN", "PATTERN") }
    var positionPatternHelp:   String { e("Playing pattern · ▸ next pattern · bars until the change (none: at the end of track 1)",
                                          "Laufendes Pattern · ▸ nächstes Pattern · Takte bis zum Wechsel (ohne Zahl: am Ende von Spur 1)") }
    var positionBarsLegend: String { e("BAR BEAT DIV TICK", "TAKT SCHLAG TEIL TICK") }
    var positionTimeLegend: String { e("H MIN SEC MS", "STD MIN SEK MS") }
    func meterBeatUnit(_ m: TimeSignature) -> String {
        let unit: String
        switch m.denominator {
        case 2:  unit = e("halves", "Halbe")
        case 8:  unit = e("eighths", "Achtel")
        case 16: unit = e("sixteenths", "Sechzehntel")
        default: unit = e("quarters", "Viertel")
        }
        return "\(m.numerator) \(unit)"
    }
    var infoNoteValue:     String { e("Note value", "Notenwert") }
    var infoTrackLength:   String { e("Track length", "Spurlänge") }
    var infoAtTempo:       String { e("at the current tempo, without swing and offsets",
                                      "beim aktuellen Tempo, ohne Swing und Versatz") }
    func seconds(_ s: Double) -> String {
        s < 1 ? String(format: "%.1f ms", s * 1000).replacingOccurrences(of: ".", with: de ? "," : ".")
              : String(format: "%.3f s", s).replacingOccurrences(of: ".", with: de ? "," : ".")
    }
    func stepsCount(_ n: Int) -> String { n == 1 ? e("1 step", "1 Step") : e("\(n) steps", "\(n) Steps") }
    /// „1 T 2 Sl. 1/16" bzw. „1 bar 2 beats 1/16"; gebrochen „10/3 /16".
    func span(_ s: (num: Int, den: Int), meter m: TimeSignature) -> String {
        guard let p = TimingInfo.split(sixteenths: s, meter: m) else { return "\(s.num)/\(s.den * 16)" }
        var parts: [String] = []
        if p.bars > 0 { parts.append(barsShort(p.bars)) }
        if p.beats > 0 { parts.append(de ? "\(p.beats) Sl." : (p.beats == 1 ? "1 beat" : "\(p.beats) beats")) }
        if p.sixteenths > 0 { parts.append("\(p.sixteenths)/16") }
        return parts.isEmpty ? "0" : parts.joined(separator: " ")
    }
    // Taktart (v1.18.12)
    var timeSignatureHelp:   String { e("Time signature of this pattern — bars of the song, audio loops, pad lengths, the grid and the plug-in transport follow it",
                                        "Taktart dieses Patterns — Takte im Song, Audio-Loops, Pad-Längen, Raster und der Takt für Plug-ins folgen ihr") }
    var timeSignatureLocked: String { e("Stop playback to change the time signature",
                                        "Zum Ändern der Taktart die Wiedergabe anhalten") }
    /// Länge einer Lane als Text: „Gruppe 3+4", ganze Takte „2 T", sonst Notenwert „1/16"
    /// (v1.18.31).
    func laneLength(_ lane: LaneData, meter: TimeSignature) -> String {
        if lane.stepGroup { return stepGroupLabel + " " + TimeSignature.groupingText(lane.effectiveGroups(meter)) }
        return noteValue(num: lane.stepLengthNumerator, den: lane.stepLengthDenominator, meter: meter)
    }
    /// Länge (in Sechzehnteln) als Notenwert: ganze Takte „2 T", sonst Bruch der ganzen Note.
    func noteValue(num: Int, den: Int, meter: TimeSignature) -> String {
        if den == 1, num % meter.sixteenthsPerBar == 0, num >= meter.sixteenthsPerBar {
            return barsShort(num / meter.sixteenthsPerBar)
        }
        let f = TrackData.wholeFraction(num: num, den: den)
        return "\(f.p)/\(f.q)"
    }
    /// Hilfetext eines Notenwerts: Name und wie viele Steps eine Viertel/Halbe/Ganze füllen.
    func noteValueHelp(p: Int, q: Int) -> String {
        let names: [String: (String, String)] = [
            "1/32": ("thirty-second", "Zweiunddreißigstel"), "1/16": ("sixteenth", "Sechzehntel"),
            "1/8": ("eighth", "Achtel"), "1/4": ("quarter", "Viertel"), "1/2": ("half note", "Halbe"),
            "1/1": ("whole note", "Ganze"), "3/32": ("dotted 32nd", "punktierte Zweiunddreißigstel"),
            "3/16": ("dotted sixteenth", "punktierte Sechzehntel"), "3/8": ("dotted eighth", "punktierte Achtel"),
            "3/4": ("dotted quarter", "punktierte Viertel"), "1/24": ("sixteenth triplet", "Sechzehnteltriole"),
            "1/12": ("eighth triplet", "Achteltriole"), "1/6": ("quarter triplet", "Vierteltriole"),
            "1/3": ("half-note triplet", "Halbetriole"), "1/20": ("sixteenth quintuplet", "Sechzehntelquintole"),
            "1/10": ("eighth quintuplet", "Achtelquintole"), "1/5": ("quarter quintuplet", "Viertelquintole"),
            "1/28": ("sixteenth septuplet", "Sechzehntelseptole"), "1/14": ("eighth septuplet", "Achtelseptole"),
            "1/7": ("quarter septuplet", "Viertelseptole"),
        ]
        let name = names["\(p)/\(q)"].map { e($0.0, $0.1) } ?? "\(p)/\(q)"
        // Wie viele Steps füllen eine Viertel, Halbe oder Ganze genau?
        for (x, en, deName) in [(4, "a quarter", "eine Viertel"), (2, "a half note", "eine Halbe"), (1, "a whole note", "eine Ganze")]
        where q % (x * p) == 0 {
            let n = q / (x * p)
            return e("\(p)/\(q) = \(name): \(n) steps fill \(en)", "\(p)/\(q) = \(name): \(n) Steps füllen \(deName)")
        }
        return "\(p)/\(q) = \(name)"
    }
    func noteRowLabel(_ r: TrackData.NoteRow) -> String {
        switch r {
        case .straight:   return e("STRAIGHT", "GERADE")
        case .dotted:     return e("DOTTED", "PUNKTIERT")
        case .triplet:    return e("TRIPLET", "TRIOLE")
        case .quintuplet: return e("QUINTUPLET", "QUINTOLE")
        case .septuplet:  return e("SEPTUPLET", "SEPTOLE")
        }
    }
    var barsRowLabel:        String { e("BARS", "TAKTE") }
    var groupRowLabel:       String { e("GROUP", "GRUPPE") }
    var customFractionLabel: String { e("OWN VALUE", "EIGENER BRUCH") }
    var customFractionHelp:  String { e("Any note value as a fraction of a whole note, e.g. 5/16 or 1/9 (Return).",
                                        "Jeder Notenwert als Bruch der ganzen Note, z. B. 5/16 oder 1/9 (Return).") }
    var customFractionInvalid: String { e("Not valid (from 1/96 up to 8 bars).", "Ungültig (von 1/96 bis 8 Takte).") }
    var groupsFieldHelp:     String { e("Groups of this track in eighths, separated by + (e.g. 3+4, 3+3+2), Return.",
                                        "Gruppen dieser Spur in Achteln, mit + getrennt (z. B. 3+4, 3+3+2), Return.") }
    var groupsInvalid:       String { e("Not valid: 1–8 groups of 1–64 eighths.", "Ungültig: 1–8 Gruppen zu 1–64 Achteln.") }
    func groupsFit(_ g: [Int], meter: TimeSignature) -> String {
        let sum16 = g.reduce(0, +) * 2, bar = meter.sixteenthsPerBar
        if sum16 % bar == 0 {
            let n = sum16 / bar
            return e(n == 1 ? "fits one bar" : "fits \(n) bars", n == 1 ? "passt in einen Takt" : "passt in \(n) Takte")
        }
        return e("runs against the bar (\(g.reduce(0, +))/8 against \(meter.label))",
                 "läuft gegen den Takt (\(g.reduce(0, +))/8 gegen \(meter.label))")
    }
    var groupingHeader:      String { e("GROUPING", "GRUPPIERUNG") }
    var groupingNone:        String { e("None (even)", "Keine (gleichmäßig)") }
    var groupingCustom:      String { e("Custom…", "Eigene …") }
    func groupingHint(_ n: Int) -> String {
        e("Groups in beats, separated by +; they must add up to \(n) (e.g. 5+2).",
          "Gruppen in Schlägen, mit + getrennt; Summe muss \(n) ergeben (z. B. 5+2).")
    }
    func groupingInvalid(_ n: Int) -> String {
        e("Not valid: 2–8 groups that add up to \(n).", "Ungültig: 2–8 Gruppen mit der Summe \(n).")
    }
    var stepGroupLabel:      String { e("Group", "Gruppe") }
    var stepGroupHelp:       String { e("Each step lasts one group of the time signature's grouping, in turn (3+4: 3/8, 4/8, 3/8 …). Without grouping: one bar.",
                                        "Jeder Step dauert reihum eine Gruppe der Gruppierung der Taktart (3+4: 3/8, 4/8, 3/8 …). Ohne Gruppierung: ein Takt.") }
    func timeSignaturePending(_ now: TimeSignature, _ next: TimeSignature) -> String {
        e("Playing in \(now.label) · \(next.label) applies when this pattern starts again (after a change or stop)",
          "Läuft in \(now.label) · \(next.label) gilt beim nächsten Start dieses Patterns (nach Wechsel oder Stop)")
    }
    var patternSwitchMenu:   String { e("Pattern change without song", "Patternwechsel ohne Song") }
    var patternSwitchOnBar:  String { e("At the next bar line", "Am nächsten Taktstrich") }
    var patternSwitchTrack1: String { e("At the end of track 1", "Am Ende von Spur 1") }
    var patternSwitchHelp:   String { e("Click: when a chosen pattern takes over without song mode",
                                        "Klick: wann ein gewähltes Pattern ohne Song-Modus übernimmt") }
    var undoTimeSignature:   String { e("Time Signature", "Taktart") }
    var songEmptyHint:       String { e("No scenes yet — + adds one. A scene plays a pattern for a number of bars.",
                                        "Noch keine Szenen — + fügt eine hinzu. Eine Szene spielt ein Pattern für eine Anzahl Takte.") }
    var songEnableTip:       String { e("Song mode: Play runs the scenes in order; patterns change exactly on the bar line",
                                        "Song-Modus: Play spielt die Szenen der Reihe nach; Patterns wechseln genau auf dem Taktstrich") }
    var songDisableTip:      String { e("Song mode is on — click to play single patterns again",
                                        "Song-Modus ist an — klicken, um wieder einzelne Patterns zu spielen") }
    var songLoopTip:         String { e("At the end the song starts again — click: stop at the end",
                                        "Am Ende beginnt der Song von vorn — klicken: am Ende anhalten") }
    var songEndTip:          String { e("At the end the song stops — click: loop",
                                        "Am Ende hält der Song an — klicken: Schleife") }
    var songAddTip:          String { e("Add scene", "Szene hinzufügen") }
    var songSceneTip:        String { e("Click: choose pattern and length · right-click: menu",
                                        "Klick: Pattern und Länge wählen · Rechtsklick: Menü") }
    var songDeleteScene:     String { e("Delete Scene", "Szene löschen") }
    var songDuplicateScene:  String { e("Duplicate Scene", "Szene duplizieren") }
    var songMoveLeft:        String { e("Move Left", "Nach links") }
    var songMoveRight:       String { e("Move Right", "Nach rechts") }
    var undoSong:            String { e("Edit Song", "Song bearbeiten") }
    var patternSongLockedTip: String { e("Song is playing — the scenes choose the pattern",
                                         "Song läuft — die Szenen bestimmen das Pattern") }
    func patternSwitchTipNoKey(_ letter: String) -> String {
        e("Switch to Pattern \(letter) · switches at end of Track 1",
          "Pattern \(letter) wechseln · Wechsel erfolgt am Ende von Track 1")
    }
    var padWidthHelp:        String { e("Display width of this track's long steps, in normal step widths (Auto: by length). Only changes the view, not the sound.",
                                        "Anzeigebreite der langen Steps dieser Spur in normalen Stepbreiten (Auto: nach Länge). Ändert nur die Ansicht, nicht den Klang.") }
    var fixedNoteLabel:      String { e("FIXED", "FEST") }
    var fixedNoteHelp:       String { e("Fixed note or chord for the whole track: every step plays it (e.g. a kick or a held chord). Switching on takes this step's notes; the keyboard then edits it. The steps keep their own notes and get them back when switched off.",
                                        "Fester Ton oder Akkord für die ganze Spur: Jeder Step spielt ihn (z. B. eine Kick oder einen Akkord). Einschalten übernimmt die Töne dieses Steps; die Klaviatur bearbeitet ihn dann. Die Steps behalten ihre eigenen Noten und bekommen sie beim Ausschalten zurück.") }
    var padRandomizeTooltip: String { e("RND: roll this track's long steps — every step sounds, legato (chords, single notes or mixed, as chosen with ▾).",
                                        "RND: die langen Steps dieser Spur würfeln — jeder Step klingt, legato (Akkorde, Einzeltöne oder gemischt, wie mit ▾ gewählt).") }
    var padChordSourceTooltip: String { e("RND settings: single notes, chords or mixed; chord source: progressions from Lizzio (Chord Progression Codex) and Callipari (Illustrierte Harmonie), a specific progression, or chords from the track's scale.",
                                          "RND-Einstellung: Einzeltöne, Akkorde oder gemischt; Akkordquelle: Folgen aus Lizzio (Chord Progression Codex) und Callipari (Illustrierte Harmonie), eine bestimmte Folge oder Akkorde aus der Skala des Tracks.") }
    var padChordsBooksAny:   String { e("Progressions from the books (random)", "Folgen aus den Büchern (zufällig)") }
    var padChordsFree:       String { e("Chords from the track's scale", "Akkorde aus der Skala des Tracks") }
    var padChordsBooksHeader: String { e("Lizzio · Callipari", "Lizzio · Callipari") }
    var rndNotesHeader:      String { e("RND rolls", "RND würfelt") }
    var rndNotesSingle:      String { e("Single notes", "Einzeltöne") }
    var rndNotesChords:      String { e("Chords", "Akkorde") }
    var rndNotesMixed:       String { e("Mixed (single notes and chords)", "Gemischt (Einzeltöne und Akkorde)") }
    var rndChordSourceHeader: String { e("Chord source", "Akkordquelle") }
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
    // Apple-Sampler (v1.18.16)
    var samplerLoad:         String { e("Apple Sampler: load instrument…", "Apple Sampler: Instrument laden …") }
    var samplerChoose:       String { e("Choose a sampler instrument (EXS, SoundFont, DLS, aupreset)",
                                        "Sampler-Instrument wählen (EXS, SoundFont, DLS, aupreset)") }
    var samplerGrantFolders: String { e("Share sample folder…", "Sample-Ordner freigeben …") }
    var samplerGrantMessage: String { e("Choose the folder that contains the instrument and its samples (for example Music). FIRSTofFIFTH only reads from shared folders.",
                                        "Ordner wählen, der Instrument und Samples enthält (z. B. Musik). FIRSTofFIFTH liest nur aus freigegebenen Ordnern.") }
    var samplerGrant:        String { e("Share", "Freigeben") }
    var samplerErrorTitle:   String { e("Sampler instrument not loaded", "Sampler-Instrument nicht geladen") }
    func samplerMissing(found: Int, missing: Int) -> String {
        missing == 0 && found == 0
            ? e("The samples could not be read. Share the folder that contains them.",
                "Die Samples sind nicht lesbar. Bitte den Ordner freigeben, in dem sie liegen.")
            : e("\(missing) of \(found + missing) samples could not be read. Share the folder that contains them.",
                "\(missing) von \(found + missing) Samples sind nicht lesbar. Bitte den Ordner freigeben, in dem sie liegen.")
    }
    var samplerUnsupported:  String { e("This file type cannot be loaded by the Apple Sampler.", "Diesen Dateityp lädt der Apple Sampler nicht.") }
    func samplerFailed(_ status: Int32) -> String { e("The Apple Sampler reported error \(status).", "Der Apple Sampler meldet Fehler \(status).") }
    var samplerCancel:       String { e("Cancel", "Abbrechen") }
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
    var ccTargetChooseHelp:  String { e("Target: MIDI CC — click to choose a parameter of the instrument or an effect", "Ziel: MIDI-CC — klicken, um einen Parameter des Instruments oder eines Effekts zu wählen") }
    var ccTargetPlugin:      String { e("Plug-in", "Plug-in") }
    var ccTargetSearch:      String { e("Search parameters", "Parameter suchen") }
    var ccTargetNoMatch:     String { e("No matching parameter", "Kein passender Parameter") }
    var ccTargetNotLoaded:   String { e("not loaded", "nicht geladen") }
    var ccTargetNoPlugins:   String { e("No instrument or effect on this channel", "Kein Instrument und kein Effekt in diesem Kanal") }
    func ccTargetInstrument(_ n: String) -> String { e("Instrument: \(n)", "Instrument: \(n)") }
    func ccTargetEffect(_ i: Int, _ n: String) -> String { e("Effect \(i): \(n)", "Effekt \(i): \(n)") }
    func ccTargetCount(_ shown: Int, _ all: Int) -> String {
        shown == all ? e("\(all) parameters", "\(all) Parameter") : e("\(shown) of \(all) parameters", "\(shown) von \(all) Parametern")
    }
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
    var ratioHeader:         String { e("STEP LENGTH", "STEP-LÄNGE") }
    var ratioQuickSelect:    String { e("QUICK SELECT",         "SCHNELLWAHL") }
    var ratioReset:          String { e("RESET 1/16",           "ZURÜCK 1/16") }

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
    var settingsPatternCCHint: String { e("Steps of 8: 0–7=A  8–15=B  16–23=C … 120–127=P",
                                          "Achterschritte: 0–7=A  8–15=B  16–23=C … 120–127=P") }
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
    var trackColorWheel:     String { e("Color Wheel…", "Farbrad …") }

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
    var errLoopEncode:       String { e("Audio loop material could not be encoded — the project was not saved.",
                                        "Audio-Loop-Material konnte nicht kodiert werden — das Projekt wurde nicht gespeichert.") }
    func errLoopRestore(_ n: Int) -> String { e("\(n) audio loop(s) could not be restored (damaged, too large or over the memory budget). The original data is kept and saved again unchanged.",
                                                "\(n) Audio-Loop(s) konnten nicht wiederhergestellt werden (beschädigt, zu groß oder über dem Speicherbudget). Die Originaldaten bleiben erhalten und werden unverändert mitgespeichert.") }
    var errMIDIOutputGone:   String { e("MIDI output device disconnected.", "MIDI-Ausgabegerät wurde getrennt.") }
}
