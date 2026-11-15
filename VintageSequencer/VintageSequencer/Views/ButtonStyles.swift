import SwiftUI
import AppKit

// MARK: - Small vintage button (used throughout)

struct VintageSmallButtonStyle: ButtonStyle {
    var isActive: Bool
    var accent:   Color = VintageTheme.amber

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(VintageTheme.monoSmall)
            .foregroundColor(
                isActive
                    ? .black
                    : (configuration.isPressed ? accent : VintageTheme.textPrimary)
            )
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(
                ZStack {
                    PlasticKeyBackground(tint: configuration.isPressed ? accent : nil, tintStrength: 0.30,
                                         cornerRadius: 3, pressed: configuration.isPressed || isActive)
                    if isActive {
                        RoundedRectangle(cornerRadius: 3)
                            .fill(LinearGradient(colors: [accent, accent.opacity(0.78)],
                                                 startPoint: .top, endPoint: .bottom))
                            .padding(1)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 3))
            .contentShape(Rectangle())      // ganze Taste klickbar; die Materialfläche ist Dekor
    }
}

// MARK: - Pattern selector button (A / B / C / D)

struct VintagePatternButtonStyle: ButtonStyle {
    var isActive: Bool
    var isQueued: Bool = false   // Pattern ist eingereiht — blinkt
    /// Kleine Ausführung für die 16 Pattern-Tasten der Transportleiste (v1.14.0).
    var compact: Bool = false

    func makeBody(configuration: Configuration) -> some View {
        let queueColor = Color(red: 0.3, green: 0.8, blue: 1.0)
        configuration.label
            .font(compact ? .system(size: 9, weight: .bold, design: .monospaced) : VintageTheme.monoBold)
            .foregroundColor(isActive ? .black : (isQueued ? queueColor : VintageTheme.textPrimary))
            .frame(width: compact ? 18 : 28, height: compact ? 15 : 24)
            .background(
                ZStack {
                    PlasticKeyBackground(tint: configuration.isPressed ? VintageTheme.amber : nil, tintStrength: 0.25,
                                         cornerRadius: 4, pressed: configuration.isPressed || isActive)
                    if isActive {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(LinearGradient(colors: [VintageTheme.amberBright, VintageTheme.amber],
                                                 startPoint: .top, endPoint: .bottom))
                            .padding(1)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .contentShape(Rectangle())
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(isQueued && !isActive ? queueColor : Color.clear, lineWidth: 1.5)
            )
            .shadow(color: isActive ? VintageTheme.amber.opacity(0.55) : (isQueued ? queueColor.opacity(0.6) : .clear), radius: 5)
    }
}

// MARK: - Schlichte Taste mit voller Klickfläche

/// Ersatz für `.buttonStyle(.fullArea)` (v1.13.9): die gesamte Fläche des Labels nimmt Klicks
/// an, nicht nur gezeichnete Pixel. Nötig, weil die Materialflächen (`PlasticKeyBackground`
/// u. a.) als Dekor nicht treffbar sind — sonst reagiert nur die Beschriftung.
struct FullAreaButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View { FullAreaLabel(configuration: configuration) }

    private struct FullAreaLabel: View {
        let configuration: Configuration
        @Environment(\.isEnabled) private var isEnabled
        var body: some View {
            configuration.label
                .contentShape(Rectangle())
                .opacity(!isEnabled ? 0.45 : (configuration.isPressed ? 0.7 : 1))
        }
    }
}

extension ButtonStyle where Self == FullAreaButtonStyle {
    /// Schlichte Taste, deren ganze Fläche klickbar ist.
    static var fullArea: FullAreaButtonStyle { FullAreaButtonStyle() }
}

// MARK: - Menütaste mit voller Klickfläche

/// Taste, die beim Klick ein AppKit-Menü öffnet (v1.16.2). Ersetzt SwiftUI-`Menu` mit
/// `.borderlessButton`: das nimmt Klicks nur auf der Fläche seines Titels an, auch mit
/// größerem Label. Das Menü wird erst beim Klick gebaut und ist damit immer aktuell.
struct MenuKey<Label: View>: View {
    let menu: () -> NSMenu
    @ViewBuilder let label: () -> Label

    var body: some View {
        Button { menu().popUp(positioning: nil, at: NSEvent.mouseLocation, in: nil) } label: {
            label().contentShape(Rectangle())
        }
        .buttonStyle(.fullArea)
    }
}

extension NSMenu {
    /// Menü aus fertigen Einträgen; Einträge schalten sich nicht selbst aus.
    static func of(_ items: [NSMenuItem]) -> NSMenu {
        let m = NSMenu()
        m.autoenablesItems = false
        items.forEach(m.addItem)
        return m
    }
}

extension NSMenuItem {
    /// Nicht wählbarer Eintrag (Überschrift oder Hinweis).
    static func note(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func with(image symbol: String? = nil, enabled: Bool = true, toolTip: String? = nil) -> NSMenuItem {
        if let symbol { image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil) }
        isEnabled = enabled
        if let toolTip { self.toolTip = toolTip }
        return self
    }
}
