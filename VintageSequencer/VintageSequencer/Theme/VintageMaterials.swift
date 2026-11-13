import SwiftUI
import AppKit

// MARK: - GUI-01 — Materialsystem (statisch)
//
// Eigene SwiftUI-/CoreGraphics-Bausteine; keine Rastergrafik eines Fremdprodukts.
// Licht kommt einheitlich von links oben: helle Kante oben/links, dunkle Kante unten/rechts,
// sparsame Schatten (nur an wenigen großen Flächen, nie pro Step-Zelle).
//
// Render-Invarianten (siehe ENGINEERING "GUI-01"):
//  - Die Bürstungstextur wird je Material EINMAL erzeugt (`static let`) und als Tile gezeichnet;
//    kein Würfeln/Rasterisieren pro Body- oder Playback-Update.
//  - Alle Bausteine sind zustandslos (keine @Published-/Environment-Beobachtung), damit sie keine
//    globalen Invalidierungen auslösen. Dekor reagiert nie auf Engine-/Display-Zustand.
//  - Hit-Testing: dekorative Flächen sind `allowsHitTesting(false)`.

enum MaterialTone {
    /// Anthrazit, gebürstet — Gehäuse und Modulrahmen.
    case darkMetal
    /// Hell, satiniert — Parameterflächen (Text darauf DARK: `Mat.inkOnLight`).
    case lightAluminium
}

enum Mat {
    // Schrift auf hellem Aluminium (dunkel, warmneutral — erreicht > 7:1 auf `lightTop…lightBottom`).
    static let inkOnLight          = Color(red: 0.07, green: 0.07, blue: 0.08)
    static let inkOnLightSecondary = Color(red: 0.17, green: 0.17, blue: 0.18)

    static let darkTop      = Color(red: 0.20, green: 0.20, blue: 0.215)
    static let darkBottom   = Color(red: 0.12, green: 0.12, blue: 0.13)
    // Patina (GUI-01): Aluminium leicht wärmer und nachgedunkelt; weiterhin deutlich heller als jede Schrift darauf.
    static let lightTop     = Color(red: 0.79, green: 0.775, blue: 0.74)
    static let lightBottom  = Color(red: 0.62, green: 0.605, blue: 0.575)

    /// Ruhige, dunkle Rasterfläche (Grid) — bewusst ohne Bürstung.
    static let gridTop      = Color(red: 0.085, green: 0.085, blue: 0.095)
    static let gridBottom   = Color(red: 0.115, green: 0.115, blue: 0.125)

    /// Anzeigeglas (versenkt).
    static let glass        = Color(red: 0.035, green: 0.035, blue: 0.04)

    // Kunststofftaster (Basis, ungetönt).
    static let keyTop       = Color(red: 0.26, green: 0.26, blue: 0.28)
    static let keyBottom    = Color(red: 0.15, green: 0.15, blue: 0.165)
}

// MARK: - Bürstungstextur (einmalig erzeugt)

enum MaterialTexture {
    /// Tile-Größe in Pixeln; mit `scale: 2` gezeichnet → 128 × 64 pt, nahtlos horizontal.
    private static let width = 256, height = 128

    static let dark: CGImage  = make(seed: 0xF0F5_0001, lightStreakAlpha: 0.050, darkStreakAlpha: 0.14, wearLight: true)
    static let light: CGImage = make(seed: 0xF0F5_0002, lightStreakAlpha: 0.26,  darkStreakAlpha: 0.065, wearLight: false)

    /// Horizontale Bürstung: pro Pixelzeile 1–3 lange Segmente (umlaufend → nahtlos), deterministischer PRNG.
    /// `wearLight`: Gebrauchsspuren als hellere (poliert, auf dunklem Metall) bzw. dunklere (auf Aluminium) Feinstriche.
    private static func make(seed: UInt64, lightStreakAlpha: CGFloat, darkStreakAlpha: CGFloat, wearLight: Bool) -> CGImage {
        var state = seed
        func next() -> CGFloat {           // xorshift64*, 0…1
            state ^= state >> 12; state ^= state << 25; state ^= state >> 27
            return CGFloat((state &* 2685821657736338717) >> 11) / CGFloat(1 << 53)
        }
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for y in 0..<height {
            for _ in 0..<(1 + Int(next() * 3)) {
                let light = next() < 0.5
                let a = (light ? lightStreakAlpha : darkStreakAlpha) * (0.25 + 0.75 * next())
                ctx.setFillColor(CGColor(gray: light ? 1 : 0, alpha: a))
                let w = CGFloat(40 + Int(next() * 200)), x = CGFloat(Int(next() * CGFloat(width)))
                ctx.fill(CGRect(x: x, y: CGFloat(y), width: w, height: 1))
                if x + w > CGFloat(width) {                     // umlaufen → nahtlos
                    ctx.fill(CGRect(x: x - CGFloat(width), y: CGFloat(y), width: w, height: 1))
                }
            }
        }
        // Patina: wenige sehr feine, lange Gebrauchsspuren (1 px), deterministisch (gleicher Seed → gleiche Tile).
        // Sparsam: 6 von 128 Zeilen; Amplitude klein, damit Grundbürstung und Beschriftung dominieren.
        for _ in 0..<6 {
            let y = CGFloat(Int(next() * CGFloat(height)))
            let w = CGFloat(90 + Int(next() * 140)), x = CGFloat(Int(next() * CGFloat(width)))
            ctx.setFillColor(CGColor(gray: wearLight ? 1 : 0, alpha: wearLight ? 0.10 : 0.14))
            ctx.fill(CGRect(x: x, y: y, width: w, height: 1))
            if x + w > CGFloat(width) { ctx.fill(CGRect(x: x - CGFloat(width), y: y, width: w, height: 1)) }
        }
        return ctx.makeImage()!
    }
}

// MARK: - Flächen

/// Gebürstete Metallfläche mit Lichtkante oben und Schattenkante unten.
struct MetalSurface: View {
    var tone: MaterialTone = .darkMetal
    var body: some View {
        let light = tone == .lightAluminium
        ZStack {
            LinearGradient(colors: light ? [Mat.lightTop, Mat.lightBottom]
                                         : [Mat.darkTop, Mat.darkBottom],
                           startPoint: .top, endPoint: .bottom)
            Image(decorative: light ? MaterialTexture.light : MaterialTexture.dark, scale: 2)
                .resizable(resizingMode: .tile)
            // Patina: zwei weiche, ortsfeste Mattstellen (je eine hellere und eine dunklere), sehr geringe Deckkraft.
            RadialGradient(colors: [Color.white.opacity(light ? 0.07 : 0.035), .clear],
                           center: UnitPoint(x: 0.18, y: 0.30), startRadius: 0, endRadius: 150)
            RadialGradient(colors: [Color.black.opacity(light ? 0.07 : 0.07), .clear],
                           center: UnitPoint(x: 0.80, y: 0.70), startRadius: 0, endRadius: 190)
            VStack(spacing: 0) {
                // Obere Lichtkante mit Abrieb: Deckkraft wechselt entlang der Kante (stellenweise poliert/matt).
                Rectangle()
                    .fill(LinearGradient(stops: [
                        .init(color: Color.white.opacity(light ? 0.62 : 0.24), location: 0.00),
                        .init(color: Color.white.opacity(light ? 0.30 : 0.08), location: 0.18),
                        .init(color: Color.white.opacity(light ? 0.60 : 0.22), location: 0.34),
                        .init(color: Color.white.opacity(light ? 0.22 : 0.05), location: 0.58),
                        .init(color: Color.white.opacity(light ? 0.55 : 0.20), location: 0.80),
                        .init(color: Color.white.opacity(light ? 0.34 : 0.10), location: 1.00)],
                        startPoint: .leading, endPoint: .trailing))
                    .frame(height: 1)
                Spacer(minLength: 0)
                Rectangle().fill(Color.black.opacity(light ? 0.30 : 0.45)).frame(height: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Plattenform: Metallfläche, abgerundet, mit feiner Außenkante.
struct MetalPlate<Content: View>: View {
    var tone: MaterialTone = .darkMetal
    var cornerRadius: CGFloat = 7
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .background(MetalSurface(tone: tone))
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(Color.black.opacity(tone == .lightAluminium ? 0.45 : 0.6), lineWidth: 0.75))
    }
}

/// Ruhige, versenkte Rasterfläche (Grid): flacher Verlauf + Einlassungskante oben/links.
struct GridWellSurface: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [Mat.gridTop, Mat.gridBottom], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 0) {
                Rectangle().fill(Color.black.opacity(0.55)).frame(height: 2)
                Spacer(minLength: 0)
                Rectangle().fill(Color.white.opacity(0.05)).frame(height: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Versenktes Anzeigeglas für Werteanzeigen (Inhalt liegt darüber, gut lesbar auf dunklem Grund).
struct GlassDisplayBackground: View {
    var cornerRadius: CGFloat = 4
    var body: some View {
        RoundedRectangle(cornerRadius: cornerRadius)
            .fill(Mat.glass)
            .overlay(RoundedRectangle(cornerRadius: cornerRadius)
                .strokeBorder(LinearGradient(colors: [Color.black.opacity(0.9), Color.white.opacity(0.16)],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1))
            .allowsHitTesting(false)
    }
}

// MARK: - Kunststofftaster

/// Leicht gewölbter Kunststoff. `tint` färbt zurückhaltend (Aktivität), die Kanten bleiben neutral.
/// Keine Schatten: die „Erhebung“ entsteht aus Verlauf + Lichtkante oben + dunkler unterer Kante.
struct PlasticKeyBackground: View {

    /// Beleuchtungsprofil. `.standard` = Taster/Buttons/Play (Verlauf Körper + diagonale Kante, unverändert);
    /// `.step` = matter, gleichmäßig beleuchteter Step-Kunststoff (GUI-02): enger Helligkeitsbereich, gleichmäßige
    /// Tönung, dezente obere Lichtkante und schmale weiche Unterkante — kein diagonaler Verlauf über die Breite.
    enum Profile { case standard, step }

    var tint: Color? = nil
    var tintStrength: Double = 0.20
    var cornerRadius: CGFloat = 5
    var pressed: Bool = false
    var profile: Profile = .standard

    private var bodyColors: [Color] {
        switch profile {
        case .standard:
            return pressed ? [Mat.keyBottom, Mat.keyTop.opacity(0.9)] : [Mat.keyTop, Mat.keyBottom]
        case .step:
            // Mittelwert von keyTop/keyBottom ± wenige Prozent: weitgehend ebener, matter Körper.
            return [Color(red: 0.222, green: 0.222, blue: 0.241), Color(red: 0.192, green: 0.192, blue: 0.209)]
        }
    }

    private var tintFalloff: Double { profile == .step ? 0.80 : 0.35 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius)
        ZStack {
            shape.fill(LinearGradient(colors: bodyColors, startPoint: .top, endPoint: .bottom))
            if let tint {
                shape.fill(LinearGradient(colors: [tint.opacity(tintStrength), tint.opacity(tintStrength * tintFalloff)],
                                          startPoint: .top, endPoint: .bottom))
            }
            switch profile {
            case .standard:
                // Patina: Kante diagonal beleuchtet (Licht links oben) — oben links „poliert“, unten rechts dunkel.
                shape.strokeBorder(LinearGradient(
                    colors: pressed ? [Color.black.opacity(0.55), Color.white.opacity(0.10)]
                                    : [Color.white.opacity(0.40), Color.white.opacity(0.05), Color.black.opacity(0.55)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
            case .step:
                // Licht links oben nur noch angedeutet: leichte Neigung (x 0.35 → 0.65), keine Eck-zu-Eck-Diagonale.
                shape.strokeBorder(LinearGradient(
                    stops: [.init(color: Color.white.opacity(0.17), location: 0),
                            .init(color: Color.white.opacity(0.03), location: 0.45),
                            .init(color: Color.black.opacity(0.24), location: 1)],
                    startPoint: UnitPoint(x: 0.35, y: 0), endPoint: UnitPoint(x: 0.65, y: 1)), lineWidth: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Knopf-Face

/// Gemeinsames Face für KnobView/GateKnobView: geriffelter Rand, Metallkappe, klarer Zeiger.
/// Zeichnet nur — Geste, Wertlogik und Skalen bleiben in den aufrufenden Views.
struct KnobFace: View {
    var size: CGFloat
    var indicatorDeg: Double
    var accent: Color
    var dragging: Bool
    var body: some View {
        ZStack {
            // Geriffelter Rand: gestrichelter Kreis (rein vektoriell, kein Raster).
            Circle()
                .stroke(Color.black.opacity(0.85),
                        style: StrokeStyle(lineWidth: size * 0.09, dash: [1.3, 1.7]))
                .frame(width: size - size * 0.045, height: size - size * 0.045)
            Circle()
                .fill(LinearGradient(colors: [Color(white: 0.30), Color(white: 0.08)],
                                     startPoint: .topLeading, endPoint: .bottomTrailing))
                .frame(width: size, height: size)
                .overlay(Circle().strokeBorder(LinearGradient(
                    colors: [Color.white.opacity(0.35), Color.black.opacity(0.7)],
                    startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1))
            // Kappe mit gerichtetem Glanz links oben
            Circle()
                .fill(RadialGradient(colors: [Color(white: 0.44), Color(white: 0.20), Color(white: 0.11)],
                                     center: UnitPoint(x: 0.30, y: 0.26), startRadius: 0, endRadius: size * 0.55))
                .frame(width: size * 0.70, height: size * 0.70)
                .overlay(Circle().strokeBorder(Color.black.opacity(0.55), lineWidth: 0.75))
            // Zeiger: klar, kontrastreich, bis an den Rand
            Capsule()
                .fill(dragging ? VintageTheme.amberGlow : accent)
                .frame(width: max(2.5, size * 0.07), height: size * 0.30)
                .overlay(Capsule().strokeBorder(Color.black.opacity(0.5), lineWidth: 0.5))
                .offset(y: -(size * 0.27))
                .rotationEffect(.degrees(indicatorDeg))
        }
        .frame(width: size, height: size)
        .shadow(color: .black.opacity(0.55), radius: 3, x: 1, y: 2)
    }
}

// MARK: - Fader (horizontal, WIDTH)

/// Reine Mathematik des Faders (testbar, ohne UI). Wertebereich und Schritt kommen vom Aufrufer.
enum MaterialFaderMath {
    /// Wert → Anteil 0…1 im Bereich.
    static func fraction(_ value: Double, range: ClosedRange<Double>) -> Double {
        guard range.upperBound > range.lowerBound else { return 0 }
        return ((value - range.lowerBound) / (range.upperBound - range.lowerBound)).clamped(to: 0...1)
    }
    /// Relativer Drag: Startwert + Translation entlang des Verfahrwegs, auf Schritt gerundet und geklemmt.
    /// Kein Sprung beim Greifen: Translation 0 liefert exakt den Startwert (auf Schritt gerundet).
    static func dragged(start: Double, translation: Double, travel: Double,
                        range: ClosedRange<Double>, step: Double) -> Double {
        guard travel > 0 else { return start.clamped(to: range) }
        let raw = start + translation / travel * (range.upperBound - range.lowerBound)
        return snapped(raw, range: range, step: step)
    }
    static func snapped(_ v: Double, range: ClosedRange<Double>, step: Double) -> Double {
        let s = step > 0 ? ((v - range.lowerBound) / step).rounded() * step + range.lowerBound : v
        return s.clamped(to: range)
    }
}

/// Horizontaler Materialfader: Griff 35 × 17 pt (Sick-Griffwirkung: Riffelzonen, dunkler Mittelindex),
/// Führungsschlitz, zurückhaltende Skalenmarken. Hit-Fläche 30 pt hoch über die volle Breite.
/// Gleiche Binding-Strecke wie zuvor (`Binding<Double>`); keine dB-Kennlinie, kein Command.
struct MaterialFader: View {
    @Binding var value: Double
    var range: ClosedRange<Double>
    var step: Double = 1
    /// Beschriftete Marken (Wert → Label); ungelabelte Zwischenmarken separat.
    var majorMarks: [Double] = []
    var minorMarks: [Double] = []
    var accessibilityLabelText: String
    /// Helles Aluminium als Untergrund → dunkle Marken/Beschriftung.
    var onLight: Bool = true

    @State private var dragStartValue: Double?

    static let capLength: CGFloat = 35
    static let capThickness: CGFloat = 17
    static let hitHeight: CGFloat = 30

    var body: some View {
        GeometryReader { geo in
            let travel = max(1, geo.size.width - Self.capLength)
            let f = MaterialFaderMath.fraction(value, range: range)
            let capX = travel * CGFloat(f)
            ZStack(alignment: .leading) {
                // Skala (oberhalb der Mitte), Marken exakt auf Griffmitte der jeweiligen Stellung
                marks(travel: travel, height: geo.size.height)
                // Führungsschlitz
                Capsule()
                    .fill(Color.black.opacity(0.78))
                    .frame(width: geo.size.width - 6, height: 4)
                    .overlay(Capsule().strokeBorder(Color.white.opacity(onLight ? 0.55 : 0.18), lineWidth: 0.5)
                        .offset(y: 0.5))
                    .offset(x: 3)
                FaderCap()
                    .offset(x: capX)
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { g in
                        if dragStartValue == nil { dragStartValue = value }
                        value = MaterialFaderMath.dragged(start: dragStartValue ?? value,
                                                          translation: Double(g.translation.width),
                                                          travel: Double(travel), range: range, step: step)
                    }
                    .onEnded { _ in dragStartValue = nil }
            )
        }
        .frame(height: Self.hitHeight)
        .focusable()
        .onMoveCommand { dir in
            switch dir {
            case .left:  value = MaterialFaderMath.snapped(value - step, range: range, step: step)
            case .right: value = MaterialFaderMath.snapped(value + step, range: range, step: step)
            default: break
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabelText)
        .accessibilityValue("\(Int(value))")
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: value = MaterialFaderMath.snapped(value + step, range: range, step: step)
            case .decrement: value = MaterialFaderMath.snapped(value - step, range: range, step: step)
            @unknown default: break
            }
        }
    }

    private func marks(travel: CGFloat, height: CGFloat) -> some View {
        let ink = onLight ? Mat.inkOnLightSecondary : VintageTheme.textSecondary
        return ZStack(alignment: .topLeading) {
            ForEach(minorMarks + majorMarks, id: \.self) { m in
                let major = majorMarks.contains(m)
                let x = Self.capLength / 2 + travel * CGFloat(MaterialFaderMath.fraction(m, range: range))
                Rectangle().fill(ink.opacity(major ? 0.9 : 0.55))
                    .frame(width: 1, height: major ? 5 : 3)
                    .position(x: x, y: major ? 4.5 : 3.5)
                if major {
                    Text("\(Int(m))")
                        .font(.system(size: 7, design: .monospaced))
                        .foregroundColor(ink)
                        .fixedSize()
                        .position(x: x, y: height - 3.5)
                }
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// Fadergriff (horizontal): 35 × 17, zwei Riffelzonen + dunkler Mittelindex (Sick-`LogicFaderCap`,
/// um 90° gedreht und mit FoF-Tonwerten neu gezeichnet; statisch, einmalig aufgebaut).
private struct FaderCap: View {
    private struct Band { let x: CGFloat; let w: CGFloat; let tone: Double }
    private static let bands: [Band] = {
        var r: [Band] = []
        for i in 0..<10 { r.append(Band(x: CGFloat(i) * 0.5, w: 0.5, tone: 0.82 + Double(i) * 0.008)) }
        let tones = [0.624, 0.655, 0.694, 0.745, 0.796, 0.820, 0.839, 0.859, 0.875, 0.890]
        var x: CGFloat = 5
        for i in 0..<5 { r.append(Band(x: x, w: 2, tone: tones[i])); x += 2
            if i < 4 { r.append(Band(x: x, w: 0.5, tone: tones[i] - 0.09)); x += 0.5 } }
        r.append(Band(x: 17, w: 1, tone: 0.325))                       // dunkler Mittelindex
        x = 18
        for i in 5..<10 { r.append(Band(x: x, w: 2, tone: tones[i])); x += 2
            if i < 9 { r.append(Band(x: x, w: 0.5, tone: tones[i] - 0.09)); x += 0.5 } }
        for i in 0..<10 { r.append(Band(x: 30 + CGFloat(i) * 0.5, w: 0.5, tone: 0.72 - Double(i) * 0.01)) }
        return r
    }()
    var body: some View {
        Canvas { ctx, size in
            for b in Self.bands {
                ctx.fill(Path(CGRect(x: b.x, y: 0, width: b.w, height: size.height)), with: .color(Color(white: b.tone)))
            }
        }
        .frame(width: MaterialFader.capLength, height: MaterialFader.capThickness)
        .clipShape(RoundedRectangle(cornerRadius: 2))
        .overlay(RoundedRectangle(cornerRadius: 2).strokeBorder(Color.black.opacity(0.65), lineWidth: 0.5))
        // Patina: zwei kurze, polierte Griffkanten (oben links, unten rechts) — Riffelzonen + Mittelindex bleiben.
        .overlay(alignment: .topLeading) { Rectangle().fill(Color.white.opacity(0.55)).frame(width: 9, height: 0.75).padding(.leading, 2) }
        .overlay(alignment: .bottomTrailing) { Rectangle().fill(Color.white.opacity(0.40)).frame(width: 6, height: 0.75).padding(.trailing, 2) }
        .shadow(color: .black.opacity(0.6), radius: 2, y: 2)
        .allowsHitTesting(false)
    }
}

// MARK: - Segment-/Richtungstaster

/// Hintergrund für Taster in segmentierten Gruppen (Richtung): aktiv = Akzent-Kunststoff, sonst neutraler Kunststoff.
struct PlasticSegmentBackground: View {
    var isActive: Bool
    var accent: Color
    var body: some View {
        ZStack {
            PlasticKeyBackground(tint: nil, cornerRadius: 0, pressed: isActive)
            if isActive {
                Rectangle().fill(LinearGradient(colors: [accent, accent.opacity(0.78)], startPoint: .top, endPoint: .bottom))
                    .padding(1)
            }
        }
    }
}
