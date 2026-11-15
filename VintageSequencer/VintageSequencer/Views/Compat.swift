import SwiftUI

// MARK: - Kompatibilität ab macOS 12 (v1.16.0)
//
// Das Deployment-Ziel ist macOS 12.0. Wo SwiftUI-APIs erst später kamen, gehen Views über
// diese Weichen: neuer Weg, wenn verfügbar, sonst ein gleichwertiger älterer.

extension View {
    /// Reagiert auf Wertänderungen (neuer Wert); `initial` ruft die Aktion auch beim
    /// Erscheinen. Ab macOS 14 `onChange(of:initial:_:)`, davor `onChange(of:perform:)` +
    /// `onAppear`.
    @ViewBuilder
    func onValueChange<V: Equatable>(of value: V, initial: Bool = false,
                                     _ action: @escaping (V) -> Void) -> some View {
        if #available(macOS 14.0, *) {
            onChange(of: value, initial: initial) { _, new in action(new) }
        } else {
            onChange(of: value, perform: action)
                .onAppear { if initial { action(value) } }
        }
    }

    /// Hintergrund scrollbarer Inhalte (TextEditor) ausblenden — ab macOS 13; davor bleibt
    /// der Systemhintergrund.
    @ViewBuilder
    func hiddenScrollBackground() -> some View {
        if #available(macOS 13.0, *) { scrollContentBackground(.hidden) } else { self }
    }
}
