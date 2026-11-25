import AppKit
import Combine
import SwiftUI

@main
struct HauDiApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView(services: AppServices.shared)
        } label: {
            MenuBarLabel(controller: AppServices.shared.controller)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        terminateOtherInstances()
        AppServices.shared.start()
    }

    /// The last instance launched wins: we quit the old one (e.g. the copy run from Xcode
    /// vs. the one in /Applications), otherwise both would listen for the key combination and insert the text twice.
    private func terminateOtherInstances() {
        let current = NSRunningApplication.current.processIdentifier
        for bundleID in [AppInfo.bundleID] + AppInfo.legacyBundleIDs {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            where app.processIdentifier != current {
                app.terminate()
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// ⌘Q (or hau-di → Quit) in the settings window only closes the window: hau-di stays in the menu bar.
    /// We really quit on "Quit" in the menu bar menu and on requests that arrive as Apple Events
    /// (logout, restart, shutdown, Quit from the Dock, a new hau-di instance that replaces this one).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let services = AppServices.shared
        if services.quitRequested || NSAppleEventManager.shared().currentAppleEvent != nil {
            return .terminateNow
        }
        if services.windows.isSettingsVisible {
            services.windows.closeSettings()
        }
        return .terminateCancel
    }
}

/// UI state for the key monitor (recording a new key combination, status).
@MainActor
final class HotkeyUIModel: ObservableObject {
    @Published var isCapturing = false
    @Published var live: Set<ModifierKey> = []
    @Published var monitorActive = false
    @Published var listenOnly = false
}

/// Composition root: creates and wires together all of the app's services.
@MainActor
final class AppServices {
    static let shared = AppServices()

    let settings: AppSettings
    let permissions: PermissionsManager
    let apiKeys: APIKeyStore
    let history: HistoryModel
    let transcription: TranscriptionService
    let overlay: OverlayController
    let hotkeyMonitor: HotkeyMonitor
    let hotkeyUI: HotkeyUIModel
    let navigation: SettingsNavigation
    let models: ModelCatalogStore
    let budget: BudgetTracker
    let controller: DictationController

    private(set) lazy var windows = WindowManager(navigation: navigation) { [unowned self] in
        AnyView(SettingsView(services: self))
    }

    private var cancellables = Set<AnyCancellable>()
    private var started = false
    /// Quit requested explicitly (from the menu bar menu or on relaunch); otherwise ⌘Q only closes the settings.
    private(set) var quitRequested = false

    func quit() {
        quitRequested = true
        NSApp.terminate(nil)
    }

    private init() {
        settings = AppSettings()
        permissions = PermissionsManager()
        apiKeys = APIKeyStore()
        history = HistoryModel(store: HistoryStore(fileURL: AppPaths.historyFile,
                                                   legacyFileURL: AppPaths.legacyHistoryFile, retentionMonths: 3))
        transcription = TranscriptionService()
        overlay = OverlayController()
        hotkeyMonitor = HotkeyMonitor(hotkey: settings.hotkey, handsFreeEnabled: settings.handsFreeEnabled)
        hotkeyUI = HotkeyUIModel()
        navigation = SettingsNavigation()
        models = ModelCatalogStore(fileURL: AppPaths.modelsFile, pricesURL: AppInfo.pricingURL,
                                   installID: settings.installID)
        // On the first launch with the budget, the month's total starts from what the history shows for this month.
        let month = HistoryRange.thisMonth.dates()
        budget = BudgetTracker(initialSpend: HistorySummary(entries: history.entries.between(month.from, month.to)).totalCostUSD)
        controller = DictationController(settings: settings, permissions: permissions, transcription: transcription,
                                         history: history, apiKeys: apiKeys, models: models, budget: budget,
                                         overlay: overlay, monitor: hotkeyMonitor)
    }

    var transcriptionConfiguration: TranscriptionService.Configuration {
        .init(whisperModel: settings.whisperModel, language: settings.language)
    }

    func start() {
        guard !started else { return }
        started = true
        LegacyMigration.removeLegacyCaches()

        wireHotkeyMonitor()
        observeChanges()
        controller.onNeedsPermissions = { [weak self] in
            self?.windows.showSettings(tab: .welcome)
        }

        overlay.isEnabled = settings.showOverlay
        overlay.atTop = settings.overlayPosition == .top
        permissions.refresh()
        permissions.startPolling()
        startHotkeyMonitorIfPossible()
        transcription.configure(transcriptionConfiguration)
        models.refreshIfStale(apiKey: apiKeys.apiKey)

        if !settings.onboardingDone || !permissions.allRequiredGranted {
            windows.showSettings(tab: .welcome)
        }
    }

    // MARK: - Key monitor

    private func wireHotkeyMonitor() {
        hotkeyMonitor.onEvent = { [weak self] event in
            MainActor.assumeIsolated { self?.controller.handle(event) }
        }
        hotkeyMonitor.onEscape = { [weak self] in
            MainActor.assumeIsolated { self?.controller.handleEscape() }
        }
        hotkeyMonitor.onCaptureProgress = { [weak self] keys in
            MainActor.assumeIsolated { self?.hotkeyUI.live = keys }
        }
        hotkeyMonitor.onCaptureFinished = { [weak self] hotkey in
            MainActor.assumeIsolated { self?.finishHotkeyCapture(hotkey) }
        }
    }

    func startHotkeyMonitorIfPossible() {
        permissions.refresh()
        if hotkeyMonitor.isRunning {
            // Started initially with Input Monitoring only; with Accessibility we can also consume Esc.
            if hotkeyMonitor.isListenOnly && permissions.accessibility {
                hotkeyMonitor.stop()
                hotkeyMonitor.start()
            }
        } else if permissions.accessibility || permissions.inputMonitoring {
            hotkeyMonitor.start()
        }
        hotkeyUI.monitorActive = hotkeyMonitor.isRunning
        hotkeyUI.listenOnly = hotkeyMonitor.isListenOnly
    }

    func restartHotkeyMonitor() {
        hotkeyMonitor.stop()
        startHotkeyMonitorIfPossible()
    }

    /// Some macOS versions allow creating the event tap only after the app is relaunched.
    func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, _ in
            DispatchQueue.main.async { AppServices.shared.quit() }
        }
    }

    func beginHotkeyCapture() {
        guard hotkeyMonitor.isRunning else { return }
        hotkeyUI.live = []
        hotkeyUI.isCapturing = true
        hotkeyMonitor.beginCapture()
    }

    func cancelHotkeyCapture() {
        hotkeyMonitor.cancelCapture()
        hotkeyUI.isCapturing = false
        hotkeyUI.live = []
    }

    private func finishHotkeyCapture(_ hotkey: Hotkey?) {
        hotkeyUI.isCapturing = false
        hotkeyUI.live = []
        if let hotkey, hotkey.isValid {
            settings.hotkey = hotkey
        }
    }

    // MARK: - Reacting to changes

    private func observeChanges() {
        settings.$hotkey
            .combineLatest(settings.$handsFreeEnabled)
            .dropFirst()
            .sink { [weak self] hotkey, handsFree in
                self?.hotkeyMonitor.update(hotkey: hotkey, handsFreeEnabled: handsFree)
            }
            .store(in: &cancellables)

        settings.$whisperModel
            .combineLatest(settings.$language)
            .dropFirst()
            .debounce(for: .milliseconds(400), scheduler: RunLoop.main)
            .sink { [weak self] whisperModel, language in
                self?.transcription.configure(.init(whisperModel: whisperModel, language: language))
            }
            .store(in: &cancellables)

        settings.$overlayPosition
            .dropFirst()
            .sink { [weak self] position in
                self?.overlay.atTop = position == .top
            }
            .store(in: &cancellables)

        settings.$showOverlay
            .dropFirst()
            .sink { [weak self] show in
                self?.overlay.isEnabled = show
                if !show { self?.overlay.hide() }
            }
            .store(in: &cancellables)

        permissions.$accessibility
            .combineLatest(permissions.$inputMonitoring)
            .removeDuplicates { $0 == $1 }
            .dropFirst()
            .sink { [weak self] _, _ in
                // The publisher emits before the value is written; defer by one runloop pass.
                DispatchQueue.main.async { self?.startHotkeyMonitorIfPossible() }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Windows

enum SettingsTab: String, Hashable, CaseIterable, Identifiable {
    case welcome, general, transcription, ai, dictionary, history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .welcome: return "Start"
        case .general: return "General"
        case .transcription: return "Transcription"
        case .ai: return "AI Correction"
        case .dictionary: return "Dictionary"
        case .history: return "History"
        }
    }
}

@MainActor
final class SettingsNavigation: ObservableObject {
    @Published var tab: SettingsTab = .welcome
}

/// The settings window, managed from AppKit (more predictable than the Settings scene in a menu bar app).
@MainActor
final class WindowManager: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private let navigation: SettingsNavigation
    private let makeContent: () -> AnyView

    init(navigation: SettingsNavigation, makeContent: @escaping () -> AnyView) {
        self.navigation = navigation
        self.makeContent = makeContent
        super.init()
    }

    func showSettings(tab: SettingsTab? = nil) {
        if let tab { navigation.tab = tab }
        if window == nil {
            let hosting = NSHostingController(rootView: makeContent())
            hosting.sizingOptions = []
            let window = NSWindow(contentViewController: hosting)
            window.title = "hau-di"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 780, height: 620))
            window.minSize = NSSize(width: 700, height: 540)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // While the window is open, the app appears in the Dock and in ⌘⇥.
        NSApp.setActivationPolicy(.regular)
        bringToFront()
        // The menu bar panel closes in the meantime, and macOS can give the focus back to the app that had it
        // (Terminal...), leaving the window behind it: once the panel is gone, the window comes forward again.
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard let self, self.isSettingsVisible, !(NSApp.isActive && self.window?.isKeyWindow == true) else { return }
            self.bringToFront()
        }
    }

    private func bringToFront() {
        guard let window else { return }
        // macOS 14+ activates apps cooperatively: NSApp.activate() can be declined while another app is active,
        // which is usually the case for a menu bar app. The older call asks for it outright, which is what a click
        // on Settings… or History means.
        NSApp.activate()
        (NSApp as LegacyActivation).activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // In front of the other apps' windows even if macOS still declines to activate hau-di.
        window.orderFrontRegardless()
    }

    var isSettingsVisible: Bool { window?.isVisible == true }

    func closeSettings() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}

/// NSApplication.activate(ignoringOtherApps:), deprecated in macOS 14 but still honored, called without the
/// deprecation warning (see WindowManager.bringToFront).
@MainActor
private protocol LegacyActivation {
    func activate(ignoringOtherApps flag: Bool)
}

extension NSApplication: LegacyActivation {}
