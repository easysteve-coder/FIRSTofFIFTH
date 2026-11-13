#if DEBUG
import Foundation
import Combine

// MARK: - BodyRunCounter

/// Aggregierter SwiftUI-body-Zähler für Performance-Diagnose.
///
/// Zählt, wie oft die body-Property jedes View-Typs pro Sekunde aufgerufen wird.
/// Gibt einmal pro Sekunde einen kompakten Report in der Console aus.
///
/// **Aktivierung:** `BodyRunCounter.shared.isEnabled = true`
/// (im Xcode-Debugger: `expr BodyRunCounter.shared.isEnabled = true`)
///
/// **Deaktivierung:** `BodyRunCounter.shared.isEnabled = false`
///
/// **Erwartete Werte bei 120 BPM, 8 Tracks, 32 Steps:**
///   - Idle:                     alle Werte nahe 0
///   - Normales Playback:        StepGrid ≈ 512/s   StepButton ≈ 128/s
///   - Playback + Scroll:        StepGrid ≈ 1000+/s StepButton ≈ 128/s
///   - Playback + BPM-Änderung:  TrackRow, TrackHeader, CCKnob springen kurz auf
///
/// Abweichungen von diesen Erwartungen zeigen, wo unerwartete Invalidierungen entstehen.
final class BodyRunCounter {

    static let shared = BodyRunCounter()
    private init() {
        startReportTimer()
        print("🧪 BodyRunCounter ENABLED — 📊 body/s erscheint 1×/s im Debug-Output")
    }

    /// In DEBUG automatisch aktiv. Auf `false` setzen um die Ausgabe zu unterdrücken.
    var isEnabled: Bool = true

    // MARK: - Counting

    /// Zählt einen body-Run für den angegebenen View-Namen.
    /// Sicher auf dem Main-Thread — SwiftUI ruft body immer auf dem Main-Thread auf.
    func count(_ viewName: String) {
        totals[viewName, default: 0] += 1
        guard isEnabled else { return }
        counts[viewName, default: 0] += 1
    }

    /// Kumulierte body-Runs seit Prozessstart (unabhängig von `isEnabled`) — Messfenster
    /// für Tests: Differenz vor/nach einer Aktion.
    private var totals: [String: Int] = [:]
    func total(_ viewName: String) -> Int { totals[viewName, default: 0] }

    // MARK: - Internals

    private var counts: [String: Int] = [:]

    private func startReportTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            let snapshot = self.counts
            self.counts = [:]
            guard !snapshot.isEmpty else {
                print("📊 body/s  (alle 0)")
                return
            }
            // Sortiert nach Häufigkeit absteigend — Hauptverdächtige zuerst.
            let sorted = snapshot.sorted { $0.value > $1.value }
            let report = sorted.map { "\($0.key):\($0.value)" }.joined(separator: "  ")
            print("📊 body/s  \(report)")
        }
    }
}

// MARK: - EngineChangeTracker

/// Protokolliert, welche @Published-Properties von SequencerEngine feuern.
///
/// Aktivierung: `EngineChangeTracker.shared.start(engine: engine)`
/// — einmalig aus `VintageSequencerApp.onAppear` aufrufen.
///
/// Gibt einmal pro Sekunde aus, welche Eigenschaften sich geändert haben
/// und wie oft. Zeigt, was während Playback, Scroll, Zoom, BPM-Änderung auslöst.
final class EngineChangeTracker {

    static let shared = EngineChangeTracker()
    private init() {}

    /// In DEBUG automatisch aktiv, sobald `start(engine:)` aufgerufen wurde.
    /// Auf `false` setzen um die Ausgabe zu unterdrücken.
    var isEnabled: Bool = true

    private var cancellables = Set<AnyCancellable>()
    private var counts: [String: Int] = [:]
    private var timerStarted = false

    func start(engine: SequencerEngine) {
        guard !timerStarted else { return }
        timerStarted = true
        print("🧪 EngineChangeTracker ENABLED — 🔔 published/s erscheint 1×/s im Debug-Output")

        // Einzelne @Published-Properties tracken.
        // Arch-Slice-19: Transport-Properties liegen jetzt in engine.transportState.
        // Jede Subscription feuert BEVOR der neue Wert gesetzt wird (willSet-Semantik von Combine).
        engine.transportState.$isPlaying
            .dropFirst()
            .sink { [weak self] _ in self?.record("ts.isPlaying") }
            .store(in: &cancellables)

        engine.transportState.$bpm
            .dropFirst()
            .sink { [weak self] _ in self?.record("ts.bpm") }
            .store(in: &cancellables)

        engine.transportState.$clockMode
            .dropFirst()
            .sink { [weak self] _ in self?.record("ts.clockMode") }
            .store(in: &cancellables)

        engine.transportState.$currentPatternIndex
            .dropFirst()
            .sink { [weak self] _ in self?.record("ts.patternIndex") }
            .store(in: &cancellables)

        engine.transportState.$queuedPatternIndex
            .dropFirst()
            .sink { [weak self] _ in self?.record("ts.queuedPattern") }
            .store(in: &cancellables)

        engine.midiLearnState.$learnMode
            .dropFirst()
            .sink { [weak self] _ in self?.record("mls.learnMode") }
            .store(in: &cancellables)

        engine.clockDiagnostics.$avgUs
            .dropFirst()
            .sink { [weak self] _ in self?.record("clockDiag.avgUs") }
            .store(in: &cancellables)

        engine.presetEditorState.$hasUnsavedChanges
            .dropFirst()
            .sink { [weak self] _ in self?.record("pes.unsaved") }
            .store(in: &cancellables)

        // Alle engine.objectWillChange-Fires zusammen zählen — zeigt die Gesamtrate.
        engine.objectWillChange
            .sink { [weak self] in self?.record("engine.OWC(total)") }
            .store(in: &cancellables)

        // midi.objectWillChange direkt tracken — engine leitet midi.OWC via Combine
        // weiter als engine.OWC. Mit diesem Kanal sehen wir, wie viele engine.OWC
        // von MIDIManager kommen (vs. von engine-eigenen @Published-Properties).
        // Arch-Slice-14: Identifiziert Quelle der Mystery-Spikes (92 TrackRow/s).
        engine.midi.objectWillChange
            .sink { [weak self] in self?.record("midi.OWC") }
            .store(in: &cancellables)

        // midi.@Published-Properties einzeln tracken —
        // zeigt ob outputs/inputs-Scans oder selectedOutput-Änderungen die Ursache sind.
        engine.midi.$outputs
            .dropFirst()
            .sink { [weak self] _ in self?.record("midi.outputs") }
            .store(in: &cancellables)

        engine.midi.$inputs
            .dropFirst()
            .sink { [weak self] _ in self?.record("midi.inputs") }
            .store(in: &cancellables)

        engine.midi.$selectedOutput
            .dropFirst()
            .sink { [weak self] _ in self?.record("midi.selectedOutput") }
            .store(in: &cancellables)

        engine.midi.$selectedInput
            .dropFirst()
            .sink { [weak self] _ in self?.record("midi.selectedInput") }
            .store(in: &cancellables)

        startReportTimer()
    }

    private func record(_ name: String) {
        guard isEnabled else { return }
        counts[name, default: 0] += 1
    }

    private func startReportTimer() {
        Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self, self.isEnabled else { return }
            let snapshot = self.counts
            self.counts = [:]
            guard !snapshot.isEmpty else { return }
            let sorted = snapshot.sorted { $0.value > $1.value }
            let report = sorted.map { "\($0.key):\($0.value)" }.joined(separator: "  ")
            print("🔔 published/s  \(report)")
        }
    }
}
#endif
