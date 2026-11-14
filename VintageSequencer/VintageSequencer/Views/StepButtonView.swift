import SwiftUI
import AppKit
import Combine

struct StepButtonView: View {
    @ObservedObject var track: TrackViewModel
    let index: Int
    var trackIndex:      Int        = 0
    var isCurrentStep:   Bool       = false
    var isSelected:      Bool       = false
    var accentColor:     Color      = VintageTheme.amber
    var size:            CGFloat    = VintageTheme.stepSize   // Höhe + Basis-Skalierung
    var width:          CGFloat?   = nil                      // falls gesetzt: andere Breite (Stretch)
    var onToggleSelect:  (() -> Void)? = nil
    /// Edit-Card öffnen (⌥+Klick). Die Card hängt an der Zelle in `StepGridView`, damit auch
    /// der Sekundärklick der Lane sie öffnen kann.
    var onEdit:          (() -> Void)? = nil

    @EnvironmentObject  private var engine: SequencerEngine
    @EnvironmentObject  private var mls: MIDILearnState
    @Environment(\.undoManager) private var undoManager
    @AppStorage("appLanguage") private var lang: String = "en"
    private var s: Str { Str(lang) }

    private var isLearnTarget: Bool {
        mls.learnMode &&
        mls.learnTarget?.track == trackIndex &&
        mls.learnTarget?.step  == index
    }

    private var step: Step { track.lane.steps[index] }

    private var noteLabel: String {
        if let fixed = track.lane.fixedNote {          // fester Ton der Spur (v1.13.16)
            if track.isDrum, let drumName = GMDrumMap.name(for: fixed) { return drumName }
            var single = Step(); single.notes = [fixed]
            return single.shortChordName
        }
        if track.isDrum,
           let drumName = GMDrumMap.name(for: step.note) { return drumName }
        return step.shortChordName   // Einzelnote: "C4", Akkord: "Cmaj7", "Dm7" etc.
    }

    private var noteLabelFontSize: CGFloat {
        let len = noteLabel.count
        if len <= 3 { return size < 44 ? 9 : 10 }
        if len <= 5 { return size < 44 ? 7 : 8  }
        return size < 44 ? 6 : 7
    }

    // Modify step via ModelWriter — Undo-Registrierung bleibt erhalten (Slice E).
    private let writer = ModelWriter()

    private func modifyStep(_ transform: (inout Step) -> Void) {
        let old = track.lane.steps
        var updated = track.lane.steps
        transform(&updated[index])
        writer.apply(.setSteps(trackID: track.id,
                               oldSteps: old,
                               newSteps: updated,
                               actionName: s.undoStep),
                     to: track.data,
                     undoManager: undoManager)
    }

    var body: some View {
        #if DEBUG
        let _ = BodyRunCounter.shared.count("StepButton")
        let _ = Self._debugRender(track: trackIndex, step: index)
        #endif
        ZStack(alignment: .bottom) {
            // GUI-01: Kunststofftaster. Aktivität = Tönung des Kunststoffs, Auswahl/Learn = getrennte
            // Überlagerung; Playback bleibt ausschließlich die lokale LED (kein pulsierender Körper).
            // GUI-02: Step-Profil — gleichmäßig beleuchteter, matter Kunststoff statt Standard-Tasterverlauf.
            PlasticKeyBackground(tint: step.isActive ? accentColor : nil, tintStrength: 0.24, cornerRadius: 5,
                                 profile: .step)
            if isSelected || isLearnTarget {
                RoundedRectangle(cornerRadius: 5).fill(bgColor)
                RoundedRectangle(cornerRadius: 5).stroke(borderColor, lineWidth: 1.25)
            }

            VStack(spacing: 2) {
                Circle()
                    .fill(ledColor)
                    .frame(width: 7, height: 7)
                    .background(Circle().fill(Color.black.opacity(0.6)).frame(width: 10, height: 10))   // LED-Fassung
                    .shadow(color: ledColor.opacity(ledGlow), radius: ledGlowR)
                    .padding(.top, 5)

                Text(step.isActive ? (step.isHold ? "→" : noteLabel) : "·")
                    .font(.system(size: track.isDrum ? 8 : noteLabelFontSize,
                                  weight: .medium, design: .monospaced))
                    .foregroundColor(step.isActive ? VintageTheme.textPrimary : VintageTheme.textDim)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if step.isActive && step.isHold {
                    Text("HOLD")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(accentColor.opacity(0.8))
                } else if step.isActive && step.isDrone {
                    Text("DRONE")
                        .font(.system(size: 7, weight: .bold, design: .monospaced))
                        .foregroundColor(accentColor)
                } else if step.isActive && step.ratchet != .x1 {
                    Text(step.ratchet.label)
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(accentColor.opacity(0.8))
                }

                if step.isActive && step.probability < 1.0 {
                    Text("\(Int(step.probability * 100))%")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(VintageTheme.textSecondary)
                }

                Spacer(minLength: 0)

                Rectangle()
                    .fill(step.isActive ? accentColor.opacity(0.75) : VintageTheme.stepInactive)
                    .frame(height: step.isActive ? max(2, CGFloat(step.velocity) / 127.0 * (size * 0.22)) : 2)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 4)
                    .padding(.bottom, 4)
            }
        }
        .frame(width: width ?? size, height: size)
        // Die ganze Taste ist Klickfläche. Der Tastenkörper (`PlasticKeyBackground`) ist als
        // Dekor nicht treffbar; ohne contentShape reagierten nur LED, Beschriftung und Streifen.
        .contentShape(Rectangle())
        .overlay(
            // MIDI Learn highlight ring
            RoundedRectangle(cornerRadius: 5)
                .stroke(Color.white, lineWidth: isLearnTarget ? 2 : 0)
                .opacity(isLearnTarget ? 0.9 : 0)
        )
        .help(s.stepTip)
        .onTapGesture {
            let flags  = NSEvent.modifierFlags
            let option = flags.contains(.option)
            let shift  = flags.contains(.shift)
            if option {
                onEdit?()                  // ⌥+Klick = Edit
            } else if shift {
                onToggleSelect?()          // ⇧+Klick = Markieren
            } else if mls.learnMode {
                engine.setLearnTarget(track: trackIndex, step: index)
            } else if isSelected {
                onToggleSelect?()
            } else {
                modifyStep { $0.isActive.toggle() }
            }
        }
    }

    // LED-only Highlight (P3 Rückbau):
    // bgColor und borderColor reagieren NICHT mehr auf isCurrentStep.
    // Das Playback-Feedback lebt ausschließlich in ledColor / ledGlow / ledGlowR.
    // Begründung: weniger Rendering-Aufwand, kein springender Rahmen bei
    // Timing-Schwankungen, stabiler und dezenterer Eindruck.
    private var bgColor: Color {
        if isLearnTarget { return Color.white.opacity(0.12) }
        if isSelected    { return Color(red:0.15,green:0.35,blue:0.65).opacity(0.45) }
        if step.isActive { return accentColor.opacity(0.07) }
        return VintageTheme.stepInactive
    }
    private var borderColor: Color {
        if isLearnTarget { return Color.white.opacity(0.8) }
        if isSelected    { return Color(red: 0.3, green: 0.6, blue: 1.0) }
        if step.isActive { return accentColor.opacity(0.35) }
        return VintageTheme.stepBorder
    }
    private var ledColor: Color {
        if isCurrentStep { return VintageTheme.amberBright }
        if step.isActive { return accentColor }
        return VintageTheme.amberDim.opacity(0.4)
    }
    private var ledGlow:  Double  { isCurrentStep ? 1.0 : (step.isActive ? 0.5 : 0) }
    private var ledGlowR: CGFloat { isCurrentStep ? 8 : 4 }
}

// MARK: - Debug render counter (P3 — Equatable-Verifikation)
#if DEBUG
extension StepButtonView {
    /// Gibt für jede tatsächliche `StepButtonView.body`-Auswertung eine Zeile aus.
    ///
    /// Standardmäßig `false` — würde sonst den Debug-Output fluten.
    ///
    /// **Aktivierung:** Hier im Code auf `true` setzen und neu bauen.
    ///   Kein LLDB nötig.
    ///
    /// **Erwartetes Ergebnis bei korrektem `.equatable()`-Verhalten:**
    ///   Pro Step-Advance erscheinen genau 2 Zeilen:
    ///   - die Zelle, die `isCurrentStep` verliert (alt)
    ///   - die Zelle, die `isCurrentStep` bekommt (neu)
    ///
    /// Erscheinen mehr Zeilen, ist das Equatable-Gating unwirksam.
    static var logBodyRenders: Bool = false

    /// GUI-01: Zähler für body-Auswertungen (UI-Regression unter Playhead-Last, nur Main).
    static var renderCount = 0

    @discardableResult
    static func _debugRender(track: Int, step: Int) -> Bool {
        renderCount &+= 1
        guard logBodyRenders else { return false }
        print("🔵 StepButtonView.body t=\(track) s=\(step)")
        return true
    }
}
#endif

// MARK: - Equatable (P3 — SwiftUI Diffing)

/// Vergleicht nur die Properties, die visuell unterscheidbare Zustände erzeugen.
///
/// SwiftUI ruft `==` auf, wenn der Parent-Body neu ausgeführt wurde und entscheidet
/// anhand des Ergebnisses, ob `StepButtonView.body` erneut ausgewertet werden muss.
///
/// **isCurrentStep:** Seit P3-Rückbau data-driven via `playbackDisplay.steps[trackIndex]`.
/// StepGridView übergibt `true` genau für den aktiven Step jedes Tracks. Das `.equatable()`
/// Diffing stellt sicher, dass nur die 2 betroffenen Zellen (an/aus) neu gerendert werden.
///
/// **isSelected:** Ändert sich bei Rubber-Band- und ⇧+Klick-Selektion.
///
/// **width:** Ändert sich bei Zoom (engine.stepWidthSize) → body muss neu evaluiert werden.
///
/// **Bewusst ausgeschlossen:**
/// - `track`, `index`, `trackIndex` — strukturell stabil innerhalb einer ForEach-Identität;
///   Änderungen an Track-Inhalten treiben `@ObservedObject`-Updates, nicht den Parent-Body-Pfad.
/// - `accentColor`, `size` — ändern sich nicht während Playback oder Zoom.
/// - `onToggleSelect` — Closure, nicht Equatable; hat keinen Einfluss auf das Render-Ergebnis.
extension StepButtonView: Equatable {
    static func == (lhs: StepButtonView, rhs: StepButtonView) -> Bool {
        lhs.isCurrentStep == rhs.isCurrentStep &&
        lhs.isSelected    == rhs.isSelected    &&
        lhs.width         == rhs.width
    }
}
