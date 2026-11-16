import Foundation
import FrameScriptCore

/// Real `ProductionNavigator` used by the app. Publishing and research are
/// separate panels, so the checklist forwards those destinations here instead
/// of claiming they do not exist (E-1).
@MainActor
final class AppProductionNavigator: ProductionNavigator {
    private weak var appState: AppState?

    init(appState: AppState) {
        self.appState = appState
    }

    func navigate(to target: ProductionTarget) -> Bool {
        guard let appState, appState.hasOpenProject else { return false }

        switch target {
        case .publishing(let languageCode):
            PublishingPresentation.shared.selectedLanguageCode = languageCode
            appState.showPublishingPanel()
            return true

        case .research(let claimID):
            guard let claim = appState.project.claims.first(where: { $0.id == claimID }) else {
                return false
            }
            appState.openResearchPanel(sceneID: claim.sceneIDs.first)
            ResearchPresentation.shared.selectedClaimID = claimID
            ResearchPresentation.shared.onlyPending = false
            return true

        case .scene, .bRoll, .editing, .takes, .manualTask:
            // Those destinations are handled directly by `AppState+Production`.
            return false
        }
    }
}
