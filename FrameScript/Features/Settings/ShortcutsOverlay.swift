import SwiftUI

struct ShortcutsOverlay: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(appState.localized("shortcuts.title"))
                        .font(.system(size: 24, weight: .semibold))

                    ForEach(ShortcutsOverlayLayout.categorySections) { section in
                        VStack(alignment: .leading, spacing: 8) {
                            Text(appState.localized(section.category.localizationKey))
                                .font(.system(size: 13, weight: .semibold))
                                .foregroundStyle(theme.secondaryText)

                            LazyVGrid(columns: [GridItem(.fixed(90)), GridItem(.flexible())], alignment: .leading, spacing: 10) {
                                ForEach(section.definitions) { shortcut in
                                    Text(appState.shortcutDisplay(for: shortcut.command))
                                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                                        .foregroundStyle(theme.primaryText)
                                    Text(appState.localized(shortcut.localizationKey))
                                        .font(.system(size: 13))
                                        .foregroundStyle(theme.secondaryText)
                                }
                            }
                        }
                    }
                }
                .padding(24)
            }

            Divider()
                .overlay(theme.divider)

            HStack {
                Spacer()
                // Mouse-only users need a visible way out; Escape keeps working.
                Button(appState.localized("dialog.ok")) {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                .clickableCursor()
            }
            .padding(.horizontal, 24)
            .frame(height: 56)
        }
        .frame(width: 420)
        .frame(maxHeight: ShortcutsOverlayLayout.maximumContentHeight)
        .background(theme.background)
    }
}

struct ShortcutsOverlayCategorySection: Identifiable {
    let category: ShortcutCategory
    let definitions: [ShortcutDefinition]

    var id: ShortcutCategory { category }
}

enum ShortcutsOverlayLayout {
    static let maximumContentHeight: CGFloat = 620

    /// Filtering the registry preserves its definition order. Categories are
    /// deliberately driven by allCases rather than a global order comparison.
    static let categorySections = ShortcutCategory.allCases.map { category in
        ShortcutsOverlayCategorySection(
            category: category,
            definitions: ShortcutRegistry.definitions.filter { $0.category == category }
        )
    }
}
