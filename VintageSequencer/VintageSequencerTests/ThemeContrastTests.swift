import Testing
import SwiftUI
import AppKit
@testable import VintageSequencer

/// Lesbarkeit der Textfarben auf den Flächen, auf denen sie stehen (v1.13.3).
/// Kontrast nach WCAG 2 (relative Leuchtdichte, sRGB).
struct ThemeContrastTests {

    private static func luminance(_ color: Color) -> Double {
        let c = NSColor(color).usingColorSpace(.sRGB)!
        func lin(_ v: CGFloat) -> Double {
            let x = Double(v)
            return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * lin(c.redComponent) + 0.7152 * lin(c.greenComponent) + 0.0722 * lin(c.blueComponent)
    }
    private static func contrast(_ a: Color, _ b: Color) -> Double {
        let (x, y) = (luminance(a), luminance(b))
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }

    /// Nebentext (Beschriftungen, Abschnittstitel) auf Popover-/Leistenflächen.
    @Test func secondaryTextIsReadableOnDarkPanels() {
        for surface in [VintageTheme.panelDark, VintageTheme.panel, VintageTheme.background] {
            #expect(Self.contrast(VintageTheme.textSecondary, surface) >= 4.5)
        }
    }

    /// Gedämpfter Text (Statusleiste, Zeitstempel) bleibt erkennbar, aber unter dem Nebentext.
    @Test func dimTextIsReadableAndBelowSecondary() {
        for surface in [VintageTheme.panelDark, VintageTheme.panel, VintageTheme.background] {
            #expect(Self.contrast(VintageTheme.textDim, surface) >= 3.0)
        }
        #expect(Self.luminance(VintageTheme.textDim) < Self.luminance(VintageTheme.textSecondary))
        #expect(Self.luminance(VintageTheme.textSecondary) < Self.luminance(VintageTheme.textPrimary))
    }

    /// Beschriftung nicht aktiver Kunststofftasten (hellste Stelle der Taste).
    @Test func keyLabelsAreReadableOnPlasticKeys() {
        #expect(Self.contrast(VintageTheme.textPrimary, Mat.keyTop) >= 4.5)
        #expect(Self.contrast(VintageTheme.textPrimary, Mat.keyBottom) >= 4.5)
    }

    /// Titelleisten-Überdeckung: nur der Teil über dem nutzbaren Inhaltsbereich zählt.
    @Test func titlebarOverlapIsMeasuredNotAssumed() {
        #expect(TitlebarOverlapReader.overlap(viewTopInWindow: 700, contentLayoutTop: 668) == 32)
        #expect(TitlebarOverlapReader.overlap(viewTopInWindow: 668, contentLayoutTop: 668) == 0)
        #expect(TitlebarOverlapReader.overlap(viewTopInWindow: 600, contentLayoutTop: 668) == 0)
    }
}
