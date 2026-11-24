import Foundation

/// Mutarea datelor de pe bundle ID-urile vechi (AppInfo.legacyBundleIDs) pe cel curent, o singura data.
/// Modelele si istoricul nu depind de bundle ID (sunt in ~/Library/Application Support/hau-di; folderul vechi
/// „Haudi” il muta AppPaths.applicationSupport).
enum LegacyMigration {
    private static let defaultsMigratedKey = "legacyDefaultsMigrated"
    /// Indicatorii migrarilor anterioare nu se copiaza: pe ID-ul nou, fiecare migrare trebuie sa ruleze o data
    /// (altfel, de exemplu, cheia API din Keychain n-ar mai fi mutata).
    private static let internalKeys: Set<String> = [defaultsMigratedKey, "legacyKeychainMigrationAttempted"]

    /// Copiaza setarile vechi (doar cheile care lipsesc in domeniul curent), apoi sterge domeniul vechi.
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

    /// Sterge cache-urile ramase de pe ID-ul vechi (se regenereaza oricum, ex: compilarea Core ML).
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
