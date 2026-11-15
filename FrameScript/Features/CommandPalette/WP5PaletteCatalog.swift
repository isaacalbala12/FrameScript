import Foundation
import Observation

/// Data source for the command palette.
///
/// The palette used to keep its own list and covered only 17 of 30 commands
/// (commands P2-2). It now renders exactly this list, in menu order, so a
/// command can no longer exist in the menus and be missing from the palette.
/// `.commandPalette` is the palette itself and is the only command that is
/// intentionally absent.
enum PaletteCatalog {
    static let commands: [ShortcutCommand] = ApplicationMenuSpec.items
        .map(\.command)
        .filter { $0 != .commandPalette }

    /// Commands the palette hides while no project is open, on top of the
    /// availability matrix (which already covers most of them).
    static func isAvailable(_ command: ShortcutCommand, availability: CommandAvailability) -> Bool {
        availability.isEnabled(command)
    }
}

/// A palette action that must run after the palette sheet is dismissed, because
/// SwiftUI allows one sheet per window (the export sheet would otherwise be
/// requested while the palette is still on screen).
@MainActor
@Observable
final class PaletteActionHandoff {
    static let shared = PaletteActionHandoff()

    var opensExport = false

    func takeExportRequest() -> Bool {
        defer { opensExport = false }
        return opensExport
    }
}
