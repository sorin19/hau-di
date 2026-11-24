import Foundation

// Optiuni configurabile (portabile). Valorile brute sunt persistate in UserDefaults.

/// Variante WhisperKit (folderul pe Hugging Face e `openai_whisper-<id>`).
public struct WhisperModelOption: Identifiable, Hashable, Sendable {
    public let id: String
    public let title: String
    public let size: String
    public let note: String

    public static let all: [WhisperModelOption] = [
        WhisperModelOption(id: "large-v3-v20240930_turbo", title: "Large v3 Turbo", size: "1.6 GB",
                           note: "Recommended on Macs with Apple silicon: highest accuracy, fast."),
        WhisperModelOption(id: "large-v3-v20240930_626MB", title: "Large v3 Turbo (compressed)", size: "630 MB",
                           note: "Nearly the same accuracy, smaller download."),
        WhisperModelOption(id: "small", title: "Small", size: "490 MB",
                           note: "Faster, but noticeably less accurate in Romanian."),
    ]

    public static let defaultID = "large-v3-v20240930_turbo"

    public static func option(for id: String) -> WhisperModelOption {
        all.first { $0.id == id } ?? all[0]
    }
}

/// Limba dictarii: Whisper transcrie mereu in limba aleasa. Nu mai exista detectie automata: la o fraza cu multe
/// cuvinte englezesti, detectia putea alege engleza, iar Whisper traducea in loc sa transcrie. Cuvintele spuse in
/// engleza le scrie corect Claude, cand e bifat „+ engleza” (AppSettings.mixesEnglish, vezi CorrectionPrompt).
public enum DictationLanguage: String, Codable, CaseIterable, Identifiable, Sendable {
    case romanian = "ro"
    case english = "en"
    case german = "de"
    case french = "fr"
    case spanish = "es"
    case italian = "it"
    case hungarian = "hu"

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .romanian: return "Romanian"
        case .english: return "English"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .hungarian: return "Hungarian"
        }
    }

    /// Codul impus lui Whisper.
    public var code: String { rawValue }

    /// Eticheta optiunii, cu numele folosit in engleza pentru semnele limbii: germana are umlaut-uri si ß (ß e o
    /// litera, nu un semn diacritic); la franceza, spaniola, italiana si maghiara se spune „accents”. Spaniola: ñ e o
    /// litera aparte si ramane si fara accente, deci nu apare aici. nil = limba nu are (engleza).
    public var diacriticsLabel: String? {
        switch self {
        case .romanian: return "With diacritics (ă â î ș ț)"
        case .english: return nil
        case .german: return "With umlauts and ß (ä ö ü ß)"
        case .french: return "With accents (é è ê à ç)"
        case .spanish: return "With accents (á é í ó ú)"
        case .italian: return "With accents (à è é ì ò ù)"
        case .hungarian: return "With accents (á é ö ő ü ű)"
        }
    }

    /// Literele cu diacritice ale limbii, pentru eticheta optiunii; nil = limba nu are diacritice (engleza).
    public var diacriticLetters: String? {
        switch self {
        case .romanian: return "ă â î ș ț"
        case .english: return nil
        case .german: return "ä ö ü ß"
        case .french: return "é è ê à ç œ"
        case .spanish: return "á é í ó ú ñ"
        case .italian: return "à è é ì ò ù"
        case .hungarian: return "á é ö ő ü ű"
        }
    }

    /// Numele in engleza, pentru prompt-ul de corectie.
    public var englishName: String {
        switch self {
        case .romanian: return "Romanian"
        case .english: return "English"
        case .german: return "German"
        case .french: return "French"
        case .spanish: return "Spanish"
        case .italian: return "Italian"
        case .hungarian: return "Hungarian"
        }
    }

    /// Setarea salvata de versiunile vechi -> limba + valoarea implicita a bifei „+ engleza”.
    /// "ro+en" (romana sau engleza), "auto" si lipsa setarii devin romana cu engleza, ca implicitul de pana acum;
    /// o limba individuala ramane, fara engleza.
    public static func fromStored(_ raw: String?) -> (language: DictationLanguage, mixesEnglish: Bool) {
        if let language = DictationLanguage(rawValue: raw ?? "") {
            return (language, false)
        }
        return (.romanian, true)
    }
}

/// Unde apare pastila de status: jos (deasupra Dock-ului) sau sus (sub bara de meniu).
public enum OverlayPosition: String, Codable, CaseIterable, Identifiable, Sendable {
    case bottom
    case top

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .bottom: return "Bottom"
        case .top: return "Top"
        }
    }
}

public enum InsertionMethod: String, Codable, CaseIterable, Identifiable, Sendable {
    case paste
    case type

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .paste: return "Paste (⌘V via the clipboard) - recommended"
        case .type: return "Type character by character"
        }
    }
}

public enum CorrectionLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case minimal
    case standard
    case polished

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .minimal: return "Minimal"
        case .standard: return "Standard"
        case .polished: return "Polished"
        }
    }

    public var subtitle: String {
        switch self {
        case .minimal: return "Only recognition errors, diacritics, punctuation and data formatting."
        case .standard: return "Plus: removes hesitations, applies self-corrections (\"no, actually...\"), formats lists."
        case .polished: return "Plus: rephrases for clarity and adapts the tone to the app (email vs. chat)."
        }
    }
}

/// Modelele Claude. Lista vine din API (GET /v1/models, vezi ModelCatalog), iar preturile, fast mode si fallback-ul
/// la refuz din lista de preturi (PriceList, price.json pe pay.cx.ro); aici raman valorile implicite si numele afisate.
public enum ClaudeModels {
    public static let defaultModelID = "claude-opus-5-5"

    /// Cel mai nou model cunoscut pe familii, folosit cat timp lista din API nu e inca incarcata.
    static let defaultByLine = ["opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5",
                                "fable": "claude-fable-5-2"]

    public static func defaultModel(forLine line: String) -> String { defaultByLine[line] ?? defaultModelID }

    /// ID-ul fara sufixul de data: "claude-opus-4-5-20251101" -> "claude-opus-4-5".
    public static func baseID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count > 1, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) else { return id }
        return parts.dropLast().joined(separator: "-")
    }

    /// Familia din ID: "claude-opus-4-5-20251101" -> "opus" (gol daca ID-ul are alta forma).
    public static func line(of id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude", !parts[1].allSatisfy(\.isNumber) else { return "" }
        return parts[1]
    }

    /// "opus" -> "Opus".
    public static func lineTitle(_ line: String) -> String {
        line.isEmpty ? "Other" : line.prefix(1).uppercased() + line.dropFirst()
    }

    /// "claude-opus-4-5-20251101" -> "Claude Opus 4.5"; ID-urile cu alta forma raman ca atare.
    public static func displayName(for id: String) -> String {
        let parts = baseID(id).split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", !parts[1].allSatisfy(\.isNumber) else { return id }
        let numbers = parts.dropFirst(2)
        guard numbers.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return id }
        return "Claude " + lineTitle(parts[1]) + " " + numbers.joined(separator: ".")
    }

    /// Textul unei selectii din setari: "latest:opus" -> "cel mai nou Opus".
    public static func selectionTitle(_ selection: String) -> String {
        if selection.hasPrefix(ModelCatalog.latestPrefix) {
            return "Latest " + lineTitle(String(selection.dropFirst(ModelCatalog.latestPrefix.count)))
        }
        return displayName(for: selection)
    }
}

/// Cat asteptam corectia Claude, in functie de lungimea dictarii (secunde de audio).
/// Peste timpul asta se insereaza transcrierea bruta.
public struct CorrectionTimeouts: Equatable, Sendable {
    /// Pana la (inclusiv) atatea secunde de audio, dictarea e scurta.
    public var longDictationThreshold: TimeInterval
    public var short: TimeInterval
    public var long: TimeInterval

    public init(longDictationThreshold: TimeInterval, short: TimeInterval, long: TimeInterval) {
        self.longDictationThreshold = longDictationThreshold
        self.short = short
        self.long = long
    }

    /// Implicit: pana la 5 s de audio se asteapta 5 s, peste se asteapta 20 s (pana la 23.11.2026: 2 s si 15 s).
    public static let defaults = CorrectionTimeouts(longDictationThreshold: 5, short: 5, long: 20)

    /// Fara durata (ex: testul din setari) folosim timpul pentru dictare lunga.
    public func timeout(forAudio duration: TimeInterval?) -> TimeInterval {
        guard let duration else { return long }
        return duration <= longDictationThreshold ? short : long
    }
}

/// Nivelul de efort (`output_config.effort`). Ce niveluri are fiecare model spune /v1/models (`capabilities.effort`).
public enum EffortLevel: String, Codable, CaseIterable, Identifiable, Sendable {
    case low
    case medium
    case high
    case xhigh
    case max

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .low: return "Low (fastest)"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "Extra high"
        case .max: return "Max (slowest and most expensive)"
        }
    }

    /// Pozitia in ordinea low < medium < high < xhigh < max.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Fraza rostita -> text inserat (ex: "semnatura mea" -> "Cu bine, Ana").
public struct Snippet: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var trigger: String
    public var expansion: String

    public init(id: UUID = UUID(), trigger: String, expansion: String) {
        self.id = id
        self.trigger = trigger
        self.expansion = expansion
    }
}
