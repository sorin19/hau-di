import AppKit
import SwiftUI

struct GeneralSettingsView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var hotkeyUI: HotkeyUIModel
    @State private var launchAtLogin = LoginItem.isEnabled
    @State private var loginError: String?

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
        _hotkeyUI = ObservedObject(wrappedValue: services.hotkeyUI)
    }

    private var isPresetHotkey: Bool {
        Hotkey.presets.contains { $0.hotkey == settings.hotkey }
    }

    var body: some View {
        Form {
            Section("Dictation hotkey") {
                LabeledContent("Current hotkey") {
                    Text(settings.hotkey.displayString)
                        .font(.system(.body, design: .rounded).weight(.semibold))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
                }

                Picker("Presets", selection: $settings.hotkey) {
                    ForEach(Hotkey.presets) { preset in
                        Text(preset.title).tag(preset.hotkey)
                    }
                    if !isPresetHotkey {
                        Text("Custom: \(settings.hotkey.displayString)").tag(settings.hotkey)
                    }
                }

                HStack {
                    if hotkeyUI.isCapturing {
                        Image(systemName: "record.circle").foregroundStyle(.red)
                        Text(hotkeyUI.live.isEmpty
                             ? "Press and hold the key combination you want (fn, ⌃, ⌥, ⌘, ⇧), then release. Esc = cancel."
                             : "Holding: \(Hotkey.fromRecording(hotkeyUI.live).displayString)")
                        Spacer()
                        Button("Cancel") { services.cancelHotkeyCapture() }
                    } else {
                        Button("Record a new hotkey…") { services.beginHotkeyCapture() }
                            .disabled(!hotkeyUI.monitorActive)
                        if !hotkeyUI.monitorActive {
                            Text("(requires the Accessibility permission)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                if settings.hotkey.isRiskySingleModifier {
                    Label("A single ⌘/⌃/⌥/⇧ is used all the time in shortcuts. Recommended: fn, a right-side key or a combination of two keys.",
                          systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }

                if settings.hotkey.keys.contains(.function) {
                    HStack {
                        Text("For fn: System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Open") { services.permissions.open(.keyboard) }
                            .controlSize(.small)
                    }
                }

                Toggle("Double-tap for hands-free", isOn: $settings.handsFreeEnabled)
                Text("Hold to dictate, release to insert. With hands-free: a double-tap starts continuous recording, another press stops it. Esc cancels at any time.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Text insertion") {
                Picker("Method", selection: $settings.insertionMethod) {
                    ForEach(InsertionMethod.allCases) { method in
                        Text(method.title).tag(method)
                    }
                }
                Toggle("Restore the clipboard after pasting", isOn: $settings.restoreClipboard)
                    .disabled(settings.insertionMethod != .paste)
                Toggle("Smart spacing (adds a space after existing text)", isOn: $settings.smartSpacing)
                // Literele depind de limba dictarii; engleza n-are diacritice, deci optiunea dispare.
                if let label = settings.language.diacriticsLabel {
                    Toggle(label, isOn: $settings.useDiacritics)
                    Text(diacriticsHint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section("Feedback") {
                Toggle("Sounds on start / stop", isOn: $settings.playSounds)
                Toggle("Show the recording pill", isOn: $settings.showOverlay)
                Picker("Pill position", selection: $settings.overlayPosition) {
                    ForEach(OverlayPosition.allCases) { position in
                        Text(position.title).tag(position)
                    }
                }
                .pickerStyle(.segmented)
                .disabled(!settings.showOverlay)
            }

            Section("System") {
                Toggle("Launch hau-di at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        guard newValue != LoginItem.isEnabled else { return }
                        do {
                            try LoginItem.set(newValue)
                            loginError = nil
                        } catch {
                            loginError = error.localizedDescription
                            launchAtLogin = LoginItem.isEnabled
                        }
                    }
                if let loginError {
                    Text(loginError).font(.caption).foregroundStyle(.orange)
                }
            }

            Section("About") {
                LabeledContent("Version", value: AppInfo.version)
                LabeledContent("Author", value: AppInfo.author)
                LabeledContent("Company") {
                    HStack(spacing: 4) {
                        Link(AppInfo.company, destination: AppInfo.website)
                        Text("[CIF \(AppInfo.companyCIF)]")
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                }
                HStack {
                    Link("Made with Claude Code", destination: URL(string: "https://claude.com/claude-code")!)
                    Spacer()
                    Link("Support hau-di (voluntary payment)", destination: AppInfo.voluntaryPaymentURL)
                }
                .font(.caption)
                // Notele legale cerute de GPL v3 (sectiunea 5d) pentru programele cu interfata.
                Text("hau-di is free software: you can redistribute and modify it under the terms of the GNU General Public License v3. It comes with ABSOLUTELY NO WARRANTY. The cx.ro logo and the hau-di icons are not covered by the license.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("License (GPL v3)") { openLegal("LICENSE") }
                    Button("Third-party licenses") { openLegal("THIRD_PARTY_NOTICES") }
                    Button("Logo and icons") { openLegal("BRANDING") }
                    Spacer()
                    if let source = AppInfo.sourceURL {
                        Link("Source code", destination: source)
                    }
                }
                .controlSize(.small)
            }
        }
        .formStyle(.grouped)
    }

    /// Ce inseamna „fara diacritice” in limba dictarii.
    private var diacriticsHint: String {
        let language = settings.language
        let marks: String
        let rule: String
        switch language {
        case .romanian: marks = "diacritics"; rule = ""
        case .german: marks = "umlauts and ß"; rule = " (ä → ae, ö → oe, ü → ue, ß → ss)"
        case .spanish: marks = "accents"; rule = " (ñ stays: it is a letter, not an accent)"
        case .french: marks = "accents"; rule = " (ç → c, œ → oe)"
        default: marks = "accents"; rule = ""
        }
        return "Off: the text is inserted without \(marks), the way \(language.englishName) is written without them\(rule). With Claude, the prompt asks for it; without Claude, they are removed from the transcript. Also in the menu bar."
    }

    private func openLegal(_ name: String) {
        guard let url = AppInfo.legalFile(name) else { return }
        NSWorkspace.shared.open(url)
    }
}

struct TranscriptionSettingsView: View {
    let services: AppServices
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var transcription: TranscriptionService
    @ObservedObject private var controller: DictationController
    @State private var devices: [AudioInputDevice] = []
    @State private var defaultDeviceName = ""

    init(services: AppServices) {
        self.services = services
        _settings = ObservedObject(wrappedValue: services.settings)
        _transcription = ObservedObject(wrappedValue: services.transcription)
        _controller = ObservedObject(wrappedValue: services.controller)
    }

    var body: some View {
        Form {
            Section("Transcription model (Whisper, runs locally)") {
                Picker("Whisper model", selection: $settings.whisperModel) {
                    ForEach(WhisperModelOption.all) { option in
                        Text("\(option.title) · \(option.size)").tag(option.id)
                    }
                }
                Text(WhisperModelOption.option(for: settings.whisperModel).note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Toggle("Send the dictionary to Whisper as a hint", isOn: $settings.whisperDictionaryHint)

                HStack(spacing: 10) {
                    SetupStatusIcon(status: transcription.setupStatus, busy: transcription.isBusy, size: 16)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(transcription.activeTitle.isEmpty ? settings.currentEngineTitle : transcription.activeTitle)
                            .font(.callout.weight(.medium))
                        Text(transcription.statusText)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        if case .downloading(let fraction) = transcription.state {
                            ProgressView(value: fraction).frame(maxWidth: 240)
                        }
                    }
                    Spacer()
                    Button("Reload") { transcription.reload() }
                }
                Text("The first load of a model downloads its files and optimizes them for your Mac's Neural Engine (a few minutes). After that, it starts in a few seconds.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Last dictation: what Whisper heard") {
                WhisperWordsView(entry: controller.lastEntry)
            }

            Section("Language") {
                // Limba si „+ English” pe acelasi rand.
                LabeledContent("Dictation language") {
                    HStack(spacing: 12) {
                        Picker("Dictation language", selection: $settings.language) {
                            ForEach(DictationLanguage.allCases) { language in
                                Text(language.title).tag(language)
                            }
                        }
                        .labelsHidden()
                        .fixedSize()
                        if settings.language != .english {
                            Toggle("+ English", isOn: $settings.mixesEnglish)
                                .toggleStyle(.switch)
                                .help("You also say English words; Claude writes them in correct English.")
                        }
                    }
                }
                Text("Whisper always transcribes in the chosen language. With “+ English”, the Claude correction spells the words you say in English correctly, in English (in Romanian, e.g. “diploi” → “deploy”, “mitingul” → “meeting-ul”), while the rest of the text stays in the chosen language; without correction, they stay as Whisper wrote them. For a text entirely in English, choose English.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Section("Microphone") {
                Picker("Microphone", selection: $settings.microphoneUID) {
                    Text(defaultDeviceName.isEmpty ? "System default" : "System default (\(defaultDeviceName))")
                        .tag(String?.none)
                    ForEach(devices) { device in
                        Text(device.name).tag(String?.some(device.uid))
                    }
                }
                HStack {
                    Text("Bluetooth headphones (e.g. AirPods) switch to call mode when you use their microphone; the MacBook's built-in microphone usually gives better results.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Refresh") { refreshDevices() }
                        .controlSize(.small)
                }
            }

            Section("Model storage") {
                LabeledContent("Whisper models") {
                    Button("Show in Finder") { reveal(AppPaths.whisperKitBase) }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshDevices() }
    }

    private func refreshDevices() {
        devices = AudioDevices.inputDevices()
        defaultDeviceName = AudioDevices.defaultInputDeviceName() ?? ""
    }

    private func reveal(_ url: URL) {
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}
