import AppKit
import SwiftUI

struct SettingsView: View {
    let services: AppServices
    @ObservedObject private var navigation: SettingsNavigation

    init(services: AppServices) {
        self.services = services
        _navigation = ObservedObject(wrappedValue: services.navigation)
    }

    var body: some View {
        // Meniul de sus e acelasi control segmentat ca intervalele din Istoric: sectiunea aleasa are fundal albastru.
        VStack(spacing: 12) {
            Picker("Section", selection: $navigation.tab) {
                ForEach(SettingsTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            section(navigation.tab)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(12)
        .frame(minWidth: 700, minHeight: 540)
    }

    @ViewBuilder
    private func section(_ tab: SettingsTab) -> some View {
        switch tab {
        case .welcome: WelcomeView(services: services)
        case .general: GeneralSettingsView(services: services)
        case .transcription: TranscriptionSettingsView(services: services)
        case .ai: AISettingsView(services: services)
        case .dictionary: DictionarySettingsView(services: services)
        case .history: HistoryView(services: services)
        }
    }
}

/// Rand cu rombul de stare + actiune (folosit in onboarding): gri = nesetat, verde = setat, rosu = eroare.
struct StatusRow<Accessory: View>: View {
    let status: SetupStatus
    var busy = false
    let title: String
    let detail: String
    @ViewBuilder var accessory: () -> Accessory

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SetupStatusIcon(status: status, busy: busy, size: 18)
                .frame(width: 28, height: 22)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.headline)
                Text(detail)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 12)
            accessory()
        }
        .padding(.vertical, 4)
    }
}

struct WelcomeView: View {
    let services: AppServices
    @ObservedObject private var permissions: PermissionsManager
    @ObservedObject private var transcription: TranscriptionService
    @ObservedObject private var settings: AppSettings
    @ObservedObject private var apiKeys: APIKeyStore
    @ObservedObject private var hotkeyUI: HotkeyUIModel
    @State private var testText = ""

    init(services: AppServices) {
        self.services = services
        _permissions = ObservedObject(wrappedValue: services.permissions)
        _transcription = ObservedObject(wrappedValue: services.transcription)
        _settings = ObservedObject(wrappedValue: services.settings)
        _apiKeys = ObservedObject(wrappedValue: services.apiKeys)
        _hotkeyUI = ObservedObject(wrappedValue: services.hotkeyUI)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Welcome to hau-di").font(.largeTitle.weight(.semibold))
                    Text("Voice dictation in any app: hold \(settings.hotkey.displayString), speak, and the text (transcribed locally and corrected by Claude) appears in the active field.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 10) {
                        StatusRow(status: microphoneStatus, title: "1. Microphone",
                                  detail: microphoneDetail) {
                            if permissions.microphone != .authorized {
                                Button(permissions.microphone == .notDetermined ? "Allow" : "Open System Settings") {
                                    Task { await permissions.requestMicrophone() }
                                }
                            }
                        }
                        Divider()
                        StatusRow(status: SetupStatus(permissions.accessibility), title: "2. Accessibility",
                                  detail: "Required so hau-di can see the hotkey (including fn) and paste text into other apps. Turn on hau-di in the list, then come back here.") {
                            if !permissions.accessibility {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Button("Request permission") { permissions.requestAccessibility() }
                                    Button("Open System Settings") { permissions.open(.accessibility) }
                                        .buttonStyle(.link)
                                }
                            }
                        }
                        Divider()
                        StatusRow(status: hotkeyStatus, title: "3. Key listener",
                                  detail: hotkeyUI.monitorActive
                                    ? "Active\(hotkeyUI.listenOnly ? " (passive mode: Esc can't be intercepted)" : "")."
                                    : "Starts automatically once you grant Accessibility. If hau-di is already turned on and it still doesn't work, remove it from the list (−) and add it again.") {
                            if !hotkeyUI.monitorActive {
                                VStack(alignment: .trailing, spacing: 6) {
                                    Button("Retry") { services.restartHotkeyMonitor() }
                                    if permissions.accessibility {
                                        Button("Restart hau-di") { services.relaunch() }
                                            .buttonStyle(.link)
                                    }
                                }
                            }
                        }
                        Divider()
                        StatusRow(status: transcription.setupStatus, busy: transcription.isBusy,
                                  title: "4. Transcription model (local)",
                                  detail: "\(transcription.activeTitle.isEmpty ? settings.currentEngineTitle : transcription.activeTitle): \(transcription.statusText)") {
                            VStack(alignment: .trailing, spacing: 6) {
                                if case .downloading(let fraction) = transcription.state {
                                    ProgressView(value: fraction).frame(width: 120)
                                }
                                Button("Choose model") { services.navigation.tab = .transcription }
                                    .buttonStyle(.link)
                            }
                        }
                        Divider()
                        StatusRow(status: SetupStatus(apiKeys.hasKey), title: "5. Claude API key (optional)",
                                  detail: apiKeys.hasKey
                                    ? "Text, data and intent correction is on (\(services.models.displayName(for: services.models.resolvedID(for: settings.claudeModel))))."
                                    : "Without a key, the text is inserted exactly as the local model transcribed it.") {
                            Button(apiKeys.hasKey ? "AI settings" : "Add key") { services.navigation.tab = .ai }
                        }
                    }
                    .padding(6)
                }

                if settings.hotkey.keys.contains(.function) {
                    GroupBox {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: "globe").font(.title3)
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Using the fn (Globe) key").font(.headline)
                                Text("So that pressing fn doesn't open Emoji or Apple's Dictation: System Settings → Keyboard → “Press 🌐 key to” → Do Nothing.")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            Spacer()
                            Button("Open Keyboard") { permissions.open(.keyboard) }
                        }
                        .padding(6)
                    }
                }

                GroupBox("Try it here") {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Click in the box, hold \(settings.hotkey.displayString) and say something. Then, in Transcription, you can see what Whisper heard and how sure it was of each word.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        TextEditor(text: $testText)
                            .font(.body)
                            .frame(height: 90)
                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.secondary.opacity(0.3)))
                    }
                    .padding(6)
                }

                HStack {
                    Spacer()
                    Button("Done") {
                        settings.onboardingDone = true
                        NSApp.keyWindow?.close()
                    }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!permissions.allRequiredGranted)
                }
            }
            .padding(20)
        }
        .onAppear { permissions.refresh() }
    }

    private var microphoneStatus: SetupStatus {
        switch permissions.microphone {
        case .authorized: return .ok
        case .notDetermined: return .notSet
        default: return .error
        }
    }

    /// Rosu daca Accessibility e acordat, dar ascultarea tastelor tot nu a pornit.
    private var hotkeyStatus: SetupStatus {
        if hotkeyUI.monitorActive { return .ok }
        return permissions.accessibility ? .error : .notSet
    }

    private var microphoneDetail: String {
        switch permissions.microphone {
        case .authorized: return "Access granted. Audio never leaves your Mac."
        case .notDetermined: return "hau-di listens only while you hold the hotkey."
        default: return "Access denied. Turn on hau-di in System Settings → Privacy & Security → Microphone."
        }
    }
}
