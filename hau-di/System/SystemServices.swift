import AppKit
import AVFoundation
import ApplicationServices
import Combine
import Security
import ServiceManagement

// MARK: - Keychain (the Anthropic API key)

enum KeychainStore {
    private static let account = "anthropic-api-key"

    private static func service(for bundleID: String) -> String { bundleID + ".anthropic" }

    private static func query(service: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private static var baseQuery: [String: Any] { query(service: service(for: AppInfo.bundleID)) }

    static func read() -> String? {
        read(service: service(for: AppInfo.bundleID))
    }

    private static func read(service: String) -> String? {
        var request = query(service: service)
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(request as CFDictionary, &item) == errSecSuccess, let data = item as? Data else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    @discardableResult
    static func save(_ value: String) -> Bool {
        let data = Data(value.utf8)
        let status = SecItemUpdate(baseQuery as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var add = baseQuery
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            return SecItemAdd(add as CFDictionary, nil) == errSecSuccess
        }
        return status == errSecSuccess
    }

    static func delete() {
        SecItemDelete(baseQuery as CFDictionary)
    }

    /// A key saved by a version with an old bundle ID: we copy it to the current ID and delete the old one.
    /// macOS may ask once for the login password to grant access (the item was created by "another" app).
    static func migrateLegacyKey() -> String? {
        for legacyID in AppInfo.legacyBundleIDs where legacyID != AppInfo.bundleID {
            let legacyService = service(for: legacyID)
            guard let value = read(service: legacyService) else { continue }
            if save(value) {
                SecItemDelete(query(service: legacyService) as CFDictionary)
            }
            return value
        }
        return nil
    }
}

/// The API key, kept in memory (we read the Keychain only once).
@MainActor
final class APIKeyStore: ObservableObject {
    @Published private(set) var apiKey: String?

    private static let legacyMigrationKey = "legacyKeychainMigrationAttempted"

    init() {
        if let key = KeychainStore.read() {
            apiKey = key
        } else if !UserDefaults.standard.bool(forKey: Self.legacyMigrationKey) {
            // A single attempt: if the user denies access, we don't ask again on every launch.
            UserDefaults.standard.set(true, forKey: Self.legacyMigrationKey)
            apiKey = KeychainStore.migrateLegacyKey()
        } else {
            apiKey = nil
        }
    }

    var hasKey: Bool { !(apiKey ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    var maskedKey: String {
        guard let key = apiKey, key.count > 12 else { return hasKey ? "••••" : "" }
        return String(key.prefix(10)) + "…" + String(key.suffix(4))
    }

    @discardableResult
    func save(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            remove()
            return true
        }
        let ok = KeychainStore.save(trimmed)
        if ok { apiKey = trimmed }
        return ok
    }

    func remove() {
        KeychainStore.delete()
        apiKey = nil
    }
}

// MARK: - Permissions

@MainActor
final class PermissionsManager: ObservableObject {
    @Published private(set) var microphone: AVAuthorizationStatus
    @Published private(set) var accessibility: Bool
    @Published private(set) var inputMonitoring: Bool
    private var timer: Timer?

    enum Pane {
        case microphone, accessibility, inputMonitoring, keyboard

        var url: URL {
            switch self {
            case .microphone: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!
            case .accessibility: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
            case .inputMonitoring: return URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
            case .keyboard: return URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!
            }
        }
    }

    init() {
        microphone = AVCaptureDevice.authorizationStatus(for: .audio)
        accessibility = AXIsProcessTrusted()
        inputMonitoring = CGPreflightListenEventAccess()
    }

    var allRequiredGranted: Bool { microphone == .authorized && accessibility }

    func refresh() {
        let mic = AVCaptureDevice.authorizationStatus(for: .audio)
        if mic != microphone { microphone = mic }
        let ax = AXIsProcessTrusted()
        if ax != accessibility { accessibility = ax }
        let input = CGPreflightListenEventAccess()
        if input != inputMonitoring { inputMonitoring = input }
    }

    func startPolling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    func requestMicrophone() async {
        if microphone == .notDetermined {
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        } else if microphone != .authorized {
            open(.microphone)
        }
        refresh()
    }

    /// Shows the system dialog that sends the user to Privacy & Security > Accessibility.
    func requestAccessibility() {
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        refresh()
    }

    func requestInputMonitoring() {
        _ = CGRequestListenEventAccess()
        refresh()
    }

    func open(_ pane: Pane) {
        NSWorkspace.shared.open(pane.url)
    }
}

// MARK: - Launch at login

enum LoginItem {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }

    static func set(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
    }
}

// MARK: - Sounds

@MainActor
enum SoundEffects {
    private static func play(_ name: String, volume: Float) {
        guard let sound = NSSound(named: NSSound.Name(name))?.copy() as? NSSound else { return }
        sound.volume = volume
        sound.play()
    }

    static func start() { play("Tink", volume: 0.25) }
    static func stop() { play("Pop", volume: 0.2) }
    static func error() { play("Basso", volume: 0.25) }
}
