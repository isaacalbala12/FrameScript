import Foundation
import OSLog

/// One-time import of preferences written by the sandboxed build.
///
/// Removing the App Sandbox changes where `UserDefaults.standard` lives. On
/// first launch the unsandboxed app imports every `FrameScript.*` key from the
/// old container plist without overwriting values that already exist.
///
/// Keychain items are not copied: they live in the login keychain and are
/// addressed by service/account. `KeychainStore` sets no explicit access group,
/// so signed builds with the same bundle identifier use the same default group.
enum SandboxDataMigration {
    static let bundleIdentifier = "com.drashko.FrameScript"
    static let markerKey = "FrameScript.sandboxMigration.v1"
    static let keyPrefix = "FrameScript."

    struct Result: Equatable {
        var didMigrate = false
        var copiedKeyCount = 0
        var copiedSettings = false
        var skippedAlreadyMigrated = false
        var skippedMissingContainer = false
    }

    static func defaultContainerPlistURL(fileManager: FileManager = .default) -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers", isDirectory: true)
            .appendingPathComponent(bundleIdentifier, isDirectory: true)
            .appendingPathComponent("Data/Library/Preferences", isDirectory: true)
            .appendingPathComponent("\(bundleIdentifier).plist")
    }

    @discardableResult
    static func migrateIfNeeded(
        defaults: UserDefaults = .standard,
        containerPlistURL: URL? = nil,
        fileManager: FileManager = .default,
        logger: Logger = Logger(
            subsystem: bundleIdentifier,
            category: "SandboxMigration"
        )
    ) -> Result {
        if defaults.bool(forKey: markerKey) {
            var result = Result()
            result.skippedAlreadyMigrated = true
            return result
        }

        let plistURL = containerPlistURL ?? defaultContainerPlistURL(fileManager: fileManager)
        guard fileManager.fileExists(atPath: plistURL.path) else {
            defaults.set(true, forKey: markerKey)
            var result = Result()
            result.skippedMissingContainer = true
            logger.info("No sandbox container preferences to migrate.")
            return result
        }

        guard let data = try? Data(contentsOf: plistURL),
              let propertyList = try? PropertyListSerialization.propertyList(
                  from: data,
                  options: [],
                  format: nil
              ) as? [String: Any] else {
            var result = Result()
            logger.error("Sandbox preferences exist but could not be read; migration left unmarked.")
            return result
        }

        var result = Result()
        for (key, value) in propertyList where key.hasPrefix(keyPrefix) {
            // Never overwrite a value already written by the unsandboxed build.
            guard defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
            result.copiedKeyCount += 1
            if key == "FrameScript.settings.v1" {
                result.copiedSettings = true
            }
        }

        defaults.set(true, forKey: markerKey)
        result.didMigrate = true
        logger.info("Migrated \(result.copiedKeyCount, privacy: .public) sandbox preference keys.")
        return result
    }
}
