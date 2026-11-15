import Foundation

// MARK: - LaneKind
//
// Expliziter Lane-Typ-Diskriminator (Lane Slice 3).
//
// Zwei Cases: `.step` (Noten-Steps; Pad ist eine Darstellungsvariante davon) und
// `.cc`. Der Enum existiert, damit:
//
//   - das Persistenzschema (JSON) ein festes Typ-Tag trägt,
//   - `LaneSnapshot.kind` im RT-Pfad denselben Diskriminator sichtbar macht,
//   - künftige Lane-Typen mechanisch an allen Exhaustiveness-Schaltstellen
//     vom Compiler markiert werden, statt sich in Default-Zweigen zu
//     verstecken.
//
// Invarianten:
//   - RawValue ist stabil (String) und Teil des öffentlichen JSON-Vertrags.
//   - Neue Cases dürfen NUR mit einer eigenen Slice-Entscheidung hinzugefügt
//     werden; siehe ENGINEERING.md — „Lane-Typisierung (ab Slice 3)".
//   - Kein `default`-Zweig in Switches über `LaneKind` — Exhaustiveness ist
//     der Zweck dieses Enums.
enum LaneKind: String, Codable, Sendable {
    case step
    case cc
}
