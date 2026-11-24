import XCTest
@testable import HauDiCore

final class WordConfidenceTests: XCTestCase {
    private func piece(_ text: String, _ logProbs: Float...) -> TokenPiece {
        TokenPiece(text: text, logProbs: logProbs)
    }

    private func word(_ text: String, _ probability: Double) -> TranscribedWord {
        TranscribedWord(text: text, probability: probability)
    }

    func testGroupsPiecesIntoWordsBySpace() {
        let words = WordConfidence.words(from: [
            piece(" Am", -0.02), piece(" fa", -0.1), piece("cut", -0.05), piece(" JSON", -0.2), piece("-", -0.4),
            piece("ul", -0.3),
        ])
        XCTAssertEqual(words.map(\.text), [" Am", " facut", " JSON-ul"])
        XCTAssertEqual(words[0].probability, 0.98, accuracy: 0.001)
        XCTAssertEqual(words[1].probability, (exp(-0.075) * 1000).rounded() / 1000)
        XCTAssertEqual(words[2].probability, (exp(-0.3) * 1000).rounded() / 1000)
    }

    func testEdgePunctuationDoesNotLowerTheWord() {
        // An unsure comma or period does not make the word unsure.
        let words = WordConfidence.words(from: [piece(" gata", -0.1), piece(".", -3), piece(" (", -2), piece("ok", -0.2),
                                                piece(")", -2)])
        XCTAssertEqual(words.map(\.text), [" gata.", " (ok)"])
        XCTAssertEqual(words[0].probability, (exp(-0.1) * 1000).rounded() / 1000)
        XCTAssertEqual(words[1].probability, (exp(-0.2) * 1000).rounded() / 1000)
    }

    func testLeadingDotBelongsToTheWord() {
        let words = WordConfidence.words(from: [piece(" .", -1), piece("ht", -0.5), piece("access", -0.3)])
        XCTAssertEqual(words.map(\.text), [" .htaccess"])
        XCTAssertEqual(words[0].probability, (exp(-0.6) * 1000).rounded() / 1000)
    }

    func testPunctuationOnlyAndEmptyPieces() {
        let words = WordConfidence.words(from: [piece("", -9), piece(" ,", -2), piece(" x")])
        XCTAssertEqual(words.map(\.text), [" ,", " x"])
        XCTAssertEqual(words[0].probability, (exp(-2) * 1000).rounded() / 1000)
        XCTAssertEqual(words[1].probability, 1, "without log-probabilities we do not mark the word")
    }

    func testFirstPieceWithoutSpaceStartsAWord() {
        let words = WordConfidence.words(from: [piece("Am", -0.1), piece(" zis", -0.1)])
        XCTAssertEqual(words.map(\.text), ["Am", " zis"])
    }

    func testJoinedSegmentsKeepASpaceBetweenThem() {
        let joined = WordConfidence.joined([[word(" Am", 0.9)], [word("doi", 0.8), word(" trei", 0.7)], []])
        XCTAssertEqual(joined.map(\.text), [" Am", " doi", " trei"])
        XCTAssertEqual(WordConfidence.joined([[word("Unu", 0.9)]]).map(\.text), ["Unu"])
    }

    func testMarkedTextGroupsUnsureWordsAndKeepsPunctuationOutside() {
        let words = [word(" Am", 0.98), word(" facut", 0.95), word(" diploi", 0.31), word(" pe", 0.97),
                     word(" hashtag", 0.22), word(" accesul.", 0.18), word(" Trimit", 0.9), word(" la", 0.99),
                     word(" Audi,", 0.41), word(" gata.", 0.9)]
        XCTAssertEqual(WordConfidence.marked(words),
                       "Am facut ⟦diploi⟧ pe ⟦hashtag accesul⟧. Trimit la ⟦Audi⟧, gata.")
        XCTAssertEqual(WordConfidence.unsureCount(words), 4)
        XCTAssertEqual(WordConfidence.marked(words, threshold: 0.2), "Am facut diploi pe hashtag ⟦accesul⟧. Trimit la Audi, gata.")
    }

    func testMarkedTextQuotesAndDotfiles() {
        XCTAssertEqual(WordConfidence.marked([word(" „Audi”", 0.3)]), "„⟦Audi⟧”")
        XCTAssertEqual(WordConfidence.marked([word(" am", 0.9), word(" .htaccess", 0.4)]), "am ⟦.htaccess⟧")
        XCTAssertEqual(WordConfidence.marked([word(" ...", 0.1), word(" ok", 0.9)]), "... ok")
        XCTAssertEqual(WordConfidence.marked([]), "")
    }

    func testUncertainWordsPromptSectionOnlyWhenEnabled() {
        let off = CorrectionPrompt.systemPrompt(config: CorrectionConfig())
        let on = CorrectionPrompt.systemPrompt(config: CorrectionConfig(marksUncertainWords: true))
        XCTAssertFalse(off.contains("unsure about"))
        XCTAssertTrue(on.contains("## Words the recognizer was unsure about"))
        XCTAssertTrue(on.contains("la ⟦Audi⟧"))
        XCTAssertTrue(on.hasSuffix(off.components(separatedBy: "\n\n").last!), "the output section stays last")
        XCTAssertEqual(WordConfidence.stripMarkers("am ⟦trimis⟧ la ⟦Audi⟧."), "am trimis la Audi.")
    }

    func testSummaryForCSV() {
        XCTAssertEqual(WordConfidence.summary([word(" Am", 0.981), word(" facut,", 0.304)]), "Am:98 facut,:30")
    }

    func testHistoryKeepsWordsAndReadsOldEntries() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let entry = HistoryEntry(appName: nil, rawText: "Am facut", finalText: "Am facut", engine: "whisper",
                                 correctedBy: nil, audioDuration: 1, transcriptionTime: 0.2, correctionTime: nil,
                                 note: nil, words: [word(" Am", 0.98), word(" facut", 0.31)])
        let data = try encoder.encode(entry)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"words\":[{\"p\":0.98,\"w\":\" Am\"}") || json.contains("{\"w\":\" Am\",\"p\":0.98}"), json)
        XCTAssertEqual(try decoder.decode(HistoryEntry.self, from: data).words, entry.words)

        var old = entry
        old.words = nil
        let oldJSON = try encoder.encode(old)
        XCTAssertFalse(String(decoding: oldJSON, as: UTF8.self).contains("words"))
        XCTAssertNil(try decoder.decode(HistoryEntry.self, from: oldJSON).words)

        let csv = HistoryCSV.make([entry, old])
        let lines = csv.split(separator: "\n")
        XCTAssertTrue(lines[0].hasSuffix(",note,raw_text_marked,word_probabilities"))
        XCTAssertTrue(lines[1].hasSuffix(",Am ⟦facut⟧,Am:98 facut:31"), String(lines[1]))
        XCTAssertTrue(lines[2].hasSuffix(",,"), String(lines[2]))
    }
}
