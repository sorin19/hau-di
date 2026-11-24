import AppKit
import SwiftUI

struct AISettingsView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var apiKeys: APIKeyStore
    @ObservedObject private var models: ModelCatalogStore
    @ObservedObject private var budget: BudgetTracker
    @State private var keyDraft = ""
    @State private var keyStatus: String?
    @State private var testingKey = false
    @State private var sampleInput = "ăăă deci trimite-i lui andrei factura de o mie doua sute cincizeci de lei pana marti nu stai pana miercuri si pune-l in cc pe ion punct popescu arond gmail punct com"
    @State private var sampleOutput: String?
    @State private var testingSample = false

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
        _apiKeys = ObservedObject(wrappedValue: services.apiKeys)
        _models = ObservedObject(wrappedValue: services.models)
        _budget = ObservedObject(wrappedValue: services.budget)
    }

    var body: some View {
        Form {
            Section {
                Toggle("Correct the text with Claude (text, data, intent)", isOn: $settings.correctionEnabled)
                Text("Audio and transcription stay on your Mac; only the transcribed text (plus the context chosen below) is sent to Anthropic through the API. If the API doesn't respond in time, the raw text is inserted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("API key (Claude Console)") {
                if apiKeys.hasKey {
                    LabeledContent("Key saved in Keychain", value: apiKeys.maskedKey)
                }
                HStack {
                    SecureField(apiKeys.hasKey ? "Replace the key (sk-ant-…)" : "sk-ant-…", text: $keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(saveKey)
                    Button("Save", action: saveKey)
                        .disabled(keyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                HStack {
                    Button("Test key", action: testKey)
                        .disabled(!apiKeys.hasKey || testingKey)
                    if testingKey { ProgressView().controlSize(.small) }
                    if let keyStatus {
                        Text(keyStatus).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if apiKeys.hasKey {
                        Button("Delete key", role: .destructive) {
                            apiKeys.remove()
                            keyStatus = nil
                        }
                    }
                }
                Link("Create a key in Claude Console →", destination: URL(string: "https://console.anthropic.com/settings/keys")!)
                    .font(.caption)
            }

            Section("Model and behavior") {
                modelPicker
                Text(modelDetail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Text(catalogStatus)
                        .font(.caption)
                        .foregroundStyle(models.lastError == nil ? Color.secondary : Color.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if models.isLoading { ProgressView().controlSize(.small) }
                    Button("Reload list") { models.refresh(apiKey: apiKeys.apiKey, manual: true) }
                        .disabled(!apiKeys.hasKey || models.isLoading)
                }

                Picker("Correction level", selection: $settings.correctionLevel) {
                    ForEach(CorrectionLevel.allCases) { level in
                        Text(level.title).tag(level)
                    }
                }
                .pickerStyle(.segmented)
                Text(settings.correctionLevel.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if availableEfforts.isEmpty {
                    LabeledContent("Effort", value: "this model has no effort levels")
                } else {
                    Picker("Effort", selection: effortBinding) {
                        ForEach(availableEfforts) { effort in
                            Text(effort.title).tag(effort)
                        }
                    }
                }

                if models.mayUseFastMode(currentModelID) {
                    Toggle("Fast mode (up to ~2.5x faster, double price)", isOn: $settings.fastMode)
                }
            }

            Section("Monthly budget") {
                Toggle("Limit the monthly cost of corrections", isOn: $settings.monthlyBudgetEnabled)
                if settings.monthlyBudgetEnabled {
                    LabeledContent("Budget") {
                        Stepper(CostFormat.usd(settings.monthlyBudgetUSD) + " per month",
                                value: $settings.monthlyBudgetUSD, in: 5...500, step: 5)
                    }
                }
                Text(budgetText)
                    .font(.caption)
                    .foregroundStyle(budget.status(limit: settings.monthlyBudget) == .exceeded ? Color.orange : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Maximum wait time") {
                LabeledContent("Short dictation: up to") {
                    Stepper("\(Int(settings.longDictationThreshold)) s of audio",
                            value: $settings.longDictationThreshold, in: 1...60, step: 1)
                }
                LabeledContent("Wait time, short dictation") {
                    Stepper("\(Int(settings.shortCorrectionTimeout)) seconds",
                            value: $settings.shortCorrectionTimeout, in: 1...30, step: 1)
                }
                LabeledContent("Wait time, long dictation (over \(Int(settings.longDictationThreshold)) s)") {
                    Stepper("\(Int(settings.longCorrectionTimeout)) seconds",
                            value: $settings.longCorrectionTimeout, in: 2...60, step: 1)
                }
                Text("If Claude doesn't respond within this time, the raw transcript is inserted. Long dictations need more time: the response is longer.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Context sent to Claude") {
                Toggle("App name and window title (for tone and formatting)", isOn: $settings.sendAppContext)
                Toggle("Text before the cursor (max. 400 characters, for continuity)", isOn: $settings.sendFieldText)
                Text("Password fields are never read.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Custom instructions") {
                TextEditor(text: $settings.customInstructions)
                    .font(.body)
                    .frame(height: 90)
                Text("E.g. “Use Romanian quotation marks („…”)”, “Write amounts in euros with the € symbol”, “In Slack, don't end with a period”.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Test the correction (no microphone)") {
                Text("Raw transcript").font(.caption).foregroundStyle(.secondary)
                TextEditor(text: $sampleInput)
                    .font(.body)
                    .frame(height: 70)
                HStack {
                    Button("Correct", action: testSample)
                        .disabled(!apiKeys.hasKey || testingSample || sampleInput.isEmpty)
                    if testingSample { ProgressView().controlSize(.small) }
                    Spacer()
                }
                if let sampleOutput {
                    Text(sampleOutput)
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.05)))
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { models.refreshIfStale(apiKey: apiKeys.apiKey) }
    }

    // MARK: - Model

    /// The model actually used for the current selection.
    private var currentModelID: String { models.resolvedID(for: settings.claudeModel) }
    private var currentInfo: ClaudeModelInfo? { models.info(for: currentModelID) }

    private var modelPicker: some View {
        Picker("Model", selection: $settings.claudeModel) {
            ForEach(models.groups) { group in
                Section(ClaudeModels.lineTitle(group.line)) {
                    let latest = models.resolvedID(for: ModelCatalog.latestPrefix + group.line)
                    Text("Latest \(ClaudeModels.lineTitle(group.line)) (currently \(models.displayName(for: latest)))")
                        .tag(ModelCatalog.latestPrefix + group.line)
                    ForEach(group.models) { model in
                        Text(modelTitle(model)).tag(model.id)
                    }
                }
            }
            // The current selection must be among the options: list not loaded yet, or model removed from the API.
            if !selectionListed {
                Text(ClaudeModels.selectionTitle(settings.claudeModel)).tag(settings.claudeModel)
            }
        }
    }

    private var selectionListed: Bool {
        models.groups.contains { group in
            ModelCatalog.latestPrefix + group.line == settings.claudeModel
                || group.models.contains { $0.id == settings.claudeModel }
        }
    }

    /// "Claude Opus 5.5 · $4 / $20", plus the retirement date for deprecated models.
    private func modelTitle(_ model: ClaudeModelInfo) -> String {
        var title = model.displayName
        if let price = models.prices.label(for: model.id) { title += " · " + price }
        if model.isDeprecated { title += " · retiring" + (model.retiresOn.map { " on " + $0 } ?? "") }
        return title
    }

    /// The ID, the list price (linked to the price list) and, where relevant, the model's replacement or retirement.
    private var modelDetail: AttributedString {
        let id = currentModelID
        var text = AttributedString()
        if settings.claudeModel.hasPrefix(ModelCatalog.latestPrefix) {
            text += AttributedString("Now: \(models.displayName(for: id)) (\(id)). Switches to the new model on its own when one comes out in the family. ")
        } else if ClaudeModels.baseID(id) != ClaudeModels.baseID(settings.claudeModel) {
            text += AttributedString("\(settings.claudeModel) is no longer available; using \(models.displayName(for: id)) (\(id)) instead. ")
        } else {
            text += AttributedString("ID: \(id). ")
        }
        var priceLink = AttributedString("List price")
        priceLink.link = AppInfo.pricingURL
        text += priceLink
        if let price = models.prices.label(for: id) {
            text += AttributedString(": \(price) per million tokens (input / output).")
        } else {
            text += AttributedString(": unknown for this model, so the cost doesn't show up in History.")
        }
        if let info = currentInfo, info.isDeprecated {
            text += AttributedString(" Deprecated model" + (info.retiresOn.map { ", retiring on " + $0 } ?? "")
                                     + "; after that, the latest model in the family is used.")
        }
        return text
    }

    private var catalogStatus: String {
        var parts: [String] = []
        if let error = models.lastError {
            // Error messages usually end with a period: do not double it.
            parts.append("The model list could not be loaded: " + (error.hasSuffix(".") ? error : error + "."))
        } else if let fetchedAt = models.fetchedAt, !models.models.isEmpty {
            let shown = models.available.count, total = models.models.count
            parts.append(shown == total
                ? "\(total) models available for your key (list from \(Self.shortDate(fetchedAt)))."
                : "Only models with a known price are listed: \(shown) of the \(total) available for your key (list from \(Self.shortDate(fetchedAt))).")
        } else {
            parts.append(apiKeys.hasKey ? "The model list isn't loaded yet." : "The model list appears after you save the key.")
        }
        let updated = ModelCatalog.displayDateTime(models.prices.stamp) ?? "?"
        if models.pricesFetchedAt == nil {
            parts.append("Prices: the copy built into the app (\(updated))" + (models.pricesError.map { "; pay.cx.ro: " + $0 } ?? "") + ".")
        } else {
            parts.append("Prices updated on \(updated)" + (models.pricesError.map { " (last fetch failed: " + $0 + ")" } ?? "") + ".")
        }
        parts.append("The price list is fetched from pay.cx.ro once a week, with a random installation ID (no personal data).")
        return parts.joined(separator: " ")
    }

    private var budgetText: String {
        let spent = CostFormat.usd(budget.spentThisMonth)
        guard let limit = settings.monthlyBudget else {
            return "This month: \(spent), no limit. The cost is estimated from tokens × list price."
        }
        let percent = Int((budget.spentThisMonth / limit * 100).rounded(.down))
        var text = "This month: \(spent) of \(CostFormat.usd(limit)) (\(percent)%). "
        if budget.status(limit: limit) == .exceeded {
            text += "Budget reached: AI correction is paused until \(BudgetTracker.resumeDay()), and the text is inserted as Whisper transcribed it. Raise the budget to resume right away. "
        } else {
            text += "At 80% you get a warning, and at 100% correction stops until next month (the text is inserted as Whisper transcribed it). "
        }
        return text + "The cost is estimated from tokens × list price; the billed amount is in Claude Console, where you can also set a hard limit."
    }

    private static func shortDate(_ date: Date) -> String {
        // ISO, like the other dates in the app (2026-11-24 15:30): no day/month ambiguity.
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.string(from: date)
    }

    /// The model's effort levels (from the API); all of them if the list is not loaded yet.
    private var availableEfforts: [EffortLevel] {
        currentInfo?.efforts ?? EffortLevel.allCases
    }

    /// Shows the level actually sent (the chosen one, or the nearest lower one the model supports).
    private var effortBinding: Binding<EffortLevel> {
        Binding(get: { ModelCatalog.effort(settings.effort, for: currentInfo) ?? settings.effort },
                set: { settings.effort = $0 })
    }

    private func saveKey() {
        let value = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return }
        if apiKeys.save(value) {
            keyDraft = ""
            keyStatus = "Saved."
            testKey()
        } else {
            keyStatus = "Couldn't save to Keychain."
        }
    }

    private func testKey() {
        guard let key = apiKeys.apiKey else { return }
        testingKey = true
        keyStatus = nil
        Task {
            do {
                try await ClaudeCorrector().validate(apiKey: key)
                keyStatus = "✓ The key works."
                models.refresh(apiKey: key)
            } catch {
                keyStatus = "✗ " + (error.localizedDescription)
            }
            testingKey = false
        }
    }

    private func testSample() {
        guard let key = apiKeys.apiKey else { return }
        testingSample = true
        sampleOutput = nil
        let input = sampleInput
        let config = settings.correctionConfig
        let options = settings.claudeOptions(audioDuration: nil, models: models)
        let context = CorrectionContext(appName: "Mail", bundleID: "com.apple.mail")
        Task {
            do {
                let outcome = try await ClaudeCorrector().correct(transcript: input, context: context, config: config,
                                                                  options: options, apiKey: key)
                models.noteRejected(outcome.rejectedFeatures, for: options.model)
                budget.add(outcome.usage?.costUSD, limit: settings.monthlyBudget)
                let cost = outcome.usage?.costUSD.map(CostFormat.usd) ?? "—"
                sampleOutput = outcome.text + String(format: "\n\n(%@ · %.1f s · %@)",
                                                     outcome.servedBy ?? options.model, outcome.duration, cost)
            } catch {
                if let failure = error as? CorrectionError {
                    models.noteRejected(failure.rejectedFeatures, for: options.model)
                    budget.add(failure.usage?.costUSD, limit: settings.monthlyBudget)
                }
                sampleOutput = "Error: " + error.localizedDescription
            }
            testingSample = false
        }
    }
}
