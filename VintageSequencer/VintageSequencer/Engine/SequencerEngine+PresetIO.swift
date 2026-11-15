import Foundation
import Combine
import AppKit
import UniformTypeIdentifiers

// MARK: - Preset I/O

extension SequencerEngine {

    // MARK: - Error Feedback

    /// Sets lastErrorMessage and shows a modal NSAlert (B3).
    /// Only for Preset I/O — always runs on the Main Thread.
    /// Strings in der aktuell gewählten Sprache (Nicht-View-Code).
    var strings: Str { Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en") }

    func showError(_ message: String) {
        lastErrorMessage = message
        let alert = NSAlert()
        alert.alertStyle      = .warning
        alert.messageText     = strings.errorTitle
        alert.informativeText = message
        alert.addButton(withTitle: strings.ok)
        alert.runModal()
    }

    // MARK: - Recent Files

    func loadRecentFiles() {
        recentFiles = presetManager.loadBookmarks()
    }

    private func addToRecent(_ url: URL) {
        presetManager.addToBookmarks(url)
        recentFiles = presetManager.loadBookmarks()   // rebuild UI list
    }

    func clearRecentFiles() {
        presetManager.clearBookmarks()
        recentFiles = []
    }

    /// Loads a preset directly from a URL (used by "Open Recent").
    func loadPreset(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let data = try Data(contentsOf: url)
            if loadData(data) {
                currentPresetURL = url
                addToRecent(url)
                if let w = loadWarning { showError(w) }
            } else if let msg = lastErrorMessage {
                showError(msg)
            }
        } catch {
            showError(strings.errPresetOpen(error.localizedDescription))
        }
    }

    // MARK: - Preset Data

    /// Synchrone Variante (Tests, Messungen): kodiert fehlendes Material auf dem Aufrufer.
    /// Die Bedienung speichert über `saveDataAsync`.
    func saveData() -> Data? {
        // Klangzustand der geladenen Plug-ins zurücklesen, bevor das Rack gespeichert wird.
        rack.captureStates()
        guard let loops = rack.loopFiles() else {
            lastErrorMessage = strings.errLoopEncode
            return nil
        }
        guard let data = presetManager.encode(bpm: bpm, swing: swing, patterns: patterns,
                                              instruments: rack.channels,
                                              masterVolume: rack.masterVolume,
                                              song: song,
                                              audioLoops: loops, timeSignature: timeSignature,
                                              switchOnBar: switchOnBar) else {
            lastErrorMessage = strings.errPresetEncode
            return nil
        }
        return data
    }

    /// Speichern ohne Kodieren auf Main (v1.16.1, Codex V16-2). Main hält Modell, Rack und
    /// Loop-Speicher (je Version unveränderlich) im Moment des Aufrufs fest; fehlt für einen
    /// Loop der vorkodierte Stand, wird er im Hintergrund kodiert und dort mit dem schon
    /// kodierten Rest zusammengesetzt. `done` läuft auf Main; nil = Fehler
    /// (`lastErrorMessage` gesetzt). Ohne fehlende Kodierung bleibt alles synchron.
    func saveDataAsync(_ done: @escaping (Data?) -> Void) {
        rack.captureStates()
        let jobs = rack.loopSaveJobs()
        var ready: [AudioLoopFile] = []
        var pending: [(index: Int, id: UUID, storage: AudioLoopStorage, version: Int)] = []
        var order: [UUID] = []
        for (id, job) in jobs {
            switch job {
            case .file(let f): ready.append(f); order.append(id)
            case .encode(let st, let v): pending.append((order.count, id, st, v)); order.append(id)
            case .none: continue
            }
        }
        guard !pending.isEmpty else {
            let data = presetManager.encode(bpm: bpm, swing: swing, patterns: patterns,
                                            instruments: rack.channels, masterVolume: rack.masterVolume,
                                            song: song, audioLoops: ready, timeSignature: timeSignature,
                                            switchOnBar: switchOnBar)
            if data == nil { lastErrorMessage = strings.errPresetEncode }
            done(data); return
        }
        // Modellstand jetzt (Main) — ohne Loops; die kommen im Hintergrund dazu.
        guard let base = presetManager.encode(bpm: bpm, swing: swing, patterns: patterns,
                                              instruments: rack.channels, masterVolume: rack.masterVolume,
                                              song: song, audioLoops: [], timeSignature: timeSignature,
                                              switchOnBar: switchOnBar) else {
            lastErrorMessage = strings.errPresetEncode
            done(nil); return
        }
        let readyByID = Dictionary(ready.map { ($0.channel, $0) }, uniquingKeysWith: { a, _ in a })
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            var encodedNow: [(UUID, AudioLoopStorage, Int, AudioLoopFile)] = []
            var failed = false
            for p in pending {
                guard let f = AudioLoopAssets.encodeForSave(p.storage, channel: p.id) else { failed = true; break }
                encodedNow.append((p.id, p.storage, p.version, f))
            }
            let byID = readyByID.merging(encodedNow.map { ($0.0, $0.3) }, uniquingKeysWith: { a, _ in a })
            let files = order.compactMap { byID[$0] }
            let data = failed ? nil : PresetManager.merge(base, audioLoops: files)
            DispatchQueue.main.async {
                guard let self else { return }
                for e in encodedNow { self.rack.adoptEncodedLoop(e.3, storage: e.1, version: e.2, for: e.0) }
                if data == nil { self.lastErrorMessage = failed ? self.strings.errLoopEncode : self.strings.errPresetEncode }
                done(data)
            }
        }
    }

    /// Loads a preset from raw JSON data.
    /// Returns true on success, false on decode failure (lastErrorMessage set).
    /// Invalid field values are clamped (B4) — no crash on manipulated presets.
    @discardableResult
    func loadData(_ data: Data) -> Bool {
        let loaded: [Pattern]
        var fileTempo: (bpm: Double, swing: Double)?
        var fileInstruments: [InstrumentChannelData] = []
        var fileMaster: Float = 1
        var fileSong = Song()
        var fileLoops: [AudioLoopFile] = []
        var fileMeter = TimeSignature.common
        var fileSwitchOnBar = false              // ältere Dateien: Ende Spur 1 (E3)
        switch presetManager.decode(data) {
        case .success(.modern(let file)):
            loaded    = file.patterns
            fileTempo = (file.bpm, file.swing)
            fileInstruments = file.instruments ?? []
            fileMaster = file.masterVolume ?? 1
            fileSong = file.song ?? Song()
            fileLoops = file.audioLoops ?? []
            fileMeter = (file.timeSignature ?? .common).clamped
            fileSwitchOnBar = file.patternSwitch == "bar"
        case .success(.legacy(let legacy)):
            // Legacy format: bpm and swing are not serialized — preserve current values.
            loaded = legacy
        case .failure(let error):
            lastErrorMessage = strings.errPresetLoad(PresetManager.describe(error))
            return false
        }
        // Die App arbeitet mit 16 Pattern-Slots (A–P; bis v1.13.19 A–D). Eine Datei ohne Pattern
        // ist kein gültiges Preset; fehlende Slots werden mit leeren Patterns aufgefüllt,
        // damit kein Pattern-Index ins Leere zeigt.
        guard !loaded.isEmpty else {
            lastErrorMessage = strings.errPresetLoad(strings.errPresetNoPatterns)
            return false
        }
        var slots = loaded
        let slotNames = Pattern.slotNames
        if slots.count > slotNames.count { slots.removeLast(slots.count - slotNames.count) }
        while slots.count < slotNames.count { slots.append(Pattern(name: slotNames[slots.count])) }
        // Zeilen (v1.18.6): ältere Dateien und aufgefüllte Plätze bekommen sie nach Zeilennummer.
        Pattern.assignMissingRows(slots)

        stop()
        cancelInteractionSession()
        // Undo-Einträge und Learn-Ziel gehören zum abgelösten Projekt.
        undoManager?.removeAllActions()
        learnTarget = nil
        if !slots.indices.contains(currentPatternIndex) { currentPatternIndex = 0 }
        if let t = fileTempo {
            bpm   = t.bpm
            swing = t.swing
        }
        // Taktart je Pattern (v1.18.24, E1): ohne eigenen Schlüssel einmalig die der Datei.
        for p in slots where !p.timeSignatureFromFile { p.timeSignature = fileMeter }
        patterns = slots
        pendingMetersReset()
        replaceSwitchOnBar(fileSwitchOnBar)
        replaceSong(fileSong)
        // Das Rack gehört zum Projekt: Kanäle ersetzen, Plug-ins laden (asynchron).
        rack.replaceAll(fileInstruments, masterVolume: fileMaster)
        bindLegacyEffectTargets()
        let lostLoops = rack.restoreLoops(fileLoops)
        loadWarning = lostLoops > 0 ? strings.errLoopRestore(lostLoops) : nil
        // B4: Clamp all decoded values to valid ranges before applying to live state.
        for pattern in patterns {
            for track in pattern.tracks { track.clampToValidRanges() }
        }
        // $patterns fired when patterns was replaced above →
        // rebuildAllTrackSubs was called automatically. clampToValidRanges() writes
        // run on the Main Thread and set hasUnsavedChanges = true synchronously via
        // the track sink; the assignment below overrides that correctly.
        hasUnsavedChanges = false
        // Slice G: alle ViewModels verwerfen — die geladenen Tracks sind neue Instanzen
        // (auch bei gleicher UUID, z. B. beim erneuten Öffnen derselben Datei).
        resetVMCache()
        armExternalStart()   // EXT: nächste Sitzung mit dem geladenen Song vorbereiten
        return true
    }

    /// Speichern unter (⌘⇧S). `done(true)` nur, wenn die Datei tatsächlich geschrieben wurde
    /// (false bei Abbruch des Dialogs, Encode- oder Schreibfehler). Läuft asynchron
    /// (v1.16.1): der Dialog zuerst, dann Kodieren ohne Main-Blockade, dann Schreiben.
    func savePreset(_ done: ((Bool) -> Void)? = nil) {
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        guard let url = presetManager.chooseSaveURL(
            title: s.saveDialogTitle,
            suggestedName: currentPresetURL?.lastPathComponent ?? s.defaultPreset
        ) else { done?(false); return }   // user cancelled
        write(to: url, scoped: false) { [weak self] ok in
            if ok, let self {
                self.currentPresetURL = url
                self.addToRecent(url)
            }
            done?(ok)
        }
    }

    /// Speichern (⌘S) an die aktuelle Datei, ohne Dialog; ohne Datei wie `savePreset`.
    func savePresetInPlace(_ done: ((Bool) -> Void)? = nil) {
        guard let url = currentPresetURL else { savePreset(done); return }
        write(to: url, scoped: true, done)
    }

    /// Ein Speichervorgang zur Zeit; ein weiterer Aufruf währenddessen meldet false.
    private func write(to url: URL, scoped: Bool, _ done: ((Bool) -> Void)?) {
        guard !saveInFlight else { done?(false); return }
        saveInFlight = true
        let epoch = presetEditorState.changeEpoch
        saveDataAsync { [weak self] data in
            guard let self else { return }
            self.saveInFlight = false
            guard let data else {
                if let m = self.lastErrorMessage { self.showError(m) }
                done?(false); return
            }
            let accessing = scoped && url.startAccessingSecurityScopedResource()
            defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            do {
                // Atomar: ein Abbruch mitten im Schreiben lässt die bisherige Datei intakt.
                try data.write(to: url, options: .atomic)
                // Änderungen während des Kodierens bleiben ungespeichert markiert.
                if self.presetEditorState.changeEpoch == epoch { self.hasUnsavedChanges = false }
                done?(true)
            } catch {
                self.showError(self.strings.errPresetSave(error.localizedDescription))
                done?(false)
            }
        }
    }

    /// Ungespeicherte Änderungen: fragen, ggf. speichern, dann `proceed` (Main).
    private func confirmDiscardOrSave(message: String, then proceed: @escaping () -> Void) {
        guard hasUnsavedChanges else { proceed(); return }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        let alert = NSAlert()
        alert.messageText     = s.unsavedTitle
        alert.informativeText = message
        alert.addButton(withTitle: s.save)
        alert.addButton(withTitle: s.discard)
        alert.addButton(withTitle: s.cancel)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            // Nicht gespeichert (Abbruch/Fehler) → Projekt behalten.
            savePresetInPlace { ok in if ok { proceed() } }
        case .alertSecondButtonReturn: proceed()   // discard
        default: return                            // cancel
        }
    }

    func loadPreset() {
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        confirmDiscardOrSave(message: s.unsavedMessage) { [weak self] in
            guard let self else { return }
            do {
                guard let result = try self.presetManager.runOpenPanel(title: s.loadDialogTitle)
                else { return }   // user cancelled
                if self.loadData(result.data) {
                    self.currentPresetURL = result.url
                    self.addToRecent(result.url)
                    if let w = self.loadWarning { self.showError(w) }
                } else if let msg = self.lastErrorMessage {
                    self.showError(msg)
                }
            } catch {
                self.showError(self.strings.errPresetOpen(error.localizedDescription))
            }
        }
    }

    /// Reset to a default empty project.
    ///
    /// Prompts to save if there are unsaved changes (same flow as loadPreset).
    /// Stops playback, resets patterns to the default slots, clears currentPresetURL.
    func newProject() {
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        confirmDiscardOrSave(message: s.newProjectUnsavedMessage) { [weak self] in
            self?.resetToNewProject()
        }
    }

    private func resetToNewProject() {
        stop()
        cancelInteractionSession()
        undoManager?.removeAllActions()
        learnTarget = nil
        bpm      = 120.0
        swing    = 50.0
        patterns = Pattern.defaultSlots()
        replaceTimeSignature(.common)
        replaceSwitchOnBar(true)                 // neue Projekte: nächster Taktstrich (E3)
        replaceSong(Song())
        rack.replaceAll([])
        currentPatternIndex = 0
        currentPresetURL    = nil
        hasUnsavedChanges   = false
        // $patterns fired when patterns was replaced above →
        // rebuildAllTrackSubs called automatically.
        // Slice G: release stale TrackViewModels from previous session.
        resetVMCache()
        armExternalStart()
    }
}

// MARK: - Clipboard

extension SequencerEngine {

    func copySteps(from td: TrackData, at indices: [Int]) {
        stepClipboard = indices.sorted().map { td.lane.steps[$0] }
    }

    func pasteSteps(to td: TrackData, at indices: [Int]) {
        guard !stepClipboard.isEmpty else { return }
        let old = td.lane.steps
        var steps = old
        for (offset, idx) in indices.sorted().enumerated() where steps.indices.contains(idx) {
            steps[idx] = stepClipboard[offset % stepClipboard.count]
        }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        ModelWriter().apply(.setSteps(trackID: td.id, oldSteps: old, newSteps: steps,
                                      actionName: s.undoPasteSteps),
                            to: td, undoManager: undoManager)
    }

    func copyCurrentPattern() {
        guard let data = try? JSONEncoder().encode(currentPattern),
              let copy = try? JSONDecoder().decode(Pattern.self, from: data) else { return }
        clipboard = copy
    }

    func pasteToCurrentPattern() {
        guard let src = clipboard,
              let data = try? JSONEncoder().encode(src),
              let copy = try? JSONDecoder().decode(Pattern.self, from: data) else { return }
        copy.name = currentPattern.name   // Namen A/B/C/D behalten
        // Frische Track-/Lane-Identitäten: der JSON-Roundtrip behält die UUIDs der Quelle.
        // Ohne neue IDs teilten sich Quell- und Ziel-Pattern ViewModels und ForEach-IDs.
        copy.tracks = copy.tracks.map { $0.freshCopy() }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        replacePatternUndoable(at: currentPatternIndex, with: copy, actionName: s.pastePattern)
    }
}

// MARK: - Effekt-Ziele (v1.17.8, Codex A17-04)

extension SequencerEngine {
    /// CC-Ziele auf Effekte, die nur eine laufende Nummer tragen (Dateien vor v1.17.8), einmal
    /// an die Instanz binden, die diese Nummer in der geladenen Kette bezeichnet. Läuft direkt
    /// nach dem Ersetzen des Racks — vor jeder Umordnung durch den Benutzer.
    func bindLegacyEffectTargets() {
        for pattern in patterns {
            for td in pattern.tracks where td.lane.kind == .cc {
                guard let ref = td.lane.ccParameter, ref.effectInstance == nil, ref.effect != nil,
                      let channel = td.instrumentID else { continue }
                let bound = rack.bindEffectInstance(ref, in: channel)
                if bound != ref { td.lane.ccParameter = bound }
            }
        }
    }
}
