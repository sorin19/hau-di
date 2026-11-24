import Foundation
import Combine

/// The app's settings, persisted in UserDefaults. The API key is kept separately, in the Keychain.
@MainActor
final class AppSettings: ObservableObject {
    private let defaults: UserDefaults

    private enum Key {
        static let hotkey = "hotkey"
        static let handsFree = "handsFreeEnabled"
        static let whisperModel = "whisperModel"
        static let language = "language"
        static let whisperDictionaryHint = "whisperDictionaryHint"
        static let microphoneUID = "microphoneUID"
        static let insertionMethod = "insertionMethod"
        static let restoreClipboard = "restoreClipboard"
        static let smartSpacing = "smartSpacing"
        static let playSounds = "playSounds"
        static let showOverlay = "showOverlay"
        static let overlayPosition = "overlayPosition"
        static let correctionEnabled = "correctionEnabled"
        static let claudeModel = "claudeModel"
        static let correctionLevel = "correctionLevel"
        static let effort = "effort"
        static let fastMode = "fastMode"
        static let longDictationThreshold = "longDictationThreshold"
        static let shortCorrectionTimeout = "correctionTimeoutShort"
        static let longCorrectionTimeout = "correctionTimeoutLong"
        static let correctionTimeoutsV2 = "correctionTimeoutsV2"
        static let monthlyBudgetEnabled = "monthlyBudgetEnabled"
        static let monthlyBudgetUSD = "monthlyBudgetUSD"
        static let sendAppContext = "sendAppContext"
        static let installID = "installID"
        static let mixesEnglish = "languageMixesEnglish"
        static let sendFieldText = "sendFieldText"
        static let customInstructions = "customInstructions"
        static let useDiacritics = "useDiacritics"
        static let dictionary = "dictionary"
        static let ignoredSuggestions = "ignoredDictionarySuggestions"
        static let snippets = "snippets"
        static let historyEnabled = "historyEnabled"
        static let onboardingDone = "onboardingDone"
        /// Retired settings: the Parakeet engine (removed) and the single timeout (replaced by short / long).
        static let retired = ["engine", "parakeetModel", "correctionTimeout", "effortResetToLowV1"]
    }

    // Key combination
    @Published var hotkey: Hotkey { didSet { saveCodable(hotkey, Key.hotkey) } }
    @Published var handsFreeEnabled: Bool { didSet { defaults.set(handsFreeEnabled, forKey: Key.handsFree) } }

    // Transcription
    @Published var whisperModel: String { didSet { defaults.set(whisperModel, forKey: Key.whisperModel) } }
    @Published var language: DictationLanguage { didSet { defaults.set(language.rawValue, forKey: Key.language) } }
    /// "+ English": dictation mixes in English words (Romglish, Hunglish); Claude writes them correctly, in English.
    @Published var mixesEnglish: Bool { didSet { defaults.set(mixesEnglish, forKey: Key.mixesEnglish) } }
    @Published var whisperDictionaryHint: Bool { didSet { defaults.set(whisperDictionaryHint, forKey: Key.whisperDictionaryHint) } }
    @Published var microphoneUID: String? { didSet { defaults.set(microphoneUID, forKey: Key.microphoneUID) } }

    // Insertion and feedback
    @Published var insertionMethod: InsertionMethod { didSet { defaults.set(insertionMethod.rawValue, forKey: Key.insertionMethod) } }
    @Published var restoreClipboard: Bool { didSet { defaults.set(restoreClipboard, forKey: Key.restoreClipboard) } }
    @Published var smartSpacing: Bool { didSet { defaults.set(smartSpacing, forKey: Key.smartSpacing) } }
    @Published var playSounds: Bool { didSet { defaults.set(playSounds, forKey: Key.playSounds) } }
    @Published var showOverlay: Bool { didSet { defaults.set(showOverlay, forKey: Key.showOverlay) } }
    @Published var overlayPosition: OverlayPosition { didSet { defaults.set(overlayPosition.rawValue, forKey: Key.overlayPosition) } }

    /// The install ID: a UUID v7 (generation time + random bits), not linked to the person or to the Mac.
    /// It is sent only when fetching the price list (once a week), so the author can see how many installs
    /// use the app. An older v4 ID is replaced once with a v7 one.
    let installID: String

    // AI correction (Claude)
    @Published var correctionEnabled: Bool { didSet { defaults.set(correctionEnabled, forKey: Key.correctionEnabled) } }
    /// ID of the model chosen from the API list ("claude-opus-5-5") or "latest:<family>" (the newest in the family).
    /// Values saved by old versions (the fixed enum) were already IDs, so they stay valid.
    @Published var claudeModel: String { didSet { defaults.set(claudeModel, forKey: Key.claudeModel) } }
    @Published var correctionLevel: CorrectionLevel { didSet { defaults.set(correctionLevel.rawValue, forKey: Key.correctionLevel) } }
    /// The desired effort; if the model doesn't have that level, the nearest lower one is sent (ModelCatalog.effort).
    @Published var effort: EffortLevel { didSet { defaults.set(effort.rawValue, forKey: Key.effort) } }
    @Published var fastMode: Bool { didSet { defaults.set(fastMode, forKey: Key.fastMode) } }
    /// Dictations up to this many seconds of audio are short; beyond that, long.
    @Published var longDictationThreshold: Double { didSet { defaults.set(longDictationThreshold, forKey: Key.longDictationThreshold) } }
    /// How long we wait for the Claude correction on a short and on a long dictation, respectively.
    @Published var shortCorrectionTimeout: Double { didSet { defaults.set(shortCorrectionTimeout, forKey: Key.shortCorrectionTimeout) } }
    @Published var longCorrectionTimeout: Double { didSet { defaults.set(longCorrectionTimeout, forKey: Key.longCorrectionTimeout) } }
    /// The monthly budget for Claude corrections (on by default, $20): a warning at 80%; at 100% correction stops
    /// until the next month (BudgetTracker).
    @Published var monthlyBudgetEnabled: Bool { didSet { defaults.set(monthlyBudgetEnabled, forKey: Key.monthlyBudgetEnabled) } }
    @Published var monthlyBudgetUSD: Double { didSet { defaults.set(monthlyBudgetUSD, forKey: Key.monthlyBudgetUSD) } }
    @Published var sendAppContext: Bool { didSet { defaults.set(sendAppContext, forKey: Key.sendAppContext) } }
    @Published var sendFieldText: Bool { didSet { defaults.set(sendFieldText, forKey: Key.sendFieldText) } }
    @Published var customInstructions: String { didSet { defaults.set(customInstructions, forKey: Key.customInstructions) } }
    /// false = the text is inserted without diacritics (both with and without the Claude correction).
    @Published var useDiacritics: Bool { didSet { defaults.set(useDiacritics, forKey: Key.useDiacritics) } }

    // Dictionary and snippets
    @Published var dictionary: [String] { didSet { defaults.set(dictionary, forKey: Key.dictionary) } }
    /// Dictionary suggestions hidden with ×, by key (DictionarySuggestions.key).
    @Published var ignoredSuggestions: [String] {
        didSet { defaults.set(ignoredSuggestions, forKey: Key.ignoredSuggestions) }
    }
    @Published var snippets: [Snippet] { didSet { saveCodable(snippets, Key.snippets) } }

    // Other
    @Published var historyEnabled: Bool { didSet { defaults.set(historyEnabled, forKey: Key.historyEnabled) } }
    @Published var onboardingDone: Bool { didSet { defaults.set(onboardingDone, forKey: Key.onboardingDone) } }

    init(defaults: UserDefaults = .standard) {
        LegacyMigration.migrateDefaults(into: defaults)
        self.defaults = defaults
        func bool(_ key: String, _ fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil ? fallback : defaults.bool(forKey: key)
        }
        func codable<T: Decodable>(_ type: T.Type, _ key: String) -> T? {
            guard let data = defaults.data(forKey: key) else { return nil }
            return try? JSONDecoder().decode(type, from: data)
        }
        func seconds(_ key: String, _ fallback: Double) -> Double {
            let value = defaults.double(forKey: key)
            return value > 0 ? value : fallback
        }
        Key.retired.forEach { defaults.removeObject(forKey: $0) }

        hotkey = codable(Hotkey.self, Key.hotkey) ?? .fn
        handsFreeEnabled = bool(Key.handsFree, true)

        whisperModel = defaults.string(forKey: Key.whisperModel) ?? WhisperModelOption.defaultID
        // Old versions also had "ro+en" / "auto": they become Romanian + "+ English", saved once in the new form.
        let storedLanguage = DictationLanguage.fromStored(defaults.string(forKey: Key.language))
        let storedMixesEnglish = bool(Key.mixesEnglish, storedLanguage.mixesEnglish)
        language = storedLanguage.language
        mixesEnglish = storedMixesEnglish
        defaults.set(storedLanguage.language.rawValue, forKey: Key.language)
        defaults.set(storedMixesEnglish, forKey: Key.mixesEnglish)
        whisperDictionaryHint = bool(Key.whisperDictionaryHint, true)
        microphoneUID = defaults.string(forKey: Key.microphoneUID)

        insertionMethod = InsertionMethod(rawValue: defaults.string(forKey: Key.insertionMethod) ?? "") ?? .paste
        restoreClipboard = bool(Key.restoreClipboard, true)
        smartSpacing = bool(Key.smartSpacing, true)
        playSounds = bool(Key.playSounds, true)
        showOverlay = bool(Key.showOverlay, true)
        overlayPosition = OverlayPosition(rawValue: defaults.string(forKey: Key.overlayPosition) ?? "") ?? .bottom

        if let saved = defaults.string(forKey: Key.installID), UUIDv7.isValid(saved) {
            installID = saved
        } else {
            let newID = UUIDv7.make().uuidString.lowercased()
            installID = newID
            defaults.set(newID, forKey: Key.installID)
        }

        correctionEnabled = bool(Key.correctionEnabled, true)
        claudeModel = defaults.string(forKey: Key.claudeModel).flatMap { $0.isEmpty ? nil : $0 } ?? ClaudeModels.defaultModelID
        correctionLevel = CorrectionLevel(rawValue: defaults.string(forKey: Key.correctionLevel) ?? "") ?? .standard
        // Default Medium (the test on real dictations from 24.11.2026: Opus 5.5 on Medium makes ~3 times fewer serious
        // errors than on Low). Whatever the user has already chosen stays untouched.
        effort = EffortLevel(rawValue: defaults.string(forKey: Key.effort) ?? "") ?? .medium
        fastMode = bool(Key.fastMode, false)
        let timeouts = CorrectionTimeouts.defaults
        longDictationThreshold = seconds(Key.longDictationThreshold, timeouts.longDictationThreshold)
        var shortTimeout = seconds(Key.shortCorrectionTimeout, timeouts.short)
        var longTimeout = seconds(Key.longCorrectionTimeout, timeouts.long)
        if !defaults.bool(forKey: Key.correctionTimeoutsV2) {
            // Saved old defaults (2 s and 15 s) move to the new ones, only once; other chosen values stay.
            if shortTimeout == 2 {
                shortTimeout = timeouts.short
                defaults.set(shortTimeout, forKey: Key.shortCorrectionTimeout)
            }
            if longTimeout == 15 {
                longTimeout = timeouts.long
                defaults.set(longTimeout, forKey: Key.longCorrectionTimeout)
            }
            defaults.set(true, forKey: Key.correctionTimeoutsV2)
        }
        shortCorrectionTimeout = shortTimeout
        longCorrectionTimeout = longTimeout
        monthlyBudgetEnabled = bool(Key.monthlyBudgetEnabled, true)
        monthlyBudgetUSD = seconds(Key.monthlyBudgetUSD, 20)
        sendAppContext = bool(Key.sendAppContext, true)
        sendFieldText = bool(Key.sendFieldText, false)
        customInstructions = defaults.string(forKey: Key.customInstructions) ?? ""
        useDiacritics = bool(Key.useDiacritics, true)

        dictionary = defaults.stringArray(forKey: Key.dictionary) ?? []
        ignoredSuggestions = defaults.stringArray(forKey: Key.ignoredSuggestions) ?? []
        snippets = codable([Snippet].self, Key.snippets) ?? []

        historyEnabled = bool(Key.historyEnabled, true)
        onboardingDone = bool(Key.onboardingDone, false)
    }

    private func saveCodable<T: Encodable>(_ value: T, _ key: String) {
        if let data = try? JSONEncoder().encode(value) {
            defaults.set(data, forKey: key)
        }
    }

    // MARK: - Derived values

    var correctionConfig: CorrectionConfig {
        // English has no diacritics: the option doesn't apply (and is hidden in the UI).
        CorrectionConfig(level: correctionLevel, dictionary: dictionary, snippets: snippets,
                         customInstructions: customInstructions,
                         useDiacritics: useDiacritics || language.diacriticLetters == nil,
                         language: language, mixesEnglish: mixesEnglish)
    }

    /// The monthly limit in dollars; nil = no limit.
    var monthlyBudget: Double? { monthlyBudgetEnabled ? monthlyBudgetUSD : nil }

    var correctionTimeouts: CorrectionTimeouts {
        CorrectionTimeouts(longDictationThreshold: longDictationThreshold, short: shortCorrectionTimeout,
                           long: longCorrectionTimeout)
    }

    /// The call options: the chosen model (resolved against the API list), the effort it accepts, fast mode and
    /// fallback only where possible. `audioDuration` picks the timeout (short / long); nil = long dictation.
    func claudeOptions(audioDuration: TimeInterval?, models: ModelCatalogStore) -> ClaudeOptions {
        let id = models.resolvedID(for: claudeModel)
        let info = models.info(for: id)
        return ClaudeOptions(model: id, effort: ModelCatalog.effort(effort, for: info), fastMode: fastMode,
                             rejectedFeatures: models.rejectedFeatures(for: id), maxOutputTokens: info?.maxOutputTokens,
                             prices: models.prices, timeout: correctionTimeouts.timeout(forAudio: audioDuration))
    }

    /// The dictionary terms sent to Whisper as a prompt (if enabled).
    var whisperVocabulary: [String] {
        guard whisperDictionaryHint else { return [] }
        return dictionary.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    var currentEngineTitle: String {
        "Whisper " + WhisperModelOption.option(for: whisperModel).title
    }
}
