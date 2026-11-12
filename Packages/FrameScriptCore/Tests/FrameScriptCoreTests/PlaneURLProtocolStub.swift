import Foundation

/// A `URLProtocol` stub so the client tests exercise the real `URLSession`
/// stack without touching the network.
final class PlaneURLProtocolStub: URLProtocol {
    struct RecordedRequest: Sendable {
        let method: String?
        let url: URL?
        let headers: [String: String]
        let body: Data?

        func header(_ name: String) -> String? {
            headers.first { $0.key.caseInsensitiveCompare(name) == .orderedSame }?.value
        }

        func jsonObject() throws -> [String: Any] {
            guard let body else { throw URLError(.cannotDecodeContentData) }
            let value = try JSONSerialization.jsonObject(with: body)
            guard let object = value as? [String: Any] else {
                throw URLError(.cannotDecodeContentData)
            }
            return object
        }
    }

    struct Stub: Sendable {
        let statusCode: Int
        let headers: [String: String]
        let body: Data

        init(statusCode: Int = 200, headers: [String: String] = [:], body: Data) {
            self.statusCode = statusCode
            self.headers = headers
            self.body = body
        }
    }

    typealias Handler = @Sendable (RecordedRequest) throws -> Stub

    private static let lock = NSLock()
    nonisolated(unsafe) private static var storedHandler: Handler?
    nonisolated(unsafe) private static var storedRequests: [RecordedRequest] = []

    static func install(_ handler: @escaping Handler) {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = handler
        storedRequests = []
    }

    static func uninstall() {
        lock.lock()
        defer { lock.unlock() }
        storedHandler = nil
        storedRequests = []
    }

    static var requests: [RecordedRequest] {
        lock.lock()
        defer { lock.unlock() }
        return storedRequests
    }

    private static var handler: Handler? {
        lock.lock()
        defer { lock.unlock() }
        return storedHandler
    }

    private static func record(_ request: RecordedRequest) {
        lock.lock()
        defer { lock.unlock() }
        storedRequests.append(request)
    }

    override class func canInit(with request: URLRequest) -> Bool {
        true
    }

    override class func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let recorded = RecordedRequest(
            method: request.httpMethod,
            url: request.url,
            headers: request.allHTTPHeaderFields ?? [:],
            body: Self.bodyData(of: request)
        )
        Self.record(recorded)

        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.resourceUnavailable))
            return
        }

        do {
            let stub = try handler(recorded)
            guard let url = recorded.url,
                  let response = HTTPURLResponse(
                      url: url,
                      statusCode: stub.statusCode,
                      httpVersion: "HTTP/1.1",
                      headerFields: stub.headers
                  )
            else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }

            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !stub.body.isEmpty {
                client?.urlProtocol(self, didLoad: stub.body)
            }
            client?.urlProtocolDidFinishLoading(self)
        } catch {
            client?.urlProtocol(self, didFailWithError: error)
        }
    }

    override func stopLoading() {}

    private static func bodyData(of request: URLRequest) -> Data? {
        if let body = request.httpBody {
            return body
        }
        guard let stream = request.httpBodyStream else {
            return nil
        }

        stream.open()
        defer { stream.close() }

        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while stream.hasBytesAvailable {
            let read = stream.read(&buffer, maxLength: buffer.count)
            if read <= 0 { break }
            data.append(buffer, count: read)
        }
        return data
    }
}

extension URL {
    /// `URL.path` drops a trailing slash on this SDK. Plane paths end with one,
    /// so tests read the path back from `URLComponents` instead.
    var planePath: String {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?.path ?? path
    }

    func queryValue(_ name: String) -> String? {
        URLComponents(url: self, resolvingAgainstBaseURL: false)?
            .queryItems?
            .first { $0.name == name }?
            .value
    }
}
