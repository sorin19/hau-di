import SwiftUI

/// What Whisper heard in the last dictation: each word with its probability (how confident the model was).
/// For diagnostics only: the probabilities are not sent to Claude (the A/B test of 2026-11-24 showed no gain).
struct WhisperWordsView: View {
    let entry: HistoryEntry?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let words = entry?.words, !words.isEmpty {
                content(words)
            } else {
                Text("After a dictation, the words Whisper heard appear here, each with its probability.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func content(_ words: [TranscribedWord]) -> some View {
        let unsure = WordConfidence.unsureCount(words)
        let average = words.map(\.probability).reduce(0, +) / Double(words.count)
        let stats = "\(unsure) of \(words.count) words below \(Self.percent(WordConfidence.threshold)); average \(Self.percent(average))."

        HStack(alignment: .firstTextBaseline) {
            Text(stats)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            legend
        }

        ChipFlowLayout(spacing: 4, lineSpacing: 4) {
            ForEach(Array(words.enumerated()), id: \.offset) { _, word in
                WordChip(word: word)
            }
        }

        Text("The percentage shows how sure Whisper was of each word. A term it gets wrong (even with a high percentage) is worth adding to the Dictionary, where you'll also find suggestions from your dictations.")
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var legend: some View {
        HStack(spacing: 10) {
            swatch(WordChip.tint(for: 0), "below 50%")
            swatch(WordChip.tint(for: 0.6), "50-80%")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 4) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 10, height: 10)
            Text(label)
        }
    }

    static func percent(_ value: Double) -> String {
        "\(Int((value * 100).rounded()))%"
    }
}

/// A word with its percentage below it; red background under 50%, orange under 80%.
private struct WordChip: View {
    let word: TranscribedWord

    var body: some View {
        VStack(spacing: 1) {
            Text(word.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(.callout)
            Text(WhisperWordsView.percent(word.probability))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 3)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Self.tint(for: word.probability))
        )
        .help(String(format: "%.1f%%", word.probability * 100))
    }

    static func tint(for probability: Double) -> Color {
        if probability < WordConfidence.threshold { return Color.red.opacity(0.28) }
        if probability < 0.8 { return Color.orange.opacity(0.25) }
        return Color.primary.opacity(0.06)
    }
}
