import Foundation

/// Un cuvant din transcrierea Whisper, cu increderea modelului in el.
public struct TranscribedWord: Codable, Hashable, Sendable {
    /// Cuvantul exact cum l-a scris Whisper, cu spatiul din fata (" facut", " pay.cx.ro,").
    public var text: String
    /// Probabilitatea, intre 0 si 1: media geometrica a probabilitatilor token-urilor lui
    /// (fara punctuatia de la capete, ca o virgula nesigura sa nu faca nesigur cuvantul).
    public var probability: Double

    public init(text: String, probability: Double) {
        self.text = text
        self.probability = probability
    }

    // Chei scurte: istoricul pastreaza lista pentru fiecare dictare.
    enum CodingKeys: String, CodingKey {
        case text = "w"
        case probability = "p"
    }
}

/// Textul transcris si cuvintele lui, cu probabilitati (goala daca modelul nu le da).
public struct SpeechTranscript: Sendable {
    public var text: String
    public var words: [TranscribedWord]

    public init(text: String, words: [TranscribedWord] = []) {
        self.text = text
        self.words = words
    }
}

/// Textul unui token Whisper (sau al catorva, cand un caracter UTF-8 ca „ș” e impartit intre ei),
/// cu log-probabilitatile lor.
public struct TokenPiece: Equatable, Sendable {
    public var text: String
    public var logProbs: [Float]

    public init(text: String, logProbs: [Float]) {
        self.text = text
        self.logProbs = logProbs
    }
}

/// Increderea lui Whisper pe cuvinte, calculata din probabilitatile token-urilor (vin la orice transcriere,
/// deci fara pasul de timpi pe cuvinte si fara intarziere).
public enum WordConfidence {
    /// Sub acest prag un cuvant e „nesigur” si se marcheaza.
    public static let threshold = 0.5
    public static let openMark = "\u{27E6}"  // ⟦
    public static let closeMark = "\u{27E7}" // ⟧

    /// Ghilimele si paranteze de deschidere: raman in fata marcajului.
    static let leadingMarks: Set<Character> = ["(", "[", "{", "\u{201E}", "\u{201C}", "\u{00AB}", "\u{201A}", "\u{2018}", "\"", "'"]
    /// Punctuatia de dupa cuvant: ramane dupa marcaj. Punctul din fata (.htaccess, .env) face parte din cuvant.
    static let trailingMarks: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}", ")", "]", "}",
                                                "\u{201D}", "\u{00BB}", "\u{2019}", "\"", "'"]

    /// Grupeaza bucatile de token in cuvinte: un cuvant nou incepe la o bucata cu spatiu in fata, ca in textul final.
    public static func words(from pieces: [TokenPiece]) -> [TranscribedWord] {
        var groups: [[TokenPiece]] = []
        for piece in pieces where !piece.text.isEmpty {
            if groups.isEmpty || piece.text.first?.isWhitespace == true {
                groups.append([piece])
            } else {
                groups[groups.count - 1].append(piece)
            }
        }
        return groups.map { group in
            TranscribedWord(text: group.map(\.text).joined(), probability: probability(of: group))
        }
    }

    /// Cuvintele mai multor segmente, in ordine. Segmentele se lipesc cu spatiu (ca textul final),
    /// deci primul cuvant al fiecarui segment urmator primeste spatiu in fata daca nu are.
    public static func joined(_ segments: [[TranscribedWord]]) -> [TranscribedWord] {
        var result: [TranscribedWord] = []
        for segment in segments {
            for (index, word) in segment.enumerated() {
                var word = word
                if index == 0, !result.isEmpty, word.text.first?.isWhitespace != true {
                    word.text = " " + word.text
                }
                result.append(word)
            }
        }
        return result
    }

    /// exp(media log-probabilitatilor), rotunjit la 3 zecimale; fara punctuatia de la capete, daca mai ramane ceva.
    static func probability(of group: [TokenPiece]) -> Double {
        var core = group[...]
        while core.count > 1, let first = core.first, isMark(first.text, in: leadingMarks) { core = core.dropFirst() }
        while core.count > 1, let last = core.last, isMark(last.text, in: trailingMarks) { core = core.dropLast() }
        let logProbs = core.flatMap(\.logProbs)
        guard !logProbs.isEmpty else { return 1 }
        let mean = Double(logProbs.reduce(0, +)) / Double(logProbs.count)
        return (exp(mean) * 1000).rounded() / 1000
    }

    static func isMark(_ text: String, in marks: Set<Character>) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return !trimmed.isEmpty && trimmed.allSatisfy(marks.contains)
    }

    /// Textul cu cuvintele sub prag intre ⟦ si ⟧. Cuvintele nesigure alaturate intra in acelasi marcaj,
    /// iar punctuatia de la capete ramane in afara lui: „am modificat ⟦hashtag accesul⟧.”
    public static func marked(_ words: [TranscribedWord], threshold: Double = threshold) -> String {
        var result = ""
        var run: [TranscribedWord] = []

        func flush() {
            guard !run.isEmpty else { return }
            let text = run.map(\.text).joined()
            run.removeAll()
            let leading = String(text.prefix(while: \.isWhitespace))
            let core = Array(text.trimmingCharacters(in: .whitespacesAndNewlines))
            var start = 0
            var end = core.count
            while start < end, leadingMarks.contains(core[start]) { start += 1 }
            while end > start, trailingMarks.contains(core[end - 1]) { end -= 1 }
            guard start < end else {
                result += text
                return
            }
            result += leading + String(core[..<start]) + openMark + String(core[start..<end]) + closeMark
                + String(core[end...])
        }

        for word in words {
            if word.probability < threshold {
                run.append(word)
            } else {
                flush()
                result += word.text
            }
        }
        flush()
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Textul fara marcaje: plasa de siguranta daca modelul le lasa in raspuns.
    public static func stripMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: openMark, with: "").replacingOccurrences(of: closeMark, with: "")
    }

    /// Cate cuvinte sunt sub prag.
    public static func unsureCount(_ words: [TranscribedWord], threshold: Double = threshold) -> Int {
        words.filter { $0.probability < threshold }.count
    }

    /// Cuvintele cu procentul lor, pentru CSV: "Am:98 facut:95 diploi:31".
    public static func summary(_ words: [TranscribedWord]) -> String {
        words.map { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(text):\(Int((word.probability * 100).rounded()))"
        }.joined(separator: " ")
    }
}
