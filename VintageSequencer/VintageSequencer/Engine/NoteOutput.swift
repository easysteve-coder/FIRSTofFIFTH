import Foundation
import CoreMIDI
import Atomics

// MARK: - NoteOutput (v1.16.0, Codex M6)
//
// Besitzer von Notenbuch und Ausgaberouting des Tick-Pfads: Note-On/-Off und CC an
// CoreMIDI oder an die Warteschlange eines gehosteten Instruments, offene Offs je Ausgang,
// Ausgabe fälliger Offs. Vorher Teil von `SequencerEngine`; Verhalten unverändert.
//
// Eigentum: wie das Buch gehört alles hier dem Inhaber des Tick-Zutritts (Tick-Thread bzw.
// Main nach bewiesener Quieszenz oder als Off-Wächter mit Tick-Zutritt). Kein Lock, keine
// Allokation nach init.

final class NoteOutput {
    let midi: MIDIManager
    let rack: InstrumentRack
    /// 1 ms in Host-Ticks (Off nach einem noch künftigen On beim Stopp).
    static let safetyOffsetMach: MIDITimeStamp = HostTime.nanosToMachTime(1_000_000)

    init(midi: MIDIManager, rack: InstrumentRack) {
        self.midi = midi
        self.rack = rack
    }

    deinit {
        noteBook.deinitialize(count: Self.noteBookSize);       noteBook.deallocate()
        earliestPendingOff.deinitialize(count: Self.portCount); earliestPendingOff.deallocate()
        portEpoch.deinitialize(count: Self.portCount); portEpoch.deallocate()
    }

    // Notenbuch (v1.12.19; v1.12.22: Offs werden erst kurz vor ihrem Zeitpunkt gesendet)
    //
    // 16 Kanäle × 128 Noten. Je Note:
    //   pendingOff — Zeitpunkt des noch NICHT an CoreMIDI übergebenen Note-Offs (0 = keins)
    //   sentOff    — spätestes bereits übergebenes Off (kann noch in der Zukunft liegen)
    //   lastOn     — spätestes übergebenes On (kann noch in der Zukunft liegen)
    //
    // Ein einmal übergebenes Off lässt sich nicht zurückholen. Würde es wie früher zusammen
    // mit dem On geplant, schnitte es eine später begonnene gleiche Note ab (Gate > 100 %
    // auf gleicher Tonhöhe, zwei Spuren auf demselben Kanal). Deshalb bleibt das Off im Buch,
    // bis sein Zeitpunkt im Fenster des laufenden Ticks liegt (`flushDueNoteOffs`); ein
    // neues On derselben Note verlängert es bis dahin (`sendNote`).
    //
    // Schreiber ist der Tick-Thread (innerhalb des Tick-Zutritts). Main fasst das Buch nur
    // an, wenn kein Tick laufen kann: nach bewiesener Quieszenz (stop/teardown) oder als
    // Inhaber des Tick-Zutritts (Off-Wächter bei ausbleibender externer Clock).
    struct NoteBookEntry {
        var pendingOff: UInt64 = 0
        var sentOff:    UInt64 = 0
        var lastOn:     UInt64 = 0
    }
    /// Ein Buchabschnitt je Ausgang: Abschnitt 0 = externe MIDI-Ausgabe, Abschnitt
    /// `route + 1` = gehostetes Instrument. Dieselbe Tonhöhe auf verschiedenen Ausgängen
    /// ist nicht dieselbe Note.
    static let notesPerPort = 16 * 128
    static let portCount    = 1 + InstrumentRack.maxChannels
    static let noteBookSize = portCount * notesPerPort
    private let noteBook: UnsafeMutablePointer<NoteBookEntry> = {
        let p = UnsafeMutablePointer<NoteBookEntry>.allocate(capacity: NoteOutput.noteBookSize)
        p.initialize(repeating: NoteBookEntry(), count: NoteOutput.noteBookSize)
        return p
    }()
    /// Je Ausgang: untere Schranke des frühesten `pendingOff` (.max = keins) — erspart den
    /// Durchlauf von Abschnitten, in denen nichts fällig ist. Gehört wie das Buch dem
    /// Inhaber des Tick-Zutritts.
    private let earliestPendingOff: UnsafeMutablePointer<UInt64> = {
        let p = UnsafeMutablePointer<UInt64>.allocate(capacity: NoteOutput.portCount)
        p.initialize(repeating: .max, count: NoteOutput.portCount)
        return p
    }()
    /// Je Ausgang: Belegungsepoche, zu der die Einträge des Buchabschnitts gehören
    /// (v1.13.13). Gehört wie das Buch dem Inhaber des Tick-Zutritts.
    private let portEpoch: UnsafeMutablePointer<UInt32> = {
        let p = UnsafeMutablePointer<UInt32>.allocate(capacity: NoteOutput.portCount)
        p.initialize(repeating: 0, count: NoteOutput.portCount)
        return p
    }()
    /// Für den Off-Wächter (Main): gibt es ungesendete Offs, und wann lief der letzte
    /// externe Tick? Beides vom Tick-Thread geschrieben.
    let hasPendingOffs  = ManagedAtomic<Bool>(false)

    @inline(__always) @discardableResult
    func outNoteOn(route: Int, epoch: UInt32, channel: Int, note: Int, velocity: Int,
                           at t: MIDITimeStamp) -> Bool {
        if route < 0 {
            midi.noteOn(channel: channel, note: note, velocity: velocity, at: t)
            return true
        }
        return rack.queues[route]._withUnsafeGuaranteedRef {
            $0.pushFromTick(UInt8(0x90 | (channel - 1) & 0x0F), UInt8(note & 0x7F),
                            UInt8(velocity & 0x7F), at: t, epoch: epoch)
        }
    }

    @inline(__always) @discardableResult
    func outNoteOff(route: Int, epoch: UInt32, channel: Int, note: Int,
                            at t: MIDITimeStamp) -> Bool {
        if route < 0 {
            midi.noteOff(channel: channel, note: note, at: t)
            return true
        }
        return rack.queues[route]._withUnsafeGuaranteedRef {
            $0.pushFromTick(UInt8(0x80 | (channel - 1) & 0x0F), UInt8(note & 0x7F), 0,
                            at: t, epoch: epoch)
        }
    }

    @inline(__always) @discardableResult
    func outCC(route: Int, epoch: UInt32, channel: Int, number: Int, value: Int,
                       at t: MIDITimeStamp) -> Bool {
        if route < 0 {
            midi.cc(channel: channel, number: number, value: value, at: t)
            return true
        }
        return rack.queues[route]._withUnsafeGuaranteedRef {
            $0.pushFromTick(UInt8(0xB0 | (channel - 1) & 0x0F), UInt8(number & 0x7F),
                            UInt8(value & 0x7F), at: t, epoch: epoch)
        }
    }

    /// Tick-Pfad: gibt ein Note-On aus und trägt sein Off ins Buch ein.
    ///
    /// Steht für dieselbe Note noch ein ungesendetes Off aus, wird es aufgelöst:
    ///   - es läge NACH diesem On (Überlappung) → Off genau auf dem neuen On (Neuanschlag);
    ///     die Note klingt bis zum späteren der beiden Enden.
    ///   - es liegt davor oder gleich → jetzt mit seinem eigenen Zeitpunkt senden.
    ///
    /// `tie` (Drone): klingt die Note noch (ihr Off steht nicht vor diesem On aus), wird nur
    /// ihr Ende hinausgeschoben — kein Off, kein neues On.
    ///
    /// **Ablehnung (v1.13.13).** Weist die Warteschlange eines Instruments ein Ereignis ab
    /// (voll), bleibt das Buch ehrlich: ein abgewiesenes Off gilt nicht als gesendet — die
    /// alte Note klingt weiter, es gibt keinen Neuanschlag, ihr Ende wird bis `off`
    /// verlängert. Ein abgewiesenes On hinterlässt keinen Off-Auftrag.
    ///
    /// **Belegung.** Wechselt die Belegung eines Instrument-Slots (anderes Instrument), gehören
    /// die offenen Offs dieses Buchabschnitts der vorigen Belegung; sie werden verworfen.
    @inline(__always)
    func sendNote(route: Int, epoch: UInt32, channel: Int, note: Int, velocity: Int,
                          on: MIDITimeStamp, off: MIDITimeStamp, tie: Bool = false) {
        let port = route + 1                                   // Snapshot-Werte sind geclampt
        if route >= 0, portEpoch[port] != epoch { resetPort(port, epoch: epoch) }
        let e = noteBook + (port * Self.notesPerPort + (channel - 1) * 128 + note)
        let pending = e.pointee.pendingOff
        if tie, pending >= on, pending != 0 {
            // `earliestPendingOff` darf zu früh stehen: der nächste Durchlauf der Off-Ausgabe
            // rechnet es neu.
            if off > pending { e.pointee.pendingOff = off }
            return
        }
        if pending == 0 {
            guard outNoteOn(route: route, epoch: epoch, channel: channel, note: note,
                            velocity: velocity, at: on) else { return }
            e.pointee.pendingOff = off
        } else {
            let offAt = pending > on ? on : pending
            guard outNoteOff(route: route, epoch: epoch, channel: channel, note: note, at: offAt) else {
                // Off abgewiesen: alte Note klingt weiter, Ende verlängern, kein Neuanschlag.
                e.pointee.pendingOff = max(pending, off)
                if e.pointee.pendingOff < earliestPendingOff[port] { earliestPendingOff[port] = e.pointee.pendingOff }
                return
            }
            if pending <= on { e.pointee.sentOff = pending }
            if outNoteOn(route: route, epoch: epoch, channel: channel, note: note,
                         velocity: velocity, at: on) {
                e.pointee.pendingOff = pending > on ? max(pending, off) : off
            } else {
                e.pointee.sentOff    = offAt              // Note ist mit dem Off beendet
                e.pointee.pendingOff = 0
                return
            }
        }
        if on > e.pointee.lastOn { e.pointee.lastOn = on }
        if e.pointee.pendingOff < earliestPendingOff[port] { earliestPendingOff[port] = e.pointee.pendingOff }
    }

    /// Belegung eines Instrument-Slots hat gewechselt: offene Offs der vorigen Belegung
    /// verwerfen (ihr Instrument gibt es nicht mehr). Tick-Zutritt. Fest begrenzt
    /// (ein Buchabschnitt), nur bei einem Wechsel.
    @inline(__always)
    private func resetPort(_ port: Int, epoch: UInt32) {
        (noteBook + port * Self.notesPerPort).update(repeating: NoteBookEntry(), count: Self.notesPerPort)
        earliestPendingOff[port] = .max
        portEpoch[port] = epoch
    }

    /// Übergibt alle Offs bis einschließlich `horizon` an ihren Ausgang, jedes mit seinem
    /// eigenen Zeitpunkt. Nur als Inhaber des Tick-Zutritts aufrufen.
    ///
    /// Horizont im Tick-Pfad ist der Tick-Zeitpunkt T(k): der nächste Tick wird erst kurz vor
    /// T(k) ausgegeben und erzeugt nur Ons nach T(k) — ein hier gesendetes Off kann also
    /// keine später begonnene Note mehr treffen.
    @inline(__always)
    func flushDueNoteOffs(upTo horizon: UInt64) {
        var anyPending = false
        for port in 0..<Self.portCount {
            let first = earliestPendingOff[port]
            if first == .max { continue }
            if first > horizon { anyPending = true; continue }
            let base  = port * Self.notesPerPort
            let route = port - 1
            var earliest = UInt64.max
            for i in 0..<Self.notesPerPort {
                let due = noteBook[base + i].pendingOff
                if due == 0 { continue }
                if due <= horizon,
                   outNoteOff(route: route, epoch: portEpoch[port], channel: i / 128 + 1,
                              note: i % 128, at: due) {
                    noteBook[base + i].sentOff    = due
                    noteBook[base + i].pendingOff = 0
                } else if due < earliest {
                    // Noch nicht fällig — oder abgewiesen: bleibt im Buch, nächster Tick
                    // versucht es erneut (verspätet, aber nicht verloren).
                    earliest = due
                }
            }
            earliestPendingOff[port] = earliest
            if earliest != .max { anyPending = true }
        }
        // Der Off-Wächter muss wissen, ob etwas aussteht.
        hasPendingOffs.store(anyPending, ordering: .relaxed)
    }

    /// Songende im Tick (v1.16.1, Codex V16-1): jede noch klingende Note endet spätestens auf
    /// `end` — ihr Off geht jetzt mit dem Zeitpunkt min(geplantes Off, end) an ihren Ausgang.
    /// Danach ist das Buch leer; Main muss für das Songende nichts mehr nachsenden. Nur als
    /// Inhaber des Tick-Zutritts aufrufen. Fest begrenzt, keine Allokation.
    func endAllNotes(at end: UInt64) {
        for port in 0..<Self.portCount {
            if earliestPendingOff[port] == .max { continue }
            let base  = port * Self.notesPerPort
            let route = port - 1
            var earliest = UInt64.max
            for i in 0..<Self.notesPerPort {
                let due = noteBook[base + i].pendingOff
                if due == 0 { continue }
                // Ein schon übergebenes On hinter dem Ende (Ratchet, Swing, Offset) lässt sich
                // nicht zurückholen: sein Off kommt dann direkt danach, nie davor.
                var at = min(due, end)
                let lastOn = noteBook[base + i].lastOn
                if lastOn >= at { at = lastOn &+ Self.safetyOffsetMach }
                if outNoteOff(route: route, epoch: portEpoch[port], channel: i / 128 + 1,
                              note: i % 128, at: at) {
                    noteBook[base + i].sentOff    = at
                    noteBook[base + i].pendingOff = 0
                } else if due < earliest {
                    earliest = due   // Warteschlange voll: bleibt für den Aufräumpfad im Buch
                }
            }
            earliestPendingOff[port] = earliest
        }
        var any = false
        for port in 0..<Self.portCount where earliestPendingOff[port] != .max { any = true }
        hasPendingOffs.store(any, ordering: .relaxed)
    }

    /// Beendet jede Note, deren Off noch aussteht — ungesendet oder gesendet, aber noch in der
    /// Zukunft (MIDIFlushOutput kann es verworfen haben) — und leert das Buch. Nur aufrufen,
    /// wenn kein Tick läuft (activeTick == false und isPlayingRT == false).
    ///
    /// Externe MIDI-Ausgabe: Liegt das letzte On der Note selbst noch in der Zukunft
    /// (Ratchet/Swing/Offset planen Ons bis knapp einen Step voraus), bekommt das Off dessen
    /// Zeitpunkt + 1 ms: Der gewählte Ausgang hat das On per Flush bereits verworfen, die
    /// virtuelle Quelle liefert es aber noch aus (für `MIDIReceived` gibt es keinen Flush,
    /// Befund B5) — das Off muss danach kommen.
    ///
    /// Gehostete Instrumente: Zuerst wird alles Geplante verworfen (`silenceAll`, inklusive
    /// All Notes Off); danach genügt ein sofortiges Off je offener Note.
    func sendPendingNoteOffs() {
        rack.silenceAll()
        let now = mach_absolute_time()
        for i in 0..<Self.noteBookSize {
            let e = noteBook[i]
            guard e.pendingOff != 0 || e.sentOff > now else { continue }
            let route = i / Self.notesPerPort - 1
            let key   = i % Self.notesPerPort
            if route < 0 {
                midi.noteOff(channel: key / 128 + 1, note: key % 128,
                             at: e.lastOn > now ? e.lastOn + Self.safetyOffsetMach : 0)
            } else {
                rack.sendFromMain(route: route, epoch: portEpoch[route + 1],
                                  UInt8(0x80 | (key / 128) & 0x0F), UInt8(key % 128), 0)
            }
        }
        clear()
    }

    func clear() {
        noteBook.update(repeating: NoteBookEntry(), count: Self.noteBookSize)
        earliestPendingOff.update(repeating: .max, count: Self.portCount)
        hasPendingOffs.store(false, ordering: .relaxed)
    }

    #if DEBUG
    func _entry(channel: Int, note: Int, route: Int) -> NoteBookEntry {
        noteBook[(route + 1) * Self.notesPerPort + (channel - 1) * 128 + note]
    }
    #endif
}
