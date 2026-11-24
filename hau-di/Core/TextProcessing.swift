import Foundation

/// Cleans up the raw transcript: non-speech annotations, whitespace, typical Whisper hallucinations.
public enum TranscriptCleaner {
    /// Annotations that the models write for non-speech.
    private static let annotationPattern =
        #"[\[\(\*](?:\s*)(?:BLANK_AUDIO|blank audio|music|muzic[aă]|muzica de fundal|applause|aplauze|laughter|laughs|r[aâ]s(?:ete)?|noise|zgomot(?:e)?|silence|lini[sșş]te|inaudible|neinteligibil|sound|sunet|typing|tastare|static)(?:\s*)[\]\)\*]"#

    /// Phrases Whisper often hallucinates on silence (normalized: no diacritics, lowercase).
    private static let hallucinationPrefixes: [String] = [
        "thanks for watching",
        "thank you for watching",
        "please subscribe",
        "like and subscribe",
        "subtitles by",
        "subtitrare realizata de",
        "subtitrarea realizata de",
        "multumim pentru vizionare",
        "va multumim pentru vizionare",
        "va multumesc pentru vizionare",
        "nu uitati sa va abonati",
        "abonati-va",
        "untertitel",
        "sous-titres",
        "amara.org",
    ]

    public static func clean(_ raw: String) -> String {
        var text = raw
        text = text.replacingOccurrences(of: annotationPattern, with: " ", options: [.regularExpression, .caseInsensitive])
        text = text.replacingOccurrences(of: "♪", with: " ")
        text = text.replacingOccurrences(of: "♫", with: " ")
        // Multiple spaces on the same line -> one; newlines are kept.
        text = text.replacingOccurrences(of: "[ \t\u{00A0}]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHallucination(text) { return "" }
        return text
    }

    /// Normalized text for comparisons: no diacritics, lowercase, no punctuation.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : " "
        }
        return String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// True if the whole text is just a typical hallucination (a video outro, a subtitle credit).
    public static func isHallucination(_ text: String) -> Bool {
        let value = normalized(text)
        guard !value.isEmpty else { return true }
        for prefix in hallucinationPrefixes where value.hasPrefix(prefix) {
            // Only if the utterance is short and dominated by the phrase (not a longer real sentence).
            if value.count <= prefix.count + 30 { return true }
        }
        return false
    }
}

/// Joins the dictated text naturally onto what is already before the cursor.
public enum SmartSpacing {
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "„", "«", "“", "‘", "/", "@", "#", "-", "–", "—", "\n", "\t"]

    public static func adjust(_ text: String, precedingText: String?) -> String {
        guard let preceding = precedingText, let last = preceding.last, let first = text.first else {
            return text
        }
        if last.isWhitespace || noSpaceAfter.contains(last) { return text }
        if first.isWhitespace { return text }
        // Attached punctuation gets no space before it (", ok" / ". Apoi").
        if ",.;:!?…)]}".contains(first) { return text }
        return " " + text
    }
}

/// Simple analysis of the audio signal (16 kHz mono).
public enum AudioAnalysis {
    /// The highest RMS over 30 ms windows - useful to detect recordings without speech.
    public static func peakWindowRMS(_ samples: [Float], sampleRate: Int = 16_000) -> Float {
        let window = max(1, sampleRate * 30 / 1000)
        guard !samples.isEmpty else { return 0 }
        var peak: Float = 0
        var index = 0
        while index < samples.count {
            let end = min(index + window, samples.count)
            var sum: Float = 0
            var i = index
            while i < end {
                let s = samples[i]
                sum += s * s
                i += 1
            }
            let rms = (sum / Float(end - index)).squareRoot()
            if rms > peak { peak = rms }
            index = end
        }
        return peak
    }

    /// Default threshold ~ -46 dBFS: below it, we assume nothing was said.
    public static let silenceThreshold: Float = 0.005

    public static func containsSpeech(_ samples: [Float], threshold: Float = silenceThreshold) -> Bool {
        peakWindowRMS(samples) >= threshold
    }

    /// Appends silence at the end (helps the last word get decoded correctly).
    public static func padded(_ samples: [Float], trailingSilence seconds: Double, minimumDuration: Double, sampleRate: Int = 16_000) -> [Float] {
        var result = samples
        result.append(contentsOf: [Float](repeating: 0, count: Int(seconds * Double(sampleRate))))
        let minimumCount = Int(minimumDuration * Double(sampleRate))
        if result.count < minimumCount {
            result.append(contentsOf: [Float](repeating: 0, count: minimumCount - result.count))
        }
        return result
    }
}

/// Removes diacritics: ă/â→a, î→i, ș/ş→s, ț/ţ→t, é→e... Keeps everything else (emoji, symbols, ß).
public enum Diacritics {
    /// The text without diacritics, the way the given language is written without them: in German ä → ae, ö → oe,
    /// ü → ue, ß → ss; in Spanish ñ stays (it is a different letter: "año" is not "ano"); in French œ → oe, æ → ae;
    /// otherwise the marks are dropped (ă → a, é → e).
    public static func strip(_ text: String, language: DictationLanguage = .romanian) -> String {
        var result = ""
        result.reserveCapacity(text.utf8.count)
        for character in text {
            if let replacement = replacement(for: character, language: language) {
                result += replacement
            } else if language == .spanish, character == "ñ" || character == "Ñ" {
                result.append(character)
            } else {
                result += stripMarks(character)
            }
        }
        return result
    }

    static func replacement(for character: Character, language: DictationLanguage) -> String? {
        switch language {
        case .german:
            switch character {
            case "ä": return "ae"
            case "ö": return "oe"
            case "ü": return "ue"
            case "Ä": return "Ae"
            case "Ö": return "Oe"
            case "Ü": return "Ue"
            case "ß": return "ss"
            case "ẞ": return "SS"
            default: return nil
            }
        case .french:
            switch character {
            case "œ": return "oe"
            case "Œ": return "Oe"
            case "æ": return "ae"
            case "Æ": return "Ae"
            default: return nil
            }
        default:
            return nil
        }
    }

    /// Only the combining marks from the "Combining Diacritical Marks" block (U+0300-U+036F),
    /// so that emoji variation selectors (U+FE0F) stay untouched.
    static func stripMarks(_ character: Character) -> String {
        let decomposed = String(character).decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }
}

/// Number + noun, the way Romanian says it: "1 dictare", "5 dictari", "20 de dictari", "101 dictari".
public enum RomanianCount {
    public static func format(_ count: Int, singular: String, plural: String) -> String {
        if count == 1 { return "1 \(singular)" }
        let lastTwo = abs(count) % 100
        let needsDe = abs(count) >= 20 && (lastTwo == 0 || lastTwo >= 20)
        return "\(count) \(needsDe ? "de " : "")\(plural)"
    }
}
