import ArrdeckData
import Observation
import SwiftUI

/// Light, dark, or whatever the system is.
public enum Appearance: String, CaseIterable, Sendable {
    case system, light, dark

    public var label: String {
        switch self {
        case .system: String(localized: "System")
        case .light: String(localized: "Light")
        case .dark: String(localized: "Dark")
        }
    }
}

/// The chosen palette and appearance. Observable, so a view that reads one of
/// the colours below redraws when the palette changes — the colours reach it
/// through `Color.grouped` and friends rather than being threaded through
/// every initialiser. Light and dark variants resolve through dynamic colours.
@MainActor @Observable
public final class ThemeStore {
    public static let shared = ThemeStore()

    public var palette: Palette {
        didSet { UserDefaults.standard.set(palette.rawValue, forKey: Self.paletteKey) }
    }
    public var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    static let paletteKey = "display.palette"
    static let appearanceKey = "display.appearance"

    init() {
        palette = UserDefaults.standard.pref(Self.paletteKey, default: Palette.arrdeck)
        appearance = UserDefaults.standard.pref(Self.appearanceKey, default: Appearance.system)
    }

    /// nil follows the system; a palette with no light variant pins dark.
    public var colorScheme: ColorScheme? {
        if palette.darkOnly { return .dark }
        return switch appearance {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    /// One role of the palette as a colour that follows light and dark, or
    /// nil for arrdeck's own, which uses the system colours.
    func color(_ role: KeyPath<PaletteTokens, UInt32>) -> Color? {
        guard let dark = palette.dark else { return nil }
        let light = palette.light ?? dark
        return Color.dynamic(light: light[keyPath: role], dark: dark[keyPath: role])
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255, green: Double((hex >> 8) & 0xFF) / 255, blue: Double(hex & 0xFF) / 255)
    }

    static func dynamic(light: UInt32, dark: UInt32) -> Color {
        #if os(iOS)
        Color(uiColor: UIColor { traits in
            UIColor(Color(hex: traits.userInterfaceStyle == .dark ? dark : light))
        })
        #else
        Color(nsColor: NSColor(name: nil) { appearance in
            NSColor(Color(hex: appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light))
        })
        #endif
    }

    /// The grouped background behind cards.
    @MainActor static var grouped: Color {
        if let themed = ThemeStore.shared.color(\.background) { return themed }
        #if os(iOS)
        return Color(uiColor: .systemGroupedBackground)
        #else
        return Color(nsColor: .windowBackgroundColor)
        #endif
    }

    /// A card on the grouped background.
    @MainActor static var card: Color {
        if let themed = ThemeStore.shared.color(\.card) { return themed }
        #if os(iOS)
        return Color(uiColor: .secondarySystemGroupedBackground)
        #else
        return Color(nsColor: .controlBackgroundColor)
        #endif
    }

    /// The palette's status colours; the system's under arrdeck's colours.
    @MainActor static var success: Color { ThemeStore.shared.color(\.success) ?? .green }
    @MainActor static var warning: Color { ThemeStore.shared.color(\.warning) ?? .orange }

    /// The palette's accent; the app's own blue under arrdeck's colours.
    @MainActor static var accent: Color { ThemeStore.shared.color(\.accent) ?? .accentColor }
}

extension View {
    /// At the root: the palette's appearance and accent. Text keeps the system
    /// colours, which sit close to every palette's own and keep list icons
    /// tinted rather than turning them the text colour.
    func themed() -> some View { modifier(ThemedRoot()) }

    /// A list or form on the palette's background, rows on its cards.
    func themedList() -> some View { modifier(ThemedList()) }
}

private struct ThemedRoot: ViewModifier {
    func body(content: Content) -> some View {
        let store = ThemeStore.shared
        content
            .preferredColorScheme(store.colorScheme)
            .tint(Color.accent)
    }
}

private struct ThemedList: ViewModifier {
    func body(content: Content) -> some View {
        if ThemeStore.shared.palette == .arrdeck {
            content
        } else {
            content
                .scrollContentBackground(.hidden)
                .background(Color.grouped)
                .environment(\.themedRowBackground, true)
        }
    }
}

extension EnvironmentValues {
    /// Set inside a themed list; rows read it to take the palette's card colour.
    @Entry var themedRowBackground = false
}
