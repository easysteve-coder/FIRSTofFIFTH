import Testing
import Foundation
import AppKit
import SwiftUI
import Combine
@testable import VintageSequencer

// v1.18.25 — Spurfarbe (Stephan: „Track: Farbe auswählen geht nicht. da wollte ich auch mehr
// farben + Farbrad haben."): 16er-Palette, eigene Farbe aus dem Farbrad, Undo, Preset `color`.

@MainActor @Suite struct TrackColorTests {

    @Test func paletteGrewWithoutMovingOldIndices() {
        #expect(VintageTheme.trackColors.count == 16)
        #expect(VintageTheme.color(forTrack: 0) == Color(red: 1.00, green: 0.55, blue: 0.00))
        #expect(VintageTheme.color(forTrack: 7) == Color(red: 0.20, green: 0.90, blue: 0.80))
    }

    @Test func customColorWinsAndUndoes() {
        let td = TrackData(name: "T", stepCount: 16, midiChannel: 1, colorIndex: 2)
        let um = UndoManager(); um.groupsByEvent = false
        um.beginUndoGrouping()
        ModelWriter().apply(.setTrackColor(trackID: td.id, oldIndex: 2, oldCustom: nil, newIndex: 2, newCustom: "#336699"),
                            to: td, undoManager: um)
        um.endUndoGrouping()
        #expect(td.customColor == "#336699")
        #expect(VintageTheme.color(for: td) == VintageTheme.color(hex: "#336699"))
        um.beginUndoGrouping()
        ModelWriter().apply(.setTrackColor(trackID: td.id, oldIndex: 2, oldCustom: "#336699", newIndex: 9, newCustom: nil),
                            to: td, undoManager: um)
        um.endUndoGrouping()
        #expect(td.customColor == nil && td.colorIndex == 9)
        #expect(VintageTheme.color(for: td) == VintageTheme.trackColors[9])
        um.undo()
        #expect(td.customColor == "#336699" && td.colorIndex == 2)
        um.undo()
        #expect(td.customColor == nil && td.colorIndex == 2)
    }

    /// Ändert sich die Farbe, meldet die Spur das (die Spurzeile beobachtet genau das).
    @Test func colorChangeNotifiesTrack() {
        let td = TrackData(name: "T", stepCount: 16, midiChannel: 1)
        var fired = 0
        let sub = td.changed.sink { fired += 1 }
        ModelWriter().apply(.setTrackColor(trackID: td.id, oldIndex: 0, oldCustom: nil, newIndex: 5, newCustom: nil),
                            to: td, undoManager: nil)
        #expect(fired == 1)
        withExtendedLifetime(sub) {}
    }

    @Test func presetKeyIsOptional() throws {
        let td = TrackData(name: "T", stepCount: 16, midiChannel: 1, colorIndex: 3)
        let plain = try JSONEncoder().encode(td)
        #expect(!(String(data: plain, encoding: .utf8) ?? "").contains("\"color\""))
        td.customColor = "#A0B0C0"
        let data = try JSONEncoder().encode(td)
        let back = try JSONDecoder().decode(TrackData.self, from: data)
        #expect(back.customColor == "#A0B0C0" && back.colorIndex == 3)
        // Unlesbar → Palette, Spur lädt trotzdem.
        let bad = try #require(String(data: data, encoding: .utf8)?.replacingOccurrences(of: "#A0B0C0", with: "nope")
            .data(using: .utf8))
        let b2 = try JSONDecoder().decode(TrackData.self, from: bad)
        #expect(b2.customColor == nil && b2.colorIndex == 3)
        #expect(td.freshCopy().customColor == "#A0B0C0")
    }

    @Test func hexRoundTrip() {
        let c = NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1)
        #expect(TrackColorPanel.hex(c) == "#336699")
        #expect(VintageTheme.color(hex: "zz") == nil && VintageTheme.color(hex: "#12345") == nil)
        #expect(!TrackColorPanel.swatch(.red, selected: false).isTemplate)
    }
}
