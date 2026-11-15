import Foundation
import AVFoundation
import CoreAudio

// MARK: - AudioLoopController (v1.18.4, Codex A17-10 — Zerlegung des Racks, Schritt 4)
//
// Einziger Besitzer der Audio-Loop-Steuerung auf Main: Block der Loop-Kerne (einer je Slot,
// für Tick-, Eingangs- und Ausgangs-Render über den Slot-Index), Taktanker, Material
// (`AudioLoopAssets`), Eingangs-Engine, Anzeigen samt Abfrage, Latenzmessung. Audioknoten
// (Loop-Quelle, Gates, Fader) gehören weiter dem Rack; es erfährt über `AudioLoopHost`, wann
// ein Kanal neu eingestellt wurde.
//
// Das Rack meldet Belegung und Freigabe jedes Slots (`occupy`/`vacate`), auch für Kanäle
// ohne Loop: der Kern folgt der Belegungsepoche der Kanal-Warteschlange. Nur Main.

/// Was die Loop-Steuerung vom Rack liest und ihm meldet.
protocol AudioLoopHost: AnyObject {
    /// Audio-Loop-Kanäle in Kanalreihenfolge.
    var loopChannels: [(id: UUID, settings: AudioLoopSettings)] { get }
    /// Abtastrate des Ausgangs; nil, solange kein Ausgabegerät bekannt ist.
    var loopSampleRate: Double? { get }
    /// Die Audio-Engine läuft.
    var loopOutputRunning: Bool { get }
    /// Latenz + Sicherheitsabstand des Ausgabegeräts, an dem die Engine hängt (Frames).
    var loopOutputLatencyFrames: Int { get }
    /// Kern eines Kanals neu eingestellt: Gates setzen, Routenlatenz neu bestimmen.
    func loopConfigured(_ id: UUID, _ settings: AudioLoopSettings)
    /// Neue Einstellungen aus der Latenzmessung übernehmen (Kanaldaten gehören dem Rack).
    func loopSettingsMeasured(_ settings: AudioLoopSettings, for id: UUID)
    /// Material oder Aufnahmezustand hat das Projekt verändert.
    func loopProjectChanged()
}

final class AudioLoopController {

    weak var host: AudioLoopHost?

    /// Taktanker vom Tick-Thread für die Loop-Kerne.
    let barClock = BarClock()
    /// Musikalische Position (Tempo, Beat, Taktart) — Zeitdehnung der Loops (v1.18.13) und
    /// Host-Takt der Plug-ins (`InstrumentRack.hostSync`).
    let hostSync = HostSync()
    /// Fester Block von Loop-Kernen, einer je Slot (Lebensdauer der Steuerung).
    let cores: UnsafeMutablePointer<Unmanaged<AudioLoopCore>>
    private let count: Int
    func core(_ slot: Int) -> AudioLoopCore { cores[slot].takeUnretainedValue() }

    /// Material samt Kodierung und Wellenform (Codex M6).
    let assets = AudioLoopAssets()
    private(set) lazy var inputEngine = AudioInputEngine(cores: cores, count: count)
    private var inputIdleTimer: Timer?

    /// Slot je Audio-Loop-Kanal.
    private var slots: [UUID: Int] = [:]
    /// Anzeigezustand je Kanal (Codex M5): die Zeile beobachtet nur ihren Kanal.
    private var displays: [UUID: AudioLoopDisplay] = [:]
    /// Abfrage des Kernzustands (10 Hz) — läuft nur, solange ein Loop aktiv ist.
    private var statusTimer: Timer?
    /// Transport läuft (von der Engine gemeldet).
    private var transportRunning = false
    private var probing: Set<UUID> = []
    /// Geräte von Aufnahme und Wiedergabe (Anzeige, v1.18.7). Der Ist-Zustand kommt über
    /// `devices.probe` (setzt das Rack); abgeglichen wird bei jedem Start/Stop/Wechsel.
    let devices = AudioDeviceState()

    static let probeTimeout: TimeInterval = 3
    private static let hostTicksPerSecond: Double = {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        return 1_000_000_000.0 * Double(tb.denom) / Double(tb.numer)
    }()

    init(count: Int) {
        self.count = count
        cores = .allocate(capacity: count)
        let clock = barClock, sync = hostSync
        for i in 0..<count {
            (cores + i).initialize(to: .passRetained(AudioLoopCore(barClock: clock, musical: sync)))
        }
    }

    deinit {
        statusTimer?.invalidate()
        inputIdleTimer?.invalidate()
        inputEngine.stop()
        for i in 0..<count { cores[i].release() }
        cores.deinitialize(count: count); cores.deallocate()
    }

    // MARK: Belegung

    /// Kern eines Audio-Loop-Kanals (nil bei anderen Kanälen).
    func core(for id: UUID?) -> AudioLoopCore? {
        guard let id, let slot = slots[id] else { return nil }
        return core(slot)
    }

    func display(_ id: UUID?) -> AudioLoopDisplay? { id.flatMap { displays[$0] } }

    /// Slot belegt (jeder Kanal): Kern folgt der Belegungsepoche; ein Loop-Kanal bekommt
    /// Anzeige und real belegte Puffer (Main).
    func occupy(slot: Int, epoch: UInt32, loop: (id: UUID, settings: AudioLoopSettings)?) {
        let c = core(slot)
        if loop != nil { c.prefault() }
        c.beginOccupancy(epoch)
        guard let loop else { return }
        slots[loop.id] = slot
        displays[loop.id] = AudioLoopDisplay(channelID: loop.id, core: c, settings: loop.settings)
    }

    /// Slot freigegeben: alte Tick-Meldungen und Audio-Zustände entwerten, Material lösen.
    func vacate(_ id: UUID, slot: Int, epoch: UInt32) {
        let c = core(slot)
        c.beginOccupancy(epoch)
        c.bind(nil)
        c.configure(AudioLoopSettings(), latencyFrames: 0, sampleRate: 0)
        assets.remove(id)
        displays[id] = nil
        slots[id] = nil
    }

    /// Material eines Kanals auf eine Kopie übertragen (Kanal duplizieren).
    func copyMaterial(from src: UUID, to dst: UUID) {
        guard let c = core(for: dst), let st0 = assets[src],
              AudioLoopStorage.fits(frames: st0.frames), let st = st0.copy() else { return }
        assets.set(st, for: dst)
        c.bind(st)
        kickDisplays()
    }

    /// Entnommenes Material wieder einsetzen (Redo „Audio-Loop-Spur hinzufügen").
    func put(_ storage: AudioLoopStorage?, for id: UUID) {
        if let st = storage, let c = core(for: id) {
            assets.set(st, for: id)
            c.bind(st)
        }
        kickDisplays()
    }

    // MARK: Einstellungen

    /// Einstellungen in die Anzeige übernehmen (Kanaldaten haben sich geändert).
    func settingsChanged(_ id: UUID, _ s: AudioLoopSettings) { displays[id]?._setSettings(s) }

    /// Überträgt die Einstellungen auf den Kern; das Rack setzt danach die Gates.
    func configure(_ id: UUID, _ s: AudioLoopSettings) {
        guard let c = core(for: id) else { return }
        c.configure(s, latencyFrames: automaticLatencyFrames(), sampleRate: host?.loopSampleRate ?? 0)
        host?.loopConfigured(id, s)
    }

    private func configureAll() {
        for c in host?.loopChannels ?? [] { configure(c.id, c.settings) }
    }

    private func automaticLatencyFrames() -> Int {
        (inputEngine.isRunning ? inputEngine.latencyFrames : 0) + (host?.loopOutputLatencyFrames ?? 0)
    }

    private func settings(_ id: UUID) -> AudioLoopSettings? {
        host?.loopChannels.first { $0.id == id }?.settings
    }

    // MARK: Aufnahme und Material

    /// Scharfschalten (true) oder Aufnahme beenden (false). Legt beim ersten Mal den Speicher
    /// an (Länge aus Takten, Tempo `bpm` und Abtastrate des Ausgangs) und startet den Eingang.
    func setRecording(_ on: Bool, for id: UUID, bpm: Double, quartersPerBar: Double = 4) {
        guard let settings = settings(id), let core = core(for: id) else { return }
        if on {
            let sr = host?.loopSampleRate ?? 0
            guard sr > 0 else { setError(id, "noOutput"); return }
            let current = assets[id]
            // Taktlänge aus Tempo und Taktart (v1.18.12).
            let barFrames = AudioLoopStorage.barFrames(bpm: bpm, sampleRate: sr, quarters: quartersPerBar)
            // Overdub auf gedehntes Material würde zeitversetzt landen (v1.18.13): abweisen.
            if let current, core.hasMaterial, abs(current.barFrames - barFrames) > 1 {
                setError(id, "stretched"); return
            }
            if current == nil || (!core.hasMaterial && (current!.bars != settings.bars
                                                         || current!.sampleRate != sr
                                                         || current!.barFrames != barFrames)) {
                // Budget vor der Allokation (Codex R5).
                let frames = barFrames * settings.bars
                guard AudioLoopStorage.fits(frames: frames) else { setError(id, "budget"); return }
                guard let st = AudioLoopStorage(bars: settings.bars, sampleRate: sr, bpm: bpm,
                                                barFrames: barFrames) else {
                    setError(id, "tooLong"); return
                }
                assets.set(st, for: id)
                core.bind(st)
            }
            setError(id, nil)
            core.setRecording(true)
            host?.loopProjectChanged()
        } else {
            core.setRecording(false)
        }
        updateInputNeeded()
        kickDisplays()
    }

    /// Undo/Redo des letzten Durchlaufs: Austausch gegen einen Speicher mit vertauschtem
    /// Durchlauf (v1.15.1) — Main schreibt nie in veröffentlichtes PCM. Rückgabe: (vorher,
    /// nachher) für den versionsgebundenen Dokument-Undo (v1.15.2, Codex M2).
    func undo(_ id: UUID) -> (old: AudioLoopStorage, new: AudioLoopStorage)? {
        guard let core = core(for: id), let cur = assets[id] else { return nil }
        // Die Undo-Kopie ist eine volle Kopie: vorher ins Budget (Codex R5).
        guard AudioLoopStorage.fits(frames: cur.frames) else { setError(id, "budget"); return nil }
        guard let st = core.undoSwapped() else { return nil }
        assets.set(st, for: id)
        core.bind(st, keepUndo: true)
        setError(id, nil)
        materialChanged()
        return (cur, st)
    }

    /// Löscht das Material (nur im Ruhezustand): Speicher lösen, nicht überschreiben.
    func clear(_ id: UUID) -> AudioLoopStorage? {
        guard let core = core(for: id), core.isQuiescent, let old = assets[id] else { return nil }
        assets.set(nil, for: id)
        core.bind(nil)
        materialChanged()
        return old
    }

    /// Versionsgebundener Tausch (Dokument-Undo, Codex M2): nur wenn der Kanal noch genau
    /// `expected` trägt und der Kern ruht.
    func exchange(_ id: UUID, expected: AudioLoopStorage?, with new: AudioLoopStorage?, keepUndo: Bool) -> Bool {
        guard let core = core(for: id), core.isQuiescent, assets[id] === expected else { return false }
        assets.set(new, for: id)
        core.bind(new, keepUndo: keepUndo)
        materialChanged()
        return true
    }

    private func materialChanged() {
        schedulePrerender()
        preencodeIdle()
        kickDisplays()
        host?.loopProjectChanged()
    }

    /// Material, dessen Abtastrate nicht mehr zum Ausgang passt, umrechnen (Codex H6). Nur im
    /// Ruhezustand des Kerns; während einer Aufnahme bleibt es stumm und wird beim nächsten
    /// Umbau umgerechnet.
    func resample() {
        guard let sr = host?.loopSampleRate, sr > 0 else { return }
        let replaced = assets.resample(to: sr) { [weak self] id in self?.core(for: id)?.isQuiescent ?? false }
        for (id, st) in replaced { core(for: id)?.bind(st) }
        if !replaced.isEmpty { schedulePrerender() }
    }

    // MARK: Vorberechnung der Zeitdehnung (v1.18.15)
    //
    // Im Stillstand wird Material, dessen Taktlänge nicht zum Projekttempo/zur Taktart passt,
    // im Hintergrund hochwertig gedehnt (`fof_stretch_render_loop`) und neben dem Material
    // gebunden. Der Ausgangs-Render spielt es samplegenau, solange die Taktlänge passt; bei
    // Tempowechseln im Lauf übernimmt die Echtzeitdehnung, zurück wird auf der Taktgrenze getauscht.

    private var stretchTarget: (bpm: Double, quarters: Double)?
    private var prerenderScheduled = false
    private var prerenderJobs: Set<UUID> = []
    /// Fehlgeschlagene Ziele (Quelle, Stand, Taktlänge) je Kanal: nicht erneut versuchen.
    private var prerenderFailed: [UUID: (source: UInt, version: Int, barFrames: Int)] = [:]
    private(set) var prerenderStarts = 0
    private static let prerenderQueue = DispatchQueue(label: "fof.loop.prerender", qos: .utility)
    /// Wartezeit nach der letzten Änderung (Tempo-Regler zieht).
    static let prerenderDelay: TimeInterval = 0.25

    /// Projekttempo und Taktart (Main, bei jedem Veröffentlichen; ohne Änderung ohne Wirkung).
    func setStretchTarget(bpm: Double, quartersPerBar: Double) {
        if let t = stretchTarget, t.bpm == bpm, t.quarters == quartersPerBar { return }
        stretchTarget = (bpm, quartersPerBar)
        schedulePrerender()
    }

    func schedulePrerender() {
        guard !prerenderScheduled else { return }
        prerenderScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.prerenderDelay) { [weak self] in
            self?.prerenderScheduled = false
            self?.prerenderIdle()
        }
    }

    #if DEBUG
    /// Test: läuft im Job vor der Berechnung (z. B. auf ein Semaphor warten).
    var _prerenderHold: (() -> Void)?
    #endif

    /// Laufende Vorberechnungen (Tests/Diagnose).
    var prerenderBusy: Bool { !prerenderJobs.isEmpty || prerenderScheduled }

    private func prerenderIdle() {
        guard !transportRunning, let t = stretchTarget else { return }
        for c in host?.loopChannels ?? [] {
            guard let core = core(for: c.id), let st = core.storage, core.hasMaterial, core.isQuiescent else { continue }
            guard let bf = AudioLoopCore.prerenderBarFrames(st, bpm: t.bpm, quartersPerBar: t.quarters) else {
                core.bindRendered(nil); continue
            }
            let version = core.materialVersion, source = AudioLoopCore.identity(st), starts = transportStarts
            let writes = core.writeGeneration
            if let r = core.rendered, r.prerenderSource == source, r.prerenderVersion == version,
               r.barFrames == bf { continue }
            let id = c.id
            guard !prerenderJobs.contains(id) else { continue }   // Abschluss plant neu
            if let f = prerenderFailed[id], f.source == source, f.version == version, f.barFrames == bf { continue }
            prerenderJobs.insert(id)
            prerenderStarts += 1
            #if DEBUG
            let hold = _prerenderHold
            #endif
            Self.prerenderQueue.async { [weak self] in
                #if DEBUG
                hold?()
                #endif
                let out = AudioLoopCore.makePrerender(st, barFrames: bf)
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.prerenderJobs.remove(id)
                    // Material schreibt nur die Aufnahme, und die läuft nur mit Transport: kein Start
                    // seit Jobbeginn und jetzt Stillstand ⇒ der Job las einen ruhenden Stand.
                    // EXT startet auf dem MIDI-Thread, bevor Main davon erfährt: maßgeblich ist, ob
                    // die Aufnahme seit Jobbeginn schreiben durfte (`writeGeneration`).
                    if let out, let core = self.core(for: id), core.storage === st, core.materialVersion == version,
                       core.writeGeneration == writes,
                       self.transportStarts == starts, !self.transportRunning, core.isQuiescent {
                        out.prerenderSource = source
                        out.prerenderVersion = version
                        core.bindRendered(out)
                        self.prerenderFailed[id] = nil
                    } else if out == nil {
                        self.prerenderFailed[id] = (source, version, bf)   // Budget/Werte: bleibt Echtzeit
                    }
                    self.schedulePrerender()   // inzwischen anderes Ziel/Material: nachziehen
                }
            }
        }
    }

    /// Kodiert ruhendes Material im Hintergrund vor, damit Speichern Main nicht als
    /// Medienencoder belegt.
    func preencodeIdle() {
        for c in host?.loopChannels ?? [] {
            guard let core = core(for: c.id), core.hasMaterial, core.isQuiescent else { continue }
            let id = c.id
            assets.preencode(id, version: core.materialVersion,
                             current: { [weak self] _, v in self?.core(for: id)?.materialVersion == v },
                             retry: { [weak self] in self?.preencodeIdle() })
        }
    }

    private func currentVersion(_ id: UUID) -> Int? {
        let core = core(for: id)
        return core?.hasMaterial == true ? core?.materialVersion : nil
    }

    /// Material aller Loop-Kanäle fürs Preset. nil, wenn vorhandenes Material nicht kodiert
    /// werden kann (Codex H8).
    func files() -> [AudioLoopFile]? {
        var out: [AudioLoopFile] = []
        for c in host?.loopChannels ?? [] {
            switch assets.file(c.id, version: currentVersion(c.id)) {
            case .file(let f): out.append(f)
            case .none:        continue
            case .failure:     return nil
            }
        }
        return out
    }

    /// Speicher-Aufträge in Kanalreihenfolge (v1.16.1): nichts wird hier kodiert.
    func saveJobs() -> [(id: UUID, job: AudioLoopAssets.SaveJob)] {
        (host?.loopChannels ?? []).map { c in (c.id, assets.saveJob(c.id, version: currentVersion(c.id))) }
    }

    /// Hintergrund-Ergebnis in den Vorkodier-Zwischenspeicher übernehmen.
    func adoptEncoded(_ file: AudioLoopFile, storage: AudioLoopStorage, version: Int, for id: UUID) {
        assets.adopt(file, storage: storage, version: version, for: id) { [weak self] _, v in
            self?.core(for: id)?.materialVersion == v
        }
    }

    /// Nach dem Laden: Material zurückholen. Rückgabe: Anzahl nicht wiederhergestellter Loops.
    func restore(_ files: [AudioLoopFile]) -> Int {
        assets.beginRestore()
        let sr = host?.loopSampleRate ?? 0
        var failed = 0
        for f in files {
            guard let core = core(for: f.channel) else { continue }
            guard let st = assets.restore(f, sampleRate: sr) else { failed += 1; continue }
            core.bind(st)
        }
        schedulePrerender()
        preencodeIdle()
        kickDisplays()
        return failed
    }

    func waveform(_ id: UUID, buckets: Int) -> [AudioLoopDisplay.WaveBucket] { assets.waveform(id, buckets: buckets) }
    func frames(_ id: UUID) -> Int { assets.frames(id) }

    // MARK: Transport

    /// Transport angehalten: Anker stoppen (Host-Zeit `host`), alle Aufnahmen beenden.
    func transportStopped(at host: UInt64) {
        transportRunning = false
        barClock.stop(at: host)
        for slot in slots.values { core(slot).setRecording(false) }
        updateInputNeeded()
        kickDisplays()
        schedulePrerender()
    }

    /// Transport läuft: Wiedergabeorte anzeigen (v1.16.1).
    func transportStarted() { transportRunning = true; transportStarts &+= 1; kickDisplays() }
    /// Zählt Transportstarts: Vorberechnungen gelten nur, wenn währenddessen keiner war (R15-04).
    private var transportStarts = 0

    // MARK: Anzeige

    private func setError(_ id: UUID, _ e: String?) { displays[id]?._setError(e) }

    /// Eingangsfehler betreffen genau die Kanäle, die den Eingang gerade brauchen;
    /// Erfolg löscht Eingangsfehler aller Kanäle.
    private func setInputError(_ e: String?) {
        for c in host?.loopChannels ?? [] {
            if e == nil { setError(c.id, nil) }
            else if needsInput(c.id, c.settings) { setError(c.id, e) }
        }
    }

    /// Kernzustand und Wellenform aller Loop-Kanäle in ihre Anzeigen übernehmen.
    /// Rückgabe: weitere Abfragen nötig.
    @discardableResult
    func refreshDisplays() -> Bool {
        var busy = false
        for c in host?.loopChannels ?? [] {
            guard let d = displays[c.id] else { continue }
            let id = c.id
            if d._refresh(frames: frames(id), inputActive: needsInput(id, c.settings),
                          waveform: { self.waveform(id, buckets: 400) }) { busy = true }
            if transportRunning, d.status.hasMaterial { busy = true }
        }
        return busy
    }

    /// Anzeigen jetzt abgleichen und die Abfrage starten, falls ein Loop aktiv ist.
    func kickDisplays() {
        guard refreshDisplays(), statusTimer == nil else { return }
        let t = Timer(timeInterval: 0.1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            if !self.refreshDisplays() { t.invalidate(); self.statusTimer = nil }
        }
        RunLoop.main.add(t, forMode: .common)
        statusTimer = t
    }

    // MARK: Eingang

    /// Eingang läuft genau dann, wenn eine Spur scharf ist, aufnimmt, mithört oder misst.
    private var inputNeeded: Bool {
        (host?.loopChannels ?? []).contains { needsInput($0.id, $0.settings) }
    }

    private func needsInput(_ id: UUID, _ s: AudioLoopSettings) -> Bool {
        guard let core = core(for: id) else { return false }
        return s.monitor || core.isRecordRequested || core.state != .idle || probing.contains(id)
    }

    func updateInputNeeded() {
        let needed = inputNeeded
        if needed, !inputEngine.isRunning {
            if inputEngine.onRestart == nil {
                inputEngine.onRestart = { [weak self] ok in
                    guard let self else { return }
                    self.setInputError(ok ? nil : self.inputEngine.lastError)
                    self.configureAll()
                    self.devices.refresh()
                }
            }
            inputEngine.start(stillNeeded: { [weak self] in self?.inputNeeded ?? false }) { [weak self] ok in
                guard let self else { return }
                self.setInputError(ok ? nil : self.inputEngine.lastError)
                if ok { self.configureAll() }
                self.devices.refresh()
            }
        } else if !needed {
            inputEngine.stop()   // auch einen noch ausstehenden Freigabe-Auftrag entwerten
        }
        devices.refresh()
        // Nach dem Ende einer Aufnahme (Audio-Thread) den Eingang wieder abschalten.
        if needed, inputIdleTimer == nil {
            inputIdleTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] t in
                guard let self else { t.invalidate(); return }
                self.preencodeIdle()
                if !self.inputNeeded { t.invalidate(); self.inputIdleTimer = nil; self.updateInputNeeded() }
            }
        }
    }

    // MARK: Latenzmessung per Loopback (v1.15.2, Codex T4/M1)
    //
    // Der Kanal spielt einen Klick, der Eingang (per Kabel mit dem Ausgang verbunden) fängt
    // ihn auf. Gemessen wird zwischen den beiden Gerätezeitstempeln — damit enthält das
    // Ergebnis genau die Anteile, die die Zeitstempel nicht schon abbilden. Daraus folgt der
    // Aufnahmeausgleich; der Feinwert wird so gesetzt, dass Automatik + Feinwert = Messung.

    func measureLatency(_ id: UUID) {
        guard let core = core(for: id), !probing.contains(id) else { return }
        probing.insert(id)
        displays[id]?._setProbe(.running)
        updateInputNeeded()
        let started = Date()
        var armed = false
        let t = Timer(timeInterval: 0.05, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            // Erst klicken, wenn Eingang und Ausgang laufen (Freigabedialog, Anlauf).
            if !armed, self.inputEngine.isRunning, self.host?.loopOutputRunning == true {
                armed = true; core.startLatencyProbe()
            }
            if let ticks = core.latencyProbeTicks {
                self.finishProbe(id, t, result: Double(ticks) / Self.hostTicksPerSecond)
            } else if Date().timeIntervalSince(started) > Self.probeTimeout {
                core.cancelLatencyProbe()
                self.finishProbe(id, t, result: nil)
            }
        }
        RunLoop.main.add(t, forMode: .common)
    }

    private func finishProbe(_ id: UUID, _ t: Timer, result: Double?) {
        t.invalidate()
        probing.remove(id)
        defer { updateInputNeeded() }
        guard let roundTrip = result, let core = core(for: id), var s = settings(id) else {
            displays[id]?._setProbe(.failed); return
        }
        // Wiedergabe liest um die Kettenlatenz voraus; was der Eingang davon zurückbekommt,
        // muss die Aufnahme um (Rundlauf − Vorauslesen) zurückschieben.
        let advance = Double(core.outputAdvanceHost) / Self.hostTicksPerSecond
        let needed = roundTrip - advance
        let auto = Double(automaticLatencyFrames()) / (host?.loopSampleRate ?? 48_000)
        let offsetMs = Float(((needed - auto) * 1000).rounded())
        s.latencyOffsetMs = offsetMs
        s.clamp()
        host?.loopSettingsMeasured(s, for: id)
        displays[id]?._setProbe(.done(roundTripMs: roundTrip * 1000, offsetMs: Double(s.latencyOffsetMs),
                                      clamped: s.latencyOffsetMs != offsetMs))
    }

    // MARK: Test-Zugang

    #if DEBUG
    /// Bindet Material ohne Aufnahme (Tests).
    func _setStorage(_ st: AudioLoopStorage, for id: UUID) {
        guard let c = core(for: id) else { return }
        assets.set(st, for: id)
        c.bind(st)
        kickDisplays()
    }
    var _statusPolling: Bool { statusTimer != nil }
    #endif
}
