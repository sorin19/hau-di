import Foundation
import OSLog

enum AppInfo {
    static let bundleID = Bundle.main.bundleIdentifier ?? "ro.cx.app.hau-di"
    /// ID-uri folosite de versiuni mai vechi (inainte de redenumirea Haudi → hau-di, 2026-11-23);
    /// setarile si cheia API se muta automat de pe ele.
    static let legacyBundleIDs = ["ro.cx.app.haudi", "ro.haudi.app"]
    /// Autorul si firma, afisate in Setari → General → Despre.
    static let author = "Sorin Buturugeanu"
    static let company = "CEXA DIGITAL SRL"
    /// Codul fiscal al firmei (fara RO), afisat langa nume: "CEXA DIGITAL SRL [CIF 35370537]".
    static let companyCIF = "35370537"
    static let website = URL(string: "https://cx.ro")!
    /// Pagina de plati voluntare.
    static let voluntaryPaymentURL = URL(string: "https://pay.cx.ro/hau-di/")!
    /// Lista de preturi Claude (si fast mode / fallback pe modele), citita o data pe saptamana.
    static let pricingURL = URL(string: "https://pay.cx.ro/hau-di/pricing/")!
    /// Codul sursa (GitHub), afisat in Setari → General → About (GPL v3: sursa la indemana).
    static let sourceURL: URL? = URL(string: "https://github.com/sorin19/hau-di")
    /// Fisierele de licenta incluse in aplicatie (hau-di/Resources/Legal).
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
    /// ~/Library/Application Support/hau-di (nu folosim ~/Documents ca sa evitam promptul TCC).
    /// La prima folosire dupa redenumire, folderul vechi „Haudi” (modele, istoric) se muta aici: pe acelasi disc
    /// e doar o redenumire, deci instantanee, si modelele nu se mai descarca o data.
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

    /// Radacina de download pentru WhisperKit (modele + tokenizer).
    static var whisperKitBase: URL {
        let url = applicationSupport.appendingPathComponent("WhisperKit", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Istoricul (JSON Lines, ultimele 3 luni).
    static var historyFile: URL {
        applicationSupport.appendingPathComponent("history.jsonl")
    }

    /// Lista de modele Claude din API (cache) + parametrii refuzati de fiecare model.
    static var modelsFile: URL {
        applicationSupport.appendingPathComponent("claude-models.json")
    }

    /// Formatul vechi (ultimele 200, un singur array JSON); se migreaza automat.
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
