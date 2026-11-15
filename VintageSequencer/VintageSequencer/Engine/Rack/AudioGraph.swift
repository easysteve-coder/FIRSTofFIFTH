import Foundation
import AVFoundation

// MARK: - AudioGraph (v1.18.3, Codex A17-10 — Zerlegung des Racks, Schritt 3)
//
// Einziger Besitzer der AVAudioEngine: Anlegen, Start, Stop, Neustart beim Aufnehmen neuer
// Knoten, Geräte-/Formatwechsel (Beobachtung), Summe (Master-Gain, Lautstärke, Summen-Tap) und
// das Mischformat. Kanäle kennt der Graph nicht: das Rack sagt, welche Knoten eine Kette
// bilden (`connectChain`), der Graph verbindet sie und nimmt neue Knoten in den Renderweg auf.
//
// Jeder Start und Neustart läuft über `start()`: davor `onWillStart` (Engine steht — das Rack
// bestätigt dort die Host-Blöcke der Plug-ins, Codex A17-09, v1.18.10), danach `onStarted`. Ein Geräte-/Formatwechsel meldet
// `onConfigurationChange` (das Rack verbindet die Kanäle neu). Nur Main.

final class AudioGraph {

    /// Pegel der Summe (gehört dem Rack, der Graph setzt nur den Tap).
    private let masterMeter: LevelMeter
    private(set) var engineIfCreated: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private let masterGain = AVAudioUnitEQ(numberOfBands: 0)
    private var masterGainWired = false
    private var masterVolume: Float = 1
    private(set) var masterTapInstalled = false
    private var masterTapNode: AVAudioNode?

    /// Starts seit Anlegen (Diagnose, Tests: jeder Neustart unterbricht den Ton).
    private(set) var starts = 0
    /// Letzter Startfehler (nil = gestartet oder nie versucht).
    private(set) var startError: String?
    var isRunning: Bool { engineIfCreated?.isRunning ?? false }

    /// Nach jedem (Neu-)Start (Main).
    var onStarted: (() -> Void)?
    /// Unmittelbar vor jedem Start, Engine steht (Main): die einzige Stelle, an der Host-Blöcke
    /// der Plug-ins gesetzt werden dürfen — nie, während sie rendern (v1.18.10).
    var onWillStart: (() -> Void)?
    /// Ausgabegerät/-format gewechselt; die Engine hat dabei angehalten (Main).
    var onConfigurationChange: ((AVAudioEngine) -> Void)?

    init(masterMeter: LevelMeter) { self.masterMeter = masterMeter }

    deinit {
        if let o = configObserver { NotificationCenter.default.removeObserver(o) }
        if let e = engineIfCreated { _ = FoFEngineStop(e) }
    }

    /// Die Engine, bei Bedarf angelegt (mit verdrahteter Summe und Wechselbeobachtung).
    /// Außer Betrieb liefert sie weiter die alte Engine; Umbauer fragen vorher `faulted`.
    func engine() -> AVAudioEngine {
        if let e = engineIfCreated { return e }
        let e = AVAudioEngine()
        engineIfCreated = e
        e.attach(masterGain)
        wireMaster()
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: e, queue: nil
        ) { [weak self] _ in DispatchQueue.main.async { self?.onConfigurationChange?(e) } }   // nie warten lassen (v1.18.20)
        return e
    }

    /// Stereo in der Abtastrate des Ausgangs; nil, solange kein Ausgabegerät bekannt ist.
    var mixFormat: AVAudioFormat? {
        guard let e = engineIfCreated else { return nil }
        let sr = e.outputNode.outputFormat(forBus: 0).sampleRate
        guard sr > 0 else { return nil }
        return AVAudioFormat(standardFormatWithSampleRate: sr, channels: 2)
    }

    // MARK: Summe

    /// Main-Mixer → Gain-Stufe der Summe → Ausgang. Ohne bekanntes Ausgabeformat bleibt die
    /// Standardverbindung (Main-Mixer → Ausgang) bestehen.
    func wireMaster() {
        guard faulted == nil, let e = engineIfCreated else { return }
        if let format = mixFormat {
            e.connect(e.mainMixerNode, to: masterGain, format: format)
            e.connect(masterGain, to: e.outputNode, format: format)
            masterGainWired = true
        } else {
            masterGainWired = false
        }
        applyMasterVolume(masterVolume)
    }

    /// Linearer Gain der Summe (0 … +6 dB).
    func applyMasterVolume(_ v: Float) {
        masterVolume = v
        guard let e = engineIfCreated else { return }
        if masterGainWired {
            masterGain.globalGain = InstrumentRack.decibels(v)
            e.mainMixerNode.outputVolume = v > 0 ? 1 : 0
        } else {
            e.mainMixerNode.outputVolume = min(1, v)
        }
    }

    var masterGainDB: Float { masterGain.globalGain }

    func installMasterTap() {
        guard faulted == nil, !masterTapInstalled, let e = engineIfCreated, mixFormat != nil else { return }
        let meter = masterMeter
        masterTapNode = masterGainWired ? masterGain : e.mainMixerNode
        masterTapNode?.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.feed(buffer) }
        masterTapInstalled = true
    }

    func removeMasterTap() {
        guard faulted == nil, masterTapInstalled else { return }
        masterTapNode?.removeTap(onBus: 0)
        masterTapNode = nil
        masterTapInstalled = false
        masterMeter.reset()
    }

    // MARK: Verbindungen

    // MARK: Fehlergrenze (v1.18.38)
    //
    // `connect` an einer toten ausgelagerten Einheit wirft eine ObjC-Ausnahme (iMac 17:18,
    // `AUInterfaceBaseV3::SetFormat`), die FoF sonst beendet. Alle Engine-Operationen an
    // Plug-in-Knoten laufen über die Funktionen in `ObjCExceptionBarrier.m`: eine Operation je
    // @try, kein Swift zwischen Wurfstelle und @catch. Scheitert ein Verbinden, trennt der Graph
    // die Kette wieder. Scheitert dieses Aufräumen (oder ein Lösen/Stoppen), ist der Zustand der
    // Engine unbekannt: der Graph geht in `faulted`, hält an und nimmt keine Operation mehr an.
    // Audio bleibt dann aus, bis FoF neu startet (Cocoa ist nicht ausnahmefest; Codex R38-02).

    /// Grund, warum der Graph außer Betrieb ist (nil = in Ordnung). Endgültig bis zum Neustart.
    private(set) var faulted: String?
    /// Der Graph ist eben außer Betrieb gegangen (Main).
    var onFault: ((String) -> Void)?

    /// `stopFailed`: der auslösende Fehler war schon ein gescheitertes Anhalten (kein zweiter Versuch).
    private func enterFault(_ reason: String, stopFailed: Bool = false) {
        guard faulted == nil else { return }
        var text = reason
        // Höchstens ein Versuch anzuhalten, kein Wiederholen auf unbekanntem Zustand. Scheitert er,
        // sagt die Meldung das: die Engine kann weiterlaufen (Codex R38-R2-03).
        if !stopFailed, let e = engineIfCreated, e.isRunning, let f = FoFEngineStop(e) { text += " — stop: \(f)" }
        faulted = text
        startError = text
        onFault?(text)
    }

    /// Hängt einen Knoten an. false: gescheitert, Graph außer Betrieb.
    @discardableResult
    func attach(_ node: AVAudioNode) -> Bool {
        guard faulted == nil else { return false }
        if let f = FoFEngineAttach(engine(), node) { enterFault("attach: \(f)"); return false }
        return true
    }

    /// Löst einen Knoten. false: gescheitert, Graph außer Betrieb.
    @discardableResult
    func detach(_ node: AVAudioNode) -> Bool {
        guard faulted == nil, let e = engineIfCreated else { return false }
        if let f = FoFEngineDetach(e, node) { enterFault("detach: \(f)"); return false }
        return true
    }

    /// Trennt den Ausgang eines Knotens. false: gescheitert, Graph außer Betrieb.
    @discardableResult
    func disconnectOutput(_ node: AVAudioNode) -> Bool {
        guard faulted == nil, let e = engineIfCreated else { return false }
        if let f = FoFEngineDisconnectOutput(e, node) { enterFault("disconnect: \(f)"); return false }
        return true
    }

    /// Verbindet zwei Knoten. Rückgabe: nil = verbunden, sonst die Ausnahme (Graph bleibt in Betrieb;
    /// der Aufrufer räumt auf).
    func connect(_ a: AVAudioNode, to b: AVAudioNode, format: AVAudioFormat?) -> String? {
        guard faulted == nil, let e = engineIfCreated else { return faulted ?? "no engine" }
        return FoFEngineConnect(e, a, b, format)
    }

    /// Trennt die Ausgänge von `chain` und den Eingang von `sink`. false: Aufräumen gescheitert,
    /// Graph außer Betrieb.
    @discardableResult
    func disconnect(_ chain: [AVAudioNode], from sink: AVAudioNode) -> Bool {
        guard faulted == nil, let e = engineIfCreated else { return false }
        for n in chain {
            if let f = FoFEngineDisconnectOutput(e, n) { enterFault("disconnect: \(f)"); return false }
        }
        if let f = FoFEngineDisconnectInput(e, sink) { enterFault("disconnect: \(f)"); return false }
        return true
    }

    /// Verbindet `chain` (Quelle zuerst) der Reihe nach in `sink`. Neue Knoten bei laufender
    /// Engine nimmt `adopt` in den Renderweg auf.
    /// `headFormat`: Format der ersten Verbindung (eigene Rate des Instruments vor der
    /// Umrechnungsstufe), sonst das Mischformat.
    /// - Returns: nil = verbunden; sonst die Ausnahme. Die Kette ist dann wieder ganz getrennt,
    ///   oder (Aufräumen gescheitert) der Graph ist außer Betrieb (`faulted`).
    @discardableResult
    func connectChain(_ chain: [AVAudioNode], into sink: AVAudioNode, headFormat: AVAudioFormat? = nil) -> String? {
        guard faulted == nil, engineIfCreated != nil else { return faulted }
        guard disconnect(chain, from: sink) else { return faulted }
        guard var upstream = chain.first else { return nil }
        let format = mixFormat
        for (i, node) in chain.dropFirst().enumerated() {
            if let f = connect(upstream, to: node, format: i == 0 ? (headFormat ?? format) : format) {
                disconnect(chain, from: sink)
                return f
            }
            upstream = node
        }
        if let f = connect(upstream, to: sink, format: format) {
            disconnect(chain, from: sink)
            return f
        }
        return nil
    }

    /// Nimmt bei laufender Engine neu verbundene Knoten in den Renderweg auf.
    ///
    /// Rückfall (seit v1.18.10 im Normalfall nicht mehr nötig, siehe `InstrumentRack.hook`):
    /// meldet ein Knoten nach dem Verbinden keine Render-Ressourcen, bliebe er stumm
    /// (v1.13.6), und Plug-ins, die ihre Freischaltung bis dahin aufschieben (UADx), blieben
    /// im Ladezustand. Ein Neustart baut den Renderweg vollständig auf; er unterbricht den
    /// Ton aller Kanäle kurz.
    /// - Returns: true, wenn neu gestartet wurde.
    @discardableResult
    func adopt(_ nodes: [AVAudioNode]) -> Bool {
        guard faulted == nil, adoptNeeded(nodes), let e = engineIfCreated else { return false }
        if let f = FoFEngineStop(e) { enterFault("stop: \(f)", stopFailed: true); return false }
        start()
        return true
    }

    /// Bräuchte `adopt` einen Neustart?
    func adoptNeeded(_ nodes: [AVAudioNode]) -> Bool {
        guard let e = engineIfCreated, e.isRunning else { return false }
        return nodes.contains { !$0.auAudioUnit.renderResourcesAllocated }
    }

    // MARK: Lauf

    /// (Neu-)Start: vorbereiten, starten, `onStarted` melden. Außer Betrieb: nichts.
    func start() {
        guard faulted == nil, let e = engineIfCreated else { return }
        if !e.isRunning { onWillStart?() }
        starts += 1
        // `prepare` reicht Formate an alle Knoten weiter; eine tote Einheit, deren Meldung noch
        // aussteht, kann dort werfen. Dann steht die Engine mit Fehlertext; die Meldung des
        // Plug-ins führt später zum Wiederanlauf.
        var error: NSError?
        if let f = FoFEnginePrepareAndStart(e, &error) {
            if let g = FoFEngineStop(e) { enterFault("\(f) — stop: \(g)", stopFailed: true); return }
            startError = f
        } else {
            startError = error?.localizedDescription
        }
        onStarted?()
    }

    func stop() {
        guard let e = engineIfCreated, faulted == nil else { return }
        if let f = FoFEngineStop(e) { enterFault("stop: \(f)", stopFailed: true) }
    }

    /// Wiederherstellung: Knotenzustand verwerfen (NaN im Filtergedächtnis).
    func stopAndReset() {
        guard let e = engineIfCreated, faulted == nil else { return }
        if let f = FoFEngineStop(e) { enterFault("stop: \(f)", stopFailed: true); return }
        e.reset()
    }
}
