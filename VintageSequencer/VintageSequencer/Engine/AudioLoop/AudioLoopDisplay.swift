import Foundation
import Combine

// MARK: - AudioLoopDisplay (v1.15.2, Codex M5)
//
// Anzeigezustand genau eines Audio-Loop-Kanals (Main). Die Loop-Zeile beobachtet nur dieses
// Objekt — Fader, Plug-ins oder andere Kanäle invalidieren sie nicht mehr. Das Rack schreibt
// hier hinein: Einstellungen beim Ändern, Kernzustand und Wellenform aus einer einzigen
// Abfrage, die nur läuft, solange ein Loop scharf ist, aufnimmt, mithört oder spielt.
// Veröffentlicht wird nur, was sich geändert hat.

final class AudioLoopDisplay: ObservableObject {

    /// Zustand des Loop-Kerns, wie die Bedienung ihn braucht.
    struct Status: Equatable {
        var state: AudioLoopCore.State = .idle
        var requested = false
        var hasMaterial = false
        var canUndo = false
        var rateMismatch = false
        /// Der Kern gibt gerade Material wieder (Wiedergabeort ≥ 0).
        var playing = false
        /// Eingang wird für diesen Kanal gebraucht (Mithören, scharf, Aufnahme).
        var inputActive = false
        /// Länge des Speichers in Frames (0 = kein Speicher).
        var frames = 0

        var armed: Bool { state == .armed || (state == .idle && requested) }
        var isQuiescent: Bool { state == .idle && !requested }
    }

    let channelID: UUID
    /// Kern des Slots (lebt so lange wie das Rack). Nur für hochfrequente Blattanzeigen
    /// (Wiedergabeort, Eingangspegel), die selbst in eigenem Takt lesen.
    let core: AudioLoopCore

    @Published fileprivate(set) var settings: AudioLoopSettings
    @Published fileprivate(set) var status = Status()
    /// Fehler dieses Kanals (Budget, Länge, Eingang), sonst nil.
    @Published fileprivate(set) var error: String?
    /// Min/Max je Abschnitt; neu gerechnet, wenn sich die Materialversion ändert.
    @Published fileprivate(set) var wave: [WaveBucket] = []

    struct WaveBucket: Equatable { var lo: Float; var hi: Float }

    /// Latenzmessung per Loopback (T4/M1).
    enum Probe: Equatable {
        case idle, running, failed
        case done(roundTripMs: Double, offsetMs: Double, clamped: Bool)
    }
    @Published fileprivate(set) var probe: Probe = .idle

    fileprivate var waveVersion = -1
    fileprivate var waveAt: TimeInterval = 0

    init(channelID: UUID, core: AudioLoopCore, settings: AudioLoopSettings) {
        self.channelID = channelID
        self.core = core
        self.settings = settings
    }
}

// MARK: - Schreibzugang des Racks

extension AudioLoopDisplay {
    func _setSettings(_ s: AudioLoopSettings) { if settings != s { settings = s } }
    func _setError(_ e: String?) { if error != e { error = e } }
    func _setProbe(_ p: Probe) { if probe != p { probe = p } }

    /// Kernzustand übernehmen; Wellenform höchstens viermal je Sekunde neu rechnen, außer
    /// das Material ruht (dann sofort den Endstand). Rückgabe: braucht weitere Abfragen.
    func _refresh(frames: Int, inputActive: Bool, waveform: () -> [WaveBucket]) -> Bool {
        let c = core
        let s = Status(state: c.state, requested: c.isRecordRequested, hasMaterial: c.hasMaterial,
                       canUndo: c.canUndo, rateMismatch: c.rateMismatch, playing: c.playFrame >= 0,
                       inputActive: inputActive, frames: frames)
        if s != status { status = s }
        let version = c.materialVersion
        let now = ProcessInfo.processInfo.systemUptime
        if version != waveVersion, s.isQuiescent || now - waveAt >= 0.25 || waveVersion < 0 {
            waveVersion = version
            waveAt = now
            let w = s.hasMaterial || frames > 0 ? waveform() : []
            if w != wave { wave = w }
        }
        return s.playing || s.inputActive || !s.isQuiescent || version != waveVersion
    }
}
