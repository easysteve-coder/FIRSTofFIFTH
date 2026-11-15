import SwiftUI

enum VintageTheme {
    /// Liest die Versionsnummer direkt aus dem App-Bundle (CFBundleShortVersionString).
    /// Wird automatisch von MARKETING_VERSION im Xcode-Projekt gesetzt — nie mehr manuell anpassen.
    static let appVersion: String = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
    // Background / panels
    static let background     = Color(red: 0.08, green: 0.08, blue: 0.09)
    static let panel          = Color(red: 0.13, green: 0.13, blue: 0.145)
    static let panelDark      = Color(red: 0.10, green: 0.10, blue: 0.11)
    static let panelBorder    = Color(red: 0.28, green: 0.24, blue: 0.18)

    // Amber LED palette
    static let amber          = Color(red: 1.00, green: 0.55, blue: 0.00)
    static let amberBright    = Color(red: 1.00, green: 0.80, blue: 0.20)
    static let amberDim       = Color(red: 0.38, green: 0.20, blue: 0.00)
    static let amberGlow      = Color(red: 1.00, green: 0.88, blue: 0.35)

    // Step buttons
    static let stepInactive   = Color(red: 0.17, green: 0.17, blue: 0.18)
    static let stepBorder     = Color(red: 0.30, green: 0.27, blue: 0.20)

    // Knobs

    // Text
    static let textPrimary    = Color(red: 0.85, green: 0.80, blue: 0.68)
    // Lesbarkeit (v1.13.3): Nebentext ≥ 4,5:1 und gedämpfter Text ≥ 3:1 auf den dunklen
    // Flächen (`panel`, `panelDark`); Tastenbeschriftung nutzt `textPrimary`
    // (≥ 4,5:1 auf `Mat.keyTop`). Abgesichert durch `ThemeContrastTests`.
    static let textSecondary  = Color(red: 0.72, green: 0.68, blue: 0.58)
    static let textAmber      = Color(red: 1.00, green: 0.65, blue: 0.10)
    static let textDim        = Color(red: 0.56, green: 0.52, blue: 0.44)

    // Per-track accent colors
    static let trackColors: [Color] = [
        Color(red: 1.00, green: 0.55, blue: 0.00), // amber
        Color(red: 0.20, green: 0.70, blue: 1.00), // blue
        Color(red: 0.30, green: 0.85, blue: 0.45), // green
        Color(red: 0.90, green: 0.25, blue: 0.65), // magenta
        Color(red: 0.80, green: 0.80, blue: 0.20), // yellow
        Color(red: 0.60, green: 0.30, blue: 1.00), // purple
        Color(red: 1.00, green: 0.35, blue: 0.25), // red
        Color(red: 0.20, green: 0.90, blue: 0.80), // cyan
        // v1.18.25: acht weitere (die ersten acht bleiben, Indizes alter Presets unverändert).
        Color(red: 1.00, green: 0.78, blue: 0.30), // gold
        Color(red: 0.45, green: 0.55, blue: 1.00), // indigo
        Color(red: 0.65, green: 0.95, blue: 0.30), // lime
        Color(red: 1.00, green: 0.50, blue: 0.75), // pink
        Color(red: 0.95, green: 0.65, blue: 0.45), // peach
        Color(red: 0.40, green: 0.80, blue: 0.95), // sky
        Color(red: 0.75, green: 0.55, blue: 0.95), // lavender
        Color(red: 0.85, green: 0.85, blue: 0.85), // silver
    ]

    /// Löst `TrackData.colorIndex` auf einen Palettenfarbwert auf.
    ///
    /// Verbindliche Architekturregel (Track-Farben-Slice v1.12.0):
    /// Farbe ist Eigenschaft des Tracks. Lanes haben keine eigene Farbe —
    /// sie erben die Track-Farbe ausschließlich durch Parameter-Durchreich.
    /// Diese Funktion ist der **einzige** Ort, der `colorIndex → Color`
    /// auflöst; aufgerufen wird sie ausschließlich in `MainView` an der
    /// Wurzel der Track-Hierarchie. Alle anderen Views bekommen ein
    /// bereits aufgelöstes `accentColor: Color` als Parameter.
    ///
    /// Die Modulo-Normierung dient als Gürtel-und-Hosenträger gegen
    /// Sentinel-`-1` aus alten Presets (die der Pattern-Decoder in v1.9.1
    /// bereits positionsbasiert nachpatcht) und gegen zukünftige
    /// Paletten-Verkleinerungen — so kann der Resolver nie indexen außerhalb.
    /// Farbe einer Spur (v1.18.25): eigene Farbe aus dem Farbrad, sonst Palette. Aufgerufen
    /// von Views, die das TrackViewModel beobachten (TrackRowView, Mixer) — nur so folgt die
    /// Anzeige einer Änderung (auch per Undo) sofort; bis v1.18.24 löste `MainView` die Farbe
    /// auf und zeichnete bei einer reinen Spuränderung nicht neu.
    static func color(for td: TrackData) -> Color {
        if let hex = td.customColor, let c = color(hex: hex) { return c }
        return color(forTrack: td.colorIndex)
    }

    /// "#RRGGBB" → Farbe; nil bei ungültiger Angabe.
    static func color(hex: String) -> Color? {
        var h = hex.trimmingCharacters(in: .whitespaces)
        if h.hasPrefix("#") { h.removeFirst() }
        guard h.count == 6, let v = UInt32(h, radix: 16) else { return nil }
        return Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255,
                     blue: Double(v & 0xFF) / 255)
    }

    static func color(forTrack colorIndex: Int) -> Color {
        let n = trackColors.count
        let normalized = ((colorIndex % n) + n) % n
        return trackColors[normalized]
    }

    // Fonts
    static let monoSmall  = Font.system(size:  9, weight: .regular,  design: .monospaced)
    static let monoMedium = Font.system(size: 11, weight: .regular,  design: .monospaced)
    static let monoBold   = Font.system(size: 11, weight: .semibold, design: .monospaced)
    static let monoLarge  = Font.system(size: 14, weight: .semibold, design: .monospaced)
    static let monoTitle  = Font.system(size: 17, weight: .bold,     design: .monospaced)

    // Layout
    static let stepSize:           CGFloat = 54
    static let stepSpacing:        CGFloat =  4
    /// Horizontales Padding des Step-HStack innerhalb des Scaled Content Containers.
    /// Wird in `StepGridView` (.padding(.horizontal, …)) und in der Zoom-Scroll-Formel
    /// (`ViewportController.adjustScroll`) verwendet — beide müssen denselben Wert nutzen.
    static let stepGridLeadingPad: CGFloat =  8
    /// Breite der Corner-Handle-Spalte am Ende jeder Lane (`CornerHandlesView`); Teil der Lane-Inhaltsbreite (G01).
    static let cornerHandlesWidth: CGFloat = 12
    static let knobSize:           CGFloat = 38
    static let trackHeaderWidth:   CGFloat = 224

    // Lane-Inhaltsbreite und Scrollgrenze: siehe `LaneGeometry` (G01) — Summe der real gerenderten
    // `distributedStepWidth`-Zellen; die frühere Schätzung (einheitliche Breite + Buffer) entfällt.

    /// Berechnet die gestreckte Step-Breite für das gegebene Verhältnis num/den.
    /// Gibt eine einheitliche Breite zurück (für Schätzungen, Scroll-Berechnung etc.).
    /// Für das Rendering einzelner Steps → distributedStepWidth(index:…) verwenden.
    static func stretchedStepWidth(num: Int, den: Int, stepWidthSize: Double) -> CGFloat {
        let base    = CGFloat(stepWidthSize)
        let spacing = VintageTheme.stepSpacing
        return ((base + spacing)
            * CGFloat(num)
            / CGFloat(den)
            - spacing)
            .rounded(.toNearestOrEven)
    }

    /// Bresenham-verteilte Step-Breite für Step `index` bei ratio num/den.
    ///
    /// Statt alle Steps mit derselben gerundeten Breite zu rendern, wird der
    /// Rundungsfehler gleichmäßig über den Zyklus verteilt:
    ///   slotSize = (base + spacing) × num/den  (exakt, ungerundet)
    ///   width(i) = round((i+1) × slotSize) − round(i × slotSize) − spacing
    ///
    /// Eigenschaft: Summe der Breiten über beliebig viele Steps entspricht exakt
    /// dem idealen Gesamtraum — kein Drift, kein „5,5,5,5,4"-Muster.
    ///
    /// Für ganzzahlige Verhältnisse (z. B. 1:1, 1:2) ist das Ergebnis identisch
    /// mit stretchedStepWidth — kein Behavior-Change.
    static func distributedStepWidth(index: Int, num: Int, den: Int, stepWidthSize: Double) -> CGFloat {
        let slotSize = (CGFloat(stepWidthSize) + stepSpacing) * CGFloat(num) / CGFloat(den)
        return (slotSize * CGFloat(index + 1)).rounded(.toNearestOrEven)
             - (slotSize * CGFloat(index    )).rounded(.toNearestOrEven)
             - stepSpacing
    }
}
