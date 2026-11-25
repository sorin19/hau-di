import Foundation

/// Splits a long recording into pieces that Whisper can transcribe whole.
///
/// Whisper (in WhisperKit 1.1) writes the text of each piece of audio into a context of 224 tokens, which also holds
/// the dictionary prompt. When a piece holds more speech than fits, the text simply stops, mid-sentence, and the rest
/// of the piece is lost. So pieces are kept short enough for the tokens left after the prompt, and each one ends in
/// the longest pause available (usually between sentences or phrases), never right at the limit.
///
/// Each piece is transcribed on its own: Whisper doesn't see the text of the piece before it (WhisperKit's own
/// split didn't pass it on either). Cutting in the longest pause keeps sentences whole as often as possible.
public enum AudioSplitter {
    /// Text tokens of a fast, continuous dictation, per second of audio. Measured on real dictations in Romanian:
    /// 3.2 on average, 4.2 for the fastest tenth, 5.6 at most over a whole dictation.
    public static let tokensPerSecond = 6.0
    /// A piece is never longer than one Whisper window (30 s), with a margin.
    public static let longestPiece = 28.0
    /// Nor shorter than this, except for a recording that is short as a whole: WhisperKit doesn't decode a piece
    /// shorter than a second at all, and very short pieces tend to produce made-up text.
    public static let shortestPiece = 2.0
    /// Loudness is measured over frames this long...
    static let frameSeconds = 0.03
    /// ...this far apart, which are also the candidate cut points.
    static let searchStep = 0.01

    /// WhisperKit 1.1 stops a piece's text when the context reaches 223 tokens: <|startofprev|> and the prompt
    /// (only if there is one), 4 special tokens (start of transcript, language, task, no timestamps), then the text.
    public static func textTokens(promptTokens: Int) -> Int {
        223 - 4 - (promptTokens > 0 ? 1 + promptTokens : 0)
    }

    /// The longest piece whose speech still fits in the given number of text tokens (between 10 s and longestPiece).
    public static func maxPieceSeconds(textTokens: Int) -> Double {
        min(longestPiece, max(10, Double(textTokens) / tokensPerSecond))
    }

    /// The pieces, as ranges of samples: in order, without gaps or overlaps, each at most maxSeconds long.
    /// A recording that fits stays whole.
    public static func split(_ samples: [Float], maxSeconds: Double, sampleRate: Int = 16_000) -> [Range<Int>] {
        let shortest = Int(shortestPiece * Double(sampleRate))
        let longest = max(Int(maxSeconds * Double(sampleRate)), 2 * shortest)
        var pieces: [Range<Int>] = []
        var start = 0
        while samples.count - start > longest {
            // As few pieces as possible: after the cut, the remaining pieces must still be able to hold the rest.
            // No piece shorter than shortestPiece. Within those bounds, the longest pause.
            let piecesAfter = (samples.count - start + longest - 1) / longest - 1
            let lower = max(start + shortest, samples.count - piecesAfter * longest)
            let upper = min(start + longest, samples.count - shortest)
            let cut = cutPoint(in: samples, from: lower, to: upper, sampleRate: sampleRate)
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<samples.count)
        return pieces
    }

    /// The piece cut in two at the longest pause in its middle half; nil if a half would be shorter than shortestPiece.
    public static func halves(_ samples: [Float], sampleRate: Int = 16_000) -> [Range<Int>]? {
        let shortest = Int(shortestPiece * Double(sampleRate))
        guard samples.count >= 2 * shortest else { return nil }
        let cut = cutPoint(in: samples, from: max(shortest, samples.count / 4),
                           to: min(samples.count - shortest, samples.count * 3 / 4), sampleRate: sampleRate)
        return [0..<cut, cut..<samples.count]
    }

    /// Where to cut between lower and upper (both included): in the middle of the longest pause. A pause is a run of
    /// frames no louder than the threshold below; among equally long pauses, the last one, so that pieces stay as
    /// long as allowed. Without any pause (continuous speech), the quietest moment.
    static func cutPoint(in samples: [Float], from lower: Int, to upper: Int, sampleRate: Int) -> Int {
        guard lower < upper else { return lower }
        let half = max(1, Int(frameSeconds * Double(sampleRate)) / 2)
        let step = max(1, Int(searchStep * Double(sampleRate)))
        // Running sums of squares over [lower - half, upper + half), so each frame costs two lookups.
        let base = max(0, lower - half)
        let end = min(samples.count, upper + half)
        var sums = [Double](repeating: 0, count: end - base + 1)
        for index in base..<end {
            let sample = Double(samples[index])
            sums[index - base + 1] = sums[index - base] + sample * sample
        }
        var centers: [Int] = []
        var levels: [Double] = [] // RMS of the frame around each center
        var center = lower
        while center <= upper {
            let from = max(base, center - half)
            let to = min(end, center + half)
            centers.append(center)
            levels.append(((sums[to - base] - sums[from - base]) / Double(max(1, to - from))).squareRoot())
            center = center == upper ? upper + 1 : min(center + step, upper)
        }

        // Quiet: at most 10 dB above the background (the quietest tenth of the frames) and at most 30% of the speech
        // level (the loudest tenth), so that the quietest moments of continuous speech still count; never below
        // -60 dBFS, nor below the quietest frame.
        let sorted = levels.sorted()
        let background = sorted[sorted.count / 10]
        let speech = sorted[sorted.count * 9 / 10]
        let threshold = max(min(background * 3.16, speech * 0.3), 0.001, sorted[0])

        var best = (start: 0, length: 0)
        var runStart = 0
        for (index, level) in levels.enumerated() {
            if level > threshold {
                runStart = index + 1
            } else if index - runStart + 1 >= best.length {
                best = (runStart, index - runStart + 1)
            }
        }
        return centers[best.start + (best.length - 1) / 2]
    }
}
