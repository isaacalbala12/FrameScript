import AppKit
import SwiftUI

enum AppearanceTheme: String, Codable, CaseIterable, Identifiable {
    case system = "System"
    case light = "Light"
    case dark = "Dark"

    var id: String { rawValue }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

enum AccentPalette: String, Codable, CaseIterable, Identifiable {
    case lavender = "Lavender"
    case sage = "Sage"
    case rose = "Rose"
    case sand = "Sand"
    case sky = "Sky"
    case mint = "Mint"
    case peach = "Peach"
    case slate = "Slate"

    var id: String { rawValue }

    var color: Color {
        switch self {
        case .lavender: Color(hex: 0xB8A9FF)
        case .sage: Color(hex: 0xB6C6B0)
        case .rose: Color(hex: 0xD9B6C3)
        case .sand: Color(hex: 0xD4C0A1)
        case .sky: Color(hex: 0xB8CCE2)
        case .mint: Color(hex: 0xAFCFC4)
        case .peach: Color(hex: 0xE5B9A6)
        case .slate: Color(hex: 0xAEB8C2)
        }
    }
}

struct FrameTheme {
    let colorScheme: ColorScheme
    let accent: AccentPalette

    var appBackground: Color {
        colorScheme == .dark ? Color(hex: 0x111216) : Color(hex: 0xF7F6F3)
    }

    var windowBackground: Color {
        colorScheme == .dark ? Color(hex: 0x14161B) : Color(hex: 0xFDFCF9)
    }

    var sidebarBackground: Color {
        colorScheme == .dark ? Color(hex: 0x15171C) : Color(hex: 0xF1F0EC)
    }

    var panelBackground: Color {
        colorScheme == .dark ? Color(hex: 0x181A20) : Color(hex: 0xFBFAF7)
    }

    var cardBackground: Color {
        colorScheme == .dark ? Color(hex: 0x1B1D23) : Color(hex: 0xFFFFFF)
    }

    var editorSurface: Color {
        colorScheme == .dark ? Color(hex: 0x101217) : Color(hex: 0xFBFAF7)
    }

    var editorBackground: Color {
        editorSurface
    }

    var background: Color {
        appBackground
    }

    var sidebar: Color {
        sidebarBackground
    }

    var surface: Color {
        cardBackground
    }

    var editor: Color {
        editorSurface
    }

    var primaryText: Color {
        colorScheme == .dark ? Color(hex: 0xF4F4F5) : Color(hex: 0x1D1D1F)
    }

    var secondaryText: Color {
        colorScheme == .dark ? Color(hex: 0xA1A1AA) : Color(hex: 0x6F6F74)
    }

    var tertiaryText: Color {
        colorScheme == .dark ? Color(hex: 0x71717A) : Color(hex: 0x8A8882)
    }

    var divider: Color {
        colorScheme == .dark ? Color(hex: 0x262A31) : Color(hex: 0xE2E0DA)
    }

    var accentSoft: Color {
        accent.color.opacity(colorScheme == .dark ? 0.24 : 0.32)
    }

    /// Accent darkened/lightened to reach at least 4.5:1 against white text (filled buttons).
    var accentStrong: Color {
        Color(nsColor: MarkupEditorPalette.ensuredContrast(NSColor(accent.color), against: .white, minimum: 4.5))
    }

    /// Accent usable as text: at least 4.5:1 against `appBackground` in light and dark.
    var accentText: Color {
        Color(nsColor: MarkupEditorPalette.ensuredContrast(NSColor(accent.color), against: NSColor(appBackground), minimum: 4.5))
    }

    var softAccent: Color {
        accentSoft
    }

    var hover: Color {
        colorScheme == .dark ? Color.white.opacity(0.06) : Color.black.opacity(0.045)
    }

    var selection: Color {
        accent.color.opacity(colorScheme == .dark ? 0.30 : 0.24)
    }

    var focus: Color {
        accent.color.opacity(colorScheme == .dark ? 0.75 : 0.62)
    }

    var focusRing: Color {
        focus
    }

    var destructive: Color {
        colorScheme == .dark ? Color(hex: 0xFF8A8A) : Color(hex: 0xB42318)
    }

    var warning: Color {
        colorScheme == .dark ? Color(hex: 0xF7C66B) : Color(hex: 0xB7791F)
    }

    var success: Color {
        colorScheme == .dark ? Color(hex: 0x8FD3A6) : Color(hex: 0x2F7D52)
    }

    var bRollMarker: Color {
        colorScheme == .dark ? Color(hex: 0x6EA8FF) : Color(hex: 0x2563EB)
    }

    var editingMarker: Color {
        colorScheme == .dark ? Color(hex: 0x78D39A) : Color(hex: 0x2F8F55)
    }
}

@MainActor
@Observable
final class ResolvedThemeManager {
    var selectedTheme: AppearanceTheme = .system
    var systemColorScheme: ColorScheme = .light
    var resolvedColorScheme: ColorScheme = .light
    var accentColor: AccentPalette = .sage

    private var appearanceObserver: NSObjectProtocol?

    init() {
        systemColorScheme = Self.currentSystemColorScheme()
        resolvedColorScheme = systemColorScheme
        appearanceObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name("AppleInterfaceThemeChangedNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.refreshSystemAppearance()
            }
        }
    }

    var preferredColorScheme: ColorScheme? {
        selectedTheme.colorScheme
    }

    var frameTheme: FrameTheme {
        FrameTheme(colorScheme: resolvedColorScheme, accent: accentColor)
    }

    func update(selectedTheme: AppearanceTheme, systemColorScheme: ColorScheme? = nil, accentColor: AccentPalette) {
        self.selectedTheme = selectedTheme
        self.accentColor = accentColor
        applyAppAppearance(for: selectedTheme)
        self.systemColorScheme = systemColorScheme ?? Self.currentSystemColorScheme()
        resolvedColorScheme = selectedTheme.colorScheme ?? self.systemColorScheme

        if selectedTheme == .system {
            Task { @MainActor in
                self.refreshSystemAppearance()
            }
        }
    }

    func refreshSystemAppearance() {
        systemColorScheme = Self.currentSystemColorScheme()
        resolvedColorScheme = selectedTheme.colorScheme ?? systemColorScheme
    }

    private func applyAppAppearance(for theme: AppearanceTheme) {
        guard let app = NSApp else {
            return
        }

        let appearanceName: NSAppearance.Name?
        switch theme {
        case .system:
            appearanceName = nil
        case .light:
            appearanceName = .aqua
        case .dark:
            appearanceName = .darkAqua
        }

        let appearance = appearanceName.map(NSAppearance.init(named:)) ?? nil
        app.appearance = appearance
        for window in app.windows {
            window.appearance = appearance
        }
    }

    private static func currentSystemColorScheme() -> ColorScheme {
        if let match = NSApp?.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) {
            return match == .darkAqua ? .dark : .light
        }

        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark" ? .dark : .light
    }
}

private struct FrameThemeKey: EnvironmentKey {
    static let defaultValue = FrameTheme(colorScheme: .light, accent: .lavender)
}

extension EnvironmentValues {
    var frameTheme: FrameTheme {
        get { self[FrameThemeKey.self] }
        set { self[FrameThemeKey.self] = newValue }
    }
}

extension Color {
    init(hex: UInt, alpha: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: alpha
        )
    }
}

extension View {
    func cursor(_ cursor: NSCursor, enabled: Bool = true) -> some View {
        modifier(CursorModifier(cursor: cursor, enabled: enabled))
    }

    func clickableCursor(enabled: Bool = true) -> some View {
        cursor(.pointingHand, enabled: enabled)
    }

    func resizeHorizontalCursor(enabled: Bool = true) -> some View {
        cursor(.resizeLeftRight, enabled: enabled)
    }

    func textCursor(enabled: Bool = true) -> some View {
        cursor(.iBeam, enabled: enabled)
    }
}

struct CursorPlainButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.75 : 1)
            .clickableCursor(enabled: isEnabled)
    }
}

extension ButtonStyle where Self == CursorPlainButtonStyle {
    static var cursorPlain: CursorPlainButtonStyle {
        CursorPlainButtonStyle()
    }
}

private struct CursorModifier: ViewModifier {
    @Environment(\.isEnabled) private var isEnabled
    let cursor: NSCursor
    let enabled: Bool

    func body(content: Content) -> some View {
        content.overlay {
            CursorRectRepresentable(cursor: enabled && isEnabled ? cursor : nil)
                .allowsHitTesting(false)
        }
    }
}

private struct CursorRectRepresentable: NSViewRepresentable {
    let cursor: NSCursor?

    func makeNSView(context: Context) -> CursorRectView {
        let view = CursorRectView()
        view.cursor = cursor
        return view
    }

    func updateNSView(_ nsView: CursorRectView, context: Context) {
        nsView.cursor = cursor
    }
}

private final class CursorRectView: NSView {
    var cursor: NSCursor? {
        didSet {
            window?.invalidateCursorRects(for: self)
        }
    }

    override func resetCursorRects() {
        super.resetCursorRects()

        if let cursor {
            addCursorRect(bounds, cursor: cursor)
        }
    }
}
