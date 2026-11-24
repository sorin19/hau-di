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

    /// Ultima instanta pornita castiga: o inchidem pe cea veche (ex: copia rulata din Xcode
    /// vs. cea din /Applications), altfel ambele ar asculta combinatia si ar insera textul de doua ori.
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

    /// ⌘Q (sau hau-di → Quit) din fereastra de setari inchide doar fereastra: hau-di ramane in bara de meniu.
    /// Inchidem de-adevaratelea la „Iesire” din meniul din bara si la cererile venite prin Apple Event
    /// (logout, restart, oprire, Quit din Dock, o instanta noua hau-di care o inlocuieste pe asta).
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

/// Starea UI pentru monitorul de taste (inregistrarea unei combinatii noi, status).
@MainActor
final class HotkeyUIModel: ObservableObject {
    @Published var isCapturing = false
    @Published var live: Set<ModifierKey> = []
    @Published var monitorActive = false
    @Published var listenOnly = false
}

/// Radacina de compozitie: creeaza si leaga toate serviciile aplicatiei.
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
    /// Iesire ceruta explicit (din meniul din bara sau la repornire); altfel ⌘Q doar inchide setarile.
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
        // La prima pornire cu bugetul, suma lunii porneste de la ce arata istoricul pentru luna asta.
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

    // MARK: - Monitorul de taste

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
            // Pornit initial doar cu Input Monitoring; cu Accessibility putem consuma si Esc.
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

    /// Unele versiuni macOS permit crearea event tap-ului abia dupa repornirea aplicatiei.
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

    // MARK: - Reactii la schimbari

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
                // Publisher-ul emite inainte ca valoarea sa fie scrisa; amanam o bucla de runloop.
                DispatchQueue.main.async { self?.startHotkeyMonitorIfPossible() }
            }
            .store(in: &cancellables)
    }
}

// MARK: - Ferestre

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

/// Fereastra de setari gestionata din AppKit (mai previzibil decat scena Settings intr-o aplicatie de bara de meniu).
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
        // Cat timp fereastra e deschisa, aplicatia apare in Dock si in ⌘⇥.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    var isSettingsVisible: Bool { window?.isVisible == true }

    func closeSettings() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
    }
}
