import Foundation

// Configurable options (portable). The raw values are persisted in UserDefaults.

/// WhisperKit variants (the folder on Hugging Face is `openai_whisper-<id>`).
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

/// The dictation language: Whisper always transcribes in the chosen language. Automatic detection was removed: on a
/// sentence with many English words, detection could pick English, and Whisper translated instead of transcribing.
/// Claude spells the words spoken in English correctly when "+ English" is checked (AppSettings.mixesEnglish, see
/// CorrectionPrompt).
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

    /// The language code forced on Whisper.
    public var code: String { rawValue }

    /// The option label, with the English name for the language's marks: German has umlauts and ß (ß is a letter,
    /// not a diacritic); for French, Spanish, Italian and Hungarian the word is "accents". Spanish: ñ is a separate
    /// letter and stays even without accents, so it does not appear here. nil = the language has none (English).
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

    /// The language's letters with diacritics, for the option label; nil = the language has no diacritics (English).
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

    /// The English name, for the correction prompt.
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

    /// The setting saved by old versions -> language + the default value of the "+ English" checkbox.
    /// "ro+en" (Romanian or English), "auto" and a missing setting become Romanian with English, like the previous
    /// default; a single language stays as it is, without English.
    public static func fromStored(_ raw: String?) -> (language: DictationLanguage, mixesEnglish: Bool) {
        if let language = DictationLanguage(rawValue: raw ?? "") {
            return (language, false)
        }
        return (.romanian, true)
    }
}

/// Where the status pill appears: at the bottom (above the Dock) or at the top (below the menu bar).
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

/// The Claude models. The list comes from the API (GET /v1/models, see ModelCatalog), and the prices, fast mode
/// and the fallback on refusal come from the price list (PriceList, price.json on pay.cx.ro); the defaults and
/// display names stay here.
public enum ClaudeModels {
    public static let defaultModelID = "claude-opus-5-5"

    /// The newest known model per family, used while the list from the API is not loaded yet.
    static let defaultByLine = ["opus": "claude-opus-5-5", "sonnet": "claude-sonnet-5-5", "haiku": "claude-haiku-5-5",
                                "fable": "claude-fable-5-2"]

    public static func defaultModel(forLine line: String) -> String { defaultByLine[line] ?? defaultModelID }

    /// The ID without the date suffix: "claude-opus-4-5-20251101" -> "claude-opus-4-5".
    public static func baseID(_ id: String) -> String {
        let parts = id.split(separator: "-")
        guard parts.count > 1, let last = parts.last, last.count == 8, last.allSatisfy(\.isNumber) else { return id }
        return parts.dropLast().joined(separator: "-")
    }

    /// The family from the ID: "claude-opus-4-5-20251101" -> "opus" (empty if the ID has another shape).
    public static func line(of id: String) -> String {
        let parts = id.split(separator: "-").map(String.init)
        guard parts.count >= 2, parts[0] == "claude", !parts[1].allSatisfy(\.isNumber) else { return "" }
        return parts[1]
    }

    /// "opus" -> "Opus".
    public static func lineTitle(_ line: String) -> String {
        line.isEmpty ? "Other" : line.prefix(1).uppercased() + line.dropFirst()
    }

    /// "claude-opus-4-5-20251101" -> "Claude Opus 4.5"; IDs with any other shape stay as they are.
    public static func displayName(for id: String) -> String {
        let parts = baseID(id).split(separator: "-").map(String.init)
        guard parts.count >= 3, parts[0] == "claude", !parts[1].allSatisfy(\.isNumber) else { return id }
        let numbers = parts.dropFirst(2)
        guard numbers.allSatisfy({ $0.allSatisfy(\.isNumber) }) else { return id }
        return "Claude " + lineTitle(parts[1]) + " " + numbers.joined(separator: ".")
    }

    /// The text for a selection in the settings: "latest:opus" -> "Latest Opus".
    public static func selectionTitle(_ selection: String) -> String {
        if selection.hasPrefix(ModelCatalog.latestPrefix) {
            return "Latest " + lineTitle(String(selection.dropFirst(ModelCatalog.latestPrefix.count)))
        }
        return displayName(for: selection)
    }
}

/// How long we wait for the Claude correction, depending on the dictation length (seconds of audio).
/// Past this time, the raw transcript is inserted.
public struct CorrectionTimeouts: Equatable, Sendable {
    /// Up to (and including) this many seconds of audio, the dictation is short.
    public var longDictationThreshold: TimeInterval
    public var short: TimeInterval
    public var long: TimeInterval

    public init(longDictationThreshold: TimeInterval, short: TimeInterval, long: TimeInterval) {
        self.longDictationThreshold = longDictationThreshold
        self.short = short
        self.long = long
    }

    /// Default: up to 5 s of audio we wait 5 s, above that we wait 20 s (until 2026-11-23: 2 s and 15 s).
    public static let defaults = CorrectionTimeouts(longDictationThreshold: 5, short: 5, long: 20)

    /// Without a duration (e.g. the test in the settings) we use the long-dictation timeout.
    public func timeout(forAudio duration: TimeInterval?) -> TimeInterval {
        guard let duration else { return long }
        return duration <= longDictationThreshold ? short : long
    }
}

/// The effort level (`output_config.effort`). /v1/models says which levels each model has (`capabilities.effort`).
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

    /// The position in the order low < medium < high < xhigh < max.
    public var rank: Int { Self.allCases.firstIndex(of: self) ?? 0 }
}

/// Spoken phrase -> inserted text (e.g. "my signature" -> "Best, Ana").
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
