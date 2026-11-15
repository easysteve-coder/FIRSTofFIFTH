import CoreMIDI
import Foundation
import Combine
import Darwin   // mach_absolute_time()
import Atomics  // ManagedAtomic (N2/RT-4c)

enum ClockMode: String, CaseIterable, Codable {
    case `internal` = "INT"
    case external   = "EXT"
}

// MARK: - MIDIManager

class MIDIManager: ObservableObject {
    private var client:  MIDIClientRef   = 0
    private var outPort: MIDIPortRef     = 0
    private var inPort:  MIDIPortRef     = 0
    private var virtSrc: MIDIEndpointRef = 0
    private var virtDst: MIDIEndpointRef = 0

    // RT-4c: atomarer Endpoint-Snapshot statt Trylock-Drop. Ein einzelnes
    // 32-Bit-Wort kann nicht zerreißen — Store/Load sind wait-free und
    // schlagen nie fehl. Der RT-Thread sieht immer entweder den alten oder
    // den neuen Endpoint, nie eine künstliche "kein Output"-Contention-0
    // (Ersatz für den bisherigen os_unfair_lock_trylock-Miss-Drop, s. N2).
    private let rtOutputAtomic = ManagedAtomic<MIDIEndpointRef>(0)

    @Published var outputs:        [(ref: MIDIEndpointRef, name: String)] = []
    @Published var inputs:         [(ref: MIDIEndpointRef, name: String)] = []
    @Published var selectedOutput: MIDIEndpointRef = 0 {
        didSet {
            // RT-4c: atomarer Store statt Lock/Unlock — läuft auf Main Thread.
            rtOutputAtomic.store(selectedOutput, ordering: .releasing)
        }
    }
    @Published var selectedInput:  MIDIEndpointRef = 0

    // Callbacks — called from the MIDI read thread (clock pulse) or main thread
    /// 0xF8 mit der Host-Zeit des Pakets (CoreMIDI-Empfangszeitstempel; 0 → jetzt). Läuft
    /// direkt auf dem MIDI-Read-Thread.
    var onClockPulse:        ((UInt64) -> Void)?
    var onStart:             (() -> Void)?
    var onStop:              (() -> Void)?
    var onContinue:          (() -> Void)?
    /// 0xFA/0xFB direkt auf dem MIDI-Read-Thread, vor der Main-Zustellung (v1.15.2). RT-Pflicht.
    var onStartRT:           (() -> Void)?
    var onCC:                ((Int, Int, Int) -> Void)?   // (channel 1-16, ccNumber, value)
    var onNoteOn:            ((Int, Int, Int) -> Void)?   // (channel 1-16, note, velocity)
    /// C1: Wird aufgerufen (Main-Thread) wenn das aktuell gewählte Output-Device entfernt wird.
    var onOutputDisconnected: (() -> Void)?

    // MARK: - Setup

    func setup() {
        // Modern block-based client — no C-function-pointer, no Unmanaged dance.
        MIDIClientCreateWithBlock("VintageSequencer" as CFString, &client) { [weak self] _ in
            DispatchQueue.main.async { self?.refreshPorts() }
        }

        MIDIOutputPortCreate(client, "VintSeq-Out" as CFString, &outPort)

        // Modern block-based input port (macOS 11+, deployment target: 14.6+).
        // Receives UMP-wrapped MIDI 1.0 events via MIDIEventList.
        // kMIDIProtocol_1_0 = 1 — Swift-Bridging-Name variiert je Xcode-Version; rawValue sicher.
        MIDIInputPortCreateWithProtocol(client, "VintSeq-In" as CFString, MIDIProtocolID(rawValue: 1)!, &inPort) { [weak self] evtList, _ in
            self?.handleEventList(evtList)
        }

        MIDISourceCreate(client, "Vintage Sequencer" as CFString, &virtSrc)

        // kMIDIProtocol_1_0 = 1
        MIDIDestinationCreateWithProtocol(client, "Vintage Sequencer" as CFString, MIDIProtocolID(rawValue: 1)!, &virtDst) { [weak self] evtList, _ in
            self?.handleEventList(evtList)
        }

        refreshPorts()
    }

    func refreshPorts() {
        // Aktuellen Output merken, bevor die Liste neu aufgebaut wird (C1).
        let prevOutput = selectedOutput

        let nDst = MIDIGetNumberOfDestinations()
        outputs = (0..<nDst).compactMap { i in
            let ep = MIDIGetDestination(i)
            guard ep != virtDst else { return nil }   // eigenen Eingang nicht als Ausgang anbieten
            return endpointName(ep).map { (ref: ep, name: $0) }
        }
        let nSrc = MIDIGetNumberOfSources()
        inputs = (0..<nSrc).compactMap { i in
            let ep = MIDIGetSource(i)
            guard ep != virtSrc else { return nil }   // eigenen Ausgang nicht als Eingang anbieten
            return endpointName(ep).map { (ref: ep, name: $0) }
        }

        // C1: Prüfen ob das gewählte Output-Device noch vorhanden ist.
        // Läuft auf dem Main-Thread (DispatchQueue.main.async im notify-Callback).
        // prevOutput == 0: kein Gerät gewählt — kein Disconnect möglich.
        if prevOutput != 0 && !outputs.contains(where: { $0.ref == prevOutput }) {
            selectedOutput = 0
            onOutputDisconnected?()
        }
    }

    func connectInput(_ ep: MIDIEndpointRef) {
        if selectedInput != 0 { MIDIPortDisconnectSource(inPort, selectedInput) }
        selectedInput = ep
        if ep != 0 { MIDIPortConnectSource(inPort, ep, nil) }
    }

    // MARK: - Send helpers

    /// Sendet MIDI-Bytes mit optionalem Future-Timestamp (Mach absolute time).
    /// Nur für Non-RT-Aufrufe (Transport-Messages, Setup).
    /// timestamp == 0  →  sofort (mach_absolute_time() wird intern gesetzt).
    /// timestamp >  0  →  CoreMIDI liefert das Paket exakt zum angegebenen Zeitpunkt.
    func send(_ bytes: [UInt8], at timestamp: MIDITimeStamp = 0) {
        let bufSize  = 256
        let buf      = UnsafeMutableRawPointer.allocate(
            byteCount: bufSize,
            alignment: MemoryLayout<MIDIPacketList>.alignment)
        defer { buf.deallocate() }

        let pl  = buf.bindMemory(to: MIDIPacketList.self, capacity: 1)
        var pkt = MIDIPacketListInit(pl)
        let ts  = timestamp == 0 ? mach_absolute_time() : timestamp
        pkt = MIDIPacketListAdd(pl, bufSize, pkt, ts, bytes.count, bytes)

        // N2: Snapshot-Prinzip — selectedOutput einmal lesen, ausschließlich `out` verwenden.
        // send() läuft auf dem Main-Thread; selectedOutput wird nur dort geschrieben.
        // Kein Lock nötig — Snapshot verhindert Check/Use auf getrennten Reads.
        let out = selectedOutput
        if out     != 0 { MIDISend(outPort, out, pl) }
        if virtSrc != 0 { MIDIReceived(virtSrc, pl) }
    }

    /// RT-sicherer Send-Kern für bis zu 3 MIDI-Bytes.
    /// Vollständig stack-basiert: kein allocate(), kein Array, kein Foundation.
    /// MIDIPacketList (~272 Bytes) liegt auf dem Stack.
    /// Aufrufbar vom Audio-Callback-Thread.
    @inline(__always)
    private func sendRTSafe(_ b0: UInt8, _ b1: UInt8 = 0, _ b2: UInt8 = 0,
                             count: Int, at timestamp: MIDITimeStamp) {
        #if DEBUG
        // Test-Naht am tatsächlichen Sendekern: vor dem Playback gesetzt, danach nur
        // gelesen. Im Release-Build nicht vorhanden.
        _testSendObserver?(b0, b1, b2, count, timestamp)
        #endif
        var bytes   = (b0, b1, b2)                       // 3 Bytes auf dem Stack
        var pktList = MIDIPacketList()                   // ~272 Bytes auf dem Stack
        // RT-4c: atomarer Snapshot statt Trylock — schlägt nie fehl, kein
        // Event wird mehr wegen Lock-Kontention still übersprungen.
        let out     = rtOutputAtomic.load(ordering: .acquiring)
        let src     = virtSrc
        let port    = outPort
        withUnsafeMutablePointer(to: &pktList) { listPtr in
            let pkt = MIDIPacketListInit(listPtr)
            withUnsafeBytes(of: &bytes) { raw in
                _ = MIDIPacketListAdd(
                    listPtr,
                    MemoryLayout<MIDIPacketList>.size,
                    pkt,
                    timestamp,
                    count,
                    raw.baseAddress!.assumingMemoryBound(to: UInt8.self))
            }
            if out  != 0 { MIDISend(port, out, listPtr) }
            if src  != 0 { MIDIReceived(src, listPtr) }
        }
    }

    #if DEBUG
    /// Beobachter aller über `sendRTSafe` gesendeten Nachrichten (Bytes, Länge, Timestamp).
    /// Nur setzen, solange kein Playback läuft.
    var _testSendObserver: ((UInt8, UInt8, UInt8, Int, MIDITimeStamp) -> Void)?
    // RT-4c: Test-Fenster auf den atomaren Endpoint-Snapshot — identischer
    // Lesepfad wie sendRTSafe() intern nutzt.
    func _rt4cReadOutputAtomic() -> MIDIEndpointRef { rtOutputAtomic.load(ordering: .acquiring) }
    #endif

    /// RT-SAFE: Stack-only, direkter CoreMIDI-Call, keine Allokation.
    /// Aufrufbar vom Audio-Callback-Thread. RT-Audit abgeschlossen: 2026-03-26.
    func noteOn(channel: Int, note: Int, velocity: Int, at timestamp: MIDITimeStamp = 0) {
        sendRTSafe(UInt8(0x90 | (channel - 1) & 0x0F),
                   UInt8(note     & 0x7F),
                   UInt8(velocity & 0x7F),
                   count: 3, at: timestamp)
    }

    /// RT-SAFE: Stack-only, direkter CoreMIDI-Call, keine Allokation.
    /// Aufrufbar vom Audio-Callback-Thread. RT-Audit abgeschlossen: 2026-03-26.
    func noteOff(channel: Int, note: Int, at timestamp: MIDITimeStamp = 0) {
        sendRTSafe(UInt8(0x80 | (channel - 1) & 0x0F),
                   UInt8(note & 0x7F),
                   0,
                   count: 3, at: timestamp)
    }

    /// RT-SAFE: Stack-only, direkter CoreMIDI-Call, keine Allokation.
    /// Aufrufbar vom Audio-Callback-Thread. RT-Audit abgeschlossen: 2026-03-26.
    func cc(channel: Int, number: Int, value: Int, at timestamp: MIDITimeStamp = 0) {
        sendRTSafe(UInt8(0xB0 | (channel - 1) & 0x0F),
                   UInt8(number & 0x7F),
                   UInt8(value  & 0x7F),
                   count: 3, at: timestamp)
    }

    /// RT-SAFE: Stack-only, direkter CoreMIDI-Call, keine Allokation.
    /// 0xF8 = MIDI-Clock-Puls. Aufrufbar vom Audio-Callback-Thread.
    /// RT-Audit abgeschlossen: 2026-03-26.
    func sendClock(at timestamp: MIDITimeStamp) {
        sendRTSafe(0xF8, count: 1, at: timestamp)
    }

    /// RT-SAFE: Sendet MIDI-Start (0xFA) mit Future-Timestamp. Stack-only, keine Allokation.
    ///
    /// Arch-Slice-16b: Ermöglicht es, 0xFA vom Tick-Thread mit demselben
    /// Future-Timestamp wie der erste 0xF8 zu senden — eliminiert den Gap zwischen
    /// 0xFA (vorher: sofort bei play()) und erstem 0xF8 (erst nach Engine-Startup).
    /// Das externe Gerät erhält Start und ersten Clock-Puls gleichzeitig → kein Resync-Ruckeln.
    func sendStartRT(at timestamp: MIDITimeStamp) {
        sendRTSafe(0xFA, count: 1, at: timestamp)
    }

    /// RT-SAFE: MIDI-Stop (0xFC) mit Future-Timestamp — Songende aus dem Tick (v1.16.1).
    func sendStopRT(at timestamp: MIDITimeStamp) {
        sendRTSafe(0xFC, count: 1, at: timestamp)
    }

    /// Löscht alle noch ausstehenden Future-Timestamp-Events aus der CoreMIDI-Queue.
    /// Muss beim Stop aufgerufen werden, damit geplante Note-Offs nicht nach dem
    /// Stoppen noch feuern.
    func flushOutput() {
        // N2: Snapshot-Prinzip — einmal lesen, ausschließlich `out` verwenden.
        let out = selectedOutput
        if out != 0 { MIDIFlushOutput(out) }
    }

    func allNotesOff(channel: Int) { cc(channel: channel, number: 123, value: 0) }
    /// Non-RT-Wrapper (kein Timestamp). Für Kompatibilität erhalten.
    /// RT-Pfad: sendClock(at:) verwenden.
    func clock()      { sendClock(at: mach_absolute_time()) }
    func start()      { send([0xFA]) }
    func stop()       { send([0xFC]) }
    func `continue`() { send([0xFB]) }

    // MARK: - Receive

    /// Entry point for both the input port and virtual destination receive blocks.
    /// Called on CoreMIDI's internal read thread — must not block or allocate.
    private func handleEventList(_ evList: UnsafePointer<MIDIEventList>) {
        let numPackets = Int(evList.pointee.numPackets)
        guard numPackets > 0 else { return }

        // Navigate to the first MIDIEventPacket via raw pointer arithmetic.
        // MIDIEventList layout: [protocol: Int32 (4)][numPackets: UInt32 (4)][packet[0]...]
        // Offset = 8 bytes; MIDIEventPacket is 8-byte aligned (starts with UInt64 timeStamp). ✓
        let headerStride = MemoryLayout<MIDIProtocolID>.size + MemoryLayout<UInt32>.size
        var pktPtr = UnsafeRawPointer(evList)
            .advanced(by: headerStride)
            .assumingMemoryBound(to: MIDIEventPacket.self)

        for i in 0..<numPackets {
            let stamp = pktPtr.pointee.timeStamp
            let packetTime = stamp != 0 ? stamp : mach_absolute_time()
            let wordCount = min(Int(pktPtr.pointee.wordCount), 64)   // clamp: guard against corrupt data
            for w in 0..<wordCount {
                // Read each UMP word inline — no heap allocation.
                let word: UInt32 = withUnsafeBytes(of: pktPtr.pointee.words) {
                    $0.load(fromByteOffset: w * 4, as: UInt32.self)
                }
                handleUMPWord(word, time: packetTime)
            }
            // Do not advance past the last packet (undefined memory beyond list end).
            if i < numPackets - 1 {
                pktPtr = UnsafePointer(MIDIEventPacketNext(pktPtr))
            }
        }
    }

    /// Parses one Universal MIDI Packet (UMP) word and dispatches to the appropriate callback.
    /// MIDI 1.0 protocol: all channel voice and real-time messages are single-word packets.
    private func handleUMPWord(_ word: UInt32, time: UInt64) {
        // UMP message type occupies the top 4 bits.
        let msgType = UInt8((word >> 28) & 0x0F)

        switch msgType {
        case 0x1:   // System Real-Time / System Common — 1 word
            let status = UInt8((word >> 16) & 0xFF)
            switch status {
            case 0xF8: onClockPulse?(time)   // direkt — Zeitbezug ist der Paketzeitstempel
            case 0xFA: onStartRT?(); DispatchQueue.main.async { [weak self] in self?.onStart?() }
            case 0xFB: onStartRT?(); DispatchQueue.main.async { [weak self] in self?.onContinue?() }
            case 0xFC: DispatchQueue.main.async { [weak self] in self?.onStop?() }
            default:   break   // SysEx common, MTC, SPP, etc. — not used, silently ignored
            }

        case 0x2:   // MIDI 1.0 Channel Voice — 1 word
            let status = UInt8((word >> 16) & 0xFF)
            let data1  = UInt8((word >>  8) & 0x7F)
            let data2  = UInt8( word        & 0x7F)

            switch status {
            case 0x90...0x9F:   // Note On
                guard data2 > 0 else { break }   // velocity 0 = Note Off — not handled here
                let ch   = Int(status & 0x0F) + 1
                let note = Int(data1)
                let vel  = Int(data2)
                DispatchQueue.main.async { [weak self] in self?.onNoteOn?(ch, note, vel) }

            case 0xB0...0xBF:   // Control Change
                let ch  = Int(status & 0x0F) + 1
                let num = Int(data1)
                let val = Int(data2)
                DispatchQueue.main.async { [weak self] in self?.onCC?(ch, num, val) }

            default: break   // Note Off, Poly AT, Program Change, etc. — silently ignored
            }

        default:
            break   // MIDI 2.0 extended types (0x4+), SysEx 8 (0x5), etc. — silently ignored
        }
    }

    // MARK: - Cleanup

    func cleanup() {
        if virtSrc != 0 { MIDIEndpointDispose(virtSrc) }
        if virtDst != 0 { MIDIEndpointDispose(virtDst) }
        if outPort != 0 { MIDIPortDispose(outPort) }
        if inPort  != 0 { MIDIPortDispose(inPort) }
        if client  != 0 { MIDIClientDispose(client) }
    }

    // MARK: - Private

    private func endpointName(_ ep: MIDIEndpointRef) -> String? {
        var prop: Unmanaged<CFString>?
        MIDIObjectGetStringProperty(ep, kMIDIPropertyDisplayName, &prop)
        return prop?.takeRetainedValue() as String?
    }
}
