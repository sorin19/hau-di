import AppKit
import Combine
import SwiftUI
import UniformTypeIdentifiers

struct DictionarySettingsView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var history: HistoryModel
    @ObservedObject private var transcription: TranscriptionService
    @State private var newTerm = ""
    @State private var trigger = ""
    @State private var expansion = ""
    /// How many terms (from the start of the list) reach Whisper; nil while the model is not loaded.
    @State private var whisperReach: Int?
    /// The term another term is being dragged over right now (the dragged one lands in front of it).
    @State private var dropTarget: String?
    @State private var suggestions: [DictionarySuggestion] = []
    @State private var showAllSuggestions = false

    private static let suggestionsShown = 8

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
        _history = ObservedObject(wrappedValue: services.history)
        _transcription = ObservedObject(wrappedValue: services.transcription)
    }

    var body: some View {
        Form {
            Section("Personal dictionary") {
                Text("Names, technical terms, brands. Claude gets all of them and writes them exactly like this; the first ones (as many as fit in the ~110-token hint) also go to Whisper. New terms go at the start.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                // Bordered full-width field aligned with the button (in a Form, the label would sit apart on the left).
                HStack(alignment: .center, spacing: 8) {
                    TextField("New term", text: $newTerm, prompt: Text("Add terms, separated by commas (e.g. Kubernetes, Ștefănescu, hau-di)"))
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: .infinity)
                        .onSubmit(addTerm)
                    Button("Add", action: addTerm)
                        .disabled(newTerm.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if settings.dictionary.isEmpty {
                    Text("No terms yet.").foregroundStyle(.secondary)
                } else {
                    ChipFlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(Array(settings.dictionary.enumerated()), id: \.element) { index, term in
                            DictionaryChip(term: term, reachesWhisper: reachesWhisper(index),
                                           isDropTarget: dropTarget == term) {
                                remove(term)
                            }
                            .draggable(term)
                            .dropDestination(for: String.self) { items, _ in
                                insert(items.first, before: term)
                            } isTargeted: { targeted in
                                if targeted {
                                    dropTarget = term
                                } else if dropTarget == term {
                                    dropTarget = nil
                                }
                            }
                            .contextMenu {
                                Button("Move to start") { move(term, toStart: true) }
                                Button("Move to end") { move(term, toStart: false) }
                                Divider()
                                Button("Delete", role: .destructive) { remove(term) }
                            }
                        }
                    }
                    Text(reachText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Suggestions from your dictations") {
                Text("Words Whisper misheard and Claude corrected, most frequent first. Once they're in the Dictionary, Whisper gets them right on its own. + adds a word at the start, the pencil lets you edit it right there first (Enter adds it), × hides it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                let visible = visibleSuggestions
                if visible.isEmpty {
                    Text(suggestions.isEmpty ? "They appear after dictations corrected by Claude." : "No new suggestions.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(showAllSuggestions ? visible : Array(visible.prefix(Self.suggestionsShown))) { item in
                        SuggestionRow(item: item) { term in
                            addSuggestion(item, term: term)
                        } onIgnore: {
                            settings.ignoredSuggestions.append(item.suggestion.key)
                        }
                    }
                    if visible.count > Self.suggestionsShown {
                        Button(showAllSuggestions ? "Show fewer" : "\(visible.count - Self.suggestionsShown) more") {
                            showAllSuggestions.toggle()
                        }
                        .buttonStyle(.link)
                    }
                }
                if !settings.ignoredSuggestions.isEmpty {
                    Button("Show hidden suggestions (\(settings.ignoredSuggestions.count))") {
                        settings.ignoredSuggestions = []
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }

            Section("Voice snippets") {
                Text("Say the trigger phrase and the full text is inserted (requires AI correction). E.g. “my signature” → your email signature.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                TextField("Phrase", text: $trigger, prompt: Text("When I say… (e.g. my address)"))
                    .labelsHidden()
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: .infinity)
                Text("…insert this text:").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $expansion)
                    .font(.body)
                    .frame(height: 60)
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                HStack {
                    Spacer()
                    Button("Add snippet", action: addSnippet)
                        .disabled(trigger.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || expansion.isEmpty)
                }
                ForEach(settings.snippets) { snippet in
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("“\(snippet.trigger)”").fontWeight(.semibold)
                            Text(snippet.expansion)
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(4)
                        }
                        Spacer()
                        Button {
                            settings.snippets.removeAll { $0.id == snippet.id }
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(HoverIconButtonStyle(destructive: true))
                        .help("Delete snippet")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: ReachKey(terms: settings.whisperVocabulary, ready: transcription.isReady)) {
            whisperReach = await transcription.vocabularyReach(settings.whisperVocabulary)
        }
        .task(id: history.entries.count) {
            await refreshSuggestions()
        }
    }

    // MARK: - Terms

    private struct ReachKey: Equatable {
        var terms: [String]
        var ready: Bool
    }

    /// true/false = reaches Whisper or not; nil = not known yet (the model is not loaded).
    private func reachesWhisper(_ index: Int) -> Bool? {
        guard settings.whisperDictionaryHint else { return false }
        return whisperReach.map { index < $0 }
    }

    private var reachText: String {
        let count = settings.dictionary.count
        let tip = "Drag a term to move it; right-click for more."
        guard settings.whisperDictionaryHint else {
            return "Whisper doesn't get the dictionary (the option is off in Transcription); Claude gets all of it. " + tip
        }
        guard let reach = whisperReach else {
            return "How many terms also go to Whisper shows once the model is loaded. " + tip
        }
        if reach >= count {
            return "Whisper also gets \(count == 1 ? "the term" : "all \(count) terms") (marked in blue). " + tip
        }
        return "Whisper also gets the first \(reach) of \(count) terms (marked in blue); Claude gets all of them. " + tip
    }

    /// New terms go at the start, in the order typed: that way they reach Whisper (which only sees the first ones).
    private func addTerm() {
        var seen = Set(settings.dictionary)
        var added: [String] = []
        for part in newTerm.split(whereSeparator: { $0 == "," || $0 == "\n" }) {
            let term = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if !term.isEmpty, seen.insert(term).inserted { added.append(term) }
        }
        settings.dictionary.insert(contentsOf: added, at: 0)
        newTerm = ""
    }

    private func remove(_ term: String) {
        settings.dictionary.removeAll { $0 == term }
        if dropTarget == term { dropTarget = nil }
    }

    /// The dragged term lands in front of the one it is dropped on. Text dragged from elsewhere becomes a new term.
    private func insert(_ dragged: String?, before target: String) -> Bool {
        dropTarget = nil
        guard let dragged = dragged?.trimmingCharacters(in: .whitespacesAndNewlines), !dragged.isEmpty,
              dragged != target else { return false }
        var list = settings.dictionary
        if let from = list.firstIndex(of: dragged) {
            list.remove(at: from)
        } else if dragged.count > 40 || dragged.contains(where: \.isNewline) {
            return false
        }
        list.insert(dragged, at: list.firstIndex(of: target) ?? list.count)
        settings.dictionary = list
        return true
    }

    private func move(_ term: String, toStart: Bool) {
        var list = settings.dictionary
        guard let from = list.firstIndex(of: term) else { return }
        list.remove(at: from)
        if toStart {
            list.insert(term, at: 0)
        } else {
            list.append(term)
        }
        settings.dictionary = list
    }

    // MARK: - Suggestions

    /// The suggestions to show: those not in the dictionary, plus those that are but do not reach Whisper.
    private var visibleSuggestions: [VisibleSuggestion] {
        let keys = settings.dictionary.map { DictionarySuggestions.key($0) }
        let ignored = Set(settings.ignoredSuggestions)
        return suggestions.compactMap { suggestion -> VisibleSuggestion? in
            guard !ignored.contains(suggestion.key) else { return nil }
            guard let position = keys.firstIndex(of: suggestion.key) else {
                return VisibleSuggestion(suggestion: suggestion, position: nil)
            }
            guard settings.whisperDictionaryHint, let reach = whisperReach, position >= reach else { return nil }
            return VisibleSuggestion(suggestion: suggestion, position: position)
        }
    }

    /// The proposed or edited term goes at the start of the dictionary. A term already there (but not reaching
    /// Whisper) moves to the start. If it was edited, the original suggestion is hidden: it is resolved.
    private func addSuggestion(_ item: VisibleSuggestion, term: String) {
        if item.position != nil,
           let existing = settings.dictionary.first(where: { DictionarySuggestions.key($0) == item.suggestion.key }) {
            move(existing, toStart: true)
            return
        }
        var list = settings.dictionary.filter { $0 != term }
        list.insert(term, at: 0)
        settings.dictionary = list
        if DictionarySuggestions.key(term) != item.suggestion.key {
            settings.ignoredSuggestions.append(item.suggestion.key)
        }
    }

    /// Recomputed on open and after every new dictation, off the main thread (it covers the whole history).
    private func refreshSuggestions() async {
        let entries = history.entries
        let ignored = Set(settings.ignoredSuggestions)
        suggestions = await Task.detached(priority: .utility) {
            DictionarySuggestions.compute(from: entries, ignoring: ignored, limit: 40)
        }.value
    }

    private func addSnippet() {
        let key = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty, !expansion.isEmpty else { return }
        settings.snippets.append(Snippet(trigger: key, expansion: expansion))
        trigger = ""
        expansion = ""
    }
}

private struct VisibleSuggestion: Identifiable {
    let suggestion: DictionarySuggestion
    /// The position in the dictionary, if the term is already there (but does not reach Whisper).
    let position: Int?
    var id: String { suggestion.id }
}

/// A dictionary term, as a tag: background on hover (so you see what you are deleting), × inside.
/// Blue = also reaches Whisper. The line on the left shows where a term dragged over it will go.
private struct DictionaryChip: View {
    let term: String
    let reachesWhisper: Bool?
    let isDropTarget: Bool
    let onDelete: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 3) {
            if reachesWhisper == true {
                Image(systemName: "waveform")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.accentColor)
            }
            Text(term)
                .font(.callout)
            ChipDeleteButton(term: term, action: onDelete)
        }
        .padding(.leading, 7)
        .padding(.trailing, 2)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(fill)
        )
        .overlay(alignment: .leading) {
            if isDropTarget {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 2)
                    .offset(x: -4)
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .help(helpText)
    }

    private var helpText: String {
        switch reachesWhisper {
        case true?: return "Goes to Claude and Whisper"
        case false?: return "Goes to Claude only"
        case nil: return "Goes to Claude; whether it also goes to Whisper shows once the model is loaded"
        }
    }

    private var fill: Color {
        let whisper = reachesWhisper == true
        if hovering { return whisper ? Color.accentColor.opacity(0.28) : Color.primary.opacity(0.14) }
        return whisper ? Color.accentColor.opacity(0.15) : Color.primary.opacity(0.06)
    }
}

/// The × in the tag: red with a round background when the mouse is right on it.
private struct ChipDeleteButton: View {
    let term: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 15, height: 15)
                .background(Circle().fill(hovering ? Color.red.opacity(0.18) : Color.clear))
        }
        .buttonStyle(.plain)
        .foregroundStyle(hovering ? Color.red : Color.secondary)
        .onHover { hovering = $0 }
        .help("Delete “\(term)”")
        .accessibilityLabel("Delete \(term)")
    }
}

/// A suggestion: the term, how many times, Whisper's average score and what it heard; + / pencil / ×.
private struct SuggestionRow: View {
    let item: VisibleSuggestion
    /// Adds the term (the proposed or the edited one) at the start of the dictionary.
    let onAdd: (String) -> Void
    let onIgnore: () -> Void
    /// In-place editing, right on the suggestion's row (the top field may be off screen): Enter adds, Esc cancels.
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField("Term", text: $draft)
                        .labelsHidden()
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onAppear { DispatchQueue.main.async { fieldFocused = true } }
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(item.suggestion.term).fontWeight(.semibold)
                        Text("\(item.suggestion.count)×")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if let probability = item.suggestion.averageProbability {
                            Text(verbatim: "average score \(Int((probability * 100).rounded()))%")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Text("heard: \(heardText)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if let position = item.position {
                    Text("In the Dictionary at position \(position + 1), but it doesn't go to Whisper.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
            Spacer(minLength: 8)
            if editing {
                Button("Add", action: commit)
                    .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Cancel") { editing = false }
            } else {
                if item.position == nil {
                    Button {
                        draft = item.suggestion.term
                        editing = true
                    } label: {
                        Image(systemName: "pencil")
                    }
                    .buttonStyle(HoverIconButtonStyle())
                    .help("Edit it before adding it")
                    Button { onAdd(item.suggestion.term) } label: { Image(systemName: "plus") }
                        .buttonStyle(HoverIconButtonStyle())
                        .help("Add “\(item.suggestion.term)” to the start of the Dictionary")
                } else {
                    Button { onAdd(item.suggestion.term) } label: { Image(systemName: "arrow.up.to.line") }
                        .buttonStyle(HoverIconButtonStyle())
                        .help("Move it to the start of the Dictionary so it goes to Whisper")
                }
                Button(action: onIgnore) { Image(systemName: "xmark") }
                    .buttonStyle(HoverIconButtonStyle())
                    .help("Hide suggestion")
            }
        }
    }

    private func commit() {
        let term = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !term.isEmpty else { return }
        editing = false
        onAdd(term)
    }

    private var heardText: String {
        item.suggestion.heard.prefix(4)
            .map { $0.count > 1 ? "\($0.text) (\($0.count)×)" : $0.text }
            .joined(separator: ", ")
    }
}

struct HistoryView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var history: HistoryModel
    @State private var range: HistoryRange = .thisMonth
    /// As in the menu bar panel: the ranges are recomputed even when the window stays open past midnight.
    @State private var now = Date()
    @State private var exportMessage: String?

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
        _history = ObservedObject(wrappedValue: services.history)
    }

    var body: some View {
        // Computed on every render, so that "Today" stays correct after midnight too.
        let dates = range.dates(now: now)
        let entries = history.entries.between(dates.from, dates.to)
        let summary = HistorySummary(entries: entries)
        VStack(spacing: 0) {
            HStack {
                Toggle("Keep history locally (last 3 months)", isOn: $settings.historyEnabled)
                Spacer()
                Button("Delete all", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
            }
            .padding(.horizontal, 12)
            .padding(.top, 10)

            Picker("Range", selection: $range) {
                ForEach(HistoryRange.allCases) { item in
                    Text(item.title).tag(item)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            HStack(spacing: 14) {
                // The rhombus in the state colors: red = dictation (recording), orange = Claude correction.
                Label {
                    Text("\(summary.count) \(summary.count == 1 ? "dictation" : "dictations")")
                } icon: {
                    StatusDiamond(color: BrandTone.red.color(onDark: true))
                        .frame(width: 11, height: 11)
                }
                Label {
                    Text("\(summary.correctedCount) with Claude")
                } icon: {
                    StatusDiamond(color: BrandTone.orange.color(onDark: true))
                        .frame(width: 11, height: 11)
                }
                Label("Cost: \(CostFormat.usd(summary.totalCostUSD))", systemImage: "dollarsign.circle")
                    .fontWeight(.semibold)
                if let average = summary.averageCostUSD {
                    Text("average \(CostFormat.usd(average)) / correction")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if let exportMessage {
                    Text(exportMessage).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Button("Export CSV...") { export(entries) }
                    .disabled(entries.isEmpty)
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.bottom, 4)
            Text(tokenSummary(summary))
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 8)
            Divider()

            if entries.isEmpty {
                // Fills the space below the header: otherwise everything (header included) ends up vertically centered.
                ContentUnavailableView(history.entries.isEmpty ? "No dictations yet" : "Nothing in the selected range",
                                       systemImage: "waveform",
                                       description: Text(history.entries.isEmpty
                                                         ? "Hold the hotkey and speak."
                                                         : "Choose another range above."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Each dictation is its own card: from the date to the buttons, everything belongs to one entry.
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(entries) { entry in
                            HistoryRow(entry: entry) {
                                history.remove(entry.id)
                            }
                        }
                    }
                    .padding(12)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            now = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            now = Date()
        }
    }

    /// The tokens in the range; "the model's list price" links to the price list used by the app.
    private func tokenSummary(_ summary: HistorySummary) -> AttributedString {
        var text = AttributedString("Tokens in range: \(summary.inputTokens.formatted()) input (including cache), "
                                    + "\(summary.outputTokens.formatted()) output. The cost is estimated from tokens × ")
        var link = AttributedString("the model's list price")
        link.link = AppInfo.pricingURL
        text += link
        text += AttributedString(".")
        return text
    }

    private func export(_ entries: [HistoryEntry]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd"
        // Named after the first and last exported dictation ("All time" has no bounds to show).
        let first = entries.map(\.date).min() ?? Date()
        let last = entries.map(\.date).max() ?? Date()
        panel.nameFieldStringValue = "hau-di-history-\(stamp.string(from: first))_\(stamp.string(from: last)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            // UTF-8 BOM: so that Excel recognizes the diacritics correctly.
            try ("\u{FEFF}" + HistoryCSV.make(entries)).write(to: url, atomically: true, encoding: .utf8)
            exportMessage = "Exported: \(url.lastPathComponent)"
        } catch {
            exportMessage = "Export failed: \(error.localizedDescription)"
        }
    }
}

private struct HistoryRow: View {
    let entry: HistoryEntry
    let onDelete: () -> Void
    @State private var showRaw = false

    /// 2026-11-21 21:15:03, regardless of the system language.
    private static let timestamp: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // The metadata (date, app, model, cost) in a monospaced font.
            HStack(spacing: 10) {
                Text(Self.timestamp.string(from: entry.date))
                    .foregroundStyle(.primary)
                if let app = entry.appName {
                    // The app and the window in which the dictation started.
                    Text([app, entry.windowTitle].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " — "))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(entry.windowTitle ?? app)
                }
                Spacer(minLength: 8)
                if let usage = entry.usage {
                    Text(ClaudeModels.displayName(for: usage.model) + (usage.fastMode ? " (fast)" : ""))
                    Text(usage.costUSD.map(CostFormat.usd) ?? "—")
                        .fontWeight(.semibold)
                        .foregroundStyle(.primary)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .foregroundStyle(.secondary)

            Text(entry.finalText)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            if entry.rawText != entry.finalText {
                // Not a DisclosureGroup: on macOS only its arrow responds to clicks, not the title.
                VStack(alignment: .leading, spacing: 6) {
                    DisclosureToggle(title: "Raw transcript", isExpanded: $showRaw)
                        .font(.caption)
                    if showRaw {
                        Text(entry.rawText)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.leading, DisclosureToggle.indent)
                    }
                }
            }

            if let note = entry.note {
                Text(note).font(.caption).foregroundStyle(.orange)
            }

            Divider()

            HStack(alignment: .firstTextBaseline) {
                Text(details)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                CopyIconButton(text: entry.finalText)
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(HoverIconButtonStyle(destructive: true))
                .help("Delete")
                .accessibilityLabel("Delete")
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.16), lineWidth: 1))
    }

    private var details: String {
        var parts = [String(format: "audio %.1f s", entry.audioDuration),
                     String(format: "transcription %.2f s", entry.transcriptionTime)]
        if let correction = entry.correctionTime {
            parts.append(String(format: "Claude %.1f s", correction))
        }
        if let usage = entry.usage {
            parts.append("\(usage.promptTokens) tokens in (\(usage.cacheReadTokens) from cache) / \(usage.outputTokens) out")
        }
        // There are several Whisper variants (Turbo, compressed, Small): the model stays useful for comparisons.
        parts.append(entry.engine)
        return parts.joined(separator: " · ")
    }
}

/// An arrow and a title that open and close a section below: the whole label is clickable, with a subtle
/// background on hover and on press (like the icon buttons), without taking up more room than the text.
private struct DisclosureToggle: View {
    let title: String
    @Binding var isExpanded: Bool

    /// How far the section's content is indented: the arrow and the space after it.
    static let indent: CGFloat = 14

    var body: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.15)) { isExpanded.toggle() }
        } label: {
            HStack(spacing: 4) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .rotationEffect(.degrees(isExpanded ? 90 : 0))
                    .frame(width: Self.indent - 4)
                Text(verbatim: title)
            }
        }
        .buttonStyle(DisclosureToggleStyle())
        .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
    }
}

private struct DisclosureToggleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureToggleLabel(configuration: configuration)
    }
}

private struct DisclosureToggleLabel: View {
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.primary.opacity(configuration.isPressed ? 0.16 : hovering ? 0.09 : 0))
            )
            .contentShape(Rectangle())
            .onHover { hovering = $0 }
            // The background reaches past the text, but the layout keeps the text's size and position.
            .padding(.horizontal, -5)
            .padding(.vertical, -2)
    }
}
