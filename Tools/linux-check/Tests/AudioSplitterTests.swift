import XCTest
@testable import HauDiCore

final class AudioSplitterTests: XCTestCase {
    private let rate = 16_000

    /// "Speech" (a loud tone with a little variation) for the given seconds, with pauses (silence) at the given times.
    private func speech(seconds: Double, pauses: [(at: Double, length: Double)] = [], floor: Float = 0) -> [Float] {
        var samples = (0..<Int(seconds * Double(rate))).map { index -> Float in
            let t = Float(index) / Float(rate)
            return 0.3 * sin(2 * .pi * 220 * t) * (0.8 + 0.2 * sin(2 * .pi * 3 * t))
        }
        for pause in pauses {
            let from = Int(pause.at * Double(rate))
            let to = min(samples.count, from + Int(pause.length * Double(rate)))
            for index in from..<to { samples[index] = floor * sin(Float(index)) }
        }
        return samples
    }

    private func seconds(_ sample: Int) -> Double { Double(sample) / Double(rate) }

    private func assertCoversEverything(_ pieces: [Range<Int>], count: Int, maxSeconds: Double,
                                        file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(pieces.first?.lowerBound, 0, file: file, line: line)
        XCTAssertEqual(pieces.last?.upperBound, count, file: file, line: line)
        for (previous, next) in zip(pieces, pieces.dropFirst()) {
            XCTAssertEqual(previous.upperBound, next.lowerBound, "no gaps, no overlaps", file: file, line: line)
        }
        for piece in pieces {
            XCTAssertLessThanOrEqual(seconds(piece.count), maxSeconds + 0.001, file: file, line: line)
            XCTAssertGreaterThanOrEqual(seconds(piece.count), AudioSplitter.shortestPiece, file: file, line: line)
        }
    }

    func testTokenBudgetAndPieceLength() {
        XCTAssertEqual(AudioSplitter.textTokens(promptTokens: 0), 219)
        XCTAssertEqual(AudioSplitter.textTokens(promptTokens: 111), 107, "a full dictionary leaves 107 tokens for the text")
        XCTAssertEqual(AudioSplitter.maxPieceSeconds(textTokens: 107), 107.0 / 6, accuracy: 0.001)
        XCTAssertEqual(AudioSplitter.maxPieceSeconds(textTokens: 219), 28, "never longer than one window")
        XCTAssertEqual(AudioSplitter.maxPieceSeconds(textTokens: 20), 10)
    }

    func testShortRecordingStaysWhole() {
        let samples = speech(seconds: 17)
        XCTAssertEqual(AudioSplitter.split(samples, maxSeconds: 17.8), [0..<samples.count])
        XCTAssertEqual(AudioSplitter.split([], maxSeconds: 17.8), [0..<0])
    }

    func testCutsInThePauses() {
        // 40 s of continuous dictation with short pauses (0.3 s): 3 pieces (the fewest), each cut inside a pause.
        let pauses: [(at: Double, length: Double)] = [(4, 0.3), (11.2, 0.3), (15.5, 0.3), (24.1, 0.3), (31, 0.3), (37, 0.3)]
        let samples = speech(seconds: 40, pauses: pauses)
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        assertCoversEverything(pieces, count: samples.count, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 3)
        for cut in pieces.dropLast().map(\.upperBound) {
            let at = seconds(cut)
            XCTAssertTrue(pauses.contains { at > $0.at && at < $0.at + $0.length }, "cut at \(at) s is not in a pause")
        }
    }

    func testPrefersTheLongestPause() {
        // A sentence end (0.6 s) and, later, a short pause between words (0.25 s): the cut goes in the sentence end.
        let samples = speech(seconds: 26, pauses: [(10, 0.6), (16, 0.25)], floor: 0.002)
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        assertCoversEverything(pieces, count: samples.count, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(seconds(pieces[0].upperBound), 10.3, accuracy: 0.03)
    }

    func testKeepsTheFewestPieces() {
        // Cutting at the long pause (10 s) would leave 20 s, which needs two more pieces: the short pause it is.
        let samples = speech(seconds: 30, pauses: [(10, 0.6), (16, 0.25)], floor: 0.002)
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        assertCoversEverything(pieces, count: samples.count, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(seconds(pieces[0].upperBound), 16.125, accuracy: 0.03)
    }

    func testPausesInANoisyRoom() {
        // Background noise everywhere (about -37 dBFS); the pauses are only noise, the longer one wins.
        var samples = speech(seconds: 30, pauses: [(13, 0.3), (15, 0.5)], floor: 0.02)
        for index in samples.indices { samples[index] += 0.02 * sin(Float(index) * 1.7) }
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(seconds(pieces[0].upperBound), 15.25, accuracy: 0.03)
    }

    func testWithoutPausesCutsAtTheQuietestMoment() {
        // No silence at all, just a moment (14.3-14.5 s) that is quieter than the rest.
        var samples = speech(seconds: 30)
        let quiet = Int(14.3 * Double(rate))
        for index in quiet..<(quiet + 3_200) { samples[index] *= 0.05 }
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        assertCoversEverything(pieces, count: samples.count, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertEqual(seconds(pieces[0].upperBound), 14.4, accuracy: 0.02)
    }

    func testNeverLeavesATinyLastPiece() {
        // 18.5 s with a pause near the end: cutting there would leave a piece of about one second.
        let samples = speech(seconds: 18.5, pauses: [(9.5, 0.3), (17.0, 0.4)])
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        assertCoversEverything(pieces, count: samples.count, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 2)
        XCTAssertTrue((9.5...9.8).contains(seconds(pieces[0].upperBound)), "the pause at 17 s is too close to the end")
    }

    func testLongDictationIsCutIntoPiecesThatFit() {
        let samples = speech(seconds: 137, pauses: stride(from: 3.0, to: 137, by: 5.5).map { ($0, 0.25) })
        let pieces = AudioSplitter.split(samples, maxSeconds: 17.8)
        assertCoversEverything(pieces, count: samples.count, maxSeconds: 17.8)
        XCTAssertEqual(pieces.count, 8, "ceil(137 / 17.8)")
    }

    func testHalves() {
        let samples = speech(seconds: 16, pauses: [(3, 0.3), (7.4, 0.3), (14.5, 0.3)])
        let halves = AudioSplitter.halves(samples)
        XCTAssertEqual(halves?.count, 2)
        XCTAssertEqual(halves?.first?.lowerBound, 0)
        XCTAssertEqual(halves?.last?.upperBound, samples.count)
        XCTAssertEqual(halves?.first?.upperBound, halves?.last?.lowerBound)
        XCTAssertTrue((7.4...7.7).contains(seconds(halves?.first?.upperBound ?? 0)), "the pause in the middle half")
        XCTAssertNil(AudioSplitter.halves(speech(seconds: 3.9)), "halves shorter than 2 s are not made")
        XCTAssertEqual(AudioSplitter.halves(speech(seconds: 4))?.first?.count, 2 * rate)
    }
}
