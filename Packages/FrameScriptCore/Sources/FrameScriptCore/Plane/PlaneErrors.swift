import Foundation

/// Errors surfaced by the Plane module.
///
/// The API's documented failure modes are mapped to dedicated cases so the
/// app can show a useful message without inspecting status codes:
/// `401` means the API key is missing or invalid, `403` means it lacks access,
/// `404` means the workspace slug, project or work item is wrong, and `429`
/// carries the server's `Retry-After` interval.
public enum PlaneError: Error, Sendable, Equatable {
    case invalidConfiguration(String)
    case invalidResponse
    case unauthorized(message: String?)
    case forbidden(message: String?)
    case notFound(message: String?)
    case rateLimited(retryAfter: TimeInterval?, message: String?)
    case requestFailed(statusCode: Int, message: String?)
    case server(statusCode: Int, message: String?)
    case network(code: Int, message: String)
    case cancelled
    case encoding(String)
    case decoding(String)
    case paginationLimitExceeded

    var isNotFound: Bool {
        if case .notFound = self { return true }
        return false
    }
}

extension PlaneError: LocalizedError {
    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail):
            return "Invalid Plane configuration: \(detail)"
        case .invalidResponse:
            return "The Plane server returned an invalid HTTP response."
        case .unauthorized:
            return "The Plane API key was rejected. Check the token in Settings."
        case .forbidden:
            return "The Plane API key is not allowed to perform this action."
        case .notFound:
            return "The Plane workspace, project or work item was not found."
        case .rateLimited(let retryAfter, let message):
            var text: String
            if let retryAfter {
                text = "Plane rate limit reached. Retry in \(Int(retryAfter.rounded(.up))) seconds."
            } else {
                text = "Plane rate limit reached."
            }
            if let message, !message.isEmpty {
                text += " \(message)"
            }
            return text
        case .requestFailed(let statusCode, let message):
            return Self.describe("Plane rejected the request", statusCode: statusCode, message: message)
        case .server(let statusCode, let message):
            return Self.describe("Plane server error", statusCode: statusCode, message: message)
        case .network(let code, let message):
            return "Network error talking to Plane (\(code)): \(message)"
        case .cancelled:
            return "The Plane request was cancelled."
        case .encoding(let detail):
            return "Could not encode the Plane request: \(detail)"
        case .decoding(let detail):
            return "Could not decode the Plane response: \(detail)"
        case .paginationLimitExceeded:
            return "Plane returned too many pages; the request was stopped to avoid an endless loop."
        }
    }

    private static func describe(_ prefix: String, statusCode: Int, message: String?) -> String {
        if let message, !message.isEmpty {
            return "\(prefix) (\(statusCode)): \(message)"
        }
        return "\(prefix) (\(statusCode))."
    }
}

/// Abstraction over the HTTP stack so tests can drive the client without
/// touching the network. `URLSessionPlaneHTTPTransport` is the production
/// implementation.
public protocol PlaneHTTPTransport: Sendable {
    func perform(_ request: URLRequest) async throws -> PlaneHTTPResponse
}

/// The production transport, backed by an injectable `URLSession`.
public struct URLSessionPlaneHTTPTransport: PlaneHTTPTransport {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func perform(_ request: URLRequest) async throws -> PlaneHTTPResponse {
        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw PlaneError.invalidResponse
        }

        var headers: [String: String] = [:]
        headers.reserveCapacity(httpResponse.allHeaderFields.count)
        for (name, value) in httpResponse.allHeaderFields {
            let headerName: String
            if let string = name as? String {
                headerName = string
            } else {
                headerName = String(describing: name)
            }
            headers[headerName] = String(describing: value)
        }

        return PlaneHTTPResponse(statusCode: httpResponse.statusCode, headers: headers, data: data)
    }
}

/// Parses the `Retry-After` header used by a `429` response.
public enum PlaneRetryAfter {
    /// Accepts both documented forms: delay in seconds and an HTTP date.
    public static func parse(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return nil
        }
        if let seconds = TimeInterval(raw) {
            return max(0, seconds)
        }

        guard let utc = TimeZone(secondsFromGMT: 0) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = utc
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        guard let date = formatter.date(from: raw) else { return nil }
        return max(0, date.timeIntervalSince(now))
    }

    /// Derives the wait from `X-RateLimit-Reset`, documented as UTC epoch
    /// seconds. Used as a fallback when `Retry-After` is absent.
    public static func fromResetHeader(_ value: String?, now: Date = Date()) -> TimeInterval? {
        guard let raw = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty,
              let epochSeconds = TimeInterval(raw)
        else {
            return nil
        }
        return max(0, Date(timeIntervalSince1970: epochSeconds).timeIntervalSince(now))
    }
}
