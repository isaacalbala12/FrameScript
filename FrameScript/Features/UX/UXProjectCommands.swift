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
/// Research uses the stored claim's `needsResearch` flag, which is the same
/// `!personalExperience && needsVerification` rule `ResearchSummary` applies,
/// without converting every claim into a document snapshot. Production reuses
/// the debounced snapshot the sidebar, toolbar and panel already read. Both
/// hide at zero.
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
            researchPending: UXResearchPending.projectCount(in: appState.project.claims),
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

    /// VoiceOver text for the badge. Plurals are formatted by `L10n.plural`,
    /// so counts such as Russian 21 use the singular noun form correctly.
    func accessibilityText(for action: UXEditorAction, language: AppLanguage) -> String? {
        guard let count = count(for: action) else { return nil }
        return UXProjectBadgeAccessibility.text(for: action, count: count, language: language)
    }
}

/// Pluralized VoiceOver copy for the badge counts.
enum UXProjectBadgeAccessibility {
    static func text(for action: UXEditorAction, count: Int, language: AppLanguage) -> String? {
        let baseKey: String
        switch action {
        case .researchPanel:
            baseKey = "ux.action.badge.research"
        case .productionChecklist:
            baseKey = "ux.action.badge.production"
        default:
            return nil
        }
        return L10n.plural(baseKey, count: count, language: language)
    }
}

/// The pending-claim rule shared by the action-bar badge, the scene chip and
/// the inspector. `ProjectClaim.needsResearch` already encodes the product
/// rule; this only counts without building a document projection.
enum UXResearchPending {
    static func projectCount(in claims: [ProjectClaim]) -> Int {
        claims.reduce(0) { $0 + ($1.needsResearch ? 1 : 0) }
    }

    static func sceneCount(in claims: [ProjectClaim], sceneID: UUID) -> Int {
        claims.reduce(0) { result, claim in
            result + (claim.needsResearch && claim.sceneIDs.contains(sceneID) ? 1 : 0)
        }
    }
}
