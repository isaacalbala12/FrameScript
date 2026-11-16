import Foundation

/// Where a project command is invoked from.
///
/// The command palette is itself a sheet, so it asks the shared presenters to
/// wait until the palette dismisses. The menu and the action bar present
/// immediately. The routing is otherwise identical, which is why both surfaces
/// call ``UXProjectCommandDispatcher`` instead of duplicating the switches.
enum UXProjectCommandPresentation: Sendable {
    case direct
    case afterSheetDismissal
}

/// Single entry point for the project-wide panels in the Proyecto group.
///
/// Every case calls the same `AppState`/presenter seam the application menu
/// uses, so the action bar can never drift from the command it advertises.
/// Enablement stays in `CommandAvailability`, through each action's
/// `shortcutCommand`.
@MainActor
enum UXProjectCommandDispatcher {
    /// - Returns: `true` when the command belongs to the project group.
    @discardableResult
    static func perform(
        _ command: ShortcutCommand,
        appState: AppState,
        presentation: UXProjectCommandPresentation = .direct
    ) -> Bool {
        switch command {
        case .productionChecklist:
            switch presentation {
            case .direct:
                ProductionPresentation.shared.present()
            case .afterSheetDismissal:
                ProductionPresentation.shared.presentAfterPaletteDismissal()
            }
        case .researchPanel:
            appState.openResearchPanel()
        case .assets:
            appState.isAssetsPresented = true
        case .publishingPack:
            appState.showPublishingPanel()
        case .resolvePack:
            let languageCode = appState.resolvePackDefaultLanguageCode
            switch presentation {
            case .direct:
                ResolvePackPresenter.shared.present(languageCode: languageCode)
            case .afterSheetDismissal:
                ResolvePackPresenter.shared.presentAfterPaletteDismissal(languageCode: languageCode)
            }
        default:
            return false
        }
        return true
    }

    /// The commands this dispatcher owns, in menu order.
    static let commands: [ShortcutCommand] = [
        .productionChecklist,
        .researchPanel,
        .assets,
        .publishingPack,
        .resolvePack
    ]
}

/// Cheap badge counts for the Proyecto buttons.
///
/// Research uses the same `ResearchSummary` pending rule as the scene badges
/// (`!personalExperience && needsVerification`). Production reuses the
/// debounced snapshot the sidebar and toolbar already read. Both hide at zero.
struct UXProjectBadges: Equatable {
    var researchPending: Int
    var productionPending: Int

    init(researchPending: Int = 0, productionPending: Int = 0) {
        self.researchPending = researchPending
        self.productionPending = productionPending
    }

    @MainActor
    init(appState: AppState) {
        guard appState.hasOpenProject else {
            self.init()
            return
        }
        self.init(
            researchPending: appState.researchCounts().pending,
            productionPending: ProductionChecklistCenter.shared.snapshot.summary.totalPending
        )
    }

    func count(for action: UXEditorAction) -> Int? {
        let value: Int
        switch action {
        case .productionChecklist:
            value = productionPending
        case .researchPanel:
            value = researchPending
        default:
            return nil
        }
        return value > 0 ? value : nil
    }
}
