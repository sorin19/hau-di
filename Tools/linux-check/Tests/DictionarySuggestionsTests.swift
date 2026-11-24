import XCTest
@testable import HauDiCore

final class DictionarySuggestionsTests: XCTestCase {
    private func entry(_ raw: String, _ final: String, date: Date = Date(timeIntervalSince1970: 1_795_000_000),
                       corrected: Bool = true, words: [TranscribedWord]? = nil) -> HistoryEntry {
        HistoryEntry(date: date, appName: nil, rawText: raw, finalText: final, engine: "whisper",
                     correctedBy: corrected ? "claude-opus-5-5" : nil, audioDuration: 2, transcriptionTime: 0.3,
                     correctionTime: corrected ? 1 : nil, note: nil, words: words)
    }

    private func terms(_ entries: [HistoryEntry], ignoring: Set<String> = []) -> [String] {
        DictionarySuggestions.compute(from: entries, ignoring: ignoring).map(\.term)
    }

    func testClaudeCorrectionBecomesSuggestion() {
        let list = DictionarySuggestions.compute(from: [
            entry("am trimis la clod textul", "Am trimis la Claude textul."),
            entry("corectarea prin Cloud a mers", "Corectarea prin Claude a mers."),
        ])
        XCTAssertEqual(list.map(\.term), ["Claude"])
        XCTAssertEqual(list[0].count, 2)
        XCTAssertEqual(Set(list[0].heard.map(\.text)), ["clod", "Cloud"])
        XCTAssertNil(list[0].averageProbability)
    }

    func testRomanianSuffixIsStripped() {
        XCTAssertEqual(terms([entry("jussonul e gata", "JSON-ul e gata.")]), ["JSON"])
        // Aceleasi litere, doar majuscule si cratima: Claude o repara oricum, nu e nimic de invatat.
        XCTAssertEqual(terms([entry("jsonul e gata", "JSON-ul e gata.")]), [])
        XCTAssertEqual(terms([entry("cu bordă-ul ăla", "cu border-ul ăla")]), ["border"])
        XCTAssertEqual(DictionarySuggestions.baseTerm("commit-urile").term, "commit")
        XCTAssertEqual(DictionarySuggestions.baseTerm("hau-di").term, "hau-di")
    }

    func testGrammarFixesAreNotSuggested() {
        XCTAssertEqual(terms([entry("știu că eu ținem aici să facem așa", "Știu că eu ți-am zis să faci așa.")]), [])
        XCTAssertEqual(terms([entry("in diccionar am pus", "În Dicționar am pus")]), [])
        // Doar majuscule, diacritice sau punctuatie diferite: nimic de invatat.
        XCTAssertEqual(terms([entry("deci github e ok", "Deci GitHub e OK.")]), [])
    }

    func testPlainWordsNeedToRepeat() {
        let once = entry("fac pomptul acum", "Fac promptul acum.")
        XCTAssertEqual(terms([once]), [])
        XCTAssertEqual(terms([once, entry("si pontul e bun", "Și promptul e bun.")]), ["promptul"])
    }

    func testMultiWordCorrectionKeepsOnlyTerms() {
        XCTAssertEqual(terms([entry("e accesibil.htacces si nu", "e accesibil .htaccess și nu")]), [".htaccess"])
        XCTAssertEqual(Set(terms([entry("modelele HI cu sonet merg", "modelele Haiku, Sonnet merg")])), ["Haiku", "Sonnet"])
        XCTAssertEqual(terms([entry("de la CIP vine", "de la ce IP vine")]), ["IP"])
    }

    func testSameWordCountPairsWordByWord() {
        let list = terms([entry("setez KH1, KH-mod-ul pentru tot", "setez chown-ul, chmod-ul pentru tot")])
        XCTAssertEqual(Set(list), ["chown", "chmod"])
    }

    func testIgnoredUncorrectedAndNewestForm() {
        let old = Date(timeIntervalSince1970: 1_794_000_000)
        let new = Date(timeIntervalSince1970: 1_795_000_000)
        let entries = [
            entry("la audi merge", "la Haudi merge", date: old),
            entry("la audi merge", "la Haudi merge", date: old),
            entry("pentru howdy acum", "pentru hau-di acum", date: new),
            entry("la clod", "la clod", corrected: false),
        ]
        XCTAssertEqual(terms(entries), ["hau-di"], "forma cea mai noua, nu cea mai deasa")
        XCTAssertEqual(terms(entries, ignoring: ["haudi"]), [])
    }

    func testAverageProbabilityFromWords() {
        let words = [TranscribedWord(text: " am", probability: 0.98), TranscribedWord(text: " zis", probability: 0.9),
                     TranscribedWord(text: " Ritmii", probability: 0.61)]
        let list = DictionarySuggestions.compute(from: [entry("am zis Ritmii", "Am zis README.", words: words)])
        XCTAssertEqual(list.map(\.term), ["README"])
        XCTAssertEqual(list[0].averageProbability ?? 0, 0.61, accuracy: 0.0001)
    }

    func testReplacementBlocks() {
        let blocks = DictionarySuggestions.replacements(heard: ["a", "b", "x", "d", "y", "z"], written: ["a", "b", "c", "d"])
        XCTAssertEqual(blocks.map { [$0.heard.lowerBound, $0.heard.upperBound, $0.written.lowerBound, $0.written.upperBound] },
                       [[2, 3, 2, 3]], "doar inlocuirile cu ambele parti nevide")
        XCTAssertEqual(DictionarySuggestions.key("JSON-ul,"), "jsonul")
        XCTAssertEqual(DictionarySuggestions.key("Ștefănescu"), "stefanescu")
    }
}
