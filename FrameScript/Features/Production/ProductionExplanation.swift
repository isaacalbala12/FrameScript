import FrameScriptCore
import Foundation

/// Plain-language text for production rows, shared by the Producción sheet
/// and the inspector tab so both say the same thing about the same item.
///
/// Automatic rows are derived from the document (`ProductionChecklist`); they
/// carry the reason they exist and, where one exists, a one-click action.
/// Manual rows are the tasks the writer added.
enum ProductionExplanation {
    /// Localization key (`production.why.*`) for an item's explanation.
    static func explanationKey(for item: ProductionItem) -> String {
        switch item.reason {
        case .sceneNeedsTake:
            item.languageCode == nil ? "production.why.sceneNeedsTake" : "production.why.sceneNeedsTake.variant"
        case .bRollNeedsFootage: "production.why.bRollNeedsFootage"
        case .bRollNeedsAsset: "production.why.bRollNeedsAsset"
        case .editingNeedsWork: "production.why.editingNeedsWork"
        case .claimNeedsVerification: "production.why.claimNeedsVerification"
        case .publishingChecklist: "production.why.publishingChecklist"
        case .manualTask: "production.why.manualTask"
        }
    }

    /// Why the row is there. `recordShortcut` is the display string of the
    /// active "Grabar toma" shortcut (for example `⌘R`), or `nil` when the
    /// user cleared it.
    static func explanation(
        for item: ProductionItem,
        language: AppLanguage,
        recordShortcut: String?
    ) -> String {
        if case .sceneNeedsTake = item.reason, item.languageCode == nil {
            if let recordShortcut {
                return String(
                    format: L10n.tr("production.why.sceneNeedsTake", language: language),
                    recordShortcut
                )
            }
            return L10n.tr("production.why.sceneNeedsTake.noShortcut", language: language)
        }
        return L10n.tr(explanationKey(for: item), language: language)
    }

    /// Automatic rows are the ones the app derives itself.
    static func isAutomatic(_ item: ProductionItem) -> Bool {
        item.reason != .manualTask
    }

    /// Label of the one-click button, or `nil` for manual tasks.
    static func actionKey(for item: ProductionItem) -> String? {
        switch item.target {
        case .takes, .scene: "production.action.record"
        case .bRoll: "production.action.bRoll"
        case .editing: "production.action.editing"
        case .research: "production.action.research"
        case .publishing: "production.action.publishing"
        case .manualTask: nil
        }
    }

    static func tooltipKey(for kind: ProductionItemKind?) -> String {
        "production.kind.\(kind?.rawValue ?? "all").help"
    }

    /// Row title shared by the panel and the inspector.
    static func title(for item: ProductionItem, language: AppLanguage) -> String {
        if !item.sourceText.isEmpty { return item.sourceText }
        func tr(_ key: String) -> String { L10n.tr(key, language: language) }
        func indexed(_ base: String) -> String {
            item.sourceIndex.map { "\(base) \($0 + 1)" } ?? base
        }
        switch item.reason {
        case .sceneNeedsTake:
            if let order = item.sceneOrder {
                return String(format: tr("production.item.scene"), max(0, order) + 1)
            }
            return tr("production.item.sceneFallback")
        case .bRollNeedsFootage, .bRollNeedsAsset:
            return indexed(tr("production.item.bRoll"))
        case .editingNeedsWork:
            return indexed(tr("production.item.editing"))
        case .claimNeedsVerification:
            return tr("production.item.claim")
        case .publishingChecklist(let checklistItem):
            return tr(checklistItem.titleKey)
        case .manualTask:
            return tr("production.item.task")
        }
    }
}

/// One-time explainer at the top of the Producción sheet. Its dismissed flag
/// lives in the injected defaults (`AppEnvironment.defaults` in the app, an
/// isolated suite in tests).
struct ProductionExplainerStore {
    static let dismissedKey = "FrameScript.production.explainerDismissed"

    let defaults: UserDefaults

    init(defaults: UserDefaults = AppEnvironment.defaults) {
        self.defaults = defaults
    }

    var isDismissed: Bool {
        defaults.bool(forKey: Self.dismissedKey)
    }

    func dismiss() {
        defaults.set(true, forKey: Self.dismissedKey)
    }

    func reset() {
        defaults.removeObject(forKey: Self.dismissedKey)
    }
}
