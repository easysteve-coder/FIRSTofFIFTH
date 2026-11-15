import AppKit
import SwiftUI

// MARK: - Farbrad für die Spurfarbe (v1.18.25)
//
// Stephan: „da wollte ich auch mehr farben + Farbrad haben." Öffnet das System-Farbfenster
// (NSColorPanel) für eine Spur. Jede abgeschlossene Wahl ist ein Undo-Schritt über
// `ModelCommand.setTrackColor` (nicht kontinuierlich: beim Ziehen im Rad keine Flut von
// Schritten). Main.

@MainActor
final class TrackColorPanel: NSObject {
    static let shared = TrackColorPanel()
    private weak var track: TrackData?
    private weak var undoManager: UndoManager?
    private let writer = ModelWriter()

    func open(for td: TrackData, undoManager: UndoManager?, title: String) {
        track = td
        self.undoManager = undoManager
        let panel = NSColorPanel.shared
        panel.title = "\(title) — \(td.name)"
        panel.showsAlpha = false
        panel.isContinuous = false
        panel.setTarget(nil); panel.setAction(nil)          // erst setzen, dann Ziel (kein Fehlauslösen)
        panel.color = NSColor(VintageTheme.color(for: td))
        panel.setTarget(self)
        panel.setAction(#selector(colorChanged(_:)))
        panel.mode = .wheel
        panel.makeKeyAndOrderFront(nil)
    }

    @objc private func colorChanged(_ sender: NSColorPanel) {
        guard let td = track, let hex = Self.hex(sender.color), hex != td.customColor else { return }
        writer.apply(.setTrackColor(trackID: td.id, oldIndex: td.colorIndex, oldCustom: td.customColor,
                                    newIndex: td.colorIndex, newCustom: hex),
                     to: td, undoManager: undoManager)
    }

    /// "#RRGGBB" in sRGB.
    static func hex(_ c: NSColor) -> String? {
        guard let s = c.usingColorSpace(.sRGB) else { return nil }
        func b(_ v: CGFloat) -> Int { Int((min(1, max(0, v)) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", b(s.redComponent), b(s.greenComponent), b(s.blueComponent))
    }

    /// Farbiger Kreis fürs Menü — kein Vorlagenbild, damit macOS ihn nicht einfärbt.
    static func swatch(_ color: NSColor, selected: Bool) -> NSImage {
        let size = NSSize(width: 14, height: 14)
        let img = NSImage(size: size, flipped: false) { r in
            color.setFill()
            NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
            if selected {
                NSColor.white.setStroke()
                let p = NSBezierPath(ovalIn: r.insetBy(dx: 1.5, dy: 1.5)); p.lineWidth = 2; p.stroke()
            }
            return true
        }
        img.isTemplate = false
        return img
    }
}
