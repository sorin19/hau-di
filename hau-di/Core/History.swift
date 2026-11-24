import Foundation

public struct HistoryEntry: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var date: Date
    /// The app and window where the dictation started (the text is also inserted there).
    public var appName: String?
    public var windowTitle: String?
    public var rawText: String
    public var finalText: String
    public var engine: String
    public var correctedBy: String?
    public var audioDuration: Double
    public var transcriptionTime: Double
    public var correctionTime: Double?
    public var note: String?
    /// Tokens and cost of the Claude correction (nil if Claude was not called).
    public var usage: CorrectionUsage?
    /// The words of the Whisper transcript, each with its probability (nil for older entries).
    public var words: [TranscribedWord]?

    public init(id: UUID = UUID(), date: Date = Date(), appName: String?, rawText: String, finalText: String,
                engine: String, correctedBy: String?, audioDuration: Double, transcriptionTime: Double,
                correctionTime: Double?, note: String?, usage: CorrectionUsage? = nil, windowTitle: String? = nil,
                words: [TranscribedWord]? = nil) {
        self.id = id
        self.date = date
        self.appName = appName
        self.windowTitle = windowTitle
        self.rawText = rawText
        self.finalText = finalText
        self.engine = engine
        self.correctedBy = correctedBy
        self.audioDuration = audioDuration
        self.transcriptionTime = transcriptionTime
        self.correctionTime = correctionTime
        self.note = note
        self.usage = usage
        self.words = words
    }

    public var costUSD: Double? { usage?.costUSD }
}

/// Summary of a history selection (for the date range filters).
public struct HistorySummary: Equatable, Sendable {
    public var count: Int
    public var correctedCount: Int
    public var totalCostUSD: Double
    public var inputTokens: Int
    public var outputTokens: Int

    public init(entries: [HistoryEntry]) {
        count = entries.count
        correctedCount = entries.filter { $0.usage != nil }.count
        totalCostUSD = entries.compactMap(\.costUSD).reduce(0, +)
        inputTokens = entries.compactMap { $0.usage?.promptTokens }.reduce(0, +)
        outputTokens = entries.compactMap { $0.usage?.outputTokens }.reduce(0, +)
    }

    public var averageCostUSD: Double? {
        correctedCount > 0 ? totalCostUSD / Double(correctedCount) : nil
    }
}

extension Array where Element == HistoryEntry {
    /// The entries dated within [from, to] (inclusive).
    public func between(_ from: Date, _ to: Date) -> [HistoryEntry] {
        filter { $0.date >= from && $0.date <= to }
    }
}

/// Local history, kept for a set period (3 months by default). Newest entries first.
/// Format: JSON Lines (one entry per line). Appending writes a single line, so it stays fast
/// even with tens of thousands of entries; the file is rewritten only when old entries are pruned or on deletion.
public final class HistoryStore: @unchecked Sendable {
    public let fileURL: URL
    /// The old file (a single JSON array); it is migrated to the new format automatically.
    public let legacyFileURL: URL?
    public var retentionMonths: Int

    private let now: () -> Date
    private let lock = NSLock()
    private var cache: [HistoryEntry]?
    private var lastPrune: Date?

    public init(fileURL: URL, legacyFileURL: URL? = nil, retentionMonths: Int = 3, now: @escaping () -> Date = Date.init) {
        self.fileURL = fileURL
        self.legacyFileURL = legacyFileURL
        self.retentionMonths = retentionMonths
        self.now = now
    }

    /// Entries older than this date are deleted.
    public var cutoffDate: Date {
        Calendar(identifier: .gregorian).date(byAdding: .month, value: -retentionMonths, to: now()) ?? .distantPast
    }

    public func load() -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        return loadLocked()
    }

    @discardableResult
    public func append(_ entry: HistoryEntry) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        var entries = loadLocked()
        entries.insert(entry, at: 0)
        cache = entries
        if let line = encodeLine(entry) {
            appendToFile(line)
        }
        // Prune at most once a day, so the file is not rewritten on every dictation.
        if let lastPrune, now().timeIntervalSince(lastPrune) < 24 * 3600 { return entries }
        return pruneLocked(entries)
    }

    @discardableResult
    public func remove(id: UUID) -> [HistoryEntry] {
        lock.lock()
        defer { lock.unlock() }
        let entries = loadLocked().filter { $0.id != id }
        cache = entries
        rewriteLocked(entries)
        return entries
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        cache = []
        try? FileManager.default.removeItem(at: fileURL)
        if let legacyFileURL { try? FileManager.default.removeItem(at: legacyFileURL) }
    }

    // MARK: - Implementation

    private func loadLocked() -> [HistoryEntry] {
        if let cache { return cache }
        var entries = readLines()
        var needsRewrite = false
        if let legacy = readLegacy() {
            let known = Set(entries.map(\.id))
            entries += legacy.filter { !known.contains($0.id) }
            needsRewrite = true
        }
        entries.sort { $0.date > $1.date }
        cache = entries
        if needsRewrite {
            rewriteLocked(entries)
            if let legacyFileURL { try? FileManager.default.removeItem(at: legacyFileURL) }
        }
        return pruneLocked(entries)
    }

    private func pruneLocked(_ entries: [HistoryEntry]) -> [HistoryEntry] {
        lastPrune = now()
        let cutoff = cutoffDate
        guard entries.contains(where: { $0.date < cutoff }) else { return entries }
        let kept = entries.filter { $0.date >= cutoff }
        cache = kept
        rewriteLocked(kept)
        return kept
    }

    private func readLines() -> [HistoryEntry] {
        guard let data = try? Data(contentsOf: fileURL), let text = String(data: data, encoding: .utf8) else { return [] }
        let decoder = Self.makeDecoder()
        var result: [HistoryEntry] = []
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            // A corrupt line (e.g. an interrupted write) is skipped; it does not break the rest of the history.
            if let entry = try? decoder.decode(HistoryEntry.self, from: Data(line.utf8)) {
                result.append(entry)
            }
        }
        return result
    }

    private func readLegacy() -> [HistoryEntry]? {
        guard let legacyFileURL, let data = try? Data(contentsOf: legacyFileURL) else { return nil }
        return (try? Self.makeDecoder().decode([HistoryEntry].self, from: data)) ?? []
    }

    private func encodeLine(_ entry: HistoryEntry) -> Data? {
        guard var data = try? Self.makeEncoder().encode(entry) else { return nil }
        data.append(0x0A)
        return data
    }

    private func appendToFile(_ line: Data) {
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !FileManager.default.fileExists(atPath: fileURL.path) {
                try line.write(to: fileURL, options: .atomic)
                return
            }
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            _ = try handle.seekToEnd()
            try handle.write(contentsOf: line)
        } catch {
            // The history is optional: a write error does not stop the dictation flow.
        }
    }

    private func rewriteLocked(_ entries: [HistoryEntry]) {
        var data = Data()
        for entry in entries.reversed() { // in the file: oldest first, as when appending
            if let line = encodeLine(entry) { data.append(line) }
        }
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } catch {
            // see appendToFile
        }
    }

    private static func makeEncoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return encoder
    }

    private static func makeDecoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// CSV export (opens directly in Excel / Numbers).
public enum HistoryCSV {
    public static func make(_ entries: [HistoryEntry]) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = TimeZone.current
        var rows = ["date,app,window,model,cost_usd,input_tokens,cache_read_tokens,cache_write_tokens,output_tokens,"
            + "fast_mode,audio_s,transcription_s,correction_s,engine,raw_text,final_text,note,"
            + "raw_text_marked,word_probabilities"]
        for entry in entries {
            let usage = entry.usage
            let fields: [String] = [
                formatter.string(from: entry.date),
                entry.appName ?? "",
                entry.windowTitle ?? "",
                usage?.model ?? entry.correctedBy ?? "",
                usage?.costUSD.map { String(format: "%.6f", $0) } ?? "",
                usage.map { String($0.inputTokens) } ?? "",
                usage.map { String($0.cacheReadTokens) } ?? "",
                usage.map { String($0.cacheWriteTokens) } ?? "",
                usage.map { String($0.outputTokens) } ?? "",
                usage.map { $0.fastMode ? "yes" : "no" } ?? "",
                String(format: "%.2f", entry.audioDuration),
                String(format: "%.2f", entry.transcriptionTime),
                entry.correctionTime.map { String(format: "%.2f", $0) } ?? "",
                entry.engine,
                entry.rawText,
                entry.finalText,
                entry.note ?? "",
                // Words under 50% between ⟦ and ⟧, then every word with its percentage ("Am:98 facut:95").
                entry.words.map { WordConfidence.marked($0) } ?? "",
                entry.words.map { WordConfidence.summary($0) } ?? "",
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n") + "\n"
    }

    static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" || $0 == "\r" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}

/// Predefined ranges for the history filter.
/// The history ranges (no calendar): today, this week, this month, all.
public enum HistoryRange: String, CaseIterable, Identifiable, Sendable {
    case today, thisWeek, thisMonth, all

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .today: return "Today"
        case .thisWeek: return "This week"
        case .thisMonth: return "This month"
        case .all: return "All time"
        }
    }

    /// [start, end] inclusive, up to the end of the current day. The week starts on Monday, as in Romania, regardless
    /// of the Mac's settings. "All time" = all the retained history (the last 3 months), with no bounds.
    public func dates(now: Date = Date(), calendar: Calendar = .current) -> (from: Date, to: Date) {
        let startOfToday = calendar.startOfDay(for: now)
        let endOfToday = calendar.date(byAdding: DateComponents(day: 1, second: -1), to: startOfToday) ?? now
        switch self {
        case .today:
            return (startOfToday, endOfToday)
        case .thisWeek:
            var mondayFirst = calendar
            mondayFirst.firstWeekday = 2
            return (mondayFirst.dateInterval(of: .weekOfYear, for: now)?.start ?? startOfToday, endOfToday)
        case .thisMonth:
            return (calendar.dateInterval(of: .month, for: now)?.start ?? startOfToday, endOfToday)
        case .all:
            return (.distantPast, .distantFuture)
        }
    }
}
