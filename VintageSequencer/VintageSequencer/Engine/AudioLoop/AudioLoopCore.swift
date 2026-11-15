import Foundation
import Atomics
import CoreAudio

// MARK: - PCMChannel (v1.15.1)

/// Ein Kanal Loop-Material. Samples liegen als atomare 32-Bit-Werte und werden ausschließlich
/// relaxed gelesen/geschrieben (auf arm64/x86-64 gewöhnliche Lade-/Speicherbefehle). Damit ist
/// der gleichzeitige Zugriff von Aufnahme (Eingangs-Render), Wiedergabe (Ausgangs-Render) und
/// Anzeige/Speichern (Main) kein Datenrennen im Sinne des Speichermodells (Codex-Befund H2).
/// Konsistenz über mehrere Samples ist damit nicht zugesagt — die regeln Besitz und Austausch
/// des ganzen Speichers (`AudioLoopCore.bind`).
struct PCMChannel {
    let base: UnsafeMutablePointer<UInt32.AtomicRepresentation>
    let count: Int

    static func allocate(_ count: Int) -> PCMChannel {
        let p = UnsafeMutablePointer<UInt32.AtomicRepresentation>.allocate(capacity: count)
        p.initialize(repeating: .init(0), count: count)
        return PCMChannel(base: p, count: count)
    }
    func deallocate() { base.deinitialize(count: count); base.deallocate() }

    subscript(i: Int) -> Float {
        @inline(__always) get {
            Float(bitPattern: UnsafeAtomic<UInt32>(at: base + i).load(ordering: .relaxed))
        }
        @inline(__always) nonmutating set {
            UnsafeAtomic<UInt32>(at: base + i).store(newValue.bitPattern, ordering: .relaxed)
        }
    }

    func read(into dst: UnsafeMutablePointer<Float>, from start: Int, count n: Int) {
        for i in 0..<n { dst[i] = self[start + i] }
    }
    func write(from src: UnsafePointer<Float>, at start: Int, count n: Int) {
        for i in 0..<n { self[start + i] = src[i] }
    }
    func copy(from other: PCMChannel, range: Range<Int>) {
        for i in range { self[i] = other[i] }
    }
}

// MARK: - AudioLoopStorage

/// Aufgenommenes Material eines Audio-Loop-Kanals: Stereo-Float, fest `bars` Takte bei der
/// Abtastrate und dem Tempo der Aufnahme, dazu eine gleich große Undo-Kopie.
///
/// Undo (v1.15.1, Codex H11): Vor dem ersten Schreiben eines Abschnitts (`chunkFrames`) in
/// einem Durchlauf kopiert die Aufnahme genau diesen Abschnitt in die Undo-Kopie und markiert
/// ihn mit der Durchlaufnummer. Arbeit je Block ist damit durch die Blocklänge begrenzt, auch
/// wenn die Position nach einem Aussetzer springt; übersprungene Abschnitte bleiben unmarkiert
/// und werden beim Undo nicht getauscht.
///
/// Lebensdauer: Main hält die starke Referenz (Rack). Audio-Threads greifen nur über den
/// geschützten Rohzeiger des `AudioLoopCore` zu; abgelöste Speicher gibt Main erst frei, wenn
/// kein Hazard mehr auf sie zeigt.
final class AudioLoopStorage {
    static let chunkFrames = 1024
    static let barRange = 1...16
    static let sampleRateRange: ClosedRange<Double> = 1_000...384_000
    static let bpmRange: ClosedRange<Double> = 1...1_000

    let bars:        Int
    let barFrames:   Int
    let sampleRate:  Double
    let recordedBPM: Double
    let frames:      Int
    let chunks:      Int
    let left, right, undoLeft, undoRight: PCMChannel
    /// Durchlaufnummer, in der der Abschnitt zuletzt in die Undo-Kopie gesichert wurde.
    private let chunkPassRaw: UnsafeMutablePointer<UInt32.AtomicRepresentation>
    /// Vorberechnung (v1.18.15): Rohzeiger und Materialstand der Quelle, aus der dieser
    /// gedehnte Speicher entstand (0/−1 = Originalmaterial). Main setzt beides vor dem Veröffentlichen.
    var prerenderSource: UInt = 0
    var prerenderVersion = -1
    /// Belegungsepoche des Kerns, an den dieser Speicher zuletzt gebunden wurde (v1.15.2,
    /// Codex R3). Die Aufnahme schreibt nur, wenn sie zu derselben Belegung gehört.
    let boundOccupancy = UnsafeAtomic<UInt32>.create(0)

    /// Lebende Loop-Speicher aller Racks in Bytes (Main legt an und gibt frei). Grundlage des
    /// Projektbudgets — zählt auch abgelöste, im Undo gehaltene und Zwischenkopien (Codex R5).
    private static let liveBytesA = ManagedAtomic<Int>(0)
    static var liveBytes: Int { liveBytesA.load(ordering: .relaxed) }
    /// Passt ein weiterer Speicher mit `frames` Frames noch ins Budget?
    static func fits(frames: Int, freeing: Int = 0) -> Bool {
        liveBytes - freeing + bytes(frames: frames) <= AudioLoopSettings.maxProjectBytes
    }

    /// Reserviert `bytes` atomar im Projektbudget (Arbeitsspeicher, der kein Loop-Speicher ist,
    /// v1.18.16, Codex R15-02). false, wenn es nicht passt; sonst später `release`.
    static func reserve(bytes: Int) -> Bool {
        var cur = liveBytesA.load(ordering: .relaxed)
        while true {
            guard cur + bytes <= AudioLoopSettings.maxProjectBytes else { return false }
            let (ok, now) = liveBytesA.compareExchange(expected: cur, desired: cur + bytes, ordering: .relaxed)
            if ok { return true }
            cur = now
        }
    }
    static func release(bytes: Int) { liveBytesA.wrappingDecrement(by: bytes, ordering: .relaxed) }

    /// Bytes eines Speichers mit `frames` Frames (vier Kanäle + Abschnittsmarken).
    static func bytes(frames: Int) -> Int { frames * 16 + (frames / chunkFrames + 1) * 4 }

    /// Frames eines Takts bei `bpm` (4/4); 0 bei ungültigen Werten.
    /// Frames eines Takts aus `quarters` Vierteln (Taktart, v1.18.12; 4/4 = 4).
    static func barFrames(bpm: Double, sampleRate: Double, quarters: Double = 4) -> Int {
        guard bpm.isFinite, sampleRate.isFinite, bpmRange.contains(bpm),
              sampleRateRange.contains(sampleRate), quarters.isFinite, quarters > 0 else { return 0 }
        return Int((quarters * 60 / bpm * sampleRate).rounded())
    }

    /// nil, wenn Werte ungültig sind oder die Länge die Obergrenze überschreitet. Prüft vor
    /// jeder Allokation (Presetdaten sind nicht vertrauenswürdig, Codex H9).
    init?(bars: Int, sampleRate: Double, bpm: Double, barFrames given: Int? = nil) {
        guard Self.barRange.contains(bars), sampleRate.isFinite, bpm.isFinite,
              Self.sampleRateRange.contains(sampleRate), Self.bpmRange.contains(bpm) else { return nil }
        let bf = given ?? Self.barFrames(bpm: bpm, sampleRate: sampleRate)
        let limit = Int(AudioLoopSettings.maxSeconds * sampleRate)
        guard bf > 0, bf <= limit else { return nil }
        let (n, overflow) = bf.multipliedReportingOverflow(by: bars)
        guard !overflow, n <= limit else { return nil }
        // Zulassung atomar vor der Allokation (Codex R15-02): parallele Anleger (Main, Vorberechnung)
        // können das Projektbudget nicht gemeinsam überschreiten. `fits` bleibt Vorprüfung.
        guard Self.reserve(bytes: Self.bytes(frames: n)) else { return nil }
        self.bars = bars; self.barFrames = bf; self.sampleRate = sampleRate; self.recordedBPM = bpm
        frames = n
        chunks = (n + Self.chunkFrames - 1) / Self.chunkFrames
        left = .allocate(n); right = .allocate(n); undoLeft = .allocate(n); undoRight = .allocate(n)
        chunkPassRaw = .allocate(capacity: chunks)
        chunkPassRaw.initialize(repeating: .init(0), count: chunks)
    }

    deinit {
        left.deallocate(); right.deallocate(); undoLeft.deallocate(); undoRight.deallocate()
        chunkPassRaw.deinitialize(count: chunks); chunkPassRaw.deallocate()
        boundOccupancy.destroy()
        Self.liveBytesA.wrappingDecrement(by: Self.bytes(frames: frames), ordering: .relaxed)
    }

    var byteCount: Int { Self.bytes(frames: frames) }

    @inline(__always) func chunkPass(_ c: Int) -> UInt32 {
        UnsafeAtomic<UInt32>(at: chunkPassRaw + c).load(ordering: .relaxed)
    }
    @inline(__always) func setChunkPass(_ c: Int, _ v: UInt32) {
        UnsafeAtomic<UInt32>(at: chunkPassRaw + c).store(v, ordering: .relaxed)
    }

    /// Eigenständige Kopie; mit `includingUndo` samt Undo-Kopie und Abschnittsmarken.
    func copy(includingUndo: Bool = false) -> AudioLoopStorage? {
        guard let c = AudioLoopStorage(bars: bars, sampleRate: sampleRate, bpm: recordedBPM,
                                       barFrames: barFrames) else { return nil }
        c.left.copy(from: left, range: 0..<frames); c.right.copy(from: right, range: 0..<frames)
        if includingUndo {
            c.undoLeft.copy(from: undoLeft, range: 0..<frames)
            c.undoRight.copy(from: undoRight, range: 0..<frames)
            for k in 0..<chunks { c.setChunkPass(k, chunkPass(k)) }
        }
        return c
    }

    /// Tauscht in allen Abschnitten des Durchlaufs `pass` Material und Undo-Kopie (Main, nur
    /// an einem noch nicht veröffentlichten Speicher).
    func swapPass(_ pass: UInt32) {
        for k in 0..<chunks where chunkPass(k) == pass {
            let a = k * Self.chunkFrames, b = min(frames, a + Self.chunkFrames)
            for i in a..<b {
                let l = left[i]; left[i] = undoLeft[i]; undoLeft[i] = l
                let r = right[i]; right[i] = undoRight[i]; undoRight[i] = r
            }
        }
    }

    /// Größter Betrag (Main; für „hat Material").
    func peak() -> Float {
        var m: Float = 0
        for i in 0..<frames { m = max(m, abs(left[i]), abs(right[i])) }
        return m
    }
}

// MARK: - AudioLoopCore

/// Aufnahme und Wiedergabe eines Audio-Loop-Kanals. Ein fester Kern je Rack-Slot (wie die
/// Ereigniswarteschlangen), nie freigegeben, nur neu belegt.
///
/// **Threads.**
///   - Main: Einstellungen, Scharfschalten/Beenden, Bindung bzw. Austausch des Speichers
///     (Undo und Löschen sind Austausch, kein Schreiben in den veröffentlichten Speicher),
///     Belegung des Slots.
///   - Eingangs-Render (`consumeInput`): Mithören in den Ring, Aufnahme in den Speicher.
///     Alleiniger Besitzer des Aufnahmezustands und alleiniger Schreiber des gebundenen PCM.
///   - Ausgangs-Render (`renderOutput`): Mithören aus dem Ring, Wiedergabe (nur lesend).
///   - Tick-Thread (`markActive`/`closeWindow`): Zeitfenster, in dem die Spur klingt.
///   Im Audio-Pfad nur Atomics und vorab angelegter Speicher; kein Lock, keine Allokation,
///   kein Retain auf den Speicher (Zugriff über `_withUnsafeGuaranteedRef`).
///
/// **Speicherfreigabe (v1.15.1, Codex K1).** Dasselbe Protokoll wie der Playback-Snapshot
/// (S01), mit einem Hazard je Leser: Publizieren ist ein seq_cst-Store des Zeigers, danach
/// lädt Main die Hazards seq_cst; der Leser speichert seinen Hazard seq_cst und lädt den
/// Zeiger seq_cst erneut. In der gemeinsamen Totalordnung sieht entweder Main den Hazard oder
/// der Leser den neuen Zeiger — nie beides nicht.
///
/// **Belegung (v1.15.1, Codex H7).** `beginOccupancy(epoch)` übernimmt die Belegungsepoche der
/// Ereigniswarteschlange desselben Slots. Tick-Meldungen tragen die Epoche ihres Snapshots
/// und werden bei Abweichung verworfen; Eingangs- und Ausgangs-Render setzen ihren eigenen
/// Zustand zurück, sobald sie eine neue Epoche sehen.
///
/// **Ort im Loop.** Aus den Taktankern (`BarClock`): Takt n beginnt zur Host-Zeit t ⇒ ein
/// Sample zur Host-Zeit h liegt im Loop bei `(n mod bars) · barFrames + (h − t) / ticksPerFrame`
/// — solange ein Takt jetzt so lang ist wie bei der Aufnahme (samplegenau, unverändert).
///
/// **Zeitdehnung (v1.18.13).** Weicht die Taktlänge ab (Tempo oder Taktart), liest der Ausgang
/// über Signalsmith Stretch (Tonhöhe bleibt). Die Leseposition kommt in jedem Block aus der
/// Musikposition (`HostSync`: Beat zur Host-Zeit, pulsgenau) — `(Beat / Viertel je Takt) mod
/// bars · barFrames` —, nie aus aufsummierter Geschwindigkeit: keine Drift, ein Tempowechsel
/// gilt ab seinem Puls. Der Eingangscursor des Stretchers läuft um dessen Latenz voraus
/// (Eingang + Ausgang × Verhältnis, gemessen), damit die Ausgabe auf dem Takt liegt. Die Aufnahme rechnet mit
/// `Eingangszeit − Latenz`, damit Eingespieltes dort landet, wo es zur gehörten Wiedergabe lag.
final class AudioLoopCore {

    enum State: Int { case idle = 0, armed = 1, recording = 2, finishing = 3 }

    static let maxFrames = 8192
    static let fadeFrames = 128
    static let hostTicksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
    }()

    let barClock: BarClock
    /// Gate am Eingang (vor Mithören und Aufnahme).
    let inputGate = GateControl()
    let ring = AudioSampleRing(capacityFrames: 16384, channelCount: 2, maxDepthFrames: 2048)

    // MARK: Speicher-Veröffentlichung (Hazard-Pointer je Leser)
    private let storageRaw = UnsafeAtomic<UInt>.create(0)
    private let hazardIn   = UnsafeAtomic<UInt>.create(0)
    private let hazardOut  = UnsafeAtomic<UInt>.create(0)
    /// Vorberechnete Dehnung (v1.18.15), nur der Ausgangs-Render liest sie (eigener Hazard).
    private let renderedRaw    = UnsafeAtomic<UInt>.create(0)
    private let hazardRendered = UnsafeAtomic<UInt>.create(0)
    /// Main: gebundener Speicher (starke Referenz) und abgelöste, noch nicht freie Speicher.
    private(set) var storage: AudioLoopStorage?
    private(set) var rendered: AudioLoopStorage?
    private var retired: [AudioLoopStorage] = []
    private var reclaimScheduled = false

    // MARK: Main → Audio/Tick
    private let recordRequested = UnsafeAtomic<Bool>.create(false)
    private let monitorFlag     = UnsafeAtomic<Bool>.create(false)
    private let inputChannelA   = UnsafeAtomic<Int>.create(0)
    private let stereoFlag      = UnsafeAtomic<Bool>.create(false)
    private let latencyTicks    = UnsafeAtomic<Int>.create(0)
    private let occupancy       = UnsafeAtomic<UInt32>.create(0)
    /// Latenz der Kette hinter der Quelle (Gate, Effekte) in Host-Ticks: die Wiedergabe liest
    /// so viel voraus, dass der Kanalausgang auf dem Taktanker liegt (Codex T7).
    private let outputAdvance   = UnsafeAtomic<UInt64>.create(0)

    // MARK: Tick → Audio
    private let activeSince = UnsafeAtomic<UInt64>.create(0)
    private let activeUntil = UnsafeAtomic<UInt64>.create(0)

    // MARK: Audio → Main
    private let stateA         = UnsafeAtomic<Int>.create(0)
    private let playFrameA     = UnsafeAtomic<Int>.create(-1)
    private let hasMaterialA   = UnsafeAtomic<Bool>.create(false)
    private let materialSerial = UnsafeAtomic<Int>.create(0)
    /// Eingangs-Render → Main: erhöht, bevor ein Aufnahmeblock schreiben kann (v1.18.16, Codex
    /// R15-04). Unabhängig davon, wer den Transport startet (INT über Main, EXT auf dem MIDI-Thread).
    private let writeBeginsA   = UnsafeAtomic<Int>.create(0)
    private let undoPassA      = UnsafeAtomic<UInt32>.create(0)
    private let undoAvailableA = UnsafeAtomic<Bool>.create(false)
    private let inputPeakBits  = UnsafeAtomic<UInt32>.create(0)
    private let rateMismatchA  = UnsafeAtomic<Bool>.create(false)
    private let skippedFramesA = UnsafeAtomic<Int>.create(0)
    /// Driftausgleich: Indexschritte ≠ 1 (Aufnahme und Wiedergabe) bzw. Mithörkorrekturen.
    private let driftSlipsA    = UnsafeAtomic<Int>.create(0)
    // Latenzmessung per Loopback (v1.15.2, Codex T4/M1): 0 aus, 1 angefordert, 2 Klick
    // gesendet, 3 Klick im Eingang erkannt.
    private let probeStateA    = UnsafeAtomic<Int>.create(0)
    private let probeOutHostA  = UnsafeAtomic<UInt64>.create(0)
    private let probeInHostA   = UnsafeAtomic<UInt64>.create(0)
    private let monitorSlipsA  = UnsafeAtomic<Int>.create(0)

    // MARK: Eingangs-Render (nur dieser Thread)
    private var rtState = State.idle
    private var lastBar = -1
    private var fadeCount = 0
    private var passEpoch: UInt32 = 0
    private var passWrote = false
    private var seenOccupancyIn: UInt32 = 0
    private var gate = GateDSP()
    private var inLock = LockedIndex()
    private var inTicksPerFrame: Double = 0
    // Arbeitspuffer: genullt reserviert, real belegt erst mit `prefault` (Loop-Kanal angelegt).
    private let inL = ZeroedMemory.allocate(AudioLoopCore.maxFrames, of: Float.self)
    private let inR = ZeroedMemory.allocate(AudioLoopCore.maxFrames, of: Float.self)
    private let inMix = ZeroedMemory.allocate(2 * AudioLoopCore.maxFrames, of: Float.self)
    // MARK: Ausgangs-Render (nur dieser Thread)
    private var seenOccupancyOut: UInt32 = 0
    private var outLock = LockedIndex()
    private let outMix = ZeroedMemory.allocate(2 * (AudioLoopCore.maxFrames + 1), of: Float.self)

    // MARK: Zeitdehnung (v1.18.13) — nur Ausgangs-Render; Stretcher angelegt auf Main (`prefault`)
    /// Musikposition für die Zeitdehnung (nil: nur der samplegenaue Weg).
    let musical: HostSync?
    private var stretcher: OpaquePointer?
    static let stretchBlock = 5760, stretchInterval = 1440
    static let stretchRatioRange = 0.25...4.0
    /// Eingangsframes je Aufruf: höchstens 4 × Blocklänge plus Neuaufsetzen (Latenzen).
    static let stretchInCapacity = 4 * maxFrames + 3 * stretchBlock
    private let stInL  = ZeroedMemory.allocate(AudioLoopCore.stretchInCapacity, of: Float.self)
    private let stInR  = ZeroedMemory.allocate(AudioLoopCore.stretchInCapacity, of: Float.self)
    private let stOutL = ZeroedMemory.allocate(AudioLoopCore.maxFrames, of: Float.self)
    private let stOutR = ZeroedMemory.allocate(AudioLoopCore.maxFrames, of: Float.self)
    private let stInPtrs  = UnsafeMutablePointer<UnsafePointer<Float>?>.allocate(capacity: 2)
    private let stOutPtrs = UnsafeMutablePointer<UnsafeMutablePointer<Float>?>.allocate(capacity: 2)
    /// Nächster Eingangsframe im Material; −1 = neu aufsetzen.
    private var stCursor = -1
    private var stWasActive = false
    private var stFade = 0
    private var exactFade = 0
    /// Audio → Main/Tests: dehnt gerade; Zahl der Neuaufsetzer.
    private let stretchingA = UnsafeAtomic<Bool>.create(false)
    private let stretchSeeksA = UnsafeAtomic<Int>.create(0)
    var isStretching: Bool { stretchingA.load(ordering: .relaxed) }
    var stretchSeeks: Int { stretchSeeksA.load(ordering: .relaxed) }
    /// Audio → Main/Tests: spielt gerade die Vorberechnung; Host-Zeit des letzten Tauschs
    /// Echtzeit → Vorberechnung (Taktgrenze).
    private let prerenderedA = UnsafeAtomic<Bool>.create(false)
    private let swapHostA = UnsafeAtomic<UInt64>.create(0)
    var isPlayingPrerender: Bool { prerenderedA.load(ordering: .relaxed) }
    var lastPrerenderSwapHost: UInt64 { swapHostA.load(ordering: .relaxed) }
    /// Ausgangs-Render: zuletzt samplegenau gelesener Speicher (Wechsel → Index neu fassen).
    private var exactSource: UInt = 0
    /// Überblendung Echtzeit → Vorberechnung: bereits vergangene Frames (−1 = keine). Läuft über
    /// Blockgrenzen weiter, bis beide Rampen 128 Frames erreicht haben (Codex R15-01).
    private var xfadeDone = -1

    init(barClock: BarClock, musical: HostSync? = nil) {
        self.barClock = barClock
        self.musical = musical
        stInPtrs[0] = UnsafePointer(stInL); stInPtrs[1] = UnsafePointer(stInR)
        stOutPtrs[0] = stOutL; stOutPtrs[1] = stOutR
    }

    private var prefaulted = false
    /// Main, wenn der Kanal ein Loop-Kanal wird: Arbeitspuffer real belegen (einmal).
    func prefault() {
        guard !prefaulted else { return }
        prefaulted = true
        ring.prefault()
        ZeroedMemory.prefault(inL, count: Self.maxFrames)
        ZeroedMemory.prefault(inR, count: Self.maxFrames)
        ZeroedMemory.prefault(inMix, count: 2 * Self.maxFrames)
        ZeroedMemory.prefault(outMix, count: 2 * (Self.maxFrames + 1))
        if musical != nil {
            ZeroedMemory.prefault(stInL, count: Self.stretchInCapacity)
            ZeroedMemory.prefault(stInR, count: Self.stretchInCapacity)
            ZeroedMemory.prefault(stOutL, count: Self.maxFrames)
            ZeroedMemory.prefault(stOutR, count: Self.maxFrames)
            // Vor dem ersten Render des Kanals (die Quelle hängt erst danach im Graphen).
            stretcher = fof_stretch_create(2, Int32(Self.stretchBlock), Int32(Self.stretchInterval))
        }
    }

    deinit {
        for a in [storageRaw, hazardIn, hazardOut] { a.destroy() }
        for a in [recordRequested, monitorFlag, stereoFlag, hasMaterialA, undoAvailableA, rateMismatchA] { a.destroy() }
        for a in [inputChannelA, latencyTicks, stateA, playFrameA, materialSerial, skippedFramesA] { a.destroy() }
        occupancy.destroy(); undoPassA.destroy(); outputAdvance.destroy()
        driftSlipsA.destroy(); monitorSlipsA.destroy()
        probeStateA.destroy(); probeOutHostA.destroy(); probeInHostA.destroy()
        activeSince.destroy(); activeUntil.destroy(); inputPeakBits.destroy()
        ZeroedMemory.free(inL, count: Self.maxFrames); ZeroedMemory.free(inR, count: Self.maxFrames)
        ZeroedMemory.free(inMix, count: 2 * Self.maxFrames); ZeroedMemory.free(outMix, count: 2 * (Self.maxFrames + 1))
        if let stretcher { fof_stretch_destroy(stretcher) }
        ZeroedMemory.free(stInL, count: Self.stretchInCapacity); ZeroedMemory.free(stInR, count: Self.stretchInCapacity)
        ZeroedMemory.free(stOutL, count: Self.maxFrames); ZeroedMemory.free(stOutR, count: Self.maxFrames)
        stInPtrs.deallocate(); stOutPtrs.deallocate()
        stretchingA.destroy(); stretchSeeksA.destroy()
        renderedRaw.destroy(); hazardRendered.destroy(); prerenderedA.destroy(); swapHostA.destroy()
        writeBeginsA.destroy()
    }

    /// Identität eines Speichers für `prerenderSource` (Main).
    static func identity(_ s: AudioLoopStorage) -> UInt { raw(s) }

    @inline(__always)
    private static func raw(_ s: AudioLoopStorage) -> UInt {
        UInt(bitPattern: Unmanaged.passUnretained(s).toOpaque())
    }

    // MARK: - Main

    /// Bindet Speicher (oder nil). Der bisherige wird freigegeben, sobald kein Leser ihn hält.
    /// `keepUndo`: Undo-Stand bleibt gültig (Austausch beim Undo selbst).
    func bind(_ new: AudioLoopStorage?, keepUndo: Bool = false) {
        guard new !== storage else { return }
        bindRendered(nil, reclaiming: false)   // gehört zum alten Material (vor dessen Ablösung)
        if let old = storage { retired.append(old) }
        storage = new
        new?.boundOccupancy.store(occupancy.load(ordering: .relaxed), ordering: .relaxed)
        // S01-Ordnung: Publizieren seq_cst, danach Hazards seq_cst (in `reclaim`).
        storageRaw.store(new.map(Self.raw) ?? 0, ordering: .sequentiallyConsistent)
        hasMaterialA.store(new.map { $0.peak() > 0 } ?? false, ordering: .relaxed)
        rateMismatchA.store(false, ordering: .relaxed)
        if !keepUndo { undoAvailableA.store(false, ordering: .releasing) }
        materialSerial.wrappingIncrement(ordering: .relaxed)
        reclaim()
    }

    /// Vorberechnete Dehnung des gebundenen Materials (oder nil). Gilt im Render nur, solange
    /// `prerenderSource`/`prerenderVersion` zum gebundenen Speicher und Materialstand passen.
    func bindRendered(_ new: AudioLoopStorage?, reclaiming: Bool = true) {
        guard new !== rendered else { return }
        if let old = rendered { retired.append(old) }
        rendered = new
        renderedRaw.store(new.map(Self.raw) ?? 0, ordering: .sequentiallyConsistent)
        if reclaiming { reclaim() }
    }

    /// Gibt abgelöste Speicher frei, auf die kein Hazard mehr zeigt; sonst später erneut.
    func reclaim() {
        let busyIn = hazardIn.load(ordering: .sequentiallyConsistent)
        let busyOut = hazardOut.load(ordering: .sequentiallyConsistent)
        let busyR = hazardRendered.load(ordering: .sequentiallyConsistent)
        retired.removeAll { s in let p = Self.raw(s); return p != busyIn && p != busyOut && p != busyR }
        if !retired.isEmpty, !reclaimScheduled {
            reclaimScheduled = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.reclaimScheduled = false
                self?.reclaim()
            }
        }
    }

    /// Neue Belegung des Slots (Main): Epoche der Warteschlange übernehmen, Aufnahme beenden,
    /// Zeitfenster schließen. Audio-Threads setzen ihren Zustand beim nächsten Block zurück.
    func beginOccupancy(_ epoch: UInt32) {
        recordRequested.store(false, ordering: .releasing)
        occupancy.store(epoch, ordering: .sequentiallyConsistent)
        activeUntil.store(0, ordering: .sequentiallyConsistent)
        activeSince.store(0, ordering: .relaxed)
    }
    var occupancyEpoch: UInt32 { occupancy.load(ordering: .acquiring) }

    func configure(_ s: AudioLoopSettings, latencyFrames: Int, sampleRate: Double) {
        monitorFlag.store(s.monitor, ordering: .relaxed)
        inputChannelA.store(s.inputChannel, ordering: .relaxed)
        stereoFlag.store(s.stereo, ordering: .relaxed)
        let sr = sampleRate > 0 ? sampleRate : 48_000
        let seconds = Double(latencyFrames) / sr + Double(s.latencyOffsetMs) / 1000
        latencyTicks.store(Int(seconds * Self.hostTicksPerSecond), ordering: .relaxed)
        inputGate.apply(s.gate, enabled: s.gate.position == .input)
    }

    /// Scharfschalten (true) bzw. Aufnahme beenden (false: läuft bis zum Ende des Durchlaufs).
    func setRecording(_ on: Bool) { recordRequested.store(on, ordering: .releasing) }
    var isRecordRequested: Bool { recordRequested.load(ordering: .acquiring) }

    var state: State { State(rawValue: stateA.load(ordering: .acquiring)) ?? .idle }
    /// Wiedergabeort in Frames (−1 = keine Wiedergabe).
    var playFrame: Int { playFrameA.load(ordering: .relaxed) }
    var hasMaterial: Bool { hasMaterialA.load(ordering: .relaxed) }
    /// Ändert sich, wenn neues Material geschrieben wurde (Anzeige der Wellenform).
    var materialVersion: Int { materialSerial.load(ordering: .relaxed) }
    /// Zahl der Aufnahmeblöcke, die schreiben durften (s. `writeBeginsA`).
    var writeGeneration: Int { writeBeginsA.load(ordering: .acquiring) }
    /// Ruhezustand: kein Wunsch und kein Aufnahmezustand — dann schreibt kein Audio-Thread.
    var isQuiescent: Bool { state == .idle && !isRecordRequested }
    var canUndo: Bool { undoAvailableA.load(ordering: .acquiring) && isQuiescent }
    var rateMismatch: Bool { rateMismatchA.load(ordering: .relaxed) }
    /// Frames, die die Aufnahme wegen des Kopierbudgets ausgelassen hat (Diagnose).
    var skippedFrames: Int { skippedFramesA.load(ordering: .relaxed) }
    /// Höchster Eingangspegel seit der letzten Abfrage.
    // MARK: Latenzmessung (Main)

    /// Fordert einen Messklick an: der Ausgang setzt ihn in den nächsten Block mit gültiger
    /// Host-Zeit, der Eingang sucht ihn auf dem gewählten Eingangskanal.
    func startLatencyProbe() {
        probeInHostA.store(0, ordering: .relaxed)
        probeOutHostA.store(0, ordering: .relaxed)
        probeStateA.store(1, ordering: .releasing)
    }
    func cancelLatencyProbe() { probeStateA.store(0, ordering: .releasing) }
    var isProbing: Bool { let s = probeStateA.load(ordering: .acquiring); return s == 1 || s == 2 }
    /// Rundlauf in Host-Ticks: Zeitstempel des Ausgangsblocks mit dem Klick → Zeitstempel
    /// des Eingangsframes, in dem er ankommt. nil, solange nichts erkannt ist.
    var latencyProbeTicks: UInt64? {
        guard probeStateA.load(ordering: .acquiring) == 3 else { return nil }
        let o = probeOutHostA.load(ordering: .relaxed), i = probeInHostA.load(ordering: .relaxed)
        return i > o ? i - o : nil
    }
    static let probeThreshold: Float = 0.2

    /// Driftausgleich bisher (Diagnose): Indexsprünge und Mithörkorrekturen.
    var driftSlips: Int { driftSlipsA.load(ordering: .relaxed) }
    var monitorSlips: Int { monitorSlipsA.load(ordering: .relaxed) }

    func takeInputPeak() -> Float { Float(bitPattern: inputPeakBits.exchange(0, ordering: .relaxed)) }

    /// Speicher mit vertauschtem letzten Durchlauf (Undo; erneut = Redo), noch nicht
    /// gebunden. Nur im Ruhezustand. Der Aufrufer bindet ihn mit `keepUndo: true`.
    func undoSwapped() -> AudioLoopStorage? {
        guard canUndo, let s = storage, let c = s.copy(includingUndo: true) else { return nil }
        c.swapPass(undoPassA.load(ordering: .acquiring))
        return c
    }

    // MARK: - Tick-Thread

    /// Die Spur klingt ab `tickTime` für `spanTicks` — wenn `epoch` die aktuelle Belegung ist.
    /// RT-sicher.
    @inline(__always)
    func markActive(tickTime: UInt64, spanTicks: UInt64, epoch: UInt32) {
        guard epoch == occupancy.load(ordering: .acquiring) else { return }
        if activeUntil.load(ordering: .relaxed) < tickTime {
            activeSince.store(tickTime, ordering: .relaxed)
        }
        activeUntil.store(tickTime &+ spanTicks, ordering: .sequentiallyConsistent)
        // Belegung währenddessen gewechselt (Main): eigenes Fenster wieder schließen.
        if occupancy.load(ordering: .sequentiallyConsistent) != epoch {
            activeUntil.store(0, ordering: .relaxed)
        }
    }

    /// Die Spur klingt ab `tickTime` nicht mehr (stumm, Patternwechsel ohne diese Spur,
    /// Songende). Schließt ein offenes Fenster exakt dort. RT-sicher.
    @inline(__always)
    func closeWindow(at tickTime: UInt64) {
        if activeUntil.load(ordering: .relaxed) > tickTime {
            activeUntil.store(tickTime, ordering: .releasing)
        }
    }

    // MARK: - Audio: Hazard-Erwerb

    /// Erwirbt den gebundenen Speicher unter `hazard`. Gibt ihn ohne Retain zurück; gültig, bis
    /// der Hazard gelöscht wird.
    @inline(__always)
    private func acquire(_ hazard: UnsafeAtomic<UInt>) -> Unmanaged<AudioLoopStorage>? {
        acquire(hazard, from: storageRaw)
    }

    @inline(__always)
    private func acquire(_ hazard: UnsafeAtomic<UInt>, from source: UnsafeAtomic<UInt>) -> Unmanaged<AudioLoopStorage>? {
        var candidate = source.load(ordering: .acquiring)
        for _ in 0..<4 {
            guard candidate != 0 else { hazard.store(0, ordering: .releasing); return nil }
            hazard.store(candidate, ordering: .sequentiallyConsistent)
            let now = source.load(ordering: .sequentiallyConsistent)
            if now == candidate, let p = UnsafeRawPointer(bitPattern: candidate) {
                return Unmanaged<AudioLoopStorage>.fromOpaque(p)
            }
            candidate = now
        }
        hazard.store(0, ordering: .releasing)
        return nil
    }

    // MARK: - Audio: Ausgang

    /// Latenzausgleich der Ausgangskette in Host-Ticks (Main).
    func setOutputAdvance(_ host: UInt64) { outputAdvance.store(host, ordering: .relaxed) }
    var outputAdvanceHost: UInt64 { outputAdvance.load(ordering: .relaxed) }

    /// Tatsächliche Host-Ticks je Frame: Nominalwert × `mRateScalar` des Zeitstempels
    /// (Codex T5). Unplausible Werte gelten als 1.
    @inline(__always)
    static func ticksPerFrame(_ sampleRate: Double, rateScalar: Double) -> Double {
        guard sampleRate > 0 else { return 0 }
        let r = rateScalar > 0.98 && rateScalar < 1.02 ? rateScalar : 1
        return hostTicksPerSecond / sampleRate * r
    }

    /// Füllt `l`/`r` (beliebige Länge, intern in Blöcken ≤ `maxFrames`) mit Mithören und
    /// Loop. `host` = Host-Zeit des ersten Frames (0 = ungültig: nur Mithören);
    /// `rateScalar` = Verhältnis tatsächlicher zu nominaler Gerätetakt (Zeitstempel). RT-sicher.
    func renderOutput(host: UInt64, frames: Int, sampleRate: Double, rateScalar: Double = 1,
                      l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        let occ = occupancy.load(ordering: .acquiring)
        if occ != seenOccupancyOut {
            seenOccupancyOut = occ; ring.reset(); resetMonitorControl(); outLock.reset(); stCursor = -1; xfadeDone = -1
        }
        let tpf = sampleRate > 0 ? Self.hostTicksPerSecond / sampleRate : 0
        let tpfActual = Self.ticksPerFrame(sampleRate, rateScalar: rateScalar)
        let base = host == 0 ? 0 : host &+ outputAdvance.load(ordering: .relaxed)
        var done = 0
        while done < frames {
            let n = min(frames - done, Self.maxFrames)
            let h = base == 0 ? 0 : base &+ UInt64(Double(done) * tpfActual)
            renderBlock(host: h, frames: n, tpf: tpf, tpfActual: tpfActual, sampleRate: sampleRate,
                        l: l + done, r: r + done)
            done += n
        }
        // Messklick auf Frame 0 dieses Blocks; Bezug ist der unveränderte Ausgangszeitstempel.
        if host != 0, frames >= 4, probeStateA.load(ordering: .acquiring) == 1 {
            for f in 0..<4 { l[f] += 0.7; r[f] += 0.7 }
            probeOutHostA.store(host, ordering: .relaxed)
            probeStateA.store(2, ordering: .releasing)
        }
    }

    // MARK: Mithören: Füllstandsregelung (Codex T5)
    //
    // Eingangs- und Ausgangsgerät laufen auf eigenen Quarzen. Der Ring zwischen beiden würde
    // ohne Regelung langsam leer- oder volllaufen. Der Ausgang mittelt den Füllstand, merkt
    // sich nach dem Einschwingen einen Sollwert und gleicht Abweichungen jenseits einer
    // Hysterese um höchstens einen Frame je Block aus (einen verwerfen bzw. wiederholen).
    // Keine Interpolation: Mithören ist Kontrolle, nicht Aufnahme.

    private var monAverage: Double = -1
    private var monTarget: Double = -1
    private var monBlocks = 0
    static let monitorSettleBlocks = 200
    static let monitorHysteresisFrames: Double = 48

    private func resetMonitorControl() { monAverage = -1; monTarget = -1; monBlocks = 0 }

    /// Liest `n` Mithörframes nach `outMix`; Rückgabe: −1 verworfen, +1 wiederholt, 0 nichts.
    @inline(__always)
    private func readMonitor(_ n: Int) -> Int {
        let fill = Double(ring.fill / 2)
        if monAverage < 0 { monAverage = fill } else { monAverage += (fill - monAverage) * 0.02 }
        monBlocks += 1
        if monBlocks == Self.monitorSettleBlocks { monTarget = monAverage }
        var adjust = 0
        if monTarget >= 0, n > 1 {
            if monAverage > monTarget + Self.monitorHysteresisFrames { adjust = -1 }
            else if monAverage < monTarget - Self.monitorHysteresisFrames, fill > Double(n) { adjust = 1 }
        }
        switch adjust {
        case -1:                                   // Ring läuft voll: einen Frame verwerfen
            ring.read(into: outMix, frameCount: n + 1)
            outMix[2 * (n - 1)] = outMix[2 * n]; outMix[2 * (n - 1) + 1] = outMix[2 * n + 1]
            monAverage -= 1
        case 1:                                    // Ring läuft leer: letzten Frame wiederholen
            ring.read(into: outMix, frameCount: n - 1)
            outMix[2 * (n - 1)] = outMix[2 * (n - 2)]; outMix[2 * (n - 1) + 1] = outMix[2 * (n - 2) + 1]
            monAverage += 1
        default:
            ring.read(into: outMix, frameCount: n)
        }
        if adjust != 0 { monitorSlipsA.wrappingIncrement(ordering: .relaxed) }
        return adjust
    }

    private func renderBlock(host: UInt64, frames n: Int, tpf: Double, tpfActual: Double, sampleRate: Double,
                             l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) {
        if monitorFlag.load(ordering: .relaxed) {
            readMonitor(n)
            for f in 0..<n { l[f] = outMix[2 * f]; r[f] = outMix[2 * f + 1] }
        } else {
            if monAverage >= 0 { resetMonitorControl() }
            l.update(repeating: 0, count: n); r.update(repeating: 0, count: n)
        }
        guard tpf > 0, host != 0 else { playFrameA.store(-1, ordering: .relaxed); outLock.reset(); return }
        defer { hazardOut.store(0, ordering: .releasing) }
        guard let u = acquire(hazardOut) else { playFrameA.store(-1, ordering: .relaxed); outLock.reset(); return }
        defer { hazardRendered.store(0, ordering: .releasing) }
        let w = barClock.window()
        let since = activeSince.load(ordering: .relaxed)
        let until = activeUntil.load(ordering: .acquiring)
        let version = materialSerial.load(ordering: .relaxed)
        let last: Int = u._withUnsafeGuaranteedRef { st in
            // Material mit anderer Rate nicht falsch schnell abspielen (Gerätewechsel, H6).
            guard abs(st.sampleRate - sampleRate) < 1 else {
                rateMismatchA.store(true, ordering: .relaxed); return -1
            }
            // Taktlänge weicht ab (Tempo/Taktart): Vorberechnung, falls sie zu dieser Taktlänge
            // passt, sonst Zeitdehnung in Echtzeit.
            guard let (ratio, barNow) = stretchRatio(st, host: host, sampleRate: sampleRate) else {
                if prerenderedA.load(ordering: .relaxed) { prerenderedA.store(false, ordering: .relaxed) }
                xfadeDone = -1
                if stWasActive {
                    stWasActive = false; stCursor = -1; exactFade = Self.fadeFrames
                    stretchingA.store(false, ordering: .relaxed)
                }
                return renderExact(st, w: w, host: host, frames: n, tpf: tpf, tpfActual: tpfActual,
                                   since: since, until: until, l: l, r: r)
            }
            let pr = acquire(hazardRendered, from: renderedRaw)
            return pr.map { prU in prU._withUnsafeGuaranteedRef { p -> Int in
                guard p.prerenderSource == Self.raw(st), p.prerenderVersion == version,
                      abs(Double(p.barFrames) - barNow) <= 1, p.bars == st.bars,
                      abs(p.sampleRate - sampleRate) < 1 else {
                    return realtimeStretch(st, ratio: ratio, host: host, frames: n, tpfActual: tpfActual,
                                           since: since, until: until, l: l, r: r)
                }
                return renderPrerendered(p, st: st, ratio: ratio, w: w, host: host, frames: n, tpf: tpf,
                                         tpfActual: tpfActual, since: since, until: until, l: l, r: r)
            } } ?? realtimeStretch(st, ratio: ratio, host: host, frames: n, tpfActual: tpfActual,
                                   since: since, until: until, l: l, r: r)
        }
        playFrameA.store(last, ordering: .relaxed)
    }

    /// Samplegenauer Weg: Index aus Taktanker und Abstand (Material oder Vorberechnung).
    @inline(__always)
    private func renderExact(_ st: AudioLoopStorage, w: BarClock.Window, host: UInt64, frames n: Int,
                             tpf: Double, tpfActual: Double, since: UInt64, until: UInt64,
                             xfade: (at: Int, done: Int)? = nil,
                             l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) -> Int {
        let raw = Self.raw(st)
        if raw != exactSource { exactSource = raw; outLock.reset() }
        let bars = st.bars, bf = st.barFrames, total = st.frames
        var last = -1
        for f in 0..<n {
            // Host-Zeit dieses Frames nach dem tatsächlichen Gerätetakt (T5).
            let h = host &+ UInt64(Double(f) * tpfActual)
            guard h >= since, h < until else { outLock.reset(); continue }
            let a = w.anchor(at: h)
            guard a.isValid else { outLock.reset(); continue }
            let eF = Double(h &- a.host) / tpf
            guard eF < Double(bf) else { outLock.reset(); continue }
            let pos = outLock.next(ideal: Double((a.bar % bars) * bf) + eF, total: total).pos
            if let x = xfade {                  // Einblenden gegen die ausblendende Echtzeitdehnung
                guard f >= x.at else { continue }
                let g = min(1, Float(x.done + f - x.at) / Float(Self.fadeFrames))
                l[f] += st.left[pos] * g; r[f] += st.right[pos] * g
            } else if exactFade > 0 {           // Übergang aus der Zeitdehnung
                let g = Float(Self.fadeFrames - exactFade) / Float(Self.fadeFrames); exactFade -= 1
                l[f] += st.left[pos] * g; r[f] += st.right[pos] * g
            } else {
                l[f] += st.left[pos]; r[f] += st.right[pos]
            }
            last = pos
        }
        if outLock.slips != 0 {
            driftSlipsA.wrappingIncrement(by: outLock.slips, ordering: .relaxed); outLock.slips = 0
        }
        return last
    }

    @inline(__always)
    private func realtimeStretch(_ st: AudioLoopStorage, ratio: Double, host: UInt64, frames n: Int,
                                 tpfActual: Double, since: UInt64, until: UInt64,
                                 l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) -> Int {
        if prerenderedA.load(ordering: .relaxed) { prerenderedA.store(false, ordering: .relaxed) }
        exactSource = 0
        xfadeDone = -1
        return renderStretched(st, ratio: ratio, host: host, frames: n, tpfActual: tpfActual,
                               since: since, until: until, l: l, r: r)
    }

    /// Vorberechnung abspielen (samplegenau). Lief bis eben die Echtzeitdehnung, wird erst auf
    /// der nächsten Taktgrenze getauscht (auch auf Frame 0 eines Blocks, Codex R15-03): ab dort
    /// blenden beide Wege gegenläufig über 128 Frames, auch über Blockgrenzen (R15-01).
    private func renderPrerendered(_ p: AudioLoopStorage, st: AudioLoopStorage, ratio: Double, w: BarClock.Window,
                                   host: UInt64, frames n: Int, tpf: Double, tpfActual: Double,
                                   since: UInt64, until: UInt64,
                                   l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) -> Int {
        let xf: (at: Int, done: Int)
        if xfadeDone >= 0 {
            xf = (0, xfadeDone)                               // Überblendung läuft weiter
        } else if stWasActive {
            // Jüngster Anker bis zum letzten Frame; liegt er in diesem Block, ist er die Grenze.
            let end = host &+ UInt64(Double(n) * tpfActual)
            let a = w.anchor(at: end &- 1)
            guard a.isValid, a.host >= host, a.host < end else {
                return renderStretched(st, ratio: ratio, host: host, frames: n, tpfActual: tpfActual,
                                       since: since, until: until, l: l, r: r)
            }
            let at = min(n - 1, max(0, Int((Double(a.host &- host) / tpfActual).rounded(.up))))
            xf = (at, 0)
            swapHostA.store(a.host, ordering: .relaxed)
        } else {
            if !prerenderedA.load(ordering: .relaxed) { prerenderedA.store(true, ordering: .relaxed) }
            return renderExact(p, w: w, host: host, frames: n, tpf: tpf, tpfActual: tpfActual,
                               since: since, until: until, l: l, r: r)
        }
        _ = renderStretched(st, ratio: ratio, host: host, frames: n, tpfActual: tpfActual,
                            since: since, until: until, fadeOutAt: xf.at, fadeOutDone: xf.done, l: l, r: r)
        let last = renderExact(p, w: w, host: host, frames: n, tpf: tpf, tpfActual: tpfActual,
                               since: since, until: until, xfade: xf, l: l, r: r)
        let progressed = xf.done + (n - xf.at)
        if progressed >= Self.fadeFrames {
            xfadeDone = -1; exactFade = 0
            stWasActive = false; stCursor = -1
            stretchingA.store(false, ordering: .relaxed)
            if !prerenderedA.load(ordering: .relaxed) { prerenderedA.store(true, ordering: .relaxed) }
        } else {
            xfadeDone = progressed
        }
        return last
    }

    // MARK: Zeitdehnung (v1.18.13)

    /// Verhältnis Material- zu Ausgabeframes, wenn ein Takt jetzt anders lang ist als im
    /// Material; nil = samplegenauer Weg (gleiche Länge, Transport steht, kein Stretcher).
    @inline(__always)
    private func stretchRatio(_ st: AudioLoopStorage, host: UInt64, sampleRate: Double) -> (Double, Double)? {
        guard let m = musical, stretcher != nil else { return nil }
        let s = m.state(at: host)
        guard s.moving, s.tempo > 0 else { return nil }
        let barNow = s.quartersPerBar * 60 / s.tempo * sampleRate     // Taktart des Abschnitts (v1.18.23)
        guard abs(barNow - Double(st.barFrames)) > 0.5 else { return nil }
        let ratio = Double(st.barFrames) / barNow
        return Self.stretchRatioRange.contains(ratio) ? (ratio, barNow) : nil
    }

    /// Taktlänge in Frames, die eine Vorberechnung für Tempo `bpm` und `quartersPerBar` hat;
    /// nil, wenn keine Dehnung nötig oder sie außerhalb des Bereichs liegt (Main).
    static func prerenderBarFrames(_ st: AudioLoopStorage, bpm: Double, quartersPerBar: Double) -> Int? {
        guard bpm > 0, quartersPerBar > 0 else { return nil }
        let barNow = quartersPerBar * 60 / bpm * st.sampleRate
        guard abs(barNow - Double(st.barFrames)) > 0.5,
              stretchRatioRange.contains(Double(st.barFrames) / barNow) else { return nil }
        return Int(barNow.rounded())
    }

    /// Gedehnte Kopie von `st` mit `barFrames` je Takt (Hintergrund, allokiert). nil bei
    /// ungültigen Werten oder Budget.
    static func makePrerender(_ st: AudioLoopStorage, barFrames: Int) -> AudioLoopStorage? {
        guard barFrames > 0 else { return nil }
        let outFrames = barFrames * st.bars
        // Spitzenbedarf außer dem Ergebnis (Codex R15-02): Swift-Arbeitspuffer 2 × 4 B je Frame
        // und C++-Dreifachpuffer 2 Kanäle × 3 × 4 B je Frame, je Quelle und Ziel (ohne temporäre
        // Kopiervorlagen, s. LoopStretch.cpp); dazu die Bibliothek: STFT-Puffer je Kanal in
        // Blockgröße (120 ms). Gemessen (phys_footprint, 120-s-Loop, v1.18.19): Spitze 432,0 MiB
        // bei 32 B × Frames + Ergebnis + 8 MB = 431,9 MiB — Reserve deshalb 16 MB.
        let scratch = 32 * (st.frames + outFrames) + (16 << 20)
        guard AudioLoopStorage.reserve(bytes: scratch) else { return nil }
        defer { AudioLoopStorage.release(bytes: scratch) }
        guard AudioLoopStorage.fits(frames: outFrames),
              let out = AudioLoopStorage(bars: st.bars, sampleRate: st.sampleRate, bpm: st.recordedBPM,
                                         barFrames: barFrames) else { return nil }
        let inL = UnsafeMutablePointer<Float>.allocate(capacity: st.frames)
        let inR = UnsafeMutablePointer<Float>.allocate(capacity: st.frames)
        let oL = UnsafeMutablePointer<Float>.allocate(capacity: out.frames)
        let oR = UnsafeMutablePointer<Float>.allocate(capacity: out.frames)
        defer { inL.deallocate(); inR.deallocate(); oL.deallocate(); oR.deallocate() }
        st.left.read(into: inL, from: 0, count: st.frames); st.right.read(into: inR, from: 0, count: st.frames)
        var ins: [UnsafePointer<Float>?] = [UnsafePointer(inL), UnsafePointer(inR)]
        var outs: [UnsafeMutablePointer<Float>?] = [oL, oR]
        let ok = ins.withUnsafeMutableBufferPointer { i in outs.withUnsafeMutableBufferPointer { o in
            fof_stretch_render_loop(2, st.sampleRate, i.baseAddress, Int32(st.frames), o.baseAddress, Int32(out.frames))
        } }
        guard ok == 1 else { return nil }
        out.left.write(from: oL, at: 0, count: out.frames); out.right.write(from: oR, at: 0, count: out.frames)
        return out
    }

    /// Materialposition (Frames, 0 ..< frames) zur Host-Zeit `h`; nil, wenn der Transport steht.
    /// Absoluter Takt plus Phase im Takt des Abschnitts (v1.18.23, Codex KT-03) — nicht globale
    /// Viertel geteilt durch die jetzige Taktlänge, das liefe bei wechselnder Taktart falsch.
    @inline(__always)
    private func materialPosition(_ st: AudioLoopStorage, _ m: HostSync, at h: UInt64) -> Double? {
        let s = m.state(at: h)
        guard s.moving else { return nil }
        let phase = min(1, max(0, (s.beat - s.barStart) / s.quartersPerBar))
        let barIdx = ((s.bar % st.bars) + st.bars) % st.bars
        let p = (Double(barIdx) + phase) * Double(st.barFrames)
        return min(p, Double(st.frames) - 1e-6)
    }

    /// Kopiert `count` Materialframes ab `start` (mit Umlauf) in den Eingangspuffer.
    @inline(__always)
    private func gather(_ st: AudioLoopStorage, from start: Int, count: Int) {
        let total = st.frames
        var src = start, i = 0
        while i < count {
            let run = min(count - i, total - src)
            for k in 0..<run { stInL[i + k] = st.left[src + k]; stInR[i + k] = st.right[src + k] }
            i += run; src = 0
        }
    }

    /// Ein Block über den Stretcher. Rückgabe: Materialposition am Blockbeginn (Anzeige).
    private func renderStretched(_ st: AudioLoopStorage, ratio: Double, host: UInt64, frames n: Int,
                                 tpfActual: Double, since: UInt64, until: UInt64,
                                 fadeOutAt: Int = .max, fadeOutDone: Int = 0,
                                 l: UnsafeMutablePointer<Float>, r: UnsafeMutablePointer<Float>) -> Int {
        guard let m = musical, let s = stretcher else { return -1 }
        let total = st.frames
        let end = host &+ UInt64(Double(n) * tpfActual)
        // Spur stumm bzw. außerhalb ihres Fensters: still, beim Wiedereinsetzen neu aufsetzen.
        guard end > since, host < until, total > 0 else { stCursor = -1; stWasActive = false; return -1 }
        guard let p0 = materialPosition(st, m, at: host),
              let p1 = materialPosition(st, m, at: end) else {
            stCursor = -1; stWasActive = false; return -1
        }
        // Ausgabe zur Zeit t zeigt das Material bei Cursor(t) − Latenz (gemessen, v1.18.13).
        let latency = Double(fof_stretch_input_latency(s)) + Double(fof_stretch_output_latency(s)) * ratio
        let totalD = Double(total)
        func ahead(_ target: Double, of cursor: Int) -> Double {
            var d = (target - Double(cursor)).truncatingRemainder(dividingBy: totalD)
            if d > totalD / 2 { d -= totalD } else if d <= -totalD / 2 { d += totalD }
            return d
        }
        let target = p1 + latency
        let maxFeed = Self.stretchInCapacity - Self.stretchBlock
        var k = -1
        if stCursor >= 0, stCursor < total {
            let d = ahead(target, of: stCursor).rounded()
            if d >= 0, d <= Double(min(maxFeed, 4 * n + 256)) { k = Int(d) }
        }
        if k < 0 {
            // Neu aufsetzen (Start, Sprung, neues Material): die Ausgabe beginnt bei p0.
            let len = min(Int(fof_stretch_output_seek_length(s, ratio)), maxFeed)
            let start = min(total - 1, Int(p0))
            gather(st, from: start, count: len)
            fof_stretch_output_seek(s, stInPtrs, Int32(len))
            stCursor = (start + len) % total
            stretchSeeksA.wrappingIncrement(ordering: .relaxed)
            stFade = Self.fadeFrames
            k = max(0, min(maxFeed, Int(ahead(target, of: stCursor).rounded())))
        }
        gather(st, from: stCursor, count: k)
        fof_stretch_process(s, stInPtrs, Int32(k), stOutPtrs, Int32(n))
        stCursor = (stCursor + k) % total
        for f in 0..<n {
            let h = host &+ UInt64(Double(f) * tpfActual)
            guard h >= since, h < until else { continue }
            var g: Float = 1
            if stFade > 0 { g = Float(Self.fadeFrames - stFade) / Float(Self.fadeFrames); stFade -= 1 }
            // Ausblenden beim Tausch auf die Vorberechnung: Gegenstück zu `renderExact(xfade:)`.
            if f >= fadeOutAt {
                g *= max(0, 1 - Float(fadeOutDone + f - fadeOutAt) / Float(Self.fadeFrames))
            }
            l[f] += stOutL[f] * g; r[f] += stOutR[f] * g
        }
        if !stWasActive { stWasActive = true; stretchingA.store(true, ordering: .relaxed) }
        outLock.reset()
        return Int(p0)
    }

    // MARK: - Audio: Eingang

    /// Nimmt einen Eingangsblock entgegen (`channels` = Kanalzeiger des Geräts, nicht
    /// verschachtelt, beliebige Länge). `host` = Host-Zeit des ersten Frames. RT-sicher.
    func consumeInput(host: UInt64, frames: Int, sampleRate: Double, rateScalar: Double = 1,
                      channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, channelCount: Int) {
        let occ = occupancy.load(ordering: .acquiring)
        if occ != seenOccupancyIn {
            seenOccupancyIn = occ
            rtState = .idle; lastBar = -1; gate.reset(); inLock.reset()
        }
        inTicksPerFrame = Self.ticksPerFrame(max(sampleRate, 1), rateScalar: rateScalar)
        let tpf = inTicksPerFrame
        if probeStateA.load(ordering: .acquiring) == 2 {
            detectProbe(host: host, frames: frames, tpf: tpf, channels: channels, channelCount: channelCount)
        }
        var done = 0
        while done < frames {
            let n = min(frames - done, Self.maxFrames)
            inputBlock(host: host &+ UInt64(Double(done) * tpf), frames: n, offset: done,
                       sampleRate: sampleRate, channels: channels, channelCount: channelCount)
            done += n
        }
    }

    /// Sucht den Messklick (erster Frame über der Schwelle nach dem Senden).
    private func detectProbe(host: UInt64, frames: Int, tpf: Double,
                             channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, channelCount: Int) {
        let ch = inputChannelA.load(ordering: .relaxed)
        guard ch < channelCount, let src = channels[ch] else { return }
        let sent = probeOutHostA.load(ordering: .relaxed)
        for f in 0..<frames where abs(src[f]) > Self.probeThreshold {
            let h = host &+ UInt64(Double(f) * tpf)
            guard h > sent else { continue }
            probeInHostA.store(h, ordering: .relaxed)
            probeStateA.store(3, ordering: .releasing)
            return
        }
    }

    private func inputBlock(host: UInt64, frames n: Int, offset: Int, sampleRate: Double,
                            channels: UnsafeMutablePointer<UnsafeMutablePointer<Float>?>, channelCount: Int) {
        let req = recordRequested.load(ordering: .acquiring)
        let monitor = monitorFlag.load(ordering: .relaxed)
        // Zustand nach Wunsch fortschreiben (Beginn/Ende selbst erst an Takt-/Loopgrenzen).
        switch (rtState, req) {
        case (.idle, true):      rtState = .armed; lastBar = -1
        case (.armed, false):    rtState = .idle
        case (.recording, false): rtState = .finishing
        case (.finishing, true): rtState = .recording
        default: break
        }
        defer { stateA.store(rtState.rawValue, ordering: .releasing) }
        guard monitor || rtState != .idle else { return }

        // Kanäle wählen: Mono → beide Seiten gleich.
        let ch = inputChannelA.load(ordering: .relaxed)
        guard ch < channelCount, let src = channels[ch] else { return }
        inL.update(from: src + offset, count: n)
        let stereo = stereoFlag.load(ordering: .relaxed) && ch + 1 < channelCount && channels[ch + 1] != nil
        if stereo { inR.update(from: channels[ch + 1]! + offset, count: n) }
        gate.process(inL, stereo ? inR : inL, frames: n, sampleRate: sampleRate, inputGate.values())
        if !stereo { inR.update(from: inL, count: n) }

        var peak: Float = 0
        for f in 0..<n { peak = max(peak, abs(inL[f]), abs(inR[f])) }
        if peak > Float(bitPattern: inputPeakBits.load(ordering: .relaxed)) {
            inputPeakBits.store(peak.bitPattern, ordering: .relaxed)
        }
        // Belegung inzwischen gewechselt (Main): nichts mehr in Ring oder Speicher.
        guard occupancy.load(ordering: .acquiring) == seenOccupancyIn else { return }
        if monitor {
            for f in 0..<n { inMix[2 * f] = inL[f]; inMix[2 * f + 1] = inR[f] }
            ring.write(inMix, frameCount: n)
        }
        guard rtState != .idle else { return }
        record(host: host, frames: n, sampleRate: sampleRate)
    }

    private func record(host: UInt64, frames n: Int, sampleRate: Double) {
        #if DEBUG
        if let pause = _inputPausePoint { _inputPausePoint = nil; pause() }
        #endif
        defer { hazardIn.store(0, ordering: .releasing) }
        guard let u = acquire(hazardIn) else { rtState = .idle; return }
        u._withUnsafeGuaranteedRef { st in
            // Speicher einer anderen Belegung (Main hat zwischen Epochen-Lesen und Erwerb
            // gewechselt): nicht schreiben; der nächste Block setzt den Zustand zurück.
            guard st.boundOccupancy.load(ordering: .relaxed) == seenOccupancyIn else {
                rtState = .idle; lastBar = -1; return
            }
            record(st, host: host, frames: n, sampleRate: sampleRate)
        }
    }

    private func record(_ st: AudioLoopStorage, host: UInt64, frames n: Int, sampleRate: Double) {
        guard abs(sampleRate - st.sampleRate) < 1 else {
            rateMismatchA.store(true, ordering: .relaxed); rtState = .idle; return
        }
        let tpf = Self.hostTicksPerSecond / sampleRate        // Materialraster (nominal)
        let tpfActual = inTicksPerFrame > 0 ? inTicksPerFrame : tpf   // Gerätetakt (T5)
        let lat = latencyTicks.load(ordering: .relaxed)
        let w = barClock.window()
        let blockStart = UInt64(max(0, Int64(bitPattern: host) - Int64(lat)))
        if w.isStopped(at: blockStart) {
            // Transport steht (oder Sitzungsende erreicht): laufende Aufnahme endet hier.
            if rtState == .recording || rtState == .finishing { finishRecording() }
            lastBar = -1; inLock.reset()
            return
        }
        let bars = st.bars, bf = st.barFrames, total = st.frames, cf = AudioLoopStorage.chunkFrames
        // Vor jedem möglichen Schreiben sichtbar machen (Vorberechnung liest nebenher, R15-04).
        writeBeginsA.wrappingIncrement(ordering: .sequentiallyConsistent)
        // Kopierbudget je Block: so viele Abschnitte, wie ein zusammenhängender Block berühren
        // kann, plus Reserve für einen Takt-/Loopsprung. Darüber wird ausgelassen, nicht kopiert.
        var copyBudget = n / cf + 3
        var wrote = false
        for f in 0..<n {
            let hRaw = Int64(bitPattern: host &+ UInt64(Double(f) * tpfActual)) - Int64(lat)
            guard hRaw > 0 else { continue }
            let h = UInt64(hRaw)
            let a = w.anchor(at: h)
            guard a.isValid else { inLock.reset(); continue }
            let crossed = lastBar >= 0 && a.bar != lastBar
            lastBar = a.bar
            let eF = Double(h &- a.host) / tpf
            guard eF < Double(bf) else { inLock.reset(); continue }
            // Fortlaufender Index mit Hysterese (T5): Drift wird als einzelner Schritt
            // ausgeglichen — ein wiederholter Index wird nicht doppelt addiert, ein
            // übersprungener mit demselben Sample gefüllt.
            let step = inLock.next(ideal: Double((a.bar % bars) * bf) + eF, total: total)
            let pos = step.pos
            switch rtState {
            case .idle:
                return
            case .armed:
                guard crossed else { continue }                // Beginn auf der nächsten Taktgrenze
                rtState = .recording; fadeCount = 0
                undoAvailableA.store(false, ordering: .releasing)   // die Undo-Kopie wird jetzt überschrieben
                beginPass()
            case .recording, .finishing:
                if crossed, a.bar % bars == 0 {                 // Loop beginnt von vorn
                    if rtState == .finishing { finishRecording(); return }
                    beginPass()
                }
            }
            // Undo-Kopie: Abschnitt vor dem ersten Schreiben in diesem Durchlauf sichern.
            let chunk = pos / cf
            if st.chunkPass(chunk) != passEpoch {
                guard copyBudget > 0 else {
                    skippedFramesA.wrappingIncrement(ordering: .relaxed); continue
                }
                copyBudget -= 1
                let a0 = chunk * cf
                let range = a0..<min(total, a0 + cf)
                st.undoLeft.copy(from: st.left, range: range)
                st.undoRight.copy(from: st.right, range: range)
                st.setChunkPass(chunk, passEpoch)
            }
            if step.kind == .repeated { continue }             // Index schon beschrieben
            var g: Float = 1
            if fadeCount < Self.fadeFrames { g = Float(fadeCount) / Float(Self.fadeFrames); fadeCount += 1 }
            if rtState == .finishing {
                let toEnd = total - pos
                if toEnd < Self.fadeFrames { g *= Float(toEnd) / Float(Self.fadeFrames) }
            }
            st.left[pos] += inL[f] * g
            st.right[pos] += inR[f] * g
            if step.kind == .skipped {
                let gap = pos == 0 ? total - 1 : pos - 1
                if st.chunkPass(gap / cf) == passEpoch {          // nur gesicherte Abschnitte
                    st.left[gap] += inL[f] * g
                    st.right[gap] += inR[f] * g
                }
            }
            wrote = true
        }
        if inLock.slips != 0 {
            driftSlipsA.wrappingIncrement(by: inLock.slips, ordering: .relaxed); inLock.slips = 0
        }
        if wrote {
            passWrote = true
            if !hasMaterialA.load(ordering: .relaxed) { hasMaterialA.store(true, ordering: .relaxed) }
            materialSerial.wrappingIncrement(ordering: .relaxed)
        }
    }

    private func beginPass() {
        passEpoch &+= 1
        if passEpoch == 0 { passEpoch = 1 }   // 0 = „nie gesichert"
        passWrote = false
    }

    private func finishRecording() {
        undoPassA.store(passEpoch, ordering: .relaxed)
        undoAvailableA.store(passWrote, ordering: .releasing)
        // Wunsch zurücksetzen: sonst würde der nächste Block sofort wieder scharf schalten.
        recordRequested.store(false, ordering: .releasing)
        rtState = .idle
        lastBar = -1
        inLock.reset()
    }

    #if DEBUG
    /// Test: läuft einmalig im Eingangs-Render zwischen Belegungsprüfung und Speichererwerb.
    var _inputPausePoint: (() -> Void)?
    /// Hält den Hazard des Ausgangs-Lesers während `body` (Test der Freigabe).
    func _withOutputHazardHeld(_ body: () -> Void) {
        _ = acquire(hazardOut)
        body()
        hazardOut.store(0, ordering: .releasing)
    }
    var _retiredCount: Int { retired.count }
    var _activeWindow: (UInt64, UInt64) { (activeSince.load(ordering: .relaxed), activeUntil.load(ordering: .relaxed)) }
    #endif
}

// MARK: - LockedIndex (v1.15.2, Codex T5)

/// Fortlaufender Materialindex, der der Host-Zeit mit Hysterese folgt. Normal: +1 je Frame.
/// Weicht die aus der Host-Zeit gerechnete Idealposition um mindestens einen Frame ab
/// (Gerätequarz ≠ Hostuhr), macht der Index genau einen Ausgleichsschritt: einen Frame
/// überspringen oder wiederholen. Größere Sprünge (neuer Anker, Lücke) setzen neu auf.
/// Das Totband von ±1 Frame verhindert Hin-und-her-Springen durch Zeitstempel-Jitter.
struct LockedIndex {
    enum Kind { case normal, skipped, repeated, resync }
    private(set) var pos = -1
    /// Ausgleichsschritte seit dem letzten Abholen.
    var slips = 0

    mutating func reset() { pos = -1 }

    @inline(__always)
    mutating func next(ideal: Double, total: Int) -> (pos: Int, kind: Kind) {
        guard total > 0 else { return (0, .resync) }
        let floorIdeal = Int(ideal) % total
        guard pos >= 0 else { pos = floorIdeal; return (pos, .resync) }
        let candidate = pos + 1 == total ? 0 : pos + 1
        var d = ideal - Double(candidate)
        let half = Double(total) / 2
        if d >= half { d -= Double(total) } else if d < -half { d += Double(total) }
        if d >= 1 && d < 2 {
            pos = candidate + 1 == total ? 0 : candidate + 1
            slips += 1
            return (pos, .skipped)
        }
        if d < -1 && d >= -2 {
            slips += 1
            return (pos, .repeated)                    // Index bleibt
        }
        if d >= 2 || d < -2 { pos = floorIdeal; return (pos, .resync) }
        pos = candidate
        return (pos, .normal)
    }
}
