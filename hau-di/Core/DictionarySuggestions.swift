import Foundation

/// Un termen propus pentru Dictionar: un cuvant pe care Whisper l-a auzit gresit si Claude l-a corectat.
public struct DictionarySuggestion: Identifiable, Hashable, Sendable {
    /// Forma scrisa de Claude, fara terminatia romaneasca legata cu cratima ("border-ul" -> "border").
    public var term: String
    /// Cheia de comparare: litere mici, fara diacritice, fara semne si spatii.
    public var key: String
    /// Ce a auzit Whisper, cu numarul de aparitii (cele mai dese primele).
    public var heard: [HeardForm]
    /// De cate ori a corectat Claude termenul.
    public var count: Int
    /// Increderea medie a lui Whisper in cuvintele auzite gresit (nil daca dictarile nu au probabilitati).
    public var averageProbability: Double?
    public var lastSeen: Date

    public var id: String { key }
}

public struct HeardForm: Hashable, Sendable {
    public var text: String
    public var count: Int
}

/// Sugestiile pentru Dictionar, din istoric: unde textul final al lui Claude difera de transcrierea lui Whisper
/// printr-un cuvant (sau cateva), iar cuvantul corectat arata a termen (nume, cuvant englezesc, acronim).
public enum DictionarySuggestions {
    /// Cel mult atatea cuvinte de fiecare parte a unei corecturi; mai mult e o reformulare, nu un termen auzit gresit.
    static let maxHeardWords = 4
    static let maxWrittenWords = 3
    static let maxTermLength = 40

    public static func compute(from entries: [HistoryEntry], ignoring ignored: Set<String> = [],
                               limit: Int = 20) -> [DictionarySuggestion] {
        struct Accumulator {
            /// Formele scrise de Claude: de cate ori si cand ultima data (se propune cea mai recenta).
            var forms: [String: (count: Int, last: Date)] = [:]
            var heard: [String: Int] = [:]
            var count = 0
            var probabilities: [Double] = []
            var lastSeen = Date.distantPast
            var termLike = false
            var inflectionOnly = true
        }
        var byKey: [String: Accumulator] = [:]

        for entry in entries where entry.correctedBy != nil && entry.rawText != entry.finalText {
            for occurrence in occurrences(in: entry) {
                var acc = byKey[occurrence.key] ?? Accumulator()
                let form = acc.forms[occurrence.term] ?? (0, .distantPast)
                acc.forms[occurrence.term] = (form.count + 1, max(form.last, entry.date))
                acc.heard[occurrence.heard, default: 0] += 1
                acc.count += 1
                if let probability = occurrence.probability { acc.probabilities.append(probability) }
                acc.lastSeen = max(acc.lastSeen, entry.date)
                acc.termLike = acc.termLike || occurrence.termLike
                acc.inflectionOnly = acc.inflectionOnly && occurrence.inflection
                byKey[occurrence.key] = acc
            }
        }

        let suggestions = byKey.compactMap { key, acc -> DictionarySuggestion? in
            guard !ignored.contains(key) else { return nil }
            // Un cuvant obisnuit (fara semne de termen) apare doar daca s-a repetat si nu e doar alta forma
            // gramaticala a aceluiasi cuvant ("facem" -> "faci").
            if !acc.termLike, acc.count < 2 || acc.inflectionOnly { return nil }
            let term = acc.forms.max { ($0.value.last, $0.value.count, $1.key) < ($1.value.last, $1.value.count, $0.key) }?.key ?? key
            let heard = acc.heard.map { HeardForm(text: $0.key, count: $0.value) }
                .sorted { ($0.count, $1.text) > ($1.count, $0.text) }
            let average = acc.probabilities.isEmpty ? nil : acc.probabilities.reduce(0, +) / Double(acc.probabilities.count)
            return DictionarySuggestion(term: term, key: key, heard: heard, count: acc.count,
                                        averageProbability: average, lastSeen: acc.lastSeen)
        }
        return Array(suggestions.sorted { ($0.count, $0.lastSeen, $1.key) > ($1.count, $1.lastSeen, $0.key) }.prefix(limit))
    }

    // MARK: - O dictare

    struct HeardWord {
        var text: String
        var probability: Double?
    }

    struct Occurrence: Equatable {
        var term: String
        var key: String
        var heard: String
        var probability: Double?
        var termLike: Bool
        var inflection: Bool
    }

    /// Corecturile dintr-o dictare care pot fi termeni de dictionar.
    static func occurrences(in entry: HistoryEntry) -> [Occurrence] {
        let heardWords: [HeardWord]
        if let words = entry.words, !words.isEmpty {
            heardWords = words.map { HeardWord(text: $0.text.trimmingCharacters(in: .whitespacesAndNewlines),
                                               probability: $0.probability) }
                .filter { !$0.text.isEmpty }
        } else {
            heardWords = entry.rawText.split(whereSeparator: \.isWhitespace).map { HeardWord(text: String($0), probability: nil) }
        }
        let written = entry.finalText.split(whereSeparator: \.isWhitespace).map(String.init)
        guard heardWords.count <= 400, written.count <= 400 else { return [] }

        var result: [Occurrence] = []
        for block in replacements(heard: heardWords.map { key($0.text) }, written: written.map { key($0) }) {
            let heardCount = block.heard.count
            let writtenCount = block.written.count
            guard heardCount <= maxHeardWords, writtenCount <= maxWrittenWords else { continue }
            // Acelasi numar de cuvinte: perechi cuvant cu cuvant ("KH1, KH-mod-ul" -> "chown-ul, chmod-ul").
            let pairs: [(Range<Int>, Range<Int>)] = heardCount == writtenCount && heardCount > 1
                ? (0..<heardCount).map { offset in
                    (block.heard.lowerBound + offset..<block.heard.lowerBound + offset + 1,
                     block.written.lowerBound + offset..<block.written.lowerBound + offset + 1)
                }
                : [(block.heard, block.written)]
            for (heardRange, writtenRange) in pairs {
                let sentenceStart = writtenRange.lowerBound == 0
                    || written[writtenRange.lowerBound - 1].last.map { ".!?:".contains($0) } == true
                result += candidates(heard: Array(heardWords[heardRange]), written: Array(written[writtenRange]),
                                     sentenceStart: sentenceStart)
            }
        }
        return result
    }

    /// Termenii dintr-o corectura (heard -> written). Dintr-o corectura de mai multe cuvinte raman doar cele care
    /// arata a termen ("accesibil .htaccess" -> ".htaccess", "HI cu sonet" -> "Haiku", "Sonnet").
    static func candidates(heard heardWords: [HeardWord], written: [String], sentenceStart: Bool) -> [Occurrence] {
        let heard = trimEdges(heardWords.map { $0.text }.joined(separator: " "))
        let heardKey = key(heard)
        let heardKeys = heardWords.map { key($0.text) }
        let heardBaseKey = key(baseTerm(heard).term)
        let probabilities = heardWords.compactMap { $0.probability }
        let probability = probabilities.isEmpty ? nil : probabilities.reduce(0, +) / Double(probabilities.count)

        var result: [Occurrence] = []
        for (index, word) in written.enumerated() {
            let startsSentence = index == 0 ? sentenceStart : written[index - 1].last.map { ".!?:".contains($0) } == true
            let base = baseTerm(trimEdges(word))
            let term = base.term
            let termKey = key(term)
            guard !termKey.isEmpty, term.count <= maxTermLength, term.contains(where: \.isLetter), !term.contains("/"),
                  !stopwords.contains(termKey), termKey != heardKey, termKey != heardBaseKey,
                  !heardKeys.contains(termKey) else { continue }
            // Intr-o corectura de mai multe cuvinte, un cuvant auzit corect dar lipit de altul ramane pe dinafara:
            // "accesibil.htacces" -> "accesibil .htaccess" propune doar ".htaccess".
            if written.count > 1, termKey.count >= 4, heardKeys.contains(where: { $0.hasPrefix(termKey) }) { continue }
            let termLike = base.stripped || isTermLike(term, sentenceStart: startsSentence)
            if !termLike {
                // Un cuvant obisnuit: doar singur in corectura, de cel putin 4 litere si fara diacritice romanesti
                // (un cuvant romanesc corectat e gramatica, nu un termen de dictionar).
                if written.count > 1 || termKey.count < 4 || term.contains(where: { romanianLetters.contains($0) }) { continue }
            }
            let inflection = heardKeys.contains { sharedPrefixLength($0, termKey) >= 3 }
            result.append(Occurrence(term: term, key: termKey, heard: heard, probability: probability,
                                     termLike: termLike, inflection: inflection))
        }
        return result
    }

    static let romanianLetters: Set<Character> = ["ă", "â", "î", "ș", "ț", "ş", "ţ", "Ă", "Â", "Î", "Ș", "Ț", "Ş", "Ţ"]

    // MARK: - Termeni

    /// Litere mici, fara diacritice, fara semne si spatii: "JSON-ul," -> "jsonul", "/hau-di" -> "haudi".
    public static func key(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "ro_RO"))
        return String(folded.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(Character.init))
    }

    /// Terminatiile romanesti legate cu cratima de un cuvant strain: JSON-ul, commit-uri, PHP-ului, border-ele.
    static let romanianSuffixes: Set<String> = ["ul", "ului", "uri", "urile", "urilor", "ii", "iei", "ilor", "ele", "elor",
                                                "le", "lor", "lui", "ul-ul"]

    /// "JSON-ul" -> ("JSON", true); "hau-di" -> ("hau-di", false).
    static func baseTerm(_ word: String) -> (term: String, stripped: Bool) {
        guard let dash = word.lastIndex(of: "-"), dash > word.startIndex else { return (word, false) }
        let suffix = word[word.index(after: dash)...].lowercased()
        guard romanianSuffixes.contains(suffix) else { return (word, false) }
        return (String(word[..<dash]), true)
    }

    static let leadingMarks: Set<Character> = ["\"", "'", "„", "“", "«", "(", "[", "{", "/"]
    static let trailingMarks: Set<Character> = [".", ",", ";", ":", "!", "?", "…", "\"", "'", "”", "»", ")", "]", "}"]

    static func trimEdges(_ text: String) -> String {
        var characters = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        while let first = characters.first, leadingMarks.contains(first) { characters = characters.dropFirst() }
        while let last = characters.last, trailingMarks.contains(last) { characters = characters.dropLast() }
        return String(characters)
    }

    /// Arata a termen (nume, acronim, cuvant englezesc), nu a cuvant romanesc obisnuit.
    static func isTermLike(_ term: String, sentenceStart: Bool) -> Bool {
        // Semne sigure: majuscula in interiorul cuvantului (JSON, GitHub), cifre, puncte si alte simboluri.
        if term.dropFirst().contains(where: \.isUppercase) { return true }
        if term.contains(where: \.isNumber) { return true }
        if term.contains(where: { "./_@#+&".contains($0) }) { return true }
        // Un cuvant cu diacritice romanesti e romanesc, chiar daca incepe cu majuscula ("Dicționar").
        if term.contains(where: { romanianLetters.contains($0) }) { return false }
        // Majuscula initiala conteaza doar in mijlocul propozitiei (Claude, Apache).
        if !sentenceStart, term.first?.isUppercase == true { return true }
        let lower = term.lowercased()
        if lower.contains(where: { "wykq".contains($0) }) { return true }
        // Litere duble si grupuri rare in romana ("cc" lipseste: accesibil, succes).
        let patterns = ["bb", "dd", "ff", "gg", "ll", "mm", "pp", "rr", "ss", "tt", "zz",
                        "th", "sh", "ck", "oo", "ee", "ph"]
        return patterns.contains { lower.contains($0) }
    }

    static func sharedPrefixLength(_ a: String, _ b: String) -> Int {
        zip(a, b).prefix { $0 == $1 }.count
    }

    /// Cuvinte de legatura si foarte uzuale (fara diacritice): nu sunt termeni de dictionar.
    static let stopwords: Set<String> = [
        "si", "sa", "ca", "de", "la", "in", "cu", "pe", "din", "pentru", "care", "ce", "nu", "e", "este", "sunt", "o",
        "un", "una", "unui", "unei", "al", "ai", "ale", "a", "am", "au", "ar", "as", "eu", "tu", "el", "ea", "noi", "voi",
        "ei", "ele", "mai", "dar", "sau", "ori", "daca", "cand", "cum", "unde", "asa", "acum", "aici", "acolo", "fie",
        "va", "vor", "fi", "fost", "doar", "tot", "toate", "toti", "foarte", "deci", "iar", "ne", "te", "se", "il", "le",
        "li", "mi", "ti", "imi", "iti", "isi", "lui", "lor", "asta", "acesta", "aceasta", "ala", "aia", "ii", "nici",
        "prin", "spre", "dupa", "sub", "peste", "intre", "catre", "pana", "decat", "da", "nu", "ok", "the", "an", "to",
        "of", "and", "or", "is", "it", "on", "for", "etc",
    ]

    // MARK: - Diferenta pe cuvinte

    /// Blocurile in care cele doua texte difera (ambele parti nevide), dupa cea mai lunga subsecventa comuna de chei.
    static func replacements(heard: [String], written: [String]) -> [(heard: Range<Int>, written: Range<Int>)] {
        let n = heard.count
        let m = written.count
        guard n > 0, m > 0 else { return [] }
        // lcs[i][j] = lungimea celei mai lungi subsecvente comune pentru heard[i...] si written[j...]
        var lcs = Array(repeating: Array(repeating: 0, count: m + 1), count: n + 1)
        for i in stride(from: n - 1, through: 0, by: -1) {
            for j in stride(from: m - 1, through: 0, by: -1) {
                lcs[i][j] = heard[i] == written[j] ? lcs[i + 1][j + 1] + 1 : max(lcs[i + 1][j], lcs[i][j + 1])
            }
        }
        var blocks: [(heard: Range<Int>, written: Range<Int>)] = []
        var i = 0
        var j = 0
        var startI = 0
        var startJ = 0
        func close() {
            if i > startI, j > startJ { blocks.append((startI..<i, startJ..<j)) }
        }
        while i < n, j < m {
            if heard[i] == written[j] {
                close()
                i += 1
                j += 1
                startI = i
                startJ = j
            } else if lcs[i + 1][j] >= lcs[i][j + 1] {
                i += 1
            } else {
                j += 1
            }
        }
        i = n
        j = m
        close()
        return blocks
    }
}
