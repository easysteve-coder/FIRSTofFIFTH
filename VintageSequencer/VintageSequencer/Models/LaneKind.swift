import Foundation

// MARK: - LaneKind
//
// Expliziter Lane-Typ-Diskriminator (Lane Slice 3).
//
// Heute existiert genau ein Case (`.step`). Der Enum ist dennoch bereits
// eingeführt, damit:
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
//     der einzige Zweck dieses Enums, solange es nur einen Case gibt.
enum LaneKind: String, Codable, Sendable {
    case step
    case cc
}
