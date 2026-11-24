import Foundation
import Combine

enum ModelLoadProgress: Sendable {
    case downloading(Double)
    case compiling(String)
    case loading
}

enum SpeechEngineError: LocalizedError {
    case notLoaded
    case modelUnavailable(String)
    case stillDownloading(Int)

    var errorDescription: String? {
        switch self {
        case .notLoaded: return "The transcription model isn't loaded yet."
        case .modelUnavailable(let detail): return "The transcription model isn't available: \(detail)"
        case .stillDownloading(let percent): return "The model is still downloading (\(percent)%). Try again once it's done."
        }
    }
}

/// A local speech-to-text engine (WhisperKit).
protocol SpeechEngine: AnyObject, Sendable {
    /// Downloads (if needed) and loads the model.
    func prepare(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws
    /// 16 kHz mono Float32 audio -> text, plus its words with the probability of each.
    func transcribe(_ samples: [Float], language: DictationLanguage, vocabulary: [String]) async throws -> SpeechTranscript
    /// How many dictionary terms reach the model as a hint; nil if the model isn't loaded.
    func vocabularyReach(_ vocabulary: [String]) async -> Int?
    func unload() async
}

/// Manages the lifecycle of the active transcription engine.
@MainActor
final class TranscriptionService: ObservableObject {
    enum State: Equatable {
        case idle
        case downloading(Double)
        case preparing(String)
        case ready
        case failed(String)
    }

    struct Configuration: Equatable {
        var whisperModel: String
        var language: DictationLanguage

        /// The model doesn't depend on the language (given per transcription), so a language change doesn't reload it.
        var identity: String {
            "whisper|\(whisperModel)"
        }

        var title: String {
            "Whisper " + WhisperModelOption.option(for: whisperModel).title
        }
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var activeTitle: String = ""

    private var engine: SpeechEngine?
    private var configuration: Configuration?
    private var loadedIdentity: String?
    private var loadTask: Task<Void, Never>?
    private var loadGeneration = 0

    var isReady: Bool { state == .ready }

    /// Downloading or preparing the model right now.
    var isBusy: Bool {
        switch state {
        case .downloading, .preparing: return true
        case .idle, .ready, .failed: return false
        }
    }

    func configure(_ configuration: Configuration, force: Bool = false) {
        let identity = configuration.identity
        self.configuration = configuration
        if !force, identity == loadedIdentity || (loadTask != nil && pendingIdentity == identity) {
            return
        }
        load(configuration)
    }

    func reload() {
        guard let configuration else { return }
        configure(configuration, force: true)
    }

    private var pendingIdentity: String?

    private func load(_ configuration: Configuration) {
        let previousTask = loadTask
        previousTask?.cancel()
        loadGeneration += 1
        let generation = loadGeneration
        let previous = engine
        engine = nil
        loadedIdentity = nil
        pendingIdentity = configuration.identity
        activeTitle = configuration.title
        state = .preparing("Preparing the model…")

        let newEngine: SpeechEngine = WhisperKitEngine(variant: configuration.whisperModel)

        let report: @Sendable (ModelLoadProgress) -> Void = { [weak self] progress in
            Task { @MainActor in self?.apply(progress, generation: generation) }
        }

        loadTask = Task { [weak self] in
            await previousTask?.value
            await previous?.unload()
            do {
                try await newEngine.prepare(progress: report)
                guard let self, self.loadGeneration == generation else {
                    await newEngine.unload()
                    return
                }
                self.engine = newEngine
                self.loadedIdentity = configuration.identity
                self.pendingIdentity = nil
                self.state = .ready
                self.loadTask = nil
                Log.asr.info("Model ready: \(configuration.identity, privacy: .public)")
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                self.pendingIdentity = nil
                self.loadTask = nil
                self.state = .failed(error.localizedDescription)
                Log.asr.error("Loading the model failed: \(error.localizedDescription, privacy: .public)")
            }
        }
    }

    private func apply(_ progress: ModelLoadProgress, generation: Int) {
        guard loadGeneration == generation, state != .ready else { return }
        switch progress {
        case .downloading(let fraction):
            state = .downloading(fraction.isFinite ? min(max(fraction, 0), 1) : 0)
        case .compiling(let name):
            state = .preparing("Compiling \(name) for the Neural Engine…")
        case .loading:
            state = .preparing("Loading the model (the first time can take a few minutes)…")
        }
    }

    /// Waits for the model if it is loading, then transcribes.
    func transcribe(_ samples: [Float], language: DictationLanguage, vocabulary: [String]) async throws -> SpeechTranscript {
        if engine == nil, let loadTask {
            if case .downloading(let fraction) = state {
                throw SpeechEngineError.stillDownloading(Int(fraction * 100))
            }
            await loadTask.value
        }
        guard let engine else {
            if case .failed(let message) = state { throw SpeechEngineError.modelUnavailable(message) }
            throw SpeechEngineError.notLoaded
        }
        return try await engine.transcribe(samples, language: language, vocabulary: vocabulary)
    }

    /// How many dictionary terms (from the start of the list) reach Whisper; nil while the model isn't loaded.
    func vocabularyReach(_ vocabulary: [String]) async -> Int? {
        guard let engine else { return nil }
        return await engine.vocabularyReach(vocabulary)
    }

    var statusText: String {
        switch state {
        case .idle: return "Not loaded"
        case .downloading(let fraction): return "Downloading the model… \(Int(fraction * 100))%"
        case .preparing(let message): return message
        case .ready: return "Ready"
        case .failed(let message): return "Error: \(message)"
        }
    }
}
