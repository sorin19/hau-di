import AppKit
import Combine
import SwiftUI

struct MenuBarLabel: View {
    @ObservedObject var controller: DictationController

    var body: some View {
        let tint = controller.statusTint
        Image(nsImage: MenuBarIcon.image(for: tint))
            .renderingMode(tint.tone == nil ? .template : .original)
    }
}

struct MenuBarView: View {
    let services: AppServices
    @ObservedObject private var controller: DictationController
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var transcription: TranscriptionService
    @ObservedObject private var permissions: PermissionsManager
    @ObservedObject private var apiKeys: APIKeyStore
    @ObservedObject private var hotkeyUI: HotkeyUIModel
    @ObservedObject private var history: HistoryModel
    @ObservedObject private var budget: BudgetTracker
    /// The current time for "today" and for the budget month. SwiftUI does not redraw the panel just because time
    /// passed: without this, the next day "today" shows yesterday's cost. Updated on day change and on panel open.
    @State private var now = Date()

    init(services: AppServices) {
        self.services = services
        _controller = ObservedObject(wrappedValue: services.controller)
        _settings = ObservedObject(wrappedValue: services.settings)
        _transcription = ObservedObject(wrappedValue: services.transcription)
        _permissions = ObservedObject(wrappedValue: services.permissions)
        _apiKeys = ObservedObject(wrappedValue: services.apiKeys)
        _hotkeyUI = ObservedObject(wrappedValue: services.hotkeyUI)
        _history = ObservedObject(wrappedValue: services.history)
        _budget = ObservedObject(wrappedValue: services.budget)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            if !permissions.allRequiredGranted || !hotkeyUI.monitorActive {
                warningBox(
                    text: permissions.allRequiredGranted
                        ? "The key listener is not running."
                        : "Missing permissions (microphone / Accessibility).",
                    action: "Fix"
                ) {
                    openSettings(.welcome)
                }
            }

            modelStatus

            Text(hintText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Divider()

            // Toggles (switch style), aligned to the right like "+ English".
            panelSwitch("AI correction with Claude", isOn: $settings.correctionEnabled)
            if let label = settings.language.diacriticsLabel {
                panelSwitch(label, isOn: $settings.useDiacritics)
            }
            if settings.correctionEnabled && !apiKeys.hasKey {
                Text("Add the API key in Settings → AI Correction.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            // Language and "+ English" on the same row.
            HStack(spacing: 12) {
                Picker("Language", selection: $settings.language) {
                    ForEach(DictationLanguage.allCases) { language in
                        Text(language.title).tag(language)
                    }
                }
                .fixedSize()
                Spacer(minLength: 0)
                if settings.language != .english {
                    Toggle("+ English", isOn: $settings.mixesEnglish)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                        .hoverHint("English words, spelled correctly by Claude", alignment: .trailing)
                }
            }

            if settings.historyEnabled || settings.monthlyBudget != nil {
                costBox
            }

            if let entry = controller.lastEntry {
                lastDictation(entry)
            }

            if let error = controller.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            HStack {
                Button("Settings…") { openSettings(.general) }
                Button("History") { openSettings(.history) }
                Spacer()
                Button("Quit") { services.quit() }
            }
        }
        .padding(14)
        .frame(width: 340)
        .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged).receive(on: RunLoop.main)) { _ in
            now = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            now = Date()
        }
        .background(MenuBarPanelReader())
    }

    /// A toggle in the panel: the text on the left (as wide as the row), the switch on the right.
    private func panelSwitch(_ title: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(title)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.small)
    }

    /// Opens the settings window and closes the menu bar panel (otherwise it stays open on top of it).
    @MainActor
    private func openSettings(_ tab: SettingsTab) {
        MenuBarPanel.close()
        services.windows.showSettings(tab: tab)
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(nsImage: MenuBarIcon.image(for: controller.statusTint))
                .renderingMode(controller.statusTint.tone == nil ? .template : .original)
                .foregroundStyle(.primary)
                .frame(width: 30)
            VStack(alignment: .leading, spacing: 2) {
                Text("hau-di").font(.headline)
                Text(controller.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private var hintText: String {
        var text = "Hold \(settings.hotkey.displayString) and speak; release to insert."
        if settings.handsFreeEnabled { text += " Double-tap = hands-free." }
        text += " Esc cancels."
        return text
    }

    private var modelStatus: some View {
        HStack(spacing: 8) {
            SetupStatusIcon(status: transcription.setupStatus, busy: transcription.isBusy, size: 13)
            VStack(alignment: .leading, spacing: 1) {
                Text(transcription.activeTitle.isEmpty ? settings.currentEngineTitle : transcription.activeTitle)
                    .font(.caption.weight(.medium))
                Text(transcription.statusText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                if case .downloading(let fraction) = transcription.state {
                    ProgressView(value: fraction).frame(width: 160)
                }
            }
        }
    }

    /// A single row: how many dictations and how many Claude corrections today (red and orange rhombus, as in
    /// History), and on the right the cost of today / of the month / the budget. Today comes from the history;
    /// the month and the budget, from the budget tracker.
    private var costBox: some View {
        let limit = settings.monthlyBudget
        let status = budget.status(limit: limit)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                if settings.historyEnabled {
                    let today = HistoryRange.today.dates(now: now)
                    let summary = HistorySummary(entries: history.entries.between(today.from, today.to))
                    counter(summary.count, tone: .red, help: "Dictations today")
                    counter(summary.correctedCount, tone: .orange, help: "Corrected by Claude today")
                    Spacer(minLength: 8)
                    amount(summary.totalCostUSD, help: "Cost today")
                    separator
                } else {
                    Spacer(minLength: 8)
                }
                amount(budget.spentThisMonth, help: "Cost this month", color: color(for: status))
                if let limit {
                    separator
                    amount(limit, help: "Monthly budget", color: .secondary)
                }
            }
            if status == .exceeded {
                Text("Budget reached: AI correction is paused until \(BudgetTracker.resumeDay()).")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func counter(_ value: Int, tone: BrandTone, help: String) -> some View {
        HStack(spacing: 4) {
            StatusDiamond(color: tone.color(onDark: true))
                .frame(width: 10, height: 10)
            Text("\(value)")
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .hoverHint(help, alignment: .leading)
    }

    private func amount(_ value: Double, help: String, color: Color = .primary) -> some View {
        Text(CostFormat.usd(value))
            .font(.caption.monospaced().weight(.semibold))
            .foregroundStyle(color)
            .hoverHint(help, alignment: .trailing)
    }

    private var separator: some View {
        Text("/")
            .font(.caption.monospaced())
            .foregroundStyle(.tertiary)
    }

    /// The month: orange from 80% of the budget, red at 100%.
    private func color(for status: BudgetStatus) -> Color {
        switch status {
        case .exceeded: return .red
        case .warning: return .orange
        case .off, .ok: return .primary
        }
    }

    private func lastDictation(_ entry: HistoryEntry) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Last dictation").font(.caption.weight(.semibold))
                if let usage = entry.usage {
                    Text("\(ClaudeModels.displayName(for: usage.model)) · \(usage.costUSD.map(CostFormat.usd) ?? "—")")
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Spacer()
                CopyIconButton(text: entry.finalText)
            }
            Text(entry.finalText)
                .font(.callout)
                .lineLimit(4)
                .textSelection(.enabled)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func warningBox(text: String, action: String, perform: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
            Spacer()
            Button(action, action: perform)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.12)))
    }
}

/// The menu bar panel (MenuBarExtra, .window style). SwiftUI has no API to close it from code.
/// We close it as if by a click on the menu bar icon: that way SwiftUI's internal state stays in sync too,
/// and the next click on the icon opens it on the first try. If the button is not found (or the panel does not
/// react), we hide the window directly.
@MainActor
enum MenuBarPanel {
    /// The panel's window, found by MenuBarPanelReader when the panel is shown.
    fileprivate static weak var window: NSWindow?

    static func close() {
        guard let panel = window, panel.isVisible else { return }
        statusBarButton(excluding: panel)?.performClick(nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            if let panel = MenuBarPanel.window, panel.isVisible {
                panel.orderOut(nil)
            }
        }
    }

    /// The button of the menu bar icon (the app has a single icon there).
    private static func statusBarButton(excluding panel: NSWindow) -> NSStatusBarButton? {
        for candidate in NSApp.windows where candidate !== panel {
            if let button = find(in: candidate.contentView) { return button }
        }
        return nil
    }

    private static func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        for subview in view.subviews {
            if let button = find(in: subview) { return button }
        }
        return nil
    }
}

/// Invisible view placed in the panel: remembers the panel's window, for MenuBarPanel.close().
private struct MenuBarPanelReader: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView { ReaderView() }
    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ReaderView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { MenuBarPanel.window = window }
        }
    }
}
