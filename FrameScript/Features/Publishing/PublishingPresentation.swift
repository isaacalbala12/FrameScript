import Foundation
import Observation
import SwiftUI

/// Presentation state for the Publishing sheet. Kept out of the shared window
/// state so the feature owns its own lifecycle.
@MainActor
@Observable
final class PublishingPresentation {
    static let shared = PublishingPresentation()

    var isPresented = false
    var isGeneratingTitles = false
    var titleSuggestions: [String] = []
    var titleGenerationError: String?

    private init() {}

    func resetTitleGeneration() {
        isGeneratingTitles = false
        titleSuggestions = []
        titleGenerationError = nil
    }
}

enum PublishingTab: String, CaseIterable, Identifiable {
    case metadata
    case chapters
    case thumbnails
    case checklist

    var id: String { rawValue }

    var titleKey: String { "publishing.tab.\(rawValue)" }

    var systemImage: String {
        switch self {
        case .metadata: "text.alignleft"
        case .chapters: "list.number"
        case .thumbnails: "photo"
        case .checklist: "checklist"
        }
    }
}

/// Fixed geometry of the Publishing sheet. The content height is what remains
/// after header, tabs and footer; the snapshot tests assert it stays positive
/// at the 980×712 minimum window.
enum PublishingMetrics {
    static let panelWidth: CGFloat = 900
    static let panelHeight: CGFloat = 620
    static let headerHeight: CGFloat = 64
    static let tabBarHeight: CGFloat = 46
    static let footerHeight: CGFloat = 58

    static var contentHeight: CGFloat {
        panelHeight - headerHeight - tabBarHeight - footerHeight - 3
    }
}

/// Attaches the Publishing sheet to the main window. Called once from
/// `FrameScriptApp.swift`, next to the backups sheet.
struct PublishingSheetModifier: ViewModifier {
    let appState: AppState

    func body(content: Content) -> some View {
        @Bindable var presentation = PublishingPresentation.shared
        content.sheet(isPresented: $presentation.isPresented) {
            PublishingPanel()
                .environment(appState)
                .environment(\.frameTheme, appState.themeManager.frameTheme)
        }
    }
}

extension View {
    func publishingSheet(_ appState: AppState) -> some View {
        modifier(PublishingSheetModifier(appState: appState))
    }
}
