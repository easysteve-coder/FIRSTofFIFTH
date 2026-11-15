import Foundation
import os

// MARK: - OutputWatchdog (v1.16.0, Codex M6; Verhalten aus v1.13.11/v1.13.14)
//
// Wächter der Audioausgabe als eigener Besitzer: Timer, Stillstandszähler, Sperrfrist,
// Erholungsprüfung und Zähler. Main-Thread, viermal je Sekunde, solange er gebraucht wird.
// Die Messwerte liefert das Rack je Prüfung (`Reading`); was bei einem Befund geschieht
// (Engine anhalten, Graph neu aufbauen), entscheidet das Rack in `recover`.
//
// Engine angehalten, keine Blöcke mehr (≈ 2 s) oder NaN/∞ in einem Tap → Wiederherstellung.
// Höchstens alle 3 s; ein Befund in der Sperrfrist bleibt stehen, bis er behandelt ist.
// Danach wird geprüft, ob die Engine wieder Blöcke liefert („erholt"), sonst „ohne Erfolg".

final class OutputWatchdog {
    enum Finding: String { case stopped, stalled, nonFinite }
    enum Outcome: String { case pending, recovered, failed }

    static let interval: TimeInterval = 0.25
    /// Prüfungen ohne neuen Block, ab denen die Engine als stehend gilt (≈ 2 s).
    static let stallTicks = 8
    static let recoveryLockout: TimeInterval = 3

    /// Messwerte einer Prüfung (vom Rack).
    struct Reading {
        var needed: Bool          // Instrumente geladen
        var running: Bool         // Engine läuft
        var tapInstalled: Bool    // Summen-Tap liefert Blockzähler
        var blocks: Int           // Blockzähler der Summe
        var nonFinite: Bool       // NaN/∞ in einem Tap (nur angesehen, nicht abgeholt)
    }

    /// Reine Entscheidung über die Engine.
    static func finding(needed: Bool, running: Bool, tapInstalled: Bool,
                        stalledTicks: Int, nonFinite: Bool) -> Finding? {
        guard needed else { return nil }
        if !running { return .stopped }
        if nonFinite { return .nonFinite }
        if tapInstalled, stalledTicks >= stallTicks { return .stalled }
        return nil
    }

    /// Je Prüfung zuerst (Diagnoseprobe, Routenlatenz); dann die Messwerte, nil = keine Engine.
    var onTick: (() -> Void)?
    var read: (() -> Reading?)?
    /// Wiederherstellung ausführen; Rückgabe: Blockzähler danach (Bezug der Erholungsprüfung).
    var recover: ((Finding) -> Int)?
    /// Ergebnis der Erholungsprüfung (Diagnose-Ereignis).
    var onOutcome: ((Bool) -> Void)?

    private var timer: Timer?
    private var lastBlocks = 0
    private var stalledTicks = 0
    private var lastRecovery = Date.distantPast
    private var recoveryCheck: (at: Date, blocks: Int)?
    /// Diagnose: Wiederherstellungen seit Programmstart, letzter Anlass und Ergebnis.
    private(set) var recoveries = 0
    private(set) var lastFinding: Finding?
    private(set) var lastOutcome: Outcome?
    private static let log = Logger(subsystem: "com.firstoffifth.sequencer", category: "audio")

    var isRunning: Bool { timer != nil }

    /// Läuft, solange `needed` gilt.
    func update(needed: Bool, currentBlocks: Int) {
        if needed, timer == nil {
            lastBlocks = currentBlocks; stalledTicks = 0
            let t = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in self?.tick() }
            RunLoop.main.add(t, forMode: .common)
            timer = t
        } else if !needed, let t = timer {
            t.invalidate(); timer = nil
        }
    }

    deinit { timer?.invalidate() }

    func tick(now: Date = Date()) {
        onTick?()
        guard let r = read?() else { return }
        stalledTicks = r.blocks == lastBlocks ? stalledTicks + 1 : 0
        lastBlocks = r.blocks

        if let check = recoveryCheck, now >= check.at {
            recoveryCheck = nil
            let ok = r.running && r.blocks > check.blocks
            lastOutcome = ok ? .recovered : .failed
            if ok { Self.log.notice("Audioausgabe erholt") }
            else  { Self.log.error("Audioausgabe nach Wiederherstellung ohne Erfolg") }
            onOutcome?(ok)
        }

        guard let f = Self.finding(needed: r.needed, running: r.running, tapInstalled: r.tapInstalled,
                                   stalledTicks: stalledTicks, nonFinite: r.nonFinite),
              now.timeIntervalSince(lastRecovery) > Self.recoveryLockout else { return }
        lastRecovery = now
        stalledTicks = 0
        recoveries += 1
        lastFinding = f
        lastOutcome = .pending
        Self.log.error("Audioausgabe: Wiederherstellung versucht (\(f.rawValue, privacy: .public))")
        let blocks = recover?(f) ?? r.blocks
        recoveryCheck = (now.addingTimeInterval(2), blocks)
    }

    #if DEBUG
    /// Prüfung sofort, ohne Sperrfrist (Tests).
    func _tickIgnoringLockout() { lastRecovery = .distantPast; tick() }
    #endif
}
