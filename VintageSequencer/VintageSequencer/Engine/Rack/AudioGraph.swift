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
        engineIfCreated?.stop()
    }

    /// Die Engine, bei Bedarf angelegt (mit verdrahteter Summe und Wechselbeobachtung).
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
        guard let e = engineIfCreated else { return }
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
        guard !masterTapInstalled, let e = engineIfCreated, mixFormat != nil else { return }
        let meter = masterMeter
        masterTapNode = masterGainWired ? masterGain : e.mainMixerNode
        masterTapNode?.installTap(onBus: 0, bufferSize: 1024, format: nil) { buffer, _ in meter.feed(buffer) }
        masterTapInstalled = true
    }

    func removeMasterTap() {
        guard masterTapInstalled else { return }
        masterTapNode?.removeTap(onBus: 0)
        masterTapNode = nil
        masterTapInstalled = false
        masterMeter.reset()
    }

    // MARK: Verbindungen

    /// Trennt die Ausgänge von `chain` und den Eingang von `sink`.
    func disconnect(_ chain: [AVAudioNode], from sink: AVAudioNode) {
        guard let e = engineIfCreated else { return }
        chain.forEach { e.disconnectNodeOutput($0) }
        e.disconnectNodeInput(sink)
    }

    /// Verbindet `chain` (Quelle zuerst) der Reihe nach in `sink`. Neue Knoten bei laufender
    /// Engine nimmt `adopt` in den Renderweg auf.
    /// `headFormat`: Format der ersten Verbindung (eigene Rate des Instruments vor der
    /// Umrechnungsstufe), sonst das Mischformat.
    func connectChain(_ chain: [AVAudioNode], into sink: AVAudioNode, headFormat: AVAudioFormat? = nil) {
        guard let e = engineIfCreated else { return }
        disconnect(chain, from: sink)
        guard var upstream = chain.first else { return }
        let format = mixFormat
        for (i, node) in chain.dropFirst().enumerated() {
            e.connect(upstream, to: node, format: i == 0 ? (headFormat ?? format) : format)
            upstream = node
        }
        e.connect(upstream, to: sink, format: format)
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
        guard adoptNeeded(nodes), let e = engineIfCreated else { return false }
        e.stop()
        start()
        return true
    }

    /// Bräuchte `adopt` einen Neustart?
    func adoptNeeded(_ nodes: [AVAudioNode]) -> Bool {
        guard let e = engineIfCreated, e.isRunning else { return false }
        return nodes.contains { !$0.auAudioUnit.renderResourcesAllocated }
    }

    // MARK: Lauf

    /// (Neu-)Start: vorbereiten, starten, `onStarted` melden.
    func start() {
        guard let e = engineIfCreated else { return }
        if !e.isRunning { onWillStart?() }
        starts += 1
        e.prepare()
        do { try e.start(); startError = nil }
        catch { startError = error.localizedDescription }
        onStarted?()
    }

    func stop() { engineIfCreated?.stop() }

    /// Wiederherstellung: Knotenzustand verwerfen (NaN im Filtergedächtnis).
    func stopAndReset() {
        guard let e = engineIfCreated else { return }
        e.stop()
        e.reset()
    }
}
