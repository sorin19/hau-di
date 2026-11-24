import Foundation
import OSLog

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "ro.cx.app.hau-di"
    /// IDs used by older versions (before the Haudi → hau-di rename, 2026-11-23);
    /// the settings and the API key are moved from them automatically.
    static let legacyBundleIDs = ["ro.cx.app.haudi", "ro.haudi.app"]
    /// The author and the company, shown in Settings → General → About.
    static let author = "Sorin Buturugeanu"
    static let company = "CEXA DIGITAL SRL"
    /// The company's tax ID (without "RO"), shown next to the name: "CEXA DIGITAL SRL [CIF 35370537]".
    static let companyCIF = "35370537"
    static let website = URL(string: "https://cx.ro")!
    /// The voluntary payments page.
    static let voluntaryPaymentURL = URL(string: "https://pay.cx.ro/hau-di/")!
    /// The Claude price list (plus fast mode / fallback per model), fetched once a week.
    static let pricingURL = URL(string: "https://pay.cx.ro/hau-di/pricing/")!
    /// The source code (GitHub), shown in Settings → General → About (GPL v3: the source within easy reach).
    static let sourceURL: URL? = URL(string: "https://github.com/sorin19/hau-di")
    /// The license files bundled with the app (hau-di/Resources/Legal).
    static func legalFile(_ name: String) -> URL? {
        Bundle.main.url(forResource: name, withExtension: "txt")
    }
    static var version: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(short) (\(build))"
    }
}

enum AppPaths {
    /// ~/Library/Application Support/hau-di (not ~/Documents, to avoid the TCC prompt).
    /// On first use after the rename, the old "Haudi" folder (models, history) is moved here: on the same disk
    /// it is only a rename, so it is instant, and the models are not downloaded a second time.
    static let applicationSupport: URL = {
        let fileManager = FileManager.default
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let url = base.appendingPathComponent("hau-di", isDirectory: true)
        let legacy = base.appendingPathComponent("Haudi", isDirectory: true)
        if !fileManager.fileExists(atPath: url.path), fileManager.fileExists(atPath: legacy.path) {
            try? fileManager.moveItem(at: legacy, to: url)
        }
        try? fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Download root for WhisperKit (models + tokenizer).
    static var whisperKitBase: URL {
        let url = applicationSupport.appendingPathComponent("WhisperKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The history (JSON Lines, last 3 months).
    static var historyFile: URL {
        applicationSupport.appendingPathComponent("history.jsonl")
    }

    /// The list of Claude models from the API (cached) + the parameters each model rejected.
    static var modelsFile: URL {
        applicationSupport.appendingPathComponent("claude-models.json")
    }

    /// The old format (the last 200 entries, a single JSON array); migrated automatically.
    static var legacyHistoryFile: URL {
        applicationSupport.appendingPathComponent("history.json")
    }
}

enum Log {
    private static let subsystem = AppInfo.bundleID
    static let app = Logger(subsystem: subsystem, category: "app")
    static let hotkey = Logger(subsystem: subsystem, category: "hotkey")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let asr = Logger(subsystem: subsystem, category: "asr")
    static let ai = Logger(subsystem: subsystem, category: "ai")
    static let insert = Logger(subsystem: subsystem, category: "insert")
}
