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

/// Orchestrates the flow: key pressed -> recording -> local transcription -> Claude correction -> insertion.
@MainActor
final class DictationController: ObservableObject {
    enum RecordingState: Equatable {
        case idle
        case recording(handsFree: Bool)
    }

    enum ProcessingState: Equatable {
        case idle, transcribing, correcting, inserting
    }

    /// While recording, the system doesn't start the screensaver (see IdleSleepGuard).
    @Published private(set) var recording: RecordingState = .idle {
        didSet {
            if recording == .idle { idleGuard.end() } else { idleGuard.begin() }
        }
    }
    @Published private(set) var processing: ProcessingState = .idle
    @Published private(set) var lastEntry: HistoryEntry?
    @Published private(set) var lastError: String?

    /// Called when a permission is missing (opens the settings window).
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

    /// Screen locked, screensaver started (e.g. a manual lock), sleep or another user: the dictation in progress isn't
    /// lost. It is transcribed and corrected, but the text goes only to the clipboard and the history: we don't paste
    /// anything on the lock screen (it could end up in the password field).
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
        // The key release may never reach us: start clean on the next press.
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

    // MARK: - Events

    func handle(_ event: HotkeyEvent) {
        switch event {
        case .pressBegan: beginRecording(handsFree: false)
        case .handsFreeStarted: beginRecording(handsFree: true)
        case .pressEnded, .handsFreeStopRequested: finishRecording()
        case .pressAborted, .tapped: abortRecording(silently: true)
        }
    }

    /// Esc: cancels the recording or the processing in progress (nothing is inserted).
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

    // MARK: - Recording

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

        // The front app, window and field, captured when dictation starts (in the background: synchronous AX calls).
        // The text is inserted there, even if the user switches to another window in the meantime.
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

        // The pill and the sound appear after 150 ms, so ordinary shortcuts (e.g. fn + arrows) don't "flicker".
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

    /// insert: false = the text goes only to the clipboard and the history (dictation interrupted by a screen lock).
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
            // The state left over from the finished job is no longer valid: next comes another job, or idle.
            self.processing = self.pendingJobs == 0 ? .idle : .transcribing
            self.settleOverlay()
            self.updateEscapeCapture()
        }
    }

    // MARK: - Processing

    private func process(samples: [Float], context: Task<FocusSnapshot, Never>?, generation: Int, insert: Bool) async {
        guard generation == cancelGeneration else { return }
        let audioDuration = Double(samples.count) / AudioRecorder.sampleRate
        guard audioDuration >= 0.3, AudioAnalysis.containsSpeech(samples) else {
            // Press too short / no speech: we ignore it; settleOverlay() tidies up the pill after the job.
            if audioDuration >= 0.8 {
                showIfIdle(.message("Nothing heard. Check the microphone in Settings → Transcription.", isError: false), flash: 2.0)
            }
            return
        }

        // 1. Local transcription
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
        Log.asr.info("Transcription in \(transcriptionTime, format: .fixed(precision: 2))s, \(cleaned.count) chars")
        guard !cleaned.isEmpty else {
            showIfIdle(.message("No words recognized.", isError: false), flash: 1.6)
            return
        }

        let snapshot = await context?.value

        // 2. AI correction (Claude): text, dates, intent
        var finalText = cleaned
        var correctedBy: String?
        var correctionTime: Double?
        var note: String?
        var correctionFailed = false
        var correctionFailureReason = ""
        var usage: CorrectionUsage?
        /// The budget message on the pill: reached (no correction) or the 80% warning.
        var budgetMessage: String?

        if settings.correctionEnabled {
            if apiKeys.hasKey, budget.status(limit: settings.monthlyBudget) == .exceeded {
                // The monthly budget is reached: until the next month, the text is inserted as Whisper transcribed it.
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
                    Log.ai.info("Correction in \(outcome.duration, format: .fixed(precision: 2))s, cost \(CostFormat.usd(outcome.usage?.costUSD ?? 0), privacy: .public)")
                } catch {
                    if let failure = error as? CorrectionError {
                        models.noteRejected(failure.rejectedFeatures, for: options.model)
                    }
                    // Model retired between two reloads of the list: reload it, so that the next dictation
                    // moves to the newest model in the same family.
                    if case .http(404, _, _)? = error as? AnthropicError {
                        models.refresh(apiKey: key)
                    }
                    guard generation == cancelGeneration else { return }
                    // Even when the result is rejected, the request was paid for: keep the cost in the history.
                    usage = (error as? CorrectionError)?.usage
                    note = "AI correction failed: \(error.localizedDescription)"
                    correctionFailureReason = error.localizedDescription
                    correctionFailed = true
                    Log.ai.error("\(error.localizedDescription, privacy: .public)")
                }
                // Rejected corrections count too: they were paid for.
                if budget.add(usage?.costUSD, limit: settings.monthlyBudget) {
                    budgetMessage = budgetWarning()
                }
                models.refreshIfStale(apiKey: key)
            } else {
                // No key: insert the raw text without treating this as an error (the menu shows the hint).
                note = "No AI correction: the API key is missing."
            }
        }
        guard generation == cancelGeneration else { return }
        if !settings.useDiacritics, settings.language.diacriticLetters != nil {
            // Without Claude this is the only pass; with Claude it's the safety net for diacritics that slip through.
            finalText = Diacritics.strip(finalText, language: settings.language)
        }
        guard !finalText.isEmpty else {
            showIfIdle(.message("Nothing to insert.", isError: false), flash: 1.2)
            return
        }

        // 3. Insertion into the active field
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

        // fail() has already shown the insertion error; the text stays in the history and in the clipboard.
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

    /// "You've used 82% of your monthly budget: $16.40 of $20.00."
    private func budgetWarning() -> String {
        let limit = settings.monthlyBudgetUSD
        let spent = budget.spentThisMonth
        let percent = Int((spent / max(limit, 0.01) * 100).rounded(.down))
        return "You've used \(percent)% of your monthly budget:\n\(CostFormat.usd(spent)) of \(CostFormat.usd(limit))."
    }

    // MARK: - Utilities

    private func updateEscapeCapture() {
        monitor.setEscapeCapture(recording != .idle || pendingJobs > 0)
    }

    /// We don't cover the recording pill if the user has already started a new dictation.
    private func showIfIdle(_ mode: OverlayMode, flash: TimeInterval? = nil) {
        guard recording == .idle else { return }
        if let flash {
            overlay.flash(mode, duration: flash)
        } else {
            overlay.show(mode)
        }
    }

    /// After a canceled recording: shows what is being processed now or, if nothing is, removes the pill.
    private func restoreOverlayForProcessing() {
        guard recording == .idle else { return }
        switch processing {
        case .transcribing where pendingJobs > 0: overlay.show(.transcribing)
        case .correcting: overlay.show(.correcting)
        case .idle, .transcribing, .inserting: overlay.hideIfPersistent()
        }
    }

    /// After each job: if nothing is left to process, the pill doesn't stay stuck on "Transcribing…" or
    /// "Correcting with Claude…". Timed messages (Inserted, errors) close on their own, when their time is up.
    private func settleOverlay() {
        guard recording == .idle, pendingJobs == 0 else { return }
        overlay.hideIfPersistent()
    }

    /// How long an error message (Claude correction, microphone, transcription, insertion) stays on screen,
    /// so it can be read.
    private static let errorMessageDuration: TimeInterval = 6
    /// Dictation stopped by a screen lock or sleep: the text is in the clipboard and the history, not pasted anywhere.
    private static let interruptedNote = "The screen locked during dictation: the text is in the clipboard and in History."

    private func fail(_ message: String) {
        lastError = message
        Log.app.error("\(message, privacy: .public)")
        if settings.playSounds { SoundEffects.error() }
        showIfIdle(.message(message, isError: true), flash: Self.errorMessageDuration)
    }
}
