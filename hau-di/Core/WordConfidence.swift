import Foundation

/// A word from the Whisper transcript, with the model's confidence in it.
public struct TranscribedWord: Codable, Hashable, Sendable {
    /// The word exactly as Whisper wrote it, with its leading space (" facut", " pay.cx.ro,").
    public var text: String
    /// The probability, between 0 and 1: the geometric mean of its tokens' probabilities
    /// (without the punctuation at either end, so that an unsure comma does not make the word unsure).
    public var probability: Double

    public init(text: String, probability: Double) {
        self.text = text
        self.probability = probability
    }

    // Short keys: the history keeps the list for every dictation.
    enum CodingKeys: String, CodingKey {
        case text = "w"
        case probability = "p"
    }
}

/// The transcribed text and its words, with probabilities (the list is empty if the model does not provide them).
public struct SpeechTranscript: Sendable {
    public var text: String
    public var words: [TranscribedWord]

    public init(text: String, words: [TranscribedWord] = []) {
        self.text = text
        self.words = words
    }
}

/// The text of a Whisper token (or of several, when a UTF-8 character such as "ș" is split between them),
/// with their log-probabilities.
public struct TokenPiece: Equatable, Sendable {
    public var text: String
    public var logProbs: [Float]

    public init(text: String, logProbs: [Float]) {
        self.text = text
        self.logProbs = logProbs
    }
}

/// Whisper's per-word confidence, computed from the token probabilities (they come with every transcription,
/// so there is no word-timestamps step and no added delay).
public enum WordConfidence {
    /// Below this threshold, a word is "unsure" and gets marked.
    public static let threshold = 0.5
    public static let openMark = "\u{27E6}"  // ⟦
    public static let closeMark = "\u{27E7}" // ⟧

    /// Opening quotes and brackets: they stay in front of the marker.
    static let leadingMarks: Set<Character> = ["(", "[", "{", "\u{201E}", "\u{201C}", "\u{00AB}", "\u{201A}", "\u{2018}", "\"", "'"]
    /// Punctuation after the word: it stays after the marker. A leading dot (.htaccess, .env) is part of the word.
    static let trailingMarks: Set<Character> = [".", ",", ";", ":", "!", "?", "\u{2026}", ")", "]", "}",
                                                "\u{201D}", "\u{00BB}", "\u{2019}", "\"", "'"]

    /// Groups the token pieces into words: a new word starts at a piece with a leading space, as in the final text.
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

    /// The words of several segments, in order. Segments are joined with a space (like the final text),
    /// so the first word of each following segment gets a leading space if it has none.
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

    /// exp(mean log-probability), rounded to 3 decimals; without the punctuation at the ends, if anything is left.
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

    /// The text with the words below the threshold between ⟦ and ⟧. Adjacent unsure words share one marker,
    /// and the punctuation at the ends stays outside it: "am modificat ⟦hashtag accesul⟧."
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

    /// The text without markers: a safety net in case the model leaves them in its response.
    public static func stripMarkers(_ text: String) -> String {
        text.replacingOccurrences(of: openMark, with: "").replacingOccurrences(of: closeMark, with: "")
    }

    /// How many words are below the threshold.
    public static func unsureCount(_ words: [TranscribedWord], threshold: Double = threshold) -> Int {
        words.filter { $0.probability < threshold }.count
    }

    /// The words with their percentages, for the CSV: "Am:98 facut:95 diploi:31".
    public static func summary(_ words: [TranscribedWord]) -> String {
        words.map { word in
            let text = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            return "\(text):\(Int((word.probability * 100).rounded()))"
        }.joined(separator: " ")
    }
}
