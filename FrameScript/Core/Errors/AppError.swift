import Foundation
import FrameScriptCore
import Observation
import Security

enum AppErrorKind: String, Equatable, Sendable {
    case projectMissing
    case projectRead
    case projectWrite
    case corruptedProject
    case unsupportedProjectVersion
    case invalidProjectData
    case autosave
    case bookmark
    case recentStorage
    case settingsRead
    case settingsWrite
    case export
    case keychainRead
    case keychainWrite
    case keychainDelete
    case aiConfiguration
    case aiAuthentication
    case aiModelUnavailable
    case aiRateLimit
    case aiNetwork
    case aiProvider
    case aiMalformedResponse
    case unexpected
}

struct AppErrorContext: Equatable, Sendable {
    var fileName: String?
    var statusCode: Int?
    var reason: String?
    var diagnosticCode: String?
    /// Localized suffix for CLI/subscription errors. `reason` remains the
    /// English diagnostic used in logs.
    var reasonKey: String?
    var reasonArguments: [String]?

    init(
        fileName: String? = nil,
        statusCode: Int? = nil,
        reason: String? = nil,
        diagnosticCode: String? = nil,
        reasonKey: String? = nil,
        reasonArguments: [String]? = nil
    ) {
        self.fileName = fileName
        self.statusCode = statusCode
        self.reason = reason.map { String($0.prefix(256)) }
        self.diagnosticCode = diagnosticCode
        self.reasonKey = reasonKey
        self.reasonArguments = reasonArguments
    }
}

enum AppRecoveryAction: Equatable, Sendable {
    case retry
    case saveAs
    case chooseExportFolder
    case openAISettings
    case removeRecent(UUID)
}

struct AppErrorPresentation: Equatable, Sendable {
    let title: String
    let message: String
    let recoverySuggestion: String?
}

struct AppError: Identifiable, LocalizedError, Equatable, Sendable {
    let id: UUID
    let kind: AppErrorKind
    let context: AppErrorContext
    let recoveryAction: AppRecoveryAction?

    init(
        id: UUID = UUID(),
        kind: AppErrorKind,
        context: AppErrorContext = AppErrorContext(),
        recoveryAction: AppRecoveryAction? = nil
    ) {
        self.id = id
        self.kind = kind
        self.context = context
        self.recoveryAction = recoveryAction
    }

    var errorDescription: String? {
        presentation(language: .english).message
    }

    func presentation(language: AppLanguage) -> AppErrorPresentation {
        let title = L10n.tr("error.\(kind.rawValue).title", language: language)
        var message = L10n.tr("error.\(kind.rawValue).message", language: language)
        if let fileName = context.fileName, !fileName.isEmpty {
            message += " \(String(format: L10n.tr("error.fileName", language: language), fileName))"
        }
        if let key = context.reasonKey {
            let format = L10n.tr(key, language: language)
            let arguments = context.reasonArguments ?? []
            if arguments.isEmpty {
                message += " \(format)"
            } else {
                message += " " + String(format: format, arguments: arguments.map { $0 as CVarArg })
            }
        } else if let reason = context.reason, !reason.isEmpty,
                  kind == .aiProvider || kind == .aiConfiguration {
            message += " \(reason)"
        }
        let suggestion = recoveryAction.map {
            L10n.tr("recovery.\($0.localizationKey).suggestion", language: language)
        }
        return AppErrorPresentation(title: title, message: message, recoverySuggestion: suggestion)
    }

    var fingerprint: Fingerprint {
        Fingerprint(kind: kind, context: context, recoveryAction: recoveryAction)
    }

    struct Fingerprint: Equatable, Sendable {
        let kind: AppErrorKind
        let context: AppErrorContext
        let recoveryAction: AppRecoveryAction?
    }
}

extension AppRecoveryAction {
    var localizationKey: String {
        switch self {
        case .retry: "retry"
        case .saveAs: "saveAs"
        case .chooseExportFolder: "chooseExportFolder"
        case .openAISettings: "openAISettings"
        case .removeRecent: "removeRecent"
        }
    }
}

enum AppNoticeKind: String, Equatable, Sendable {
    case recentMissingRemoved
    case recentRemoved
    case recentsCleared
    case recentPersistenceWarning
    case recentStorageWarning
    case recentBookmarkWarning
    case exportFolderPermissionLost
    case apiKeySaved
    case apiKeyDeleted
}

struct AppNotice: Identifiable, Equatable, Sendable {
    let id: UUID
    let kind: AppNoticeKind
    let count: Int?

    init(id: UUID = UUID(), kind: AppNoticeKind, count: Int? = nil) {
        self.id = id
        self.kind = kind
        self.count = count
    }

    func message(language: AppLanguage) -> String {
        let key = count == nil ? "notice.\(kind.rawValue)" : "notice.\(kind.rawValue).multiple"
        let format = L10n.tr(key, language: language)
        return count.map { String(format: format, $0) } ?? format
    }
}

@MainActor
@Observable
final class ErrorCenter {
    private(set) var presentedError: AppError?
    private(set) var notice: AppNotice?

    private var queuedErrors: [AppError] = []
    private var noticeDismissTask: Task<Void, Never>?
    private var suppressedAutosaveFailure: AppError.Fingerprint?

    func present(_ error: AppError) {
        guard presentedError?.fingerprint != error.fingerprint,
              !queuedErrors.contains(where: { $0.fingerprint == error.fingerprint }) else { return }
        if presentedError == nil {
            presentedError = error
        } else {
            queuedErrors.append(error)
        }
    }

    func present(_ error: AppError?) {
        guard let error else { return }
        present(error)
    }

    func presentAutosave(_ error: AppError?) {
        guard let error, error.kind == .autosave,
              error.fingerprint != suppressedAutosaveFailure else { return }
        present(error)
    }

    func dismissCurrent() {
        if presentedError?.kind == .autosave {
            suppressedAutosaveFailure = presentedError?.fingerprint
        }
        presentedError = queuedErrors.isEmpty ? nil : queuedErrors.removeFirst()
    }

    func clearAutosaveFailureSuppression() {
        suppressedAutosaveFailure = nil
    }

    func showNotice(_ notice: AppNotice) {
        noticeDismissTask?.cancel()
        self.notice = notice
        noticeDismissTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .seconds(3))
            } catch is CancellationError {
                return
            } catch {
                return // Notice timing is best-effort and never blocks user work.
            }
            guard !Task.isCancelled, self?.notice?.id == notice.id else { return }
            self?.notice = nil
        }
    }

    func clearNotice() {
        noticeDismissTask?.cancel()
        noticeDismissTask = nil
        notice = nil
    }
}

enum KeychainOperation {
    case read, write, delete
}

extension AppError {
    static func project(_ error: Error, fileURL: URL?, operation: ProjectOperation) -> AppError? {
        if error is CancellationError { return nil }
        let fileName = fileURL?.lastPathComponent
        let context = AppErrorContext(fileName: fileName, diagnosticCode: diagnosticCode(for: error))

        if let fileError = error as? FrameScriptFileError {
            switch fileError {
            case .unsupportedVersion:
                return AppError(kind: .unsupportedProjectVersion, context: context)
            case .duplicateSceneID, .invalidAnchor:
                return AppError(kind: .invalidProjectData, context: context)
            }
        }
        if error is DecodingError {
            return AppError(kind: .corruptedProject, context: context)
        }
        let nsError = error as NSError
        if nsError.domain == NSCocoaErrorDomain,
           [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(nsError.code) {
            switch operation {
            case .read:
                return AppError(kind: .projectMissing, context: context)
            case .write:
                return AppError(kind: .projectWrite, context: context, recoveryAction: .saveAs)
            case .autosave:
                return AppError(kind: .autosave, context: context, recoveryAction: .saveAs)
            }
        }
        switch operation {
        case .read:
            return AppError(kind: .projectRead, context: context)
        case .write:
            return AppError(kind: .projectWrite, context: context, recoveryAction: .saveAs)
        case .autosave:
            return AppError(kind: .autosave, context: context, recoveryAction: .saveAs)
        }
    }

    static func recent(_ error: Error, recentID: UUID? = nil) -> AppError {
        guard let error = error as? RecentProjectStoreError else {
            return AppError(kind: .recentStorage, context: AppErrorContext(diagnosticCode: diagnosticCode(for: error)))
        }
        switch error {
        case .missingFile(let url):
            return AppError(
                kind: .projectMissing,
                context: AppErrorContext(fileName: url.lastPathComponent),
                recoveryAction: recentID.map(AppRecoveryAction.removeRecent)
            )
        case .unreadableFile(let url):
            return AppError(kind: .projectRead, context: AppErrorContext(fileName: url.lastPathComponent))
        case .invalidBookmark:
            return AppError(kind: .bookmark)
        case .corruptedStorage, .persistenceFailed:
            return AppError(kind: .recentStorage)
        }
    }

    static func keychain(_ error: Error, operation: KeychainOperation) -> AppError? {
        if error is CancellationError { return nil }
        let kind: AppErrorKind = switch operation {
        case .read: .keychainRead
        case .write: .keychainWrite
        case .delete: .keychainDelete
        }
        return AppError(kind: kind, context: AppErrorContext(diagnosticCode: diagnosticCode(for: error)))
    }

    private static func appError(
        kind: AppErrorKind,
        for error: Error,
        recoveryAction: AppRecoveryAction?
    ) -> AppError {
        let mapping = SubscriptionAIErrorDescription.mapping(for: error)
        return AppError(
            kind: kind,
            context: AppErrorContext(
                reason: error.localizedDescription,
                reasonKey: mapping?.key,
                reasonArguments: mapping?.arguments
            ),
            recoveryAction: recoveryAction
        )
    }

    static func ai(_ error: Error) -> AppError? {
        if error is CancellationError { return nil }
        if let error = error as? SubscriptionAIError {
            switch error {
            case .autocompleteNotSupported:
                return nil
            case .pendingQuestion:
                // The sheet already explains the question and offers T3.
                return nil
            case .busy, .emptyReply:
                return appError(kind: .aiProvider, for: error, recoveryAction: nil)
            case .notConfigured:
                return appError(kind: .aiConfiguration, for: error, recoveryAction: .openAISettings)
            }
        }
        if let error = error as? AgentCLIError {
            switch error {
            case .cancelled:
                return nil
            case .invalidConfiguration, .binaryNotFound, .projectNotFound, .noProviderAvailable:
                return appError(kind: .aiConfiguration, for: error, recoveryAction: .openAISettings)
            case .timedOut, .launchFailed, .runFailed, .malformedOutput, .outputTruncated,
                 .projectAlreadyExists, .projectNameLookupUnsupported, .serverUnavailable:
                return appError(kind: .aiProvider, for: error, recoveryAction: nil)
            }
        }
        if let error = error as? LLMProviderError {
            switch error {
            case .missingAPIKey, .invalidBaseURL:
                return AppError(kind: .aiConfiguration, recoveryAction: .openAISettings)
            case .httpStatus(let status, let message) where status == 401 || status == 403:
                return AppError(kind: .aiAuthentication, context: AppErrorContext(statusCode: status, reason: message), recoveryAction: .openAISettings)
            case .httpStatus(let status, let message) where status == 429:
                return AppError(kind: .aiRateLimit, context: AppErrorContext(statusCode: status, reason: message))
            case .httpStatus(let status, let message) where status == 404:
                return AppError(kind: .aiModelUnavailable, context: AppErrorContext(statusCode: status, reason: message), recoveryAction: .openAISettings)
            case .httpStatus(let status, let message):
                return AppError(kind: .aiProvider, context: AppErrorContext(statusCode: status, reason: message))
            case .network(let code) where code == String(URLError.Code.cancelled.rawValue):
                return nil
            case .network(let code):
                return AppError(kind: .aiNetwork, context: AppErrorContext(diagnosticCode: code))
            case .malformedResponse(let reason):
                return AppError(kind: .aiMalformedResponse, context: AppErrorContext(diagnosticCode: reason))
            }
        }
        if let urlError = error as? URLError {
            if urlError.code == .cancelled { return nil }
            return AppError(kind: .aiNetwork, context: AppErrorContext(diagnosticCode: String(urlError.code.rawValue)))
        }
        if error is DecodingError {
            return AppError(kind: .aiMalformedResponse)
        }
        if error is GenerationError {
            return AppError(kind: .aiMalformedResponse, context: AppErrorContext(reason: error.localizedDescription))
        }
        if error is KeychainError {
            return AppError(kind: .keychainRead, context: AppErrorContext(diagnosticCode: diagnosticCode(for: error)))
        }
        return AppError(kind: .aiProvider, context: AppErrorContext(diagnosticCode: diagnosticCode(for: error)))
    }

    private static func diagnosticCode(for error: Error) -> String? {
        if case KeychainError.unhandledStatus(let status) = error { return String(status) }
        let value = error as NSError
        return "\(value.domain):\(value.code)"
    }
}

enum ProjectOperation {
    case read, write, autosave
}
