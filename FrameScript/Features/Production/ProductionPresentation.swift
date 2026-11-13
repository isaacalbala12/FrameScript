import FrameScriptCore
import Observation
import SwiftUI

/// Presentation flag for the production sheet. A standalone model keeps the
/// feature out of the shared window state and lets the toolbar, menu, palette
/// and sidebar all open the same panel.
@MainActor
@Observable
final class ProductionPresentation {
    static let shared = ProductionPresentation()

    var isPresented = false

    @ObservationIgnored private var presentsAfterPaletteDismissal = false

    private init() {}

    func present() {
        isPresented = true
    }

    /// The command palette is itself a sheet. Defer opening the production
    /// sheet until the palette has dismissed so macOS never has two sheets
    /// competing for the same window.
    func presentAfterPaletteDismissal() {
        presentsAfterPaletteDismissal = true
    }

    func presentPendingRequest() {
        guard presentsAfterPaletteDismissal else { return }
        presentsAfterPaletteDismissal = false
        isPresented = true
    }

    func resetForTesting() {
        isPresented = false
        presentsAfterPaletteDismissal = false
    }
}

/// Attaches the production sheet to the main window. Called once from
/// `FrameScriptApp.swift`.
struct ProductionSheetModifier: ViewModifier {
    let appState: AppState

    func body(content: Content) -> some View {
        @Bindable var presentation = ProductionPresentation.shared
        content
            .sheet(isPresented: $presentation.isPresented) {
                ProductionPanelView()
                    .environment(appState)
                    .environment(\.frameTheme, appState.themeManager.frameTheme)
            }
            .onChange(of: appState.isCommandPalettePresented) { _, isPresented in
                if !isPresented {
                    ProductionPresentation.shared.presentPendingRequest()
                }
            }
            .modifier(DebugProductionPresentationModifier())
    }
}

extension View {
    func productionSheet(_ appState: AppState) -> some View {
        modifier(ProductionSheetModifier(appState: appState))
    }
}

private struct DebugProductionPresentationModifier: ViewModifier {
    func body(content: Content) -> some View {
        #if DEBUG
        content.onAppear {
            guard ProcessInfo.processInfo.arguments.contains("--framescript-ui-test-show-production") else {
                return
            }
            Task { @MainActor in
                await Task.yield()
                ProductionPresentation.shared.present()
            }
        }
        #else
        content
        #endif
    }
}
