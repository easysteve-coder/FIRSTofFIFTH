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
            } else if let msg = lastErrorMessage {
                showError(msg)
            }
        } catch {
            showError(strings.errPresetOpen(error.localizedDescription))
        }
    }

    // MARK: - Preset Data

    func saveData() -> Data? {
        // Klangzustand der geladenen Plug-ins zurücklesen, bevor das Rack gespeichert wird.
        rack.captureStates()
        guard let data = presetManager.encode(bpm: bpm, swing: swing, patterns: patterns,
                                              instruments: rack.channels,
                                              masterVolume: rack.masterVolume,
                                              song: song) else {
            lastErrorMessage = strings.errPresetEncode
            return nil
        }
        return data
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
        switch presetManager.decode(data) {
        case .success(.modern(let file)):
            loaded    = file.patterns
            fileTempo = (file.bpm, file.swing)
            fileInstruments = file.instruments ?? []
            fileMaster = file.masterVolume ?? 1
            fileSong = file.song ?? Song()
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
        patterns = slots
        replaceSong(fileSong)
        // Das Rack gehört zum Projekt: Kanäle ersetzen, Plug-ins laden (asynchron).
        rack.replaceAll(fileInstruments, masterVolume: fileMaster)
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
        return true
    }

    /// Rückgabe `true` nur, wenn die Datei tatsächlich geschrieben wurde
    /// (false bei Abbruch des Dialogs, Encode- oder Schreibfehler).
    @discardableResult
    func savePreset() -> Bool {
        guard let data = saveData() else { return false }
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        do {
            guard let url = try presetManager.runSavePanel(
                data: data,
                title: s.saveDialogTitle,
                suggestedName: currentPresetURL?.lastPathComponent ?? s.defaultPreset
            ) else { return false }   // user cancelled
            currentPresetURL  = url
            hasUnsavedChanges = false
            addToRecent(url)
            return true
        } catch {
            showError(strings.errPresetSave(error.localizedDescription))
            return false
        }
    }

    func loadPreset() {
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText     = s.unsavedTitle
            alert.informativeText = s.unsavedMessage
            alert.addButton(withTitle: s.save)
            alert.addButton(withTitle: s.discard)
            alert.addButton(withTitle: s.cancel)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Nicht gespeichert (Abbruch/Fehler) → Projekt behalten, nicht laden.
                guard savePresetInPlace() else { return }
            case .alertSecondButtonReturn: break   // discard
            default: return                        // cancel → abort load
            }
        }
        do {
            guard let result = try presetManager.runOpenPanel(title: s.loadDialogTitle)
            else { return }   // user cancelled
            if loadData(result.data) {
                currentPresetURL = result.url
                addToRecent(result.url)
            } else if let msg = lastErrorMessage {
                showError(msg)
            }
        } catch {
            showError(strings.errPresetOpen(error.localizedDescription))
        }
    }

    /// Reset to a default empty project.
    ///
    /// Prompts to save if there are unsaved changes (same flow as loadPreset).
    /// Stops playback, resets patterns to 4 default tracks, clears currentPresetURL.
    func newProject() {
        let s = Str(UserDefaults.standard.string(forKey: "appLanguage") ?? "en")
        if hasUnsavedChanges {
            let alert = NSAlert()
            alert.messageText     = s.unsavedTitle
            alert.informativeText = s.newProjectUnsavedMessage
            alert.addButton(withTitle: s.save)
            alert.addButton(withTitle: s.discard)
            alert.addButton(withTitle: s.cancel)
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                // Nicht gespeichert (Abbruch/Fehler) → Projekt behalten.
                guard savePresetInPlace() else { return }
            case .alertSecondButtonReturn: break   // discard
            default: return                        // cancel → abort
            }
        }
        stop()
        cancelInteractionSession()
        undoManager?.removeAllActions()
        learnTarget = nil
        bpm      = 120.0
        swing    = 50.0
        patterns = Pattern.slotNames.map { Pattern(name: $0) }
        replaceSong(Song())
        rack.replaceAll([])
        currentPatternIndex = 0
        currentPresetURL    = nil
        hasUnsavedChanges   = false
        // $patterns fired when patterns was replaced above →
        // rebuildAllTrackSubs called automatically.
        // Slice G: release stale TrackViewModels from previous session.
        resetVMCache()
    }

    /// Save the preset to the current URL without showing a dialog.
    ///
    /// Falls back to `savePreset()` (which opens a save dialog) when no URL is set.
    /// This is the "Save" (⌘S) action; `savePreset()` is "Save As…" (⌘⇧S).
    @discardableResult
    func savePresetInPlace() -> Bool {
        guard let url = currentPresetURL else {
            return savePreset()   // no URL yet → show dialog
        }
        guard let data = saveData() else { return false }
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            // Atomar: ein Abbruch mitten im Schreiben lässt die bisherige Datei intakt.
            try data.write(to: url, options: .atomic)
            hasUnsavedChanges = false
            return true
        } catch {
            showError(strings.errPresetSave(error.localizedDescription))
            return false
        }
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
