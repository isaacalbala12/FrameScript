import Foundation

public enum ResearchLinks {
    /// Only web links are openable from the panel. This deliberately rejects
    /// `file:`, `javascript:` and other schemes a pasted source might carry.
    public static func validURL(from raw: String) -> URL? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host,
              !host.isEmpty else {
            return nil
        }
        return url
    }

    /// Host shown next to a source so a long URL does not need to be read.
    public static func displayHost(from raw: String) -> String? {
        guard let url = validURL(from: raw) else { return nil }
        return url.host?.lowercased()
    }
}
