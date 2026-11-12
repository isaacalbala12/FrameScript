import Foundation
import NaturalLanguage
import OSLog

@MainActor
protocol LLMProviderProtocol {
    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse
}

@MainActor
protocol RewriteServicing {
    func rewrite(text: String, scene: Scene, settings: AIPreferences, interfaceLanguage: AppLanguage, apiKey: String) async throws -> String
}

@MainActor
protocol AnalysisServicing {
    func analyze(scene: Scene, project: FrameProject, settings: AIPreferences, interfaceLanguage: AppLanguage, apiKey: String) async throws -> [AIComment]
}

struct LLMRequest: Codable, Hashable {
    var task: AITask
    var provider: AIProviderKind
    var baseURL: String
    var systemPrompt: String
    var userPrompt: String
    var model: String
    var temperature: Double
    var maxTokens: Int
}

struct LLMResponse: Codable, Hashable {
    var text: String
    var finishReason: String? = nil

    var stoppedAtTokenLimit: Bool {
        guard let finishReason = finishReason?.lowercased() else { return false }
        return finishReason == "length" || finishReason.contains("token") || finishReason.contains("max_tokens")
    }
}

struct AutocompleteContext: Hashable {
    let prefix: String
    let suffix: String
    let sceneTitle: String
    let language: AppLanguage

    var prompt: String {
        [
            "Scene title: \(sceneTitle)",
            "Text before the caret:\n\(prefix)",
            "Text after the caret:\n\(suffix)"
        ].joined(separator: "\n\n")
    }
}

enum AutocompleteUnavailableReason: Equatable {
    case rateLimited
    case offline
    case timeout
    case dns
    case tls
    case badRequest
    case server
    case provider

    var localizationKey: String {
        switch self {
        case .rateLimited: "autocomplete.unavailable.rateLimited"
        case .offline: "autocomplete.unavailable.offline"
        case .timeout: "autocomplete.unavailable.timeout"
        case .dns: "autocomplete.unavailable.dns"
        case .tls: "autocomplete.unavailable.tls"
        case .badRequest: "autocomplete.unavailable.badRequest"
        case .server: "autocomplete.unavailable.server"
        case .provider: "autocomplete.unavailable.provider"
        }
    }

    static func from(_ error: Error) -> Self {
        if let error = error as? LLMProviderError {
            switch error {
            case .httpStatus(429, _): return .rateLimited
            case .httpStatus(400, _): return .badRequest
            case .httpStatus(let status, _) where status >= 500: return .server
            case .network(let code):
                switch URLError.Code(rawValue: Int(code) ?? -1) {
                case .notConnectedToInternet: return .offline
                case .timedOut: return .timeout
                case .cannotFindHost, .dnsLookupFailed: return .dns
                case .secureConnectionFailed, .serverCertificateHasBadDate, .serverCertificateUntrusted,
                     .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .clientCertificateRejected,
                     .clientCertificateRequired: return .tls
                default: return .provider
                }
            default: return .provider
            }
        }
        return .provider
    }
}

enum AutocompleteResult: Equatable {
    case none
    case suggestion(String)
    case temporarilyUnavailable(AutocompleteUnavailableReason)
}

struct AutocompleteProviderIssue: Equatable {
    let provider: AIProviderKind
    let reason: AutocompleteUnavailableReason
    let cooldownDeadline: Date?
}

enum AutocompleteCompletion {
    enum SanitizationResult: Equatable {
        case completion(String)
        case noCompleteSentence
        case rejected
    }

    static func sanitize(_ response: LLMResponse, context: AutocompleteContext) -> String? {
        if case let .completion(completion) = sanitizeResult(response, context: context) {
            return completion
        }
        return nil
    }

    static func sanitizeResult(_ response: LLMResponse, context: AutocompleteContext) -> SanitizationResult {
        let rawCandidate = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let candidate = firstCompleteSentence(in: rawCandidate) else { return .noCompleteSentence }
        guard !candidate.isEmpty, candidate.count <= 600,
              !candidate.contains("```"), !candidate.contains("#"),
              !candidate.hasPrefix("\"") && !candidate.hasPrefix("“") && !candidate.hasPrefix("'") else { return .rejected }

        let lowercased = candidate.lowercased()
        let conversationalPrefixes = ["assistant:", "narrator:", "user:", "answer:", "sure", "here is", "here's", "as an ai", "hello", "hi "]
        guard !conversationalPrefixes.contains(where: { lowercased.hasPrefix($0) }) else { return .rejected }

        let normalizedPrefix = context.prefix.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalizedPrefix.isEmpty || !normalizedPrefix.hasSuffix(lowercased) else { return .rejected }

        let suffix = context.suffix
        let maximumOverlap = min(candidate.count, suffix.count)

        let overlap = stride(from: maximumOverlap, through: 1, by: -1).first { length in
            candidate.suffix(length).caseInsensitiveCompare(suffix.prefix(length)) == .orderedSame
        } ?? 0
        let completion = overlap == 0
            ? candidate
            : String(candidate.dropLast(overlap))
        guard !completion.isEmpty,
              firstCompleteSentence(in: completion) == completion else { return .rejected }
        if context.prefix.last?.isWhitespace == true || completion.first?.isWhitespace == true { return .completion(completion) }
        return .completion(" " + completion)
    }

    private static func firstCompleteSentence(in text: String) -> String? {
        guard !text.isEmpty else { return nil }
        let endings: Set<Character> = [".", "!", "?", "…"]
        let closingCharacters: Set<Character> = ["\"", "'", "”", "’", "»", ")", "]", "}"]

        for index in text.indices where endings.contains(text[index]) {
            var sentenceEnd = index
            var next = text.index(after: index)
            while next != text.endIndex, closingCharacters.contains(text[next]) {
                sentenceEnd = next
                next = text.index(after: next)
            }
            guard next == text.endIndex || text[next].isWhitespace else { continue }
            return String(text[...sentenceEnd])
        }
        return nil
    }
}

enum AITask: String, Codable, Hashable {
    case autocomplete
    case rewrite
    case analyze
    case bRollGeneration
    case editingGeneration
}

@MainActor
struct MockLLMProvider: LLMProviderProtocol {
    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        let russian = request.systemPrompt.contains("Russian")
        switch request.task {
        case .autocomplete:
            return LLMResponse(text: russian ? " с более ясным следующим акцентом." : " with a clearer next beat.")
        case .rewrite:
            return LLMResponse(text: russian ? "Вот более ясная и компактная версия выбранного фрагмента." : "Here is a cleaner, tighter version of the selected passage.")
        case .analyze:
            return LLMResponse(text: russian
                ? #"{"title":"Хук","severity":"suggestion","message":"Хук понятен, но ему нужен более конкретный пример.","suggestion":"Добавьте пример перед объяснением."}"#
                : #"{"title":"Hook","severity":"suggestion","message":"The hook is clear, but it needs a more concrete example.","suggestion":"Add the example before the explanation."}"#)
        case .bRollGeneration:
            return LLMResponse(text: russian
                ? #"{"source":"Custom","description":"Добавьте спокойную запись экрана с крупным планом.","notes":"Используйте одну простую подпись."}"#
                : #"{"source":"Custom","description":"Use a calm screen recording with a close-up insert.","notes":"Use one simple label."}"#)
        case .editingGeneration:
            return LLMResponse(text: russian
                ? #"{"description":"Сохраните прямые склейки и легкие приближения.","notes":"Оставьте в субтитрах только ключевые слова."}"#
                : #"{"description":"Keep hard cuts and subtle punch-ins.","notes":"Use keyword-only captions."}"#)
        }
    }
}

@MainActor
struct OpenAICompatibleLLMProvider: LLMProviderProtocol {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "AI")
    static let tokenLimitResponseDetail = "The provider reached its token limit before returning a complete analysis."
    typealias Transport = (URLRequest) async throws -> (Data, URLResponse)
    private let transport: Transport

    init(
        transport: @escaping Transport = { try await URLSession.shared.data(for: $0) }
    ) {
        self.transport = transport
    }

    func complete(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        switch request.provider {
        case .disabled:
            return LLMResponse(text: "")
        case .openAICompatible, .openRouter, .groq, .googleAIStudio:
            return try await completeChat(request: request, apiKey: apiKey)
        }
    }

    private func completeChat(request: LLMRequest, apiKey: String) async throws -> LLMResponse {
        // The session owner supplies the in-memory key. User projects and
        // exports contain script data, not provider secrets.
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey
        }

        let base = request.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.defaultBaseURL(for: request.provider)
            : request.baseURL
        let url = try Self.endpointURL(baseURL: base)

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.httpBody = try JSONEncoder().encode(ChatCompletionRequest(
            model: request.model,
            messages: [
                ChatMessage(role: "system", content: request.systemPrompt),
                ChatMessage(role: "user", content: request.userPrompt)
            ],
            temperature: request.temperature,
            maxTokens: request.maxTokens,
            responseFormat: request.task == .analyze
                ? AnalysisStructuredOutputCapability.resolve(
                    provider: request.provider,
                    model: request.model,
                    baseURL: request.baseURL
                ).responseFormat
                : nil
        ))

        let (data, response) = try await send(urlRequest)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedResponse("Missing HTTP response.")
        }
        let topLevel = Self.topLevelJSONObject(from: data)
        guard 200..<300 ~= http.statusCode else {
            if http.statusCode == 429 {
                AutocompleteRetryAfterCache.record(http.value(forHTTPHeaderField: "Retry-After"), for: request.provider)
            }
            Self.logResponse(http: http, data: data, topLevel: topLevel, finishReason: nil, request: request)
            throw LLMProviderError.httpStatus(http.statusCode, Self.providerErrorDetail(from: topLevel))
        }
        guard topLevel != nil else {
            Self.logResponse(http: http, data: data, topLevel: nil, finishReason: nil, request: request)
            throw LLMProviderError.malformedResponse("The provider returned invalid JSON.")
        }
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            Self.logResponse(http: http, data: data, topLevel: topLevel, finishReason: nil, request: request)
            throw LLMProviderError.malformedResponse("The provider returned invalid chat response fields.")
        }
        let choice = decoded.choices.first
        let finishReason = choice?.finishReason
        Self.logResponse(http: http, data: data, topLevel: topLevel, finishReason: finishReason, request: request)
        guard let choice else {
            throw LLMProviderError.malformedResponse("The provider returned no completion choices.")
        }
        if request.task == .analyze, Self.isTokenLimitFinishReason(finishReason) {
            throw LLMProviderError.malformedResponse(Self.tokenLimitResponseDetail)
        }
        let text = choice.message.content?.text.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !text.isEmpty else {
            if request.task == .autocomplete, Self.isTokenLimitFinishReason(finishReason) {
                // AppState owns the single bounded autocomplete retry. Preserve this
                // response so it can distinguish a truncation from a provider error.
                return LLMResponse(text: "", finishReason: finishReason)
            }
            if Self.isTokenLimitFinishReason(finishReason) {
                throw LLMProviderError.malformedResponse("The provider reached its token limit before returning text.")
            }
            throw LLMProviderError.malformedResponse("The provider returned an empty completion.")
        }
        return LLMResponse(text: text, finishReason: finishReason)
    }

    func testConnection(request: LLMRequest, apiKey: String) async throws {
        guard !apiKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw LLMProviderError.missingAPIKey
        }
        if request.provider == .googleAIStudio {
            try await validateGoogleModel(apiKey: apiKey, model: request.model)
            return
        }
        var completionRequest = request
        // A connection check establishes basic reachability only. It must not
        // imply that the selected model supports structured analysis output.
        completionRequest.task = .autocomplete
        completionRequest.systemPrompt = "Reply briefly to confirm availability."
        completionRequest.userPrompt = "Connection check"
        completionRequest.maxTokens = max(128, request.maxTokens)
        _ = try await completeChat(request: completionRequest, apiKey: apiKey)
    }

    private func validateGoogleModel(apiKey: String, model: String) async throws {
        let url = try Self.googleModelURL(model: model)
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await send(request)
        guard let http = response as? HTTPURLResponse else {
            throw LLMProviderError.malformedResponse("Missing HTTP response.")
        }
        let topLevel = Self.topLevelJSONObject(from: data)
        Self.logResponse(http: http, data: data, topLevel: topLevel, finishReason: nil, provider: .googleAIStudio, model: model)
        guard 200..<300 ~= http.statusCode else {
            throw LLMProviderError.httpStatus(http.statusCode, Self.providerErrorDetail(from: topLevel))
        }
        guard let object = topLevel as? [String: Any],
              ((object["id"] as? String)?.isEmpty == false || (object["name"] as? String)?.isEmpty == false) else {
            throw LLMProviderError.malformedResponse("The model endpoint returned a malformed response.")
        }
    }

    private func send(_ request: URLRequest) async throws -> (Data, URLResponse) {
        do {
            return try await transport(request)
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as URLError {
            if error.code == .cancelled {
                throw CancellationError()
            }
            Self.logger.error("AI transport failed. Code: \(error.code.rawValue, privacy: .private)")
            throw LLMProviderError.network(String(error.code.rawValue))
        } catch {
            let value = error as NSError
            Self.logger.error("AI transport failed. Code: \(value.code, privacy: .private)")
            throw LLMProviderError.network(String(value.code))
        }
    }

    static func endpointURL(baseURL: String) throws -> URL {
        guard let url = URL(string: baseURL.trimmingCharacters(in: CharacterSet(charactersIn: "/")) + "/chat/completions") else {
            throw LLMProviderError.invalidBaseURL
        }
        return url
    }

    static func googleModelURL(model: String) throws -> URL {
        let trimmedModel = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedModel.isEmpty,
              let encodedModel = trimmedModel.addingPercentEncoding(
                withAllowedCharacters: CharacterSet.urlPathAllowed.subtracting(CharacterSet(charactersIn: "/"))
              ),
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/openai/models/\(encodedModel)") else {
            throw LLMProviderError.invalidBaseURL
        }
        return url
    }

    private static func topLevelJSONObject(from data: Data) -> Any? {
        try? JSONSerialization.jsonObject(with: data)
    }

    private static func providerErrorDetail(from topLevel: Any?) -> String? {
        guard let root = topLevel as? [String: Any],
              let error = root["error"] as? [String: Any] else { return nil }
        let status = error["status"].map { String(describing: $0) }
        let code = error["code"].map { String(describing: $0) }
        // Provider messages can echo request content. Keep only non-content diagnostics.
        let fields = [status, code].compactMap { $0 }
        return fields.isEmpty ? nil : fields.joined(separator: " · ")
    }

    private static func isTokenLimitFinishReason(_ reason: String?) -> Bool {
        guard let reason = reason?.lowercased() else { return false }
        return reason == "length" || reason.contains("token") || reason.contains("max_tokens")
    }

    private static func logResponse(http: HTTPURLResponse, data: Data, topLevel: Any?, finishReason: String?, request: LLMRequest) {
        logResponse(http: http, data: data, topLevel: topLevel, finishReason: finishReason, provider: request.provider, model: request.model)
    }

    private static func logResponse(
        http: HTTPURLResponse,
        data: Data,
        topLevel: Any?,
        finishReason: String?,
        provider: AIProviderKind,
        model: String
    ) {
        let keys = ((topLevel as? [String: Any])?.keys.sorted().joined(separator: ",")) ?? "none"
        let mime = http.mimeType ?? "unknown"
        let finish = finishReason ?? "none"
        logger.info("AI response status=\(http.statusCode, privacy: .public) mime=\(mime, privacy: .public) bytes=\(data.count, privacy: .public) keys=\(keys, privacy: .public) finish=\(finish, privacy: .public) provider=\(provider.rawValue, privacy: .public) model=\(model, privacy: .public)")
    }

    nonisolated static func defaultBaseURL(for provider: AIProviderKind) -> String {
        switch provider {
        case .openRouter:
            "https://openrouter.ai/api/v1"
        case .groq:
            "https://api.groq.com/openai/v1"
        case .googleAIStudio:
            "https://generativelanguage.googleapis.com/v1beta/openai"
        default:
            "https://api.openai.com/v1"
        }
    }
}

@MainActor
enum AutocompleteRetryAfterCache {
    private static var values: [AIProviderKind: TimeInterval] = [:]

    static func record(_ header: String?, for provider: AIProviderKind, now: Date = .now) {
        guard let seconds = retryAfterSeconds(header, now: now) else { return }
        values[provider] = seconds
    }

    static func take(for provider: AIProviderKind) -> TimeInterval? {
        defer { values.removeValue(forKey: provider) }
        return values[provider]
    }

    private static func retryAfterSeconds(_ header: String?, now: Date) -> TimeInterval? {
        guard let header = header?.trimmingCharacters(in: .whitespacesAndNewlines), !header.isEmpty else { return nil }
        if let seconds = TimeInterval(header), seconds >= 0 { return seconds }
        guard let date = HTTPDateFormatter.date(from: header) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }
}

private enum HTTPDateFormatter {
    static func date(from value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss z"
        return formatter.date(from: value)
    }
}

struct AIProviderConfiguration: Equatable {
    var model: String
    var baseURL: String
}

@MainActor
final class ProviderCredentialSession {
    typealias Reader = (String) throws -> String?

    private let reader: Reader
    private var cachedKeys: [AIProviderKind: String] = [:]

    init(reader: @escaping Reader = { try KeychainStore.readAPIKey(account: $0) }) {
        self.reader = reader
    }

    func apiKey(for provider: AIProviderKind) throws -> String {
        guard provider != .disabled else { throw LLMProviderError.missingAPIKey }
        if let cached = cachedKeys[provider] { return cached }
        guard let key = try reader(provider.keychainAccount)?.trimmingCharacters(in: .whitespacesAndNewlines),
              !key.isEmpty else { throw LLMProviderError.missingAPIKey }
        cachedKeys[provider] = key
        return key
    }

    func invalidate(for provider: AIProviderKind) {
        cachedKeys.removeValue(forKey: provider)
    }
}

struct AIProviderConfigurationStore {
    private let userDefaults: UserDefaults

    init(userDefaults: UserDefaults = .standard) {
        self.userDefaults = userDefaults
    }

    func save(_ configuration: AIProviderConfiguration, for provider: AIProviderKind) {
        guard provider != .disabled else { return }
        userDefaults.set(
            ["model": configuration.model, "baseURL": configuration.baseURL],
            forKey: key(for: provider)
        )
    }

    func load(for provider: AIProviderKind) -> AIProviderConfiguration {
        guard provider != .disabled else { return AIProviderConfiguration(model: "", baseURL: "") }
        let stored = userDefaults.dictionary(forKey: key(for: provider)) as? [String: String]
        return AIProviderConfiguration(
            model: stored?["model"] ?? Self.defaultModel(for: provider),
            baseURL: stored?["baseURL"] ?? OpenAICompatibleLLMProvider.defaultBaseURL(for: provider)
        )
    }

    func hasStoredKey(for provider: AIProviderKind) -> Bool {
        provider != .disabled && userDefaults.bool(forKey: keyMetadataKey(for: provider))
    }

    func setHasStoredKey(_ value: Bool, for provider: AIProviderKind) {
        guard provider != .disabled else { return }
        userDefaults.set(value, forKey: keyMetadataKey(for: provider))
    }

    static func defaultModel(for provider: AIProviderKind) -> String {
        switch provider {
        case .groq: "llama-3.3-70b-versatile"
        case .openRouter: "openai/gpt-4.1-mini"
        case .openAICompatible: "gpt-4.1-mini"
        case .googleAIStudio: "gemini-3.5-flash"
        case .disabled: ""
        }
    }

    private func key(for provider: AIProviderKind) -> String {
        "FrameScript.ai.provider.\(provider.rawValue)"
    }

    private func keyMetadataKey(for provider: AIProviderKind) -> String {
        "FrameScript.ai.hasStoredKey.\(provider.rawValue)"
    }
}

@MainActor
enum AIConnectionTester {
    static func saveKeyAndTest(
        pendingAPIKey: String,
        saveKey: (String) throws -> Void,
        acquireKey: () throws -> String,
        request: LLMRequest,
        test: (LLMRequest, String) async throws -> Void
    ) async throws {
        let key = pendingAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if !key.isEmpty { try saveKey(key) }
        try await test(request, key.isEmpty ? acquireKey() : key)
    }
}

enum LLMProviderError: Error, Equatable {
    case missingAPIKey
    case invalidBaseURL
    case httpStatus(Int, String?)
    case network(String)
    case malformedResponse(String?)
}

private struct ChatCompletionRequest: Codable {
    var model: String
    var messages: [ChatMessage]
    var temperature: Double
    var maxTokens: Int
    var responseFormat: ChatResponseFormat?

    enum CodingKeys: String, CodingKey {
        case model
        case messages
        case temperature
        case maxTokens = "max_tokens"
        case responseFormat = "response_format"
    }
}

private enum AnalysisStructuredOutputCapability: Equatable {
    case strictJSONSchema
    case jsonObject
    case promptOnly

    static func resolve(provider: AIProviderKind, model: String, baseURL: String) -> Self {
        guard usesDefaultEndpoint(provider: provider, baseURL: baseURL) else { return .promptOnly }

        let normalizedModel = model.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch provider {
        case .groq where normalizedModel == "llama-3.3-70b-versatile":
            return .jsonObject
        case .openAICompatible where ["gpt-4.1", "gpt-4.1-mini", "gpt-4.1-nano", "gpt-4o", "gpt-4o-mini"].contains(normalizedModel):
            return .strictJSONSchema
        case .openRouter where normalizedModel == "openai/gpt-4.1-mini":
            return .strictJSONSchema
        case .googleAIStudio where normalizedModel == "gemini-3.5-flash":
            return .strictJSONSchema
        default:
            return .promptOnly
        }
    }

    var responseFormat: ChatResponseFormat? {
        switch self {
        case .strictJSONSchema: return .analysisSchema
        case .jsonObject: return .jsonObject
        case .promptOnly: return nil
        }
    }

    private static func usesDefaultEndpoint(provider: AIProviderKind, baseURL: String) -> Bool {
        let normalized = baseURL.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/"))).lowercased()
        let expected = OpenAICompatibleLLMProvider.defaultBaseURL(for: provider)
            .trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
            .lowercased()
        return normalized.isEmpty || normalized == expected
    }
}

private struct ChatResponseFormat: Codable {
    let type: String
    let jsonSchema: JSONSchemaDefinition?

    static let analysisSchema = ChatResponseFormat(
        type: "json_schema",
        jsonSchema: JSONSchemaDefinition(
            name: "scene_analysis",
            strict: true,
            schema: JSONSchemaObject(
                type: "object",
                properties: [
                    "title": JSONSchemaProperty(type: "string", enumValues: nil),
                    "severity": JSONSchemaProperty(type: "string", enumValues: AICommentSeverity.allCases.map(\.rawValue)),
                    "message": JSONSchemaProperty(type: "string", enumValues: nil),
                    "suggestion": JSONSchemaProperty(type: "string", enumValues: nil)
                ],
                required: ["title", "severity", "message", "suggestion"],
                additionalProperties: false
            )
        )
    )

    static let jsonObject = ChatResponseFormat(type: "json_object", jsonSchema: nil)

    enum CodingKeys: String, CodingKey {
        case type
        case jsonSchema = "json_schema"
    }
}

private struct JSONSchemaDefinition: Codable {
    let name: String
    let strict: Bool
    let schema: JSONSchemaObject
}

private struct JSONSchemaObject: Codable {
    let type: String
    let properties: [String: JSONSchemaProperty]
    let required: [String]
    let additionalProperties: Bool
}

private struct JSONSchemaProperty: Codable {
    let type: String
    let enumValues: [String]?

    enum CodingKeys: String, CodingKey {
        case type
        case enumValues = "enum"
    }
}

private struct ChatMessage: Codable {
    var role: String
    var content: String
}

private struct ChatCompletionResponse: Decodable {
    var choices: [ChatChoice]
}

private struct ChatChoice: Decodable {
    var message: ChatResponseMessage
    var finishReason: String?

    enum CodingKeys: String, CodingKey {
        case message
        case finishReason = "finish_reason"
    }
}

private struct ChatResponseMessage: Decodable {
    var content: ChatResponseContent?
}

private enum ChatResponseContent: Decodable {
    case string(String)
    case parts([ChatTextPart])

    var text: String {
        switch self {
        case .string(let value): value
        case .parts(let parts): parts.compactMap(\.text).joined()
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(String.self) {
            self = .string(value)
            return
        }
        self = .parts(try container.decode([ChatTextPart].self))
    }
}

private struct ChatTextPart: Decodable {
    var text: String?
}

struct PromptBuilder {
    func systemPrompt(for task: AITask, language: AppLanguage) -> String {
        let languageName = languageName(for: language)
        let languageInstruction = "Respond only in \(languageName)."
        return switch task {
        case .autocomplete:
            "Continue the same narrator's YouTube script at the caret. Return exactly one short continuation sentence and only the insertable script text. Preserve the same narrator, language, tone, person, punctuation, capitalization, and style. Do not return a second sentence, explanation, alternatives, labels, quotes, lists, or Markdown. Never answer the narrator or start a dialogue. Do not repeat text already before the caret. Account for text after the caret and avoid duplicating it. \(languageInstruction)"
        case .rewrite:
            "Rewrite selected script text while preserving intent and voice. \(languageInstruction)"
        case .analyze:
            "Review the scene for clarity, retention, pacing, repetition, concrete examples, and weak phrasing. \(languageInstruction) Return exactly one JSON object with string fields title, severity, message, and suggestion; the title, message, and suggestion values must be written in \(languageName). Severity must be note, suggestion, or important. Write complete plain-text sentences; do not use Markdown."
        case .bRollGeneration:
            "Generate practical visual or shot ideas that strengthen the meaning of the script. \(languageInstruction)"
        case .editingGeneration:
            "Generate restrained YouTube editing notes. Avoid timeline complexity. \(languageInstruction)"
        }
    }

    /// Detects the script's language among the supported languages with Apple's
    /// Natural Language recognizer. Only confident Spanish, English, or Russian
    /// hypotheses are accepted; anything else (French, Catalan, mixed short
    /// text) falls back to the interface or system language instead of being
    /// forced into one of the three supported languages.
    func responseLanguage(for text: String, fallback: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        let letterCount = text.unicodeScalars.filter { CharacterSet.letters.contains($0) }.count
        guard letterCount >= 12 else { return resolvedLanguage(fallback, preferredLanguages: preferredLanguages) }

        let recognizer = NLLanguageRecognizer()
        recognizer.processString(text)

        let supported: [NLLanguage: AppLanguage] = [
            .spanish: .spanish,
            .english: .english,
            .russian: .russian
        ]
        var bestLanguage: AppLanguage?
        var bestConfidence = 0.0
        for (detected, confidence) in recognizer.languageHypotheses(withMaximum: 5) where confidence >= Self.minimumLanguageConfidence {
            guard let appLanguage = supported[detected], confidence > bestConfidence else { continue }
            bestLanguage = appLanguage
            bestConfidence = confidence
        }
        return bestLanguage ?? resolvedLanguage(fallback, preferredLanguages: preferredLanguages)
    }

    private static let minimumLanguageConfidence = 0.6

    func resolvedLanguage(_ language: AppLanguage, preferredLanguages: [String] = Locale.preferredLanguages) -> AppLanguage {
        L10n.resolve(language, preferredLanguages: preferredLanguages)
    }

    private func languageName(for language: AppLanguage) -> String {
        switch resolvedLanguage(language) {
        case .spanish: "Spanish"
        case .russian: "Russian"
        default: "English"
        }
    }
}

@MainActor
struct RewriteService: RewriteServicing {
    var provider: any LLMProviderProtocol
    var promptBuilder = PromptBuilder()

    func rewrite(text: String, scene: Scene, settings: AIPreferences, interfaceLanguage: AppLanguage = .english, apiKey: String) async throws -> String {
        guard settings.provider != .disabled else { return text }
        let request = LLMRequest(
            task: .rewrite,
            provider: settings.provider,
            baseURL: settings.baseURL,
            systemPrompt: promptBuilder.systemPrompt(for: .rewrite, language: promptBuilder.responseLanguage(for: text, fallback: interfaceLanguage)),
            userPrompt: "Scene: \(scene.title)\n\n\(text)",
            model: settings.model,
            temperature: settings.temperature,
            maxTokens: settings.maxTokens
        )
        return try await provider.complete(request: request, apiKey: apiKey).text
    }
}

@MainActor
struct AnalysisService: AnalysisServicing {
    var provider: any LLMProviderProtocol
    var promptBuilder = PromptBuilder()

    func analyze(scene: Scene, project: FrameProject, settings: AIPreferences, interfaceLanguage: AppLanguage = .english, apiKey: String) async throws -> [AIComment] {
        let responseLanguage = promptBuilder.responseLanguage(for: scene.scriptText, fallback: interfaceLanguage)
        guard settings.provider != .disabled else {
            return [
                AIComment(
                    sceneID: scene.id,
                    segmentID: scene.textSegments.sortedByOrder.first?.id,
                    type: L10n.tr("ai.disabled.type", language: responseLanguage),
                    severity: .note,
                    message: L10n.tr("ai.disabled.message", language: responseLanguage),
                    suggestion: L10n.tr("ai.disabled.suggestion", language: responseLanguage)
                )
            ]
        }

        var request = LLMRequest(
            task: .analyze,
            provider: settings.provider,
            baseURL: settings.baseURL,
            systemPrompt: promptBuilder.systemPrompt(for: .analyze, language: responseLanguage),
            userPrompt: userPrompt(scene: scene, project: project, privacyMode: settings.privacyMode),
            model: settings.model,
            temperature: settings.temperature,
            maxTokens: max(1_024, settings.maxTokens)
        )
        let response: String
        do {
            response = try await provider.complete(request: request, apiKey: apiKey).text
        } catch LLMProviderError.malformedResponse(let detail)
                    where detail == OpenAICompatibleLLMProvider.tokenLimitResponseDetail {
            request.maxTokens = max(2_048, request.maxTokens * 2)
            do {
                response = try await provider.complete(request: request, apiKey: apiKey).text
            } catch LLMProviderError.malformedResponse(let retryDetail)
                        where retryDetail == OpenAICompatibleLLMProvider.tokenLimitResponseDetail {
                throw LLMProviderError.malformedResponse(nil)
            }
        }
        let analysis = try AnalysisResponse.decode(from: response)
        return [
            AIComment(
                sceneID: scene.id,
                segmentID: scene.textSegments.sortedByOrder.first?.id,
                type: analysis.title,
                severity: analysis.severity,
                message: analysis.message,
                suggestion: analysis.suggestion
            )
        ]
    }

    private func userPrompt(scene: Scene, project: FrameProject, privacyMode: Bool) -> String {
        if privacyMode {
            return "Scene: \(scene.title)\n\n\(scene.scriptText)"
        }
        let context = project.scenes.sortedByOrder.map { other in
            let marker = other.id == scene.id ? "CURRENT" : "CONTEXT"
            return "[\(marker)] \(other.title)\n\(other.scriptText)"
        }.joined(separator: "\n\n")
        return "Project: \(project.title)\n\n\(context)"
    }
}

struct AnalysisResponse {
    private static let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "FrameScript", category: "AIParser")
    let title: String
    let severity: AICommentSeverity
    let message: String
    let suggestion: String

    static func decode(from response: String) throws -> AnalysisResponse {
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: Data(strippingFence(from: response).utf8))
        } catch {
            logger.error("Structured analysis parse failed: \(String(describing: error), privacy: .private)")
            throw LLMProviderError.malformedResponse("analysis.invalidJSON")
        }
        guard let object = unwrap(value) else {
            logger.error("Structured analysis parse failed: unsupported or incomplete wrapper")
            throw LLMProviderError.malformedResponse("analysis.incompleteWrapper")
        }
        guard let rawTitle = object["title"] as? String,
              let rawSeverity = object["severity"] as? String,
              let rawMessage = object["message"] as? String else {
            logger.error("Structured analysis decode failed: incomplete fields")
            throw LLMProviderError.malformedResponse("analysis.incompleteFields")
        }
        let rawSuggestion: String
        switch object["suggestion"] {
        case nil, is NSNull:
            rawSuggestion = ""
        case let value as String:
            rawSuggestion = value
        default:
            logger.error("Structured analysis decode failed: invalid suggestion")
            throw LLMProviderError.malformedResponse("analysis.incompleteFields")
        }
        guard let title = sanitizedTitle(rawTitle),
              let severity = normalizedSeverity(rawSeverity),
              let message = sanitizedRequired(rawMessage),
              let suggestion = sanitizedSuggestion(rawSuggestion) else {
            logger.error("Structured analysis validation failed")
            throw LLMProviderError.malformedResponse("analysis.invalidFields")
        }
        return AnalysisResponse(title: title, severity: severity, message: message, suggestion: suggestion)
    }

    private static func strippingFence(from response: String) -> String {
        let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
        let lines = trimmed.components(separatedBy: .newlines)
        guard lines.count >= 3, lines.first?.lowercased().hasPrefix("```") == true,
              lines.last?.trimmingCharacters(in: .whitespacesAndNewlines) == "```" else { return trimmed }
        return lines.dropFirst().dropLast().joined(separator: "\n")
    }

    private static func unwrap(_ value: Any) -> [String: Any]? {
        if let object = value as? [String: Any] {
            let required = ["title", "severity", "message"]
            if required.allSatisfy({ object[$0] != nil }) { return object }
            if object.count == 1, let nested = object.values.first { return unwrap(nested) }
            return nil
        }
        if let array = value as? [Any], array.count == 1, let nested = array.first { return unwrap(nested) }
        return nil
    }

    private static func sanitizedRequired(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 600,
              !trimmed.contains("```"), !trimmed.contains("**"), !trimmed.contains("##") else { return nil }
        return trimmed
    }

    private static func sanitizedSuggestion(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count <= 600,
              !trimmed.contains("```"), !trimmed.contains("**"), !trimmed.contains("##") else { return nil }
        return trimmed
    }

    private static func normalizedSeverity(_ value: String) -> AICommentSeverity? {
        let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard normalized.count <= 80,
              !normalized.contains("```"), !normalized.contains("**"), !normalized.contains("##") else { return nil }
        switch normalized {
        case "note", "info", "information":
            return .note
        case "suggestion", "advice", "recommendation", "warning":
            return .suggestion
        case "important", "critical", "high":
            return .important
        case "":
            return nil
        default:
            return .suggestion
        }
    }

    private static func sanitizedTitle(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 80,
              !trimmed.contains("```"), !trimmed.contains("**"), !trimmed.contains("##") else { return nil }
        return trimmed
    }
}
