import Foundation

/// Splits a long recording into pieces that Whisper can transcribe whole.
///
/// Whisper (in WhisperKit 1.1) writes the text of each piece of audio into a context of 224 tokens, which also holds
/// the dictionary prompt. When a piece holds more speech than fits, the text simply stops, mid-sentence, and the rest
/// of the piece is lost. So pieces are kept short enough for the tokens left after the prompt, and each one ends in
/// the quietest moment available (a pause between words), never right at the limit.
public enum AudioSplitter {
    /// Text tokens of a fast, continuous dictation, per second of audio. Measured on real dictations in Romanian:
    /// 3.2 on average, 4.2 for the fastest tenth, 5.6 at most over a whole dictation.
    public static let tokensPerSecond = 6.0
    /// A piece is never longer than one Whisper window (30 s), with a margin.
    public static let longestPiece = 28.0
    /// Nor shorter than this, except for a recording that is short as a whole: WhisperKit doesn't decode a piece
    /// shorter than a second at all, and very short pieces tend to produce made-up text.
    public static let shortestPiece = 2.0
    /// When looking for a pause, loudness is averaged over this long.
    static let pauseWindow = 0.2
    /// Candidate cut points are this far apart.
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
            // The cut goes in the second half of the longest possible piece, and what is left after it is never
            // shorter than shortestPiece.
            let cut = quietestPoint(in: samples, from: start + longest / 2,
                                    to: min(start + longest, samples.count - shortest), sampleRate: sampleRate)
            pieces.append(start..<cut)
            start = cut
        }
        pieces.append(start..<samples.count)
        return pieces
    }

    /// The piece cut in two at its quietest point in the middle half; nil if a half would be shorter than shortestPiece.
    public static func halves(_ samples: [Float], sampleRate: Int = 16_000) -> [Range<Int>]? {
        let shortest = Int(shortestPiece * Double(sampleRate))
        guard samples.count >= 2 * shortest else { return nil }
        let cut = quietestPoint(in: samples, from: max(shortest, samples.count / 4),
                                to: min(samples.count - shortest, samples.count * 3 / 4), sampleRate: sampleRate)
        return [0..<cut, cut..<samples.count]
    }

    /// The middle of the quietest pauseWindow centered between lower and upper (both included). If several are
    /// equally quiet, the last one, so that pieces stay as long as allowed.
    static func quietestPoint(in samples: [Float], from lower: Int, to upper: Int, sampleRate: Int) -> Int {
        guard lower < upper else { return lower }
        let half = max(1, Int(pauseWindow * Double(sampleRate)) / 2)
        let step = max(1, Int(searchStep * Double(sampleRate)))
        // Running sums of squares over [lower - half, upper + half), so each window costs two lookups.
        let base = max(0, lower - half)
        let end = min(samples.count, upper + half)
        var sums = [Double](repeating: 0, count: end - base + 1)
        for index in base..<end {
            let sample = Double(samples[index])
            sums[index - base + 1] = sums[index - base] + sample * sample
        }
        var best = lower
        var bestEnergy = Double.infinity
        var center = lower
        while center <= upper {
            let from = max(base, center - half)
            let to = min(end, center + half)
            let energy = (sums[to - base] - sums[from - base]) / Double(max(1, to - from))
            if energy <= bestEnergy {
                best = center
                bestEnergy = energy
            }
            center = center == upper ? upper + 1 : min(center + step, upper)
        }
        return best
    }
}
