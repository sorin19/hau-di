import AppKit
import Combine

@MainActor
final class HistoryModel: ObservableObject {
    @Published private(set) var entries: [HistoryEntry]
    private let store: HistoryStore

    init(store: HistoryStore) {
        self.store = store
        entries = store.load()
    }

    func add(_ entry: HistoryEntry) { entries = store.append(entry) }
    func remove(_ id: UUID) { entries = store.remove(id: id) }
    func clear() {
        store.clear()
        entries = []
    }
}

/// Orchestreaza fluxul: tasta apasata -> inregistrare -> transcriere locala -> corectie Claude -> inserare.
@MainActor
final class DictationController: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case recording(handsFree: Bool)
    }

    enum ProcessingState: Equatable {
        case idle, transcribing, correcting, inserting
    }

    /// Cat timp se inregistreaza, sistemul nu porneste screensaver-ul (vezi IdleSleepGuard).
    @Published private(set) var recording: RecordingState = .idle {
        didSet {
            if recording == .idle { idleGuard.end() } else { idleGuard.begin() }
        }
    }
    @Published private(set) var processing: ProcessingState = .idle
    @Published private(set) var lastEntry: HistoryEntry?
    @Published private(set) var lastError: String?

    /// Apelat cand lipseste o permisiune (deschide fereastra de setari).
    var onNeedsPermissions: (() -> Void)?

    private let settings: AppSettings
    private let permissions: PermissionsManager
    private let transcription: TranscriptionService
    private let history: HistoryModel
    private let apiKeys: APIKeyStore
    private let models: ModelCatalogStore
    private let budget: BudgetTracker
    private let overlay: OverlayController
    private let monitor: HotkeyMonitor
    let recorder = AudioRecorder()
    private let inserter = TextInserter()
    private let corrector = ClaudeCorrector()
    private let idleGuard = IdleSleepGuard()
    private var systemObservers: [NSObjectProtocol] = []

    private var sessionID = 0
    private var cancelGeneration = 0
    private var pendingJobs = 0
    private var recordingStartedAt: Date?
    private var contextTask: Task<FocusSnapshot, Never>?
    private var revealTask: Task<Void, Never>?
    private var processingChain: Task<Void, Never>?

    init(settings: AppSettings, permissions: PermissionsManager, transcription: TranscriptionService,
         history: HistoryModel, apiKeys: APIKeyStore, models: ModelCatalogStore, budget: BudgetTracker,
         overlay: OverlayController, monitor: HotkeyMonitor) {
        self.settings = settings
        self.permissions = permissions
        self.transcription = transcription
        self.history = history
        self.apiKeys = apiKeys
        self.models = models
        self.budget = budget
        self.overlay = overlay
        self.monitor = monitor

        recorder.onLevel = { [weak self] level in
            MainActor.assumeIsolated { self?.overlay.model.push(level: level) }
        }
        observeInterruptions()
    }

    /// Ecranul blocat, screensaver-ul pornit (ex: blocare manuala), sleep sau alt utilizator: dictarea in curs nu se
    /// pierde. Se transcrie si se corecteaza, dar textul ajunge doar in clipboard si in istoric: nu lipim nimic pe
    /// ecranul de blocare (ar putea ajunge in campul de parola).
    private func observeInterruptions() {
        let interrupt: @Sendable (Notification) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.interruptRecording() }
        }
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            systemObservers.append(distributed.addObserver(forName: Notification.Name(name), object: nil, queue: .main,
                                                           using: interrupt))
        }
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            systemObservers.append(workspace.addObserver(forName: name, object: nil, queue: .main, using: interrupt))
        }
    }

    private func interruptRecording() {
        guard case .recording = recording else { return }
        // Eliberarea tastelor poate sa nu mai ajunga la noi: pornim curat la urmatoarea apasare.
        monitor.resetStateMachine()
        finishRecording(insert: false)
    }

    var isBusy: Bool { recording != .idle || pendingJobs > 0 }

    var statusTint: StatusTint {
        if case .recording = recording { return .recording }
        switch processing {
        case .idle: return .idle
        case .transcribing: return .transcribing
        case .correcting: return .correcting
        case .inserting: return .inserting
        }
    }

    var statusText: String {
        switch recording {
        case .recording(let handsFree): return handsFree ? "Recording (hands-free)…" : "Recording…"
        case .idle: break
        }
        switch processing {
        case .idle: return "Ready"
        case .transcribing: return "Transcribing…"
        case .correcting: return "Correcting with Claude…"
        case .inserting: return "Inserting text…"
        }
    }

    // MARK: - Evenimente

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressBegan: beginRecording(handsFree: false)
        case .handsFreeStarted: beginRecording(handsFree: true)
        case .pressEnded, .handsFreeStopRequested: finishRecording()
        case .pressAborted, .tapped: abortRecording(silently: true)
        }
    }

    /// Esc: anuleaza inregistrarea sau procesarea in curs (nimic nu se insereaza).
    func handleEscape() {
        if case .recording = recording {
            abortRecording(silently: false)
            monitor.resetStateMachine()
            return
        }
        guard pendingJobs > 0 else { return }
        cancelGeneration += 1
        processingChain?.cancel()
        processing = .idle
        overlay.flash(.message("Canceled", isError: false), duration: 0.9)
        updateEscapeCapture()
    }

    // MARK: - Inregistrare

    private func beginRecording(handsFree: Bool) {
        if case .recording = recording {
            if handsFree {
                recording = .recording(handsFree: true)
                overlay.show(.recording(handsFree: true))
            }
            return
        }

        permissions.refresh()
        guard permissions.microphone == .authorized else {
            monitor.resetStateMachine()
            fail("hau-di doesn't have microphone access. Open Settings → Start.")
            onNeedsPermissions?()
            return
        }

        sessionID += 1
        let session = sessionID
        recording = .recording(handsFree: handsFree)
        recordingStartedAt = Date()
        lastError = nil
        updateEscapeCapture()

        // Aplicatia, fereastra si campul din fata, retinute la inceputul dictarii (in fundal: apeluri AX sincrone).
        // Textul se insereaza acolo, chiar daca intre timp utilizatorul trece in alta fereastra.
        let includeField = settings.smartSpacing || (settings.correctionEnabled && settings.sendFieldText)
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier != AppInfo.bundleID {
            let pid = front.processIdentifier
            let name = front.localizedName
            let bundle = front.bundleIdentifier
            contextTask = Task.detached(priority: .userInitiated) {
                FocusInspector.capture(pid: pid, appName: name, bundleID: bundle, includeTextBeforeCursor: includeField)
            }
        } else {
            contextTask = nil
        }

        let deviceUID = settings.microphoneUID
        let recorder = self.recorder
        Task { [weak self] in
            do {
                try await recorder.start(deviceUID: deviceUID)
            } catch {
                guard let self, self.sessionID == session, case .recording = self.recording else { return }
                self.recording = .idle
                self.monitor.resetStateMachine()
                self.updateEscapeCapture()
                self.fail(error.localizedDescription)
            }
        }

        // Pastila si sunetul apar dupa 150 ms, ca scurtaturile obisnuite (ex: fn + sageti) sa nu "clipeasca".
        revealTask?.cancel()
        let delay: UInt64 = handsFree ? 0 : 150_000_000
        revealTask = Task { [weak self] in
            if delay > 0 { try? await Task.sleep(nanoseconds: delay) }
            guard let self, !Task.isCancelled, self.sessionID == session,
                  case .recording(let isHandsFree) = self.recording else { return }
            self.overlay.show(.recording(handsFree: isHandsFree))
            if self.settings.playSounds { SoundEffects.start() }
        }
    }

    private func abortRecording(silently: Bool) {
        guard case .recording = recording else { return }
        recording = .idle
        sessionID += 1
        revealTask?.cancel()
        contextTask?.cancel()
        contextTask = nil
        recorder.cancel()
        updateEscapeCapture()
        if silently {
            restoreOverlayForProcessing()
        } else {
            overlay.flash(.message("Canceled", isError: false), duration: 0.9)
        }
    }

    /// insert: false = textul merge doar in clipboard si in istoric (dictare intrerupta de blocarea ecranului).
    private func finishRecording(insert: Bool = true) {
        guard case .recording = recording else { return }
        recording = .idle
        sessionID += 1
        revealTask?.cancel()
        let held = Date().timeIntervalSince(recordingStartedAt ?? Date())
        let context = contextTask
        contextTask = nil
        let generation = cancelGeneration
        if settings.playSounds && held > 0.3 { SoundEffects.stop() }

        pendingJobs += 1
        updateEscapeCapture()
        if processing == .idle { processing = .transcribing }
        overlay.show(.transcribing)

        let recorder = self.recorder
        let stopTask = Task { await recorder.stop() }
        let previous = processingChain
        processingChain = Task { [weak self] in
            let samples = await stopTask.value
            await previous?.value
            guard let self else { return }
            await self.process(samples: samples, context: context, generation: generation, insert: insert)
            self.pendingJobs -= 1
            // Starea ramasa de la job-ul terminat nu mai e valabila: urmeaza alt job sau repausul.
            self.processing = self.pendingJobs == 0 ? .idle : .transcribing
            self.settleOverlay()
            self.updateEscapeCapture()
        }
    }

    // MARK: - Procesare

    private func process(samples: [Float], context: Task<FocusSnapshot, Never>?, generation: Int, insert: Bool) async {
        guard generation == cancelGeneration else { return }
        let audioDuration = Double(samples.count) / AudioRecorder.sampleRate
        guard audioDuration >= 0.3, AudioAnalysis.containsSpeech(samples) else {
            // Apasare prea scurta / fara vorbire: o ignoram; pastila o aranjeaza settleOverlay() dupa job.
            if audioDuration >= 0.8 {
                showIfIdle(.message("Nothing heard. Check the microphone in Settings → Transcription.", isError: false), flash: 2.0)
            }
            return
        }

        // 1. Transcriere locala
        processing = .transcribing
        if transcription.isReady {
            showIfIdle(.transcribing)
        } else {
            showIfIdle(.message("Waiting for the model: \(transcription.statusText)", isError: false))
        }
        let transcriptionStart = Date()
        let transcript: SpeechTranscript
        do {
            transcript = try await transcription.transcribe(samples, language: settings.language,
                                                            vocabulary: settings.whisperVocabulary)
        } catch {
            guard generation == cancelGeneration else { return }
            fail("Transcription failed: \(error.localizedDescription)")
            return
        }
        let transcriptionTime = Date().timeIntervalSince(transcriptionStart)
        guard generation == cancelGeneration else { return }

        let cleaned = TranscriptCleaner.clean(transcript.text)
        Log.asr.info("Transcriere in \(transcriptionTime, format: .fixed(precision: 2))s, \(cleaned.count) caractere")
        guard !cleaned.isEmpty else {
            showIfIdle(.message("No words recognized.", isError: false), flash: 1.6)
            return
        }

        let snapshot = await context?.value

        // 2. Corectie AI (Claude): text, date, intentie
        var finalText = cleaned
        var correctedBy: String?
        var correctionTime: Double?
        var note: String?
        var correctionFailed = false
        var correctionFailureReason = ""
        var usage: CorrectionUsage?
        /// Mesajul de buget de pe pastila: atins (fara corectie) sau avertismentul de 80%.
        var budgetMessage: String?

        if settings.correctionEnabled {
            if apiKeys.hasKey, budget.status(limit: settings.monthlyBudget) == .exceeded {
                // Bugetul lunar e atins: pana la luna urmatoare, textul se insereaza asa cum l-a transcris Whisper.
                note = "No AI correction: the monthly budget (\(CostFormat.usd(settings.monthlyBudgetUSD))) has been reached."
                budgetMessage = "Inserted without AI correction:\nmonthly budget reached."
            } else if apiKeys.hasKey, let key = apiKeys.apiKey {
                processing = .correcting
                showIfIdle(.correcting)
                let correctionContext = CorrectionContext(
                    appName: settings.sendAppContext ? snapshot?.appName : nil,
                    bundleID: settings.sendAppContext ? snapshot?.bundleID : nil,
                    windowTitle: settings.sendAppContext ? snapshot?.windowTitle : nil,
                    textBeforeCursor: settings.sendFieldText ? snapshot?.textBeforeCursor : nil,
                    date: Date()
                )
                let options = settings.claudeOptions(audioDuration: audioDuration, models: models)
                do {
                    let outcome = try await corrector.correct(transcript: cleaned, context: correctionContext,
                                                              config: settings.correctionConfig,
                                                              options: options, apiKey: key)
                    models.noteRejected(outcome.rejectedFeatures, for: options.model)
                    finalText = outcome.text
                    correctedBy = outcome.servedBy ?? options.model
                    correctionTime = outcome.duration
                    usage = outcome.usage
                    Log.ai.info("Corectie in \(outcome.duration, format: .fixed(precision: 2))s, cost \(CostFormat.usd(outcome.usage?.costUSD ?? 0), privacy: .public)")
                } catch {
                    if let failure = error as? CorrectionError {
                        models.noteRejected(failure.rejectedFeatures, for: options.model)
                    }
                    // Model retras intre doua reincarcari ale listei: o reincarcam, ca urmatoarea dictare
                    // sa treaca pe cel mai nou model din aceeasi familie.
                    if case .http(404, _, _)? = error as? AnthropicError {
                        models.refresh(apiKey: key)
                    }
                    guard generation == cancelGeneration else { return }
                    // Si cand rezultatul e respins, requestul a fost platit: pastram costul in istoric.
                    usage = (error as? CorrectionError)?.usage
                    note = "AI correction failed: \(error.localizedDescription)"
                    correctionFailureReason = error.localizedDescription
                    correctionFailed = true
                    Log.ai.error("\(error.localizedDescription, privacy: .public)")
                }
                // Se numara si corecturile respinse: au fost platite.
                if budget.add(usage?.costUSD, limit: settings.monthlyBudget) {
                    budgetMessage = budgetWarning()
                }
                models.refreshIfStale(apiKey: key)
            } else {
                // Fara cheie: inseram textul brut fara sa tratam asta ca eroare (meniul arata indicatia).
                note = "No AI correction: the API key is missing."
            }
        }
        guard generation == cancelGeneration else { return }
        if !settings.useDiacritics, settings.language.diacriticLetters != nil {
            // Fara Claude e singura sursa; cu Claude e plasa de siguranta pentru diacriticele scapate.
            finalText = Diacritics.strip(finalText, language: settings.language)
        }
        guard !finalText.isEmpty else {
            showIfIdle(.message("Nothing to insert.", isError: false), flash: 1.2)
            return
        }

        // 3. Inserare in campul activ
        if settings.smartSpacing {
            finalText = SmartSpacing.adjust(finalText, precedingText: snapshot?.textBeforeCursor)
        }
        processing = .inserting
        var insertionFailed = false
        if !insert {
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(finalText, forType: .string)
            note = [note, Self.interruptedNote].compactMap { $0 }.joined(separator: " ")
        } else {
            do {
                try await inserter.insert(finalText, method: settings.insertionMethod,
                                          restoreClipboard: settings.restoreClipboard, target: snapshot)
            } catch {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(finalText, forType: .string)
                let message = "\(error.localizedDescription) The text is in the clipboard."
                note = [note, message].compactMap { $0 }.joined(separator: " ")
                insertionFailed = true
                fail(message)
                if let insertError = error as? TextInserter.InsertError, case .accessibilityMissing = insertError {
                    onNeedsPermissions?()
                }
            }
        }

        let entry = HistoryEntry(appName: snapshot?.appName, rawText: cleaned, finalText: finalText,
                                 engine: transcription.activeTitle, correctedBy: correctedBy,
                                 audioDuration: audioDuration, transcriptionTime: transcriptionTime,
                                 correctionTime: correctionTime, note: note, usage: usage,
                                 windowTitle: snapshot?.windowTitle,
                                 words: transcript.words.isEmpty ? nil : transcript.words)
        lastEntry = entry
        if settings.historyEnabled { history.add(entry) }

        // Eroarea de inserare a afisat-o deja fail(); textul ramane in istoric si in clipboard.
        if insertionFailed { return }
        if !insert {
            lastError = Self.interruptedNote
            showIfIdle(.message(Self.interruptedNote, isError: true), flash: Self.errorMessageDuration)
            return
        }
        if correctionFailed, let note {
            lastError = note
            showIfIdle(.message("Inserted without AI correction.\n\(correctionFailureReason)", isError: true),
                       flash: Self.errorMessageDuration)
        } else if let budgetMessage {
            showIfIdle(.message(budgetMessage, isError: false), flash: 4)
        } else {
            showIfIdle(.success, flash: 0.7)
        }
    }

    /// "Ai folosit 82% din bugetul lunar: $16.40 din $20.00."
    private func budgetWarning() -> String {
        let limit = settings.monthlyBudgetUSD
        let spent = budget.spentThisMonth
        let percent = Int((spent / max(limit, 0.01) * 100).rounded(.down))
        return "You've used \(percent)% of your monthly budget:\n\(CostFormat.usd(spent)) of \(CostFormat.usd(limit))."
    }

    // MARK: - Utilitare

    private func updateEscapeCapture() {
        monitor.setEscapeCapture(recording != .idle || pendingJobs > 0)
    }

    /// Nu acoperim pastila de inregistrare daca utilizatorul a inceput deja o dictare noua.
    private func showIfIdle(_ mode: OverlayMode, flash: TimeInterval? = nil) {
        guard recording == .idle else { return }
        if let flash {
            overlay.flash(mode, duration: flash)
        } else {
            overlay.show(mode)
        }
    }

    /// Dupa o inregistrare anulata: arata ce se proceseaza acum sau, daca nu e nimic, scoate pastila.
    private func restoreOverlayForProcessing() {
        guard recording == .idle else { return }
        switch processing {
        case .transcribing where pendingJobs > 0: overlay.show(.transcribing)
        case .correcting: overlay.show(.correcting)
        case .idle, .transcribing, .inserting: overlay.hideIfPersistent()
        }
    }

    /// Dupa fiecare job: daca nu mai e nimic de procesat, pastila nu ramane agatata pe „Transcriu…” sau
    /// „Corectez…”. Mesajele cu temporizator (Inserat, erori) se inchid singure, la timpul lor.
    private func settleOverlay() {
        guard recording == .idle, pendingJobs == 0 else { return }
        overlay.hideIfPersistent()
    }

    /// Cat ramane pe ecran un mesaj de eroare (corectia Claude, microfon, transcriere, inserare), ca sa poata fi citit.
    private static let errorMessageDuration: TimeInterval = 6
    /// Dictare oprita de blocarea ecranului sau de sleep: textul e in clipboard si in istoric, nu s-a lipit nicaieri.
    private static let interruptedNote = "The screen locked during dictation: the text is in the clipboard and in History."

    private func fail(_ message: String) {
        lastError = message
        Log.app.error("\(message, privacy: .public)")
        if settings.playSounds { SoundEffects.error() }
        showIfIdle(.message(message, isError: true), flash: Self.errorMessageDuration)
    }
}
