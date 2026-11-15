import Foundation
import AVFoundation
import Atomics

// MARK: - RackDiagnostics (v1.18.1, Codex A17-10 — Zerlegung des Racks, Schritt 2)
//
// Besitzer der Audio-Diagnose des Racks: Kopf der Aufzeichnung, Messproben (Pegel, Warte-
// schlangen, Renderdurchläufe, Latenz, Loop-Schlupf) mit ihren Vergleichsständen, Beobachtung
// der Instrumente (Preset, Parameterbaum, Gesamtzustand). Schreibt nur in den Rekorder
// `AudioDiagnostics`. Vom Rack bekommt er je Probe eine schreibgeschützte Momentaufnahme
// (`Probe`); er hält keine Referenz aufs Rack. Nur Main.

final class RackDiagnostics {

    /// Momentaufnahme eines Kanals für eine Probe.
    struct ChannelProbe {
        let data: InstrumentChannelData
        let status: String
        let meter: LevelMeter
        let queue: AUEventQueue
        let instrument: AVAudioUnit?
        let latencySeconds: Double
        let loop: AudioLoopCore?
        let hostCalls: [Int]?
    }

    /// Momentaufnahme des Racks.
    struct Probe {
        let engine: AVAudioEngine?
        let recoveries: Int
        let masterMeter: LevelMeter
        let masterGainDB: Float
        let channels: [ChannelProbe]
    }

    let recorder: AudioDiagnostics
    private var lastMasterBlocks = 0
    private var lastChannelBlocks: [UUID: Int] = [:]
    private var lastQueue: [UUID: (rejected: Int, backlog: Int, pre: Int, post: Int, err: Int, stale: Int)] = [:]
    private var lastSample: Date?
    private var observations: [UUID: [NSKeyValueObservation]] = [:]

    init(recorder: AudioDiagnostics) { self.recorder = recorder }

    static func describe(_ f: AVAudioFormat) -> String {
        "\(Int(f.sampleRate))/\(f.channelCount)\(f.isInterleaved ? "i" : "")"
    }

    /// Signalwerte eines Messpunkts seit der letzten Probe (nach Fader bzw. Summen-Gain).
    private static func signalRow(_ d: LevelMeter.Diagnostics, blocks: Int) -> [String: Any] {
        ["peak": AudioDiagnostics.num(d.peak), "over1": d.over, "over16": d.over16, "nan": d.nonFinite,
         "dc": AudioDiagnostics.num(d.dc), "rms": AudioDiagnostics.num(d.rms), "blocks": blocks]
    }

    /// Kopf der Aufzeichnung.
    func header(_ p: Probe) -> [String: Any] {
        var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
        var head: [String: Any] = ["engineRunning": p.engine?.isRunning ?? false,
                                   "audioRecoveries": p.recoveries,
                                   "hostTime": String(mach_absolute_time()),
                                   "timebase": "\(tb.numer)/\(tb.denom)", "schema": 1]
        if let e = p.engine { head["output"] = Self.describe(e.outputNode.outputFormat(forBus: 0)) }
        head["channels"] = p.channels.map { c -> [String: Any] in
            var d: [String: Any] = ["name": c.data.name, "status": c.status, "effects": c.data.effects.map(\.name)]
            if let i = c.data.instrument { d["instrument"] = i.name; d["component"] = i.componentKey }
            if let calls = c.hostCalls { d["hostCalls"] = calls }
            return d
        }
        return head
    }

    /// Eine Messprobe (Main, aus dem Wächter-Timer). Pegel sind Rohwerte nach dem Fader:
    /// `peak` darf weit über 1 liegen, `over` zählt Samples über 1,0, `nan` NaN/∞-Samples.
    func sample(_ p: Probe) {
        var s: [String: Any] = [:]
        let now = Date()
        if let last = lastSample { s["dt"] = Int(now.timeIntervalSince(last) * 1000) }   // Timer-Verspätung
        lastSample = now
        let blocks = p.masterMeter.blockCount
        s["sum"] = Self.signalRow(p.masterMeter.takeDiagnostics(), blocks: blocks &- lastMasterBlocks)
        lastMasterBlocks = blocks
        if let e = p.engine {
            s["engine"] = ["running": e.isRunning, "masterGainDB": AudioDiagnostics.num(p.masterGainDB)]
        }
        var chans: [[String: Any]] = []
        for c in p.channels {
            let id = c.data.id
            let b = c.meter.blockCount
            var row = Self.signalRow(c.meter.takeDiagnostics(), blocks: b &- (lastChannelBlocks[id] ?? b))
            lastChannelBlocks[id] = b
            let q = c.queue
            let cur = (rejected: q.rejected.load(ordering: .relaxed), backlog: q.backlog.load(ordering: .relaxed),
                       pre: q.preRenders.load(ordering: .relaxed), post: q.postRenders.load(ordering: .relaxed),
                       err: q.renderErrors.load(ordering: .relaxed), stale: q.staleNoteOns.load(ordering: .relaxed))
            let last = lastQueue[id] ?? cur
            lastQueue[id] = cur
            row["name"] = c.data.name
            row["vol"] = AudioDiagnostics.num(c.data.volume)
            row["mute"] = c.data.isMuted
            row["rejected"] = cur.rejected &- last.rejected
            row["backlog"] = cur.backlog &- last.backlog
            row["auPre"] = cur.pre &- last.pre             // Render-Durchläufe des Instruments
            row["auPost"] = cur.post &- last.post
            row["auErr"] = cur.err &- last.err
            row["staleOn"] = cur.stale &- last.stale       // verworfene überfällige Note-Ons (v1.18.36)
            if let u = c.instrument {
                row["rr"] = u.auAudioUnit.renderResourcesAllocated
                row["format"] = Self.describe(u.outputFormat(forBus: 0))
            }
            row["latencyMs"] = AudioDiagnostics.num(Float(c.latencySeconds * 1000))   // T7
            if let core = c.loop {                                                 // T5 (Summen)
                row["driftSlips"] = core.driftSlips
                row["monitorSlips"] = core.monitorSlips
            }
            chans.append(row)
        }
        s["ch"] = chans
        var dev = AudioDiagnostics.defaultOutputDevice()
        dev["overloads"] = recorder.takeOverloads()
        s["device"] = dev
        recorder.event("s", s)
    }

    /// Plug-in-seitige Änderungen eines Instruments protokollieren: Presetwahl im Editor, neuer
    /// Parameterbaum, Gesamtzustand. `name` liefert den aktuellen Kanalnamen (nil = entfernt).
    func observe(_ unit: AVAudioUnit, channel id: UUID, name: @escaping () -> String?) {
        let au = unit.auAudioUnit
        let report: (String) -> Void = { [weak self, weak unit] what in
            DispatchQueue.main.async {
                guard let self, let n = name() else { return }
                var f: [String: Any] = ["channel": n, "what": what]
                if let u = unit {
                    f["preset"] = u.auAudioUnit.currentPreset?.name ?? "-"
                    f["format"] = Self.describe(u.outputFormat(forBus: 0))
                    f["rr"] = u.auAudioUnit.renderResourcesAllocated
                }
                self.recorder.event("au", f)
            }
        }
        observations[id] = [
            au.observe(\.currentPreset) { _, _ in report("preset") },
            au.observe(\.parameterTree) { _, _ in report("parameterTree") },   // Cache: ParameterCatalog
            au.observe(\.allParameterValues) { _, _ in report("allParameterValues") },
        ]
    }

    func forget(channel id: UUID) {
        observations[id] = nil
        lastChannelBlocks[id] = nil
        lastQueue[id] = nil
    }
}
