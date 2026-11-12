import CryptoKit
import Darwin
import Foundation

/// Identity of the project file as FrameScript last read or wrote it. Comparing
/// the hash catches content changes even when a writer preserves the
/// modification date; the date and size make cheap re-checks possible and are
/// kept for diagnostics.
struct ProjectFileSnapshot: Equatable, Sendable {
    let contentHash: String
    let modificationDate: Date?
    let fileSize: Int
}

enum ProjectFileSnapshotReader {
    static func read(at url: URL) throws -> ProjectFileSnapshot {
        let data = try Data(contentsOf: url)
        let modificationDate = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        return ProjectFileSnapshot(
            contentHash: hash(of: data),
            modificationDate: modificationDate,
            fileSize: data.count
        )
    }

    static func hash(of data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

/// Watches the project file itself. Atomic saves replace the inode, so the
/// source is re-armed against the path after a delete/rename event; app
/// activation also polls as a final fallback.
@MainActor
final class ProjectFileMonitor {
    private let securityScope: SecurityScopedResourceAccess
    private var source: DispatchSourceFileSystemObject?
    private var watchedURL: URL?
    private var changeHandler: (@MainActor () -> Void)?
    private var pendingCheck: Task<Void, Never>?
    private var rearmTask: Task<Void, Never>?

    init(securityScope: SecurityScopedResourceAccess = .live) {
        self.securityScope = securityScope
    }

    func start(watching url: URL, onChange: @escaping @MainActor () -> Void) {
        stop()
        watchedURL = url
        changeHandler = onChange
        armSource(for: url)
    }

    func stop() {
        pendingCheck?.cancel()
        pendingCheck = nil
        rearmTask?.cancel()
        rearmTask = nil
        source?.cancel()
        source = nil
        watchedURL = nil
        changeHandler = nil
    }

    private func armSource(for url: URL) {
        source?.cancel()
        source = nil
        let descriptor = securityScope.withAccess(to: url) {
            open(url.path, O_EVTONLY)
        }
        guard descriptor >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .delete, .rename, .revoke, .attrib],
            queue: .main
        )
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated {
                self?.handleFileSystemEvent()
            }
        }
        source.setCancelHandler {
            close(descriptor)
        }
        self.source = source
        source.resume()
    }

    private func handleFileSystemEvent() {
        let events = source?.data ?? []
        pendingCheck?.cancel()
        pendingCheck = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(for: .milliseconds(120))
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.changeHandler?()
        }
        if events.contains(.delete) || events.contains(.rename) || events.contains(.revoke) {
            scheduleRearm()
        }
    }

    private func scheduleRearm() {
        rearmTask?.cancel()
        guard let url = watchedURL else { return }
        rearmTask = Task { @MainActor [weak self] in
            for attempt in 0..<10 {
                do {
                    try await Task.sleep(for: .milliseconds(attempt == 0 ? 100 : 300))
                } catch {
                    return
                }
                guard let self, self.watchedURL == url else { return }
                let exists = self.securityScope.withAccess(to: url) {
                    FileManager.default.fileExists(atPath: url.path)
                }
                guard exists else { continue }
                self.armSource(for: url)
                self.changeHandler?()
                return
            }
        }
    }
}
