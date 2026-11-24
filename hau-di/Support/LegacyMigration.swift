import Foundation

/// Moves the data from the old bundle IDs (AppInfo.legacyBundleIDs) to the current one, once.
/// Models and history do not depend on the bundle ID (they live in ~/Library/Application Support/hau-di; the old
/// "Haudi" folder is moved by AppPaths.applicationSupport).
enum LegacyMigration {
    private static let defaultsMigratedKey = "legacyDefaultsMigrated"
    /// The flags of earlier migrations are not copied: on the new ID, every migration must run once
    /// (otherwise, for example, the API key in the Keychain would never be moved).
    private static let internalKeys: Set<String> = [defaultsMigratedKey, "legacyKeychainMigrationAttempted"]

    /// Copies the old settings (only the keys missing from the current domain), then deletes the old domain.
    static func migrateDefaults(into defaults: UserDefaults) {
        guard !defaults.bool(forKey: defaultsMigratedKey) else { return }
        for legacyID in AppInfo.legacyBundleIDs where legacyID != AppInfo.bundleID {
            guard let old = defaults.persistentDomain(forName: legacyID), !old.isEmpty else { continue }
            for (key, value) in old where defaults.object(forKey: key) == nil && !internalKeys.contains(key) {
                defaults.set(value, forKey: key)
            }
            defaults.removePersistentDomain(forName: legacyID)
        }
        defaults.set(true, forKey: defaultsMigratedKey)
    }

    /// Deletes the caches left over from the old IDs (they are regenerated anyway, e.g. the Core ML compilation).
    static func removeLegacyCaches() {
        guard let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first else { return }
        for legacyID in AppInfo.legacyBundleIDs where legacyID != AppInfo.bundleID {
            let leftovers = [
                "Caches/\(legacyID)",
                "HTTPStorages/\(legacyID)",
                "HTTPStorages/\(legacyID).binarycookies",
                "Saved Application State/\(legacyID).savedState",
            ]
            for relative in leftovers {
                let url = library.appendingPathComponent(relative)
                if FileManager.default.fileExists(atPath: url.path) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
        }
    }
}
