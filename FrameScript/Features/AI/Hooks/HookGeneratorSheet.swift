import AppKit
import FrameScriptCore
import Observation
import SwiftUI

enum HookMode: String, Identifiable, CaseIterable {
    case hook
    case rehook

    var id: String { rawValue }

    var titleKey: String {
        self == .hook ? "hooks.title" : "hooks.rehookTitle"
    }

    var subtitleKey: String {
        self == .hook ? "hooks.subtitle" : "hooks.rehookSubtitle"
    }
}

struct HookSheetRequest: Identifiable, Equatable {
    let id = UUID()
    let mode: HookMode
}

/// A tiny presentation coordinator. The menu presents immediately; the command
/// palette stores the request and asks for it when its own sheet has closed.
@MainActor
@Observable
final class HookSheetPresenter {
    static let shared = HookSheetPresenter()

    var request: HookSheetRequest?
    private var pendingRequest: HookSheetRequest?

    func present(_ mode: HookMode) {
        request = HookSheetRequest(mode: mode)
    }

    func presentAfterPaletteDismissal(_ mode: HookMode) {
        pendingRequest = HookSheetRequest(mode: mode)
    }

    func presentPendingRequest() {
        guard let pendingRequest else { return }
        self.pendingRequest = nil
        request = pendingRequest
    }
}

// MARK: - Sheet

struct HookGeneratorSheet: View {
    let mode: HookMode

    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme
    @Environment(\.dismiss) private var dismiss
    @Environment(\.undoManager) private var undoManager

    @State private var generationToken = UUID()
    @State private var cancelRequested = false
    @State private var isLoading = true
    @State private var didCancel = false
    @State private var hookResult: HookGenerationResult?
    @State private var rehookResult: RehookGenerationResult?
    @State private var errorKey: String?
    @State private var copiedText: String?
    @State private var insertedRehooks: Set<RehookSuggestion> = []
    @State private var didInsertRehook = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(theme.divider)
            ScrollView {
                content
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider().overlay(theme.divider)
            footer
        }
        .frame(width: 720, height: 660)
        .background(theme.background)
        .task(id: generationToken) {
            guard !cancelRequested else { return }
            await generate(token: generationToken)
        }
    }

    // MARK: Chrome

    private var header: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(appState.localized(mode.titleKey))
                    .font(.system(size: 22, weight: .semibold))
                Text(appState.localized(mode.subtitleKey))
                    .font(.system(size: 12))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            Button {
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .semibold))
                    .frame(width: 26, height: 26)
                    .background(Circle().fill(theme.hover))
            }
            .buttonStyle(.cursorPlain)
            .foregroundStyle(theme.secondaryText)
            .accessibilityLabel(appState.localized("hooks.close"))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
    }

    private var footer: some View {
        HStack(spacing: 12) {
            Text(footerHint)
                .font(.system(size: 11))
                .foregroundStyle(theme.secondaryText)
                .lineLimit(2)
            Spacer()
            Button(appState.localized("hooks.regenerate")) {
                regenerate()
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(isLoading ? theme.tertiaryText : theme.primaryText)
            .disabled(isLoading)

            Button(appState.localized("hooks.close")) {
                dismiss()
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.primaryText)
            .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private var footerHint: String {
        if didInsertRehook {
            return appState.localized("hooks.inserted")
        }
        return appState.localized(mode == .hook ? "hooks.limitHint" : "hooks.rehookLimitHint")
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if isLoading {
            loadingView
        } else if didCancel {
            cancelledView
        } else if let errorKey {
            errorView(errorKey)
        } else if mode == .hook {
            hookContent
        } else {
            rehookContent
        }
    }

    private var loadingView: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.regular)
            Text(appState.localized(mode == .hook ? "hooks.loading" : "hooks.loadingRehooks"))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
            Button(appState.localized("hooks.cancel")) {
                cancel()
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.primaryText)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 110)
    }

    private var cancelledView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.localized("hooks.cancelled"))
                .font(.system(size: 14, weight: .medium))
            Button(appState.localized("hooks.retry")) {
                regenerate()
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.primaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func errorView(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text(appState.localized("hooks.error.title"))
                    .font(.system(size: 14, weight: .semibold))
            }
            Text(appState.localized(key))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 14) {
                Button(appState.localized("hooks.retry")) {
                    regenerate()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)

                if showsSettingsButton(for: key) {
                    Button(appState.localized("hooks.openSettings")) {
                        openAISettings()
                    }
                    .buttonStyle(.cursorPlain)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(theme.primaryText)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    @ViewBuilder
    private var hookContent: some View {
        if let result = hookResult {
            VStack(alignment: .leading, spacing: 14) {
                sceneRow(
                    title: result.sceneTitle,
                    duration: result.sceneDuration,
                    words: result.sceneWordCount,
                    wordsPerMinute: result.wordsPerMinute
                )
                ForEach(Array(result.hooks.enumerated()), id: \.offset) { index, hook in
                    HookCard(
                        index: index,
                        hook: hook,
                        isCopied: copiedText == hook.text,
                        onInsert: { insertHook(hook) },
                        onCopy: { copy(hook.text) }
                    )
                }
                Text(appState.localized("hooks.generatedBy"))
                    .font(.system(size: 10))
                    .foregroundStyle(theme.tertiaryText)
            }
        } else {
            emptyView("hooks.empty")
        }
    }

    @ViewBuilder
    private var rehookContent: some View {
        if let result = rehookResult {
            if result.positions.isEmpty {
                tooShortView(result)
            } else {
                VStack(alignment: .leading, spacing: 14) {
                    sceneRow(
                        title: result.sceneTitle,
                        duration: result.sceneDuration,
                        words: result.sceneWordCount,
                        wordsPerMinute: result.wordsPerMinute
                    )
                    positionsRow(result)
                    ForEach(Array(visibleRehooks.enumerated()), id: \.offset) { index, suggestion in
                        RehookCard(
                            index: index,
                            suggestion: suggestion,
                            isCopied: copiedText == suggestion.text,
                            onInsert: { insertRehook(suggestion) },
                            onCopy: { copy(suggestion.text) }
                        )
                    }
                    if visibleRehooks.isEmpty {
                        Text(appState.localized("hooks.inserted"))
                            .font(.system(size: 13, weight: .medium))
                    }
                    Text(appState.localized("hooks.generatedBy"))
                        .font(.system(size: 10))
                        .foregroundStyle(theme.tertiaryText)
                }
            }
        } else {
            emptyView("hooks.emptyRehooks")
        }
    }

    private func emptyView(_ key: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(appState.localized(key))
                .font(.system(size: 13))
                .foregroundStyle(theme.secondaryText)
            Button(appState.localized("hooks.regenerate")) {
                regenerate()
            }
            .buttonStyle(.cursorPlain)
            .font(.system(size: 12, weight: .medium))
            .foregroundStyle(theme.primaryText)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(cardBackground)
    }

    private func tooShortView(_ result: RehookGenerationResult) -> some View {
        let message = String(
            format: appState.localized("hooks.tooShortMessage"),
            appState.localized("hooks.tooShortThreshold"),
            appState.localized("hooks.tooShortMidpoint"),
            DurationEstimator.formatted(result.sceneDuration)
        )
        return VStack(alignment: .leading, spacing: 12) {
            sceneRow(
                title: result.sceneTitle,
                duration: result.sceneDuration,
                words: result.sceneWordCount,
                wordsPerMinute: result.wordsPerMinute
            )
            VStack(alignment: .leading, spacing: 8) {
                Text(appState.localized("hooks.tooShortTitle"))
                    .font(.system(size: 14, weight: .semibold))
                Text(message)
                    .font(.system(size: 13))
                    .foregroundStyle(theme.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                Button(appState.localized("hooks.regenerate")) {
                    regenerate()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.primaryText)
                .padding(.top, 2)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(cardBackground)
        }
    }

    private func sceneRow(
        title: String,
        duration: TimeInterval,
        words: Int,
        wordsPerMinute: Double
    ) -> some View {
        HStack(spacing: 8) {
            Text(appState.localized("hooks.scene"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(theme.secondaryText)
            Text(title.isEmpty ? "—" : title)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(1)
            Spacer(minLength: 12)
            Text(
                "\(DurationEstimator.formatted(duration)) · \(words) \(appState.localized("hooks.wordsShort")) · \(Int(wordsPerMinute.rounded())) \(appState.localized("hooks.wpm"))"
            )
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundStyle(theme.secondaryText)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(theme.surface)
        )
    }

    private func positionsRow(_ result: RehookGenerationResult) -> some View {
        HStack(spacing: 6) {
            ForEach(Array(result.positions.enumerated()), id: \.offset) { index, position in
                let key = position.reason == .longScene ? "hooks.positionLongScene" : "hooks.positionMidpoint"
                Text("\(index + 1) · \(appState.localized(key))")
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(theme.accentSoft))
            }
            Spacer()
        }
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(theme.surface)
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(theme.divider, lineWidth: 1)
            )
    }

    // MARK: Actions

    private var visibleRehooks: [RehookSuggestion] {
        rehookResult?.suggestions.filter { !insertedRehooks.contains($0) } ?? []
    }

    private func generate(token: UUID) async {
        isLoading = true
        didCancel = false
        errorKey = nil
        hookResult = nil
        rehookResult = nil
        insertedRehooks = []
        didInsertRehook = false
        defer {
            if generationToken == token { isLoading = false }
        }

        do {
            if mode == .hook {
                let result = try await appState.generateHookSuggestions()
                try Task.checkCancellation()
                guard generationToken == token else { return }
                hookResult = result
            } else {
                let result = try await appState.generateRehookSuggestions()
                try Task.checkCancellation()
                guard generationToken == token else { return }
                rehookResult = result
            }
        } catch is CancellationError {
            return
        } catch {
            guard !Task.isCancelled, generationToken == token else { return }
            errorKey = HookLocalization.errorKey(for: error)
        }
    }

    private func regenerate() {
        cancelRequested = false
        didCancel = false
        errorKey = nil
        generationToken = UUID()
    }

    private func cancel() {
        cancelRequested = true
        didCancel = true
        isLoading = false
        generationToken = UUID()
    }

    private func insertHook(_ hook: HookSuggestion) {
        if appState.insertHookSuggestion(hook, undoManager: undoManager) {
            dismiss()
        } else {
            errorKey = "hooks.error.noScene"
        }
    }

    private func insertRehook(_ suggestion: RehookSuggestion) {
        guard let result = rehookResult else { return }
        if appState.insertRehookSuggestion(
            suggestion,
            sceneID: result.sceneID,
            undoManager: undoManager
        ) {
            insertedRehooks.insert(suggestion)
            didInsertRehook = true
        } else {
            errorKey = "hooks.error.anchorMissing"
        }
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedText = text
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.4))
            if copiedText == text { copiedText = nil }
        }
    }

    private func openAISettings() {
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(180))
            appState.performRecovery(.openAISettings)
        }
    }

    private func showsSettingsButton(for key: String) -> Bool {
        [
            "hooks.error.disabled",
            "hooks.error.missingKey",
            "hooks.error.auth",
            "hooks.error.configuration"
        ].contains(key)
    }
}

// MARK: - Cards

private struct HookCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let index: Int
    let hook: HookSuggestion
    let isCopied: Bool
    let onInsert: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                if let angle = HookLocalization.angle(hook.angle, language: appState.currentLanguage) {
                    Text(angle)
                        .font(.system(size: 9, weight: .semibold))
                        .textCase(.uppercase)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(Capsule().fill(theme.accentSoft))
                }
                Text(HookFormat.seconds(hook.estimatedSeconds, language: appState.currentLanguage))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text(HookFormat.words(hook.wordCount, language: appState.currentLanguage))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                if hook.exceedsLimit {
                    Label(appState.localized("hooks.overLimit"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("#\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }

            Text(hook.text)
                .font(.system(size: 14))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            if !hook.onScreenText.isEmpty {
                HStack(spacing: 6) {
                    Image(systemName: "textformat")
                        .font(.system(size: 10))
                    Text("\(appState.localized("hooks.onScreen")): \(hook.onScreenText)")
                        .font(.system(size: 11))
                }
                .foregroundStyle(theme.secondaryText)
            }

            HStack(spacing: 12) {
                Button(appState.localized("hooks.insert")) {
                    onInsert()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent.color)
                .disabled(!hook.isWithinLimit)

                Button(isCopied ? appState.localized("hooks.copied") : appState.localized("hooks.copy")) {
                    onCopy()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)

                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(hook.exceedsLimit ? Color.orange.opacity(0.45) : theme.divider, lineWidth: 1)
                )
        )
    }
}

private struct RehookCard: View {
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    let index: Int
    let suggestion: RehookSuggestion
    let isCopied: Bool
    let onInsert: () -> Void
    let onCopy: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text(HookFormat.seconds(suggestion.estimatedSeconds, language: appState.currentLanguage))
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                Text(HookFormat.words(suggestion.wordCount, language: appState.currentLanguage))
                    .font(.system(size: 11))
                    .foregroundStyle(theme.secondaryText)
                if suggestion.exceedsLimit {
                    Label(appState.localized("hooks.overLimit"), systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.orange)
                }
                Spacer()
                Text("#\(index + 1)")
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(theme.tertiaryText)
            }

            Text(suggestion.text)
                .font(.system(size: 14))
                .foregroundStyle(theme.primaryText)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)

            VStack(alignment: .leading, spacing: 3) {
                Text(appState.localized("hooks.insertBefore"))
                    .font(.system(size: 9, weight: .semibold))
                    .textCase(.uppercase)
                    .foregroundStyle(theme.tertiaryText)
                Text("«\(suggestion.anchor)»")
                    .font(.system(size: 11))
                    .italic()
                    .foregroundStyle(theme.secondaryText)
                    .lineLimit(2)
            }

            HStack(spacing: 12) {
                Button(appState.localized("hooks.insertRehook")) {
                    onInsert()
                }
                .buttonStyle(.borderedProminent)
                .tint(theme.accent.color)
                .disabled(!suggestion.isWithinLimit)

                Button(isCopied ? appState.localized("hooks.copied") : appState.localized("hooks.copy")) {
                    onCopy()
                }
                .buttonStyle(.cursorPlain)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(theme.secondaryText)

                Spacer()
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(theme.surface)
                .overlay(
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(suggestion.exceedsLimit ? Color.orange.opacity(0.45) : theme.divider, lineWidth: 1)
                )
        )
    }
}

// MARK: - Formatting and localization

enum HookFormat {
    static func seconds(_ value: TimeInterval, language: AppLanguage) -> String {
        String(
            format: L10n.tr("hooks.secondsFormat", language: language),
            locale: Locale.current,
            value
        )
    }

    static func words(_ count: Int, language: AppLanguage) -> String {
        String(format: L10n.tr("hooks.words", language: language), count)
    }
}

enum HookLocalization {
    static func angle(_ raw: String, language: AppLanguage) -> String? {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            return L10n.tr("hooks.angle.general", language: language)
        }

        let key: String?
        switch value.lowercased() {
        case "pregunta", "question", "вопрос":
            key = "hooks.angle.question"
        case "contraste", "contrast", "контраст":
            key = "hooks.angle.contrast"
        case "dato", "dato concreto", "data", "данные":
            key = "hooks.angle.data"
        case "promesa", "promise", "обещание":
            key = "hooks.angle.promise"
        case "polémica", "polemica", "controversy", "спор":
            key = "hooks.angle.controversy"
        case "conflicto", "conflict", "конфликт":
            key = "hooks.angle.conflict"
        case "historia", "story", "история":
            key = "hooks.angle.story"
        default:
            key = nil
        }
        if let key {
            return L10n.tr(key, language: language)
        }
        return value.prefix(1).uppercased() + value.dropFirst()
    }

    static func errorKey(for error: Error) -> String {
        if let error = error as? HookServiceError {
            switch error {
            case .providerDisabled: return "hooks.error.disabled"
            case .truncated: return "hooks.error.truncated"
            case .noSuggestions: return "hooks.error.empty"
            }
        }
        if error is HookParsingError {
            return "hooks.error.malformed"
        }
        if error is HookGenerationError {
            return "hooks.error.noScene"
        }
        if error is CancellationError {
            return "hooks.cancelled"
        }
        if let error = error as? LLMProviderError {
            switch error {
            case .missingAPIKey:
                return "hooks.error.missingKey"
            case .invalidBaseURL:
                return "hooks.error.configuration"
            case .network:
                return "hooks.error.network"
            case .malformedResponse:
                return "hooks.error.malformed"
            case .httpStatus(let status, _):
                switch status {
                case 401, 403: return "hooks.error.auth"
                case 402: return "hooks.error.credit"
                case 429: return "hooks.error.rateLimit"
                case 400, 404, 422: return "hooks.error.configuration"
                case 500...599: return "hooks.error.server"
                default: return "hooks.error.generic"
                }
            }
        }
        return "hooks.error.generic"
    }
}

// MARK: - Presentation

private struct HookGeneratorSheetModifier: ViewModifier {
    @Bindable var presenter: HookSheetPresenter
    @Environment(AppState.self) private var appState
    @Environment(\.frameTheme) private var theme

    func body(content: Content) -> some View {
        content.sheet(item: $presenter.request) { request in
            HookGeneratorSheet(mode: request.mode)
                .environment(appState)
                .environment(\.frameTheme, theme)
        }
    }
}

extension View {
    func hookGeneratorSheets(presenter: HookSheetPresenter) -> some View {
        modifier(HookGeneratorSheetModifier(presenter: presenter))
    }
}
