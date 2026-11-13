import SwiftUI
import Combine

struct StepDetailView: View {
    @ObservedObject var track: TrackViewModel
    let index:       Int
    var accentColor: Color = VintageTheme.amber

    @Environment(\.dismiss)     private var dismiss
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage")  private var lang: String = "en"
    private var s: Str { Str(lang) }

    private var step: Step { track.lane.steps[index] }

    /// Modify a step field via ModelWriter; Undo bleibt erhalten (Slice E).
    private let writer = ModelWriter()

    /// Laufender Knob-Drag: Ausgangszustand + „wurde geändert". Referenztyp, damit der
    /// Zustand im selben Event sofort lesbar ist (kein View-Update dazwischen nötig).
    private final class KnobEdit { var baseline: [Step]?; var dirty = false }
    @State private var knobEdit = KnobEdit()

    private func modify(_ transform: (inout Step) -> Void) {
        let old = track.lane.steps
        var updated = track.lane.steps
        guard updated.indices.contains(index) else { return }
        transform(&updated[index])
        // Während eines Knob-Drags live ohne Undo schreiben; der Drag wird am Ende als
        // ein einziger Undo-Schritt registriert (knobEditingChanged).
        let dragging = knobEdit.baseline != nil
        if dragging { knobEdit.dirty = true }
        writer.apply(.setSteps(trackID: track.id,
                               oldSteps: old,
                               newSteps: updated,
                               actionName: s.undoStepEdit),
                     to: track.data,
                     undoManager: dragging ? nil : undoManager)
    }

    private func knobEditingChanged(_ editing: Bool) {
        if editing {
            knobEdit.baseline = track.lane.steps
            knobEdit.dirty    = false
            return
        }
        defer { knobEdit.baseline = nil; knobEdit.dirty = false }
        guard let baseline = knobEdit.baseline, knobEdit.dirty else { return }
        writer.apply(.setSteps(trackID: track.id,
                               oldSteps: baseline,
                               newSteps: track.lane.steps,
                               actionName: s.undoStepEdit),
                     to: track.data,
                     undoManager: undoManager)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // ── Header ─────────────────────────────────────────────────────
            HStack {
                Circle().fill(accentColor).frame(width: 8, height: 8)
                    .shadow(color: accentColor.opacity(0.8), radius: 4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(s.stepHeader(index + 1))
                        .font(VintageTheme.monoBold)
                        .foregroundColor(VintageTheme.textAmber)
                    if track.isDrum {
                        Text(GMDrumMap.name(for: step.note) ?? step.noteName)
                            .font(VintageTheme.monoSmall).foregroundColor(accentColor.opacity(0.85))
                    } else {
                        Text(step.chordName)
                            .font(.system(size: 13, weight: .bold, design: .monospaced))
                            .foregroundColor(accentColor)
                    }
                }
                Spacer()
                // Step auf Grundzustand (früher im Kontextmenü des Steps).
                Button(s.clearStep) { modify { $0 = Step() } }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Toggle(s.active, isOn: Binding(
                    get: { step.isActive },
                    set: { v in modify { $0.isActive = v } }
                ))
                .toggleStyle(.switch).tint(accentColor)
                .font(VintageTheme.monoSmall)
            }

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            // ── Dynamics ────────────────────────────────────────────────────
            // ROOT-Knob transponiert den gesamten Akkord
            HStack(spacing: 18) {
                KnobView(label: "ROOT",
                         value: Binding(
                            get: { Double(step.note) },
                            set: { v in modify { s in
                                let diff = Int(v) - s.note
                                let shifted = s.notes.map { $0 + diff }
                                // Nur transponieren wenn alle Noten im gültigen Bereich bleiben
                                guard shifted.allSatisfy({ (0...127).contains($0) }) else { return }
                                s.notes = shifted.sorted()
                            }}),
                         range: 0...127, size: 44, accentColor: accentColor)

                KnobView(label: "VEL",
                         value: Binding(get: { Double(step.velocity) },
                                        set: { v in modify { $0.velocity = Int(v) } }),
                         range: 1...127, size: 44, accentColor: accentColor)

                GateKnobView(gate: Binding(
                    get: { step.gate },
                    set: { v in modify { $0.gate = v } }),
                    accentColor: accentColor)

                KnobView(label: "PROB%",
                         value: Binding(get: { step.probability * 100 },
                                        set: { v in modify { $0.probability = v / 100.0 } }),
                         range: 0...100, size: 44, accentColor: accentColor)
            }

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            // ── Ratchet ─────────────────────────────────────────────────────
            // Step-Lane-Purify P1 (v1.10.0): CC1/CC2-Knobs entfernt. Step-Lanes
            // tragen keine Per-Step-CC-Werte mehr im sichtbaren Verhalten.
            HStack(spacing: 18) {
                // Drone: Ton hält über die ganze Spurlänge (ersetzt Gate und Ratchet).
                VStack(alignment: .leading, spacing: 5) {
                    Text(s.droneLabel)
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textSecondary)
                    Button(step.isDrone ? "ON" : "OFF") { modify { $0.isDrone.toggle() } }
                        .buttonStyle(VintageSmallButtonStyle(isActive: step.isDrone, accent: accentColor))
                        .help(s.droneHelp)
                }

                Spacer()

                VStack(alignment: .leading, spacing: 5) {
                    Text("RATCHET")
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textSecondary)
                    HStack(spacing: 5) {
                        ForEach(RatchetCount.allCases) { r in
                            Button(r.label) { modify { $0.ratchet = r } }
                                .buttonStyle(VintageSmallButtonStyle(
                                    isActive: step.ratchet == r,
                                    accent: accentColor))
                        }
                    }
                }
                .opacity(step.isDrone ? 0.4 : 1)     // gilt bei Drone nicht
            }

            // ── Akkord / Drum picker ────────────────────────────────────────
            if track.isDrum {
                VStack(alignment: .leading, spacing: 4) {
                    Text(s.drumSound)
                        .font(VintageTheme.monoSmall)
                        .foregroundColor(VintageTheme.textSecondary)
                    DrumPickerGrid(
                        note: Binding(get: { step.note },
                                      set: { v in modify { $0.note = v } }),
                        accentColor: accentColor,
                        track: track)
                }
            } else {
                PianoKeyboardView(
                    notes: Binding(
                        get: { step.notes },
                        set: { v in modify { $0.notes = v.isEmpty ? [60] : v } }),
                    accentColor: accentColor,
                    track: track,
                    onUnison: step.notes.count > 1 ? { modify { $0.notes = [$0.note] } } : nil)
            }
        }
        .padding(16)
        .background(VintageTheme.panelDark)
        .frame(width: track.isDrum ? 480 : 660)
        .preferredColorScheme(.dark)
        .environment(\.knobEditingChanged, knobEditingChanged)
        // Enter schließt das Popover
        .background(
            Button("") { dismiss() }
                .keyboardShortcut(.return, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
        )
    }
}

// MARK: - Multi-step editor

struct MultiStepEditView: View {
    @ObservedObject var track: TrackViewModel
    let indices: [Int]
    var accentColor: Color
    @EnvironmentObject private var engine: SequencerEngine
    @Environment(\.dismiss) private var dismiss
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    // Local override values
    @State private var noteVal:       Double = 64
    @State private var velVal:        Double = 100
    @State private var gateVal:       Double = 0.5
    @State private var probVal:       Double = 100
    // Transpose: Snapshot der Ausgangsnoten + Offset-Regler
    @State private var transposeBase:   [Int: [Int]] = [:]
    @State private var transposeOffset: Double = 0

    private let writer = ModelWriter()
    /// Stand der Steps beim Öffnen. Alle Änderungen dieses Dialogs schreiben live ohne
    /// Undo und werden beim Schließen als EIN Undo-Schritt registriert (v1.12.23; vorher
    /// war der Mehrfacheditor gar nicht rücknehmbar).
    private final class EditSession { var baseline: [Step]?; var dirty = false }
    @State private var session = EditSession()

    private func applyAll(_ transform: (inout Step) -> Void) {
        let old = track.lane.steps
        var steps = track.lane.steps
        for i in indices where steps.indices.contains(i) { transform(&steps[i]) }
        session.dirty = true
        writer.apply(.setSteps(trackID: track.id,
                               oldSteps: old,
                               newSteps: steps,
                               actionName: s.undoBulkEdit),
                     to: track.data,
                     undoManager: nil)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {

            // Header
            HStack {
                Circle().fill(accentColor).frame(width: 8, height: 8)
                    .shadow(color: accentColor.opacity(0.8), radius: 4)
                Text(s.bulkHeader(indices.count))
                    .font(VintageTheme.monoBold)
                    .foregroundColor(VintageTheme.textAmber)
                Spacer()
                Button(s.done) { dismiss() }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
            }

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            // Note / Drum picker
            VStack(alignment: .leading, spacing: 4) {
                Text(track.isDrum ? s.drumSoundBulk(indices.count) : s.noteBulk(indices.count))
                    .font(VintageTheme.monoSmall)
                    .foregroundColor(VintageTheme.textSecondary)
                if track.isDrum {
                    DrumPickerGrid(
                        note: Binding(get: { Int(noteVal) },
                                      set: { v in noteVal = Double(v); applyAll { $0.note = v } }),
                        accentColor: accentColor,
                        track: track)
                } else {
                    NotePickerRow(
                        note: Binding(get: { noteVal },
                                      set: { v in noteVal = v; applyAll { $0.note = Int(v) } }),
                        accentColor: accentColor)
                }
            }

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            // Dynamics
            HStack(spacing: 18) {
                VStack(spacing: 2) {
                    KnobView(label: "VEL",
                             value: Binding(get: { velVal },
                                            set: { v in velVal = v; applyAll { $0.velocity = Int(v) } }),
                             range: 1...127, size: 44, accentColor: accentColor)
                }
                GateKnobView(gate: Binding(
                    get: { gateVal },
                    set: { v in gateVal = v; applyAll { $0.gate = v } }),
                    accentColor: accentColor)
                VStack(spacing: 2) {
                    KnobView(label: "PROB%",
                             value: Binding(get: { probVal },
                                            set: { v in probVal = v; applyAll { $0.probability = v / 100 } }),
                             range: 0...100, size: 44, accentColor: accentColor)
                }
                Spacer()
            }

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            // Transpose
            HStack(spacing: 10) {
                KnobView(
                    label: "TRNS",
                    value: Binding(
                        get: { transposeOffset },
                        set: { v in
                            transposeOffset = v
                            let semi = Int(v.rounded())
                            let old  = track.lane.steps
                            var steps = track.lane.steps
                            for i in indices {
                                guard let base = transposeBase[i] else { continue }
                                steps[i].notes = base.map { max(0, min(127, $0 + semi)) }
                            }
                            session.dirty = true
                            writer.apply(.setSteps(trackID: track.id,
                                                   oldSteps: old,
                                                   newSteps: steps,
                                                   actionName: s.undoBulkEdit),
                                         to: track.data,
                                         undoManager: nil)
                        }
                    ),
                    range: -24...24,
                    size: 44,
                    accentColor: accentColor
                )
                VStack(alignment: .leading, spacing: 4) {
                    let semi = Int(transposeOffset.rounded())
                    Text(semi == 0 ? "±0 st" : (semi > 0 ? "+\(semi) st" : "\(semi) st"))
                        .font(VintageTheme.monoBold)
                        .foregroundColor(semi == 0 ? VintageTheme.textSecondary : accentColor)
                    Button("RESET") {
                        transposeOffset = 0
                        let old = track.lane.steps
                        var steps = track.lane.steps
                        for i in indices {
                            guard let base = transposeBase[i] else { continue }
                            steps[i].notes = base
                        }
                        session.dirty = true
                        writer.apply(.setSteps(trackID: track.id,
                                               oldSteps: old,
                                               newSteps: steps,
                                               actionName: s.undoBulkEdit),
                                     to: track.data,
                                     undoManager: nil)
                    }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
                }
                Spacer()
            }

            Rectangle().fill(VintageTheme.panelBorder).frame(height: 1)

            // Bulk actions
            HStack(spacing: 6) {
                Button(s.allOn)    { applyAll { $0.isActive = true  } }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Button(s.allOff)   { applyAll { $0.isActive = false } }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
                Spacer()
                Button(s.copyBulk) { engine.copySteps(from: track.data, at: indices) }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Button(s.clearBulk) { applyAll { $0 = Step() } }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .red))
            }
        }
        .padding(16)
        .background(VintageTheme.panelDark)
        .frame(width: track.isDrum ? 460 : 400)
        .preferredColorScheme(.dark)
        .onAppear {
            // Snapshot der aktuellen Noten für Transpose-Referenz
            for i in indices where track.lane.steps.indices.contains(i) {
                transposeBase[i] = track.lane.steps[i].notes
            }
            session.baseline = track.lane.steps
            session.dirty    = false
        }
        .onDisappear {
            // Das Sheet hat keinen eigenen Undo-Manager in der Umgebung — der des
            // Hauptfensters liegt an der Engine.
            guard let old = session.baseline, session.dirty else { return }
            writer.apply(.setSteps(trackID: track.id,
                                   oldSteps: old,
                                   newSteps: track.lane.steps,
                                   actionName: s.undoBulkEdit),
                         to: track.data,
                         undoManager: engine.undoManager)
        }
    }
}

// MARK: - Drum picker grid (channel 10)

private struct DrumPickerGrid: View {
    @Binding var note: Int
    var accentColor: Color
    /// Spur für die hörbare Vorschau beim Anklicken (Ausgang und Kanal).
    var track: TrackViewModel?
    @EnvironmentObject private var engine: SequencerEngine

    // Groups: [label, [(note, shortName)]]
    // Group labels localized via Str at call site — names are universal music terms
    private let groups: [(String, [(Int, String)])] = [
        ("KICK / SNARE", [(35,"Kick 2"),(36,"Kick"),(37,"Stick"),(38,"Snare"),(39,"Clap"),(40,"Snare 2")]),
        ("HI-HAT",       [(42,"HH Cls"),(44,"HH Ped"),(46,"HH Opn")]),
        ("TOMS",         [(41,"Tom FL"),(43,"Tom FH"),(45,"Tom L"),(47,"Tom LM"),(48,"Tom HM"),(50,"Tom H")]),
        ("CYMBAL",       [(49,"Crash"),(57,"Crash 2"),(51,"Ride"),(59,"Ride 2"),(52,"China"),(55,"Splash"),(56,"Cowbell")]),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(groups, id: \.0) { group in
                HStack(spacing: 4) {
                    Text(group.0)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(VintageTheme.textDim)
                        .frame(width: 62, alignment: .leading)
                    ForEach(group.1, id: \.0) { midiNote, name in
                        Button(name) {
                            note = midiNote
                            if let track { engine.previewNote(midiNote, on: track.data) }
                        }
                            .buttonStyle(VintageSmallButtonStyle(
                                isActive: note == midiNote,
                                accent: accentColor))
                    }
                }
            }
        }
    }
}

// MARK: - Piano keyboard (chord editor, 5 Oktaven)

private struct PianoKeyboardView: View {
    @Binding var notes: [Int]
    var accentColor: Color
    var track: TrackViewModel? = nil
    var onUnison: (() -> Void)? = nil   // nil = Button nicht anzeigen

    @EnvironmentObject private var engine: SequencerEngine
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    @State private var displayOctave: Int = 2   // C2–B6 als Standard (5 Oktaven)
    /// false: Klick ersetzt den Ton. true: Klick fügt Akkordton hinzu / entfernt ihn.
    /// Startwert folgt dem Step (mehrere Töne → Akkord). ⇧-Klick wirkt immer als Akkord.
    @State private var chordMode: Bool = false

    private let numOctaves   = 5
    private let whiteIntervals = [0, 2, 4, 5, 7, 9, 11]
    private let blackKeyData: [(semitone: Int, fraction: Double)] = [
        (1, 0.68), (3, 1.68), (6, 3.73), (8, 4.73), (10, 5.73)
    ]

    private var baseNote: Int { (displayOctave + 1) * 12 }
    private var numWhite:  Int { numOctaves * 7 }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            // Navigation + 8va-Transpose + UNISON
            HStack(spacing: 5) {
                Button("◂") { if displayOctave > 0 { displayOctave -= 1 } }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Text("C\(displayOctave)–B\(displayOctave + numOctaves - 1)")
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textAmber)
                    .frame(width: 82, alignment: .center)
                Button("▸") { if displayOctave < 5 { displayOctave += 1 } }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Divider().frame(height: 16).padding(.horizontal, 2)
                Button(s.noteModeSingle) { chordMode = false }
                    .buttonStyle(VintageSmallButtonStyle(isActive: !chordMode, accent: accentColor))
                    .help(s.noteModeHelp)
                Button(s.noteModeChord) { chordMode = true }
                    .buttonStyle(VintageSmallButtonStyle(isActive: chordMode, accent: accentColor))
                    .help(s.noteModeHelp)
                Spacer()
                Text("8va:")
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textSecondary)
                Button("−") {
                    let s = notes.map { $0 - 12 }
                    if s.allSatisfy({ (0...127).contains($0) }) { notes = s.sorted() }
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Button("+") {
                    let s = notes.map { $0 + 12 }
                    if s.allSatisfy({ (0...127).contains($0) }) { notes = s.sorted() }
                }
                .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                if let unison = onUnison {
                    Divider().frame(height: 16).padding(.horizontal, 2)
                    Button(s.unison) { unison() }
                        .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: .gray))
                }
            }

            // Tastatur-Rahmen (schwarz wie echtes Piano)
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(Color(white: 0.08))

                GeometryReader { geo in
                    let gap: CGFloat = 1.0
                    let wkW = (geo.size.width - CGFloat(numWhite - 1) * gap) / CGFloat(numWhite)
                    let wkH = geo.size.height
                    let bkW = wkW * 0.62
                    let bkH = wkH * 0.60

                    ZStack(alignment: .topLeading) {
                        // Weiße Tasten
                        HStack(spacing: gap) {
                            ForEach(0 ..< numWhite, id: \.self) { wi in
                                let oct  = wi / 7
                                let si   = wi % 7
                                let midi = baseNote + oct * 12 + whiteIntervals[si]
                                let ok   = midi <= 127
                                let inC  = ok && notes.contains(midi)
                                let inSc = !ok || (track?.noteInScale(midi) ?? true)
                                let isC  = whiteIntervals[si] == 0   // C-Taste

                                ZStack(alignment: .bottom) {
                                    RoundedRectangle(cornerRadius: 2)
                                        .fill(inC
                                            ? LinearGradient(colors: [accentColor.opacity(0.85), accentColor],
                                                             startPoint: .top, endPoint: .bottom)
                                            : LinearGradient(colors: [Color(white: inSc ? 0.97 : 0.78),
                                                                       Color(white: inSc ? 0.88 : 0.68)],
                                                             startPoint: .top, endPoint: .bottom))
                                    // C-Beschriftung
                                    if isC && ok {
                                        Text("C\(displayOctave + oct)")
                                            .font(.system(size: 6, design: .monospaced))
                                            .foregroundColor(inC ? .white.opacity(0.9)
                                                                  : Color(white: 0.5))
                                            .padding(.bottom, 3)
                                    }
                                }
                                .overlay(RoundedRectangle(cornerRadius: 2)
                                    .stroke(Color(white: 0.6), lineWidth: 0.5))
                                .frame(width: wkW, height: wkH)
                                .opacity(ok ? 1 : 0.15)
                            }
                        }

                        // Schwarze Tasten (Vordergrund)
                        ForEach(0 ..< numOctaves, id: \.self) { oct in
                            ForEach(0 ..< blackKeyData.count, id: \.self) { bi in
                                let bk   = blackKeyData[bi]
                                let midi = baseNote + oct * 12 + bk.semitone
                                let ok   = midi <= 127
                                let inC  = ok && notes.contains(midi)
                                let inSc = !ok || (track?.noteInScale(midi) ?? true)
                                let xCtr = (CGFloat(oct * 7) + CGFloat(bk.fraction)) * (wkW + gap)

                                RoundedRectangle(cornerRadius: 2)
                                    .fill(inC
                                        ? LinearGradient(colors: [accentColor.opacity(0.9), accentColor],
                                                         startPoint: .top, endPoint: .bottom)
                                        : LinearGradient(colors: [Color(white: 0.22), Color.black],
                                                         startPoint: .top, endPoint: .bottom))
                                    .overlay(RoundedRectangle(cornerRadius: 2)
                                        .stroke(inC ? accentColor.opacity(0.7)
                                                    : Color.gray.opacity(0.35), lineWidth: 0.5))
                                    .frame(width: bkW, height: bkH)
                                    .position(x: xCtr, y: bkH / 2)
                                    .opacity(ok ? (inSc ? 1.0 : 0.45) : 0.1)
                            }
                        }
                    }
                    // Manuelle Hit-Test-Geste (schwarze Tasten haben Priorität)
                    .gesture(
                        SpatialTapGesture()
                            .onEnded { val in
                                guard let midi = hitTest(val.location,
                                                         wkW: wkW, gap: gap, wkH: wkH,
                                                         bkW: bkW, bkH: bkH)
                                else { return }
                                // Vorschau und Eintrag verwenden denselben, auf die Skala
                                // gezogenen Ton (vorher: angeklickter Ton gehört, anderer gespeichert).
                                let snapped = track?.quantizedNote(midi) ?? midi
                                if let track { engine.previewNote(snapped, on: track.data) }
                                if chordMode || NSEvent.modifierFlags.contains(.shift) {
                                    toggleNote(snapped)
                                } else {
                                    notes = [snapped]
                                }
                            }
                    )
                }
                .padding(4)   // kleiner Rahmen
            }
            .frame(height: 92)

            // Tonart-Hinweis
            if let t = track, t.scaleIndex > 0 {
                Text(s.scaleHint(TrackData.noteNames[t.scaleRoot], TrackData.scales[t.scaleIndex].name))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
            }
        }
        .onAppear {
            if let first = notes.first {
                displayOctave = max(0, min(5, (first / 12) - 2))
            }
            chordMode = notes.count > 1
        }
    }

    // MARK: - Hit-Test: schwarze Tasten zuerst

    private func hitTest(_ p: CGPoint, wkW: CGFloat, gap: CGFloat, wkH: CGFloat,
                         bkW: CGFloat, bkH: CGFloat) -> Int? {
        for oct in 0 ..< numOctaves {
            for bk in blackKeyData {
                let midi  = baseNote + oct * 12 + bk.semitone
                guard midi <= 127 else { continue }
                let xCtr  = (CGFloat(oct * 7) + CGFloat(bk.fraction)) * (wkW + gap)
                let xLeft = xCtr - bkW / 2
                if CGRect(x: xLeft, y: 0, width: bkW, height: bkH).contains(p) { return midi }
            }
        }
        guard p.x >= 0, p.y >= 0, p.y <= wkH else { return nil }
        let wi = Int(p.x / (wkW + gap))
        guard wi >= 0, wi < numWhite else { return nil }
        let midi = baseNote + (wi / 7) * 12 + whiteIntervals[wi % 7]
        return midi <= 127 ? midi : nil
    }

    // MARK: - Akkordton ein-/ausschalten

    private func toggleNote(_ snapped: Int) {
        if notes.contains(snapped) {
            if notes.count > 1 { notes.removeAll { $0 == snapped } }
        } else {
            notes.append(snapped); notes.sort()
        }
    }
}

// MARK: - Quick note picker (Single-Note, für Bulk-Edit)

private struct NotePickerRow: View {
    @Binding var note: Double
    var accentColor: Color
    var track: TrackViewModel? = nil
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }
    private let noteNames = ["C","C#","D","D#","E","F","F#","G","G#","A","A#","B"]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 3) {
                let octave = (Int(note) / 12) - 1
                Button("-") { note = max(0, note - 12) }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Text("C\(octave)")
                    .font(VintageTheme.monoSmall).foregroundColor(VintageTheme.textAmber).frame(width: 24)
                Button("+") { note = min(127, note + 12) }
                    .buttonStyle(VintageSmallButtonStyle(isActive: false, accent: accentColor))
                Spacer().frame(width: 8)
                ForEach(0..<12, id: \.self) { semitone in
                    let candidate = (Int(note) / 12) * 12 + semitone
                    let inScale   = track?.noteInScale(candidate) ?? true
                    Button(noteNames[semitone]) {
                        let oct     = Int(note) / 12
                        let raw     = min(127, oct * 12 + semitone)
                        let snapped = track?.quantizedNote(raw) ?? raw
                        note = Double(snapped)
                    }
                    .buttonStyle(VintageSmallButtonStyle(
                        isActive: Int(note) % 12 == semitone,
                        accent: accentColor))
                    .opacity(inScale ? (noteNames[semitone].contains("#") ? 0.75 : 1.0) : 0.22)
                }
            }
            if let t = track, t.scaleIndex > 0 {
                let rootName  = TrackData.noteNames[t.scaleRoot]
                let scaleName = TrackData.scales[t.scaleIndex].name
                Text(s.scaleHint(rootName, scaleName))
                    .font(.system(size: 8, design: .monospaced))
                    .foregroundColor(VintageTheme.textSecondary)
            }
        }
    }
}
