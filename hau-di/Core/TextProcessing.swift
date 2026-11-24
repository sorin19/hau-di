import Foundation

/// Curata transcrierea bruta: adnotari non-vorbire, spatii, halucinatii tipice Whisper.
public enum TranscriptCleaner {
    /// Adnotari pe care modelele le scriu pentru non-vorbire.
    private static let annotationPattern =
        #"[\[\(\*](?:\s*)(?:BLANK_AUDIO|blank audio|music|muzic[aă]|muzica de fundal|applause|aplauze|laughter|laughs|r[aâ]s(?:ete)?|noise|zgomot(?:e)?|silence|lini[sșş]te|inaudible|neinteligibil|sound|sunet|typing|tastare|static)(?:\s*)[\]\)\*]"#

    /// Fraze halucinate frecvent de Whisper pe liniste (normalizate: fara diacritice, lowercase).
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
        // Spatii multiple pe aceeasi linie -> unul; pastram newline-urile.
        text = text.replacingOccurrences(of: "[ \t\u{00A0}]{2,}", with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #" *\n *"#, with: "\n", options: .regularExpression)
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if isHallucination(text) { return "" }
        return text
    }

    /// Text normalizat pentru comparatii: fara diacritice, lowercase, fara punctuatie.
    public static func normalized(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let scalars = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "-" || scalar == "." ? Character(scalar) : " "
        }
        return String(scalars)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }

    /// Adevarat daca tot textul e doar o halucinatie tipica (outro de video, credit de subtitrare).
    public static func isHallucination(_ text: String) -> Bool {
        let value = normalized(text)
        guard !value.isEmpty else { return true }
        for prefix in hallucinationPrefixes where value.hasPrefix(prefix) {
            // Doar daca enuntul e scurt si dominat de fraza (nu o propozitie reala mai lunga).
            if value.count <= prefix.count + 30 { return true }
        }
        return false
    }
}

/// Lipeste natural textul dictat de ce exista deja inaintea cursorului.
public enum SmartSpacing {
    private static let noSpaceAfter: Set<Character> = ["(", "[", "{", "\"", "'", "„", "«", "“", "‘", "/", "@", "#", "-", "–", "—", "\n", "\t"]

    public static func adjust(_ text: String, precedingText: String?) -> String {
        guard let preceding = precedingText, let last = preceding.last, let first = text.first else {
            return text
        }
        if last.isWhitespace || noSpaceAfter.contains(last) { return text }
        if first.isWhitespace { return text }
        // Punctuatia lipita nu primeste spatiu inainte (", ok" / ". Apoi").
        if ",.;:!?…)]}".contains(first) { return text }
        return " " + text
    }
}

/// Analiza simpla a semnalului audio (16 kHz mono).
public enum AudioAnalysis {
    /// Cel mai mare RMS pe ferestre de 30 ms - util ca sa detectam inregistrari fara voce.
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

    /// Prag implicit ~ -46 dBFS: sub el consideram ca nu s-a vorbit.
    public static let silenceThreshold: Float = 0.005

    public static func containsSpeech(_ samples: [Float], threshold: Float = silenceThreshold) -> Bool {
        peakWindowRMS(samples) >= threshold
    }

    /// Adauga liniste la final (ajuta ultimul cuvant sa fie decodat corect).
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

/// Scoate diacriticele: ă/â→a, î→i, ș/ş→s, ț/ţ→t, é→e... Pastreaza restul (emoji, simboluri, ß).
public enum Diacritics {
    /// Textul fara diacritice, cum se scrie fara ele in limba data: in germana ä → ae, ö → oe, ü → ue, ß → ss;
    /// in spaniola ñ ramane (e alta litera: "año" nu e "ano"); in franceza œ → oe, æ → ae; in rest semnele dispar
    /// (ă → a, é → e).
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

    /// Doar semnele combinate din blocul "Combining Diacritical Marks" (U+0300-U+036F),
    /// ca selectorii de variatie ai emoji (U+FE0F) sa ramana neatinsi.
    static func stripMarks(_ character: Character) -> String {
        let decomposed = String(character).decomposedStringWithCanonicalMapping
        var scalars = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where !(0x0300...0x036F).contains(scalar.value) {
            scalars.append(scalar)
        }
        return String(scalars).precomposedStringWithCanonicalMapping
    }
}

/// Numar + substantiv, cum se spune in romana: „1 dictare”, „5 dictari”, „20 de dictari”, „101 dictari”.
public enum RomanianCount {
    public static func format(_ count: Int, singular: String, plural: String) -> String {
        if count == 1 { return "1 \(singular)" }
        let lastTwo = abs(count) % 100
        let needsDe = abs(count) >= 20 && (lastTwo == 0 || lastTwo >= 20)
        return "\(count) \(needsDe ? "de " : "")\(plural)"
    }
}
