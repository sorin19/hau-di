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

/// Un motor de speech-to-text local (WhisperKit).
protocol SpeechEngine: AnyObject, Sendable {
    /// Descarca (daca e nevoie) si incarca modelul.
    func prepare(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws
    /// Audio 16 kHz mono Float32 -> text, plus cuvintele lui cu probabilitatea fiecaruia.
    func transcribe(_ samples: [Float], language: DictationLanguage, vocabulary: [String]) async throws -> SpeechTranscript
    /// Cati termeni din dictionar ajung la model ca indiciu; nil daca modelul nu e incarcat.
    func vocabularyReach(_ vocabulary: [String]) async -> Int?
    func unload() async
}

/// Gestioneaza ciclul de viata al motorului de transcriere activ.
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

        /// Modelul nu depinde de limba (ea se da la fiecare transcriere), deci schimbarea limbii nu il reincarca.
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

    /// Descarca sau pregateste modelul chiar acum.
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
                Log.asr.info("Model gata: \(configuration.identity, privacy: .public)")
            } catch {
                guard let self, self.loadGeneration == generation else { return }
                self.pendingIdentity = nil
                self.loadTask = nil
                self.state = .failed(error.localizedDescription)
                Log.asr.error("Incarcarea modelului a esuat: \(error.localizedDescription, privacy: .public)")
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

    /// Asteapta modelul daca se incarca, apoi transcrie.
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

    /// Cati termeni din dictionar (de la inceputul listei) ajung la Whisper; nil cat timp modelul nu e incarcat.
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
