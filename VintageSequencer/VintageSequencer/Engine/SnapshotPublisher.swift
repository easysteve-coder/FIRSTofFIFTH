import Foundation
import Atomics

// MARK: - SnapshotPublisher (v1.16.0, Codex M6)
//
// Besitzer der Bundle-Publikation zwischen Main (einziger Schreiber) und Tick-Thread (genau
// ein Leser): veröffentlichte Box, Hazard, aufgeschobene Freigabe, Erwerbsfehler. Vorher
// verstreut in `SequencerEngine`; Protokoll und Ordnungen sind unverändert.
//
//
//  Main-Thread publiziert einen neuen PlaybackBundleBox-Pointer atomar.
//  Der Tick-Thread erwirbt ihn über `acquire()` (Hazard-Pointer-Protokoll).
//
//  Lifetime-Garantie (Single-Reader-Hazard-Pointer, RT-3 v1.12.5, S01 v1.12.11):
//    Der Tick-Thread hält den rohen Box-Pointer über den GESAMTEN Tick
//    (advanceSteps liest bundle.snapshot/bpm/swing durch die ganze Track-Schleife).
//
//    Protokoll (Annahme: genau EIN Reader — Durchsetzung ist Slice S02, B2):
//      Reader  R1  c = load(published)                       [acquiring]
//              R2  store(hazard, c)                       [seq_cst]
//              R3  v = load(published)                       [seq_cst]
//              R4  v == c  → c ist geschützt, erst JETZT Dereferenzierung;
//                  v != c  → c = v, zurück zu R2 (höchstens `maxAttempts`
//                            Durchläufe; danach Erwerbsfehler, KEINE Dereferenzierung).
//              R5  Tick-Ende: store(hazard, 0)            [releasing]
//      Writer  W1  store(published, new)                     [seq_cst]
//              W2  h = load(hazard)                       [seq_cst]
//              W3  abgelöste Box nur freigeben, wenn rawOf(box) != h; sonst `deferred`.
//
//    Ordnungsbeweis (Dekker/Store-Buffering): R2→R3 und W1→W2 sind je ein
//    „store, dann load auf der ANDEREN Variable“. Release/Acquire erlaubt, dass
//    beide Loads die alten Werte sehen (Reader sieht den alten Pointer, Writer
//    sieht Hazard 0) → Writer gibt die Box frei, die der Reader gerade benutzt.
//    Mit seq_cst auf allen vier Operationen liegen sie in einer totalen Ordnung S:
//    steht R2 vor W1, sieht W2 (nach W1) den Hazard → Aufschub; steht W1 vor R2,
//    sieht R3 (nach R2) den neuen Pointer → Validierung scheitert, keine
//    Dereferenzierung. Auf ARM64 sind seq_cst-Store/Load stlr/ldar (RCsc, ohne
//    zusätzliche dmb); die Loads bleiben wartefrei. Sichtbarkeit des Box-Inhalts:
//    R3 (acquire-Anteil) liest den Wert aus W1 (release-Anteil) → happens-before
//    für die Initialisierung der Box. R5 (release) ordnet alle Reads der Box vor
//    das Löschen; W2 (acquire-Anteil) das Freigeben nach dem Lesen von R5.
//
//    ABA: Der Reader dereferenziert nie den bei R1 gelesenen Wert, sondern nur
//    das Objekt, das bei R3 ZUM VALIDIERUNGSZEITPUNKT publiziert ist. Eine
//    Wiederverwendung der Adresse durch eine neue Box ist deshalb harmlos: Passt
//    die Adresse zur aktuellen Publikation, ist genau diese lebende Box gemeint.
//    Auf Writer-Seite führt eine zufällig gleiche Adresse höchstens zu einem
//    überflüssigen Aufschub (konservativ). Eine aufgeschobene Box bleibt über
//    `deferred` am Leben, ihre Adresse kann nicht neu vergeben werden.
//
//    Deferred-Retention: höchstens EINE Box (nur ein Reader hat höchstens einen
//    Hazard). Sie wird beim nächsten publishSnapshot() freigegeben, sobald der
//    Hazard nicht mehr auf sie zeigt. Freigabe/Deinit laufen auf dem Publisher
//    (Main), nie auf dem Tick-Thread: der Reader hält keine Referenz (+0).
//
//    Beschränkte RT-Arbeit pro Erwerb: 1 Load + höchstens 9×(1 Store + 1 Load)
//    + 1 Clear; kein Lock, kein Alloc, kein Retain/Release, keine Schleife ohne
//    Obergrenze. Erschöpfung (≥ 9 Pointerwechsel während des Erwerbs) ist ein
//    definierter Erwerbsfehler: der Gesamttick wird abgebrochen (siehe advanceSteps).
//

final class SnapshotPublisher {

    /// Roh-Pointer der veröffentlichten Box (0 = keine). Main schreibt, Tick liest.
    private let published = ManagedAtomic<Int>(0)
    /// Box, die der Tick-Thread gerade dereferenziert (0 = keine). Nur der Leser schreibt.
    private let hazard = ManagedAtomic<Int>(0)
    /// Abgebrochene Gesamtticks wegen erschöpftem Erwerb (einziger Schreiber: Leser).
    private let acquireFailuresA = ManagedAtomic<Int>(0)
    /// Obergrenze der Erwerbsdurchläufe.
    static let maxAttempts = 9

    /// Hält die veröffentlichte Box am Leben (Main).
    private(set) var current: PlaybackBundleBox?
    /// Abgelöste Box, die der Leser laut Hazard noch benutzt (höchstens eine).
    private var deferred: PlaybackBundleBox?

    /// Ergebnis des Erwerbs. Reiner Wertetyp, kein Heap.
    enum Acquire {
        /// Box mit diesem Roh-Pointer ist im Hazard gemeldet UND validiert.
        case protected(Int)
        /// Kein Bundle publiziert.
        case noBundle
        /// Mehr als `maxAttempts` Wechsel während des Erwerbs.
        case exhausted
    }

    @inline(__always)
    static func rawOf(_ box: PlaybackBundleBox) -> Int {
        Int(bitPattern: Unmanaged.passUnretained(box).toOpaque())
    }

    // MARK: Main

    /// Neue Box veröffentlichen (W1–W3).
    func publish(_ newBox: PlaybackBundleBox) {
        let superseded = current   // bisher aktuelle Box — wird jetzt abgelöst
        current = newBox           // neue Box am Leben halten, BEVOR publiziert wird
        // W1: seq_cst — zugleich Release-Publikation des Box-Inhalts.
        published.store(Self.rawOf(newBox), ordering: .sequentiallyConsistent)
        // W2/W3: Freigabe der abgelösten Box gegen den Hazard prüfen.
        let hz = hazard.load(ordering: .sequentiallyConsistent)
        if let d = deferred, Self.rawOf(d) != hz { deferred = nil }
        if let s = superseded, Self.rawOf(s) == hz { deferred = s }
        // `superseded` nicht vor W1/W2 freigeben (ARC verkürzt Lebensdauern).
        withExtendedLifetime(superseded) {}
    }

    /// Alles freigeben. Nur nach bewiesener Quieszenz des Lesers (RT-3b).
    func teardown() {
        published.store(0, ordering: .releasing)
        current = nil
        deferred = nil
    }

    var hazardIsClear: Bool { hazard.load(ordering: .acquiring) == 0 }
    var acquireFailures: Int { acquireFailuresA.load(ordering: .acquiring) }

    // MARK: Tick-Thread (Leser)

    /// S01: beschränkter Hazard-Pointer-Erwerb (Protokoll R1–R4 am `published`).
    ///
    /// RT-Pflicht: nur Atomics, kein Lock/Alloc/ARC; höchstens
    /// 1 + 2·`maxAttempts` + 1 atomare Operationen. `@inline(never)`,
    /// damit der Nachweis „keine Aufrufe außer Atomics“ am Symbol möglich ist.
    /// Zustand beim Verlassen: `.protected` → Hazard zeigt auf die validierte Box
    /// (der Aufrufer gibt ihn am Tick-Ende frei); `.noBundle`/`.exhausted` → Hazard 0.
    @inline(never)
    func acquire() -> Acquire {
        var candidate = published.load(ordering: .acquiring)          // R1
        var attempt = 0
        while candidate != 0 {
            #if DEBUG
            _acquireHook?(.loaded, attempt)
            #endif
            hazard.store(candidate, ordering: .sequentiallyConsistent)   // R2
            #if DEBUG
            _acquireHook?(.announced, attempt)
            #endif
            var current = published.load(ordering: .sequentiallyConsistent) // R3
            #if DEBUG
            // Test-Injektion: erzwingt „Pointer hat gewechselt“ bei jedem Durchlauf, ohne
            // zweiten Writer. Protokoll, Obergrenze und Abbruchpfad bleiben unverändert.
            if _forceExhaustion.load(ordering: .relaxed) { current = candidate &+ 8 }
            #endif
            if current == candidate {                                         // R4
                #if DEBUG
                _acquireHook?(.validated, attempt)
                #endif
                return .protected(candidate)
            }
            attempt &+= 1
            if attempt >= Self.maxAttempts {
                // `current` ist NICHT gemeldet → nie dereferenzieren. Hazard räumen.
                hazard.store(0, ordering: .releasing)
                return .exhausted
            }
            candidate = current
        }
        hazard.store(0, ordering: .releasing)   // candidate == 0: nichts publiziert
        return .noBundle
    }

    /// Hazard am Tick-Ende freigeben (R5).
    @inline(__always)
    func release() {
        hazard.store(0, ordering: .releasing)
        #if DEBUG
        _acquireHook?(.released, 0)
        #endif
    }

    /// Erwerbsfehler zählen (wartefrei, einziger Schreiber).
    @inline(__always)
    func recordAcquireFailure() {
        acquireFailuresA.store(acquireFailuresA.load(ordering: .relaxed) &+ 1, ordering: .releasing)
    }

    #if DEBUG
    // MARK: Test-Zugang
    enum Stage { case loaded, announced, validated, released }
    var _acquireHook: ((Stage, Int) -> Void)?
    let _forceExhaustion = ManagedAtomic<Bool>(false)
    var _hazardRaw: Int { hazard.load(ordering: .acquiring) }
    var _publishedRaw: Int { published.load(ordering: .acquiring) }
    var _deferredRaw: Int { deferred.map { Self.rawOf($0) } ?? 0 }
    var _publishedBundle: PlaybackStateBundle? {
        let raw = published.load(ordering: .acquiring)
        guard raw != 0, let ptr = UnsafeRawPointer(bitPattern: raw) else { return nil }
        return Unmanaged<PlaybackBundleBox>.fromOpaque(ptr).takeUnretainedValue().bundle
    }
    func _announceCurrentHazard() { hazard.store(published.load(ordering: .acquiring), ordering: .releasing) }
    #endif
}
