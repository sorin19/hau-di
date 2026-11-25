import Foundation
import WhisperKit

/// Whisper run locally through WhisperKit (Core ML, Neural Engine on Apple Silicon).
actor WhisperKitEngine: SpeechEngine {
    private let variant: String
    private var pipe: WhisperKit?
    /// The dictionary prompt for the last list received (recomputed only when the list changes).
    private var promptCache: (vocabulary: [String], count: Int, tokens: [Int])?

    /// The dictionary reaches Whisper as "previous text": at most this many terms and tokens. WhisperKit keeps only
    /// the last 111 prompt tokens (224 / 2 - 1) and drops those before them, which are the first terms; and every
    /// prompt token is one less for the text of each piece of audio (see AudioSplitter).
    static let maxPromptTerms = 60
    static let maxPromptTokens = 111

    init(variant: String) {
        self.variant = variant
    }

    static var downloadBase: URL { AppPaths.whisperKitBase }

    /// The structure created by WhisperKit.download: <base>/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>
    static func localModelFolder(variant: String) -> URL {
        downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    /// Written by us only after WhisperKit.download has finished successfully.
    private static let completionMarker = ".hau-di-download-complete"
    /// The marker written before the rename (Haudi): models downloaded back then stay valid.
    private static let legacyCompletionMarker = ".haudi-download-complete"

    /// The essential files exist. The folders alone aren't enough: an interrupted download
    /// (e.g. the app relaunched from Xcode) leaves incomplete .mlmodelc folders.
    static func hasRequiredFiles(in folder: URL) -> Bool {
        let fileManager = FileManager.default
        return ["MelSpectrogram", "AudioEncoder", "TextDecoder"].allSatisfy { name in
            let model = folder.appendingPathComponent("\(name).mlmodelc", isDirectory: true)
            func exists(_ relative: String) -> Bool {
                fileManager.fileExists(atPath: model.appendingPathComponent(relative).path)
            }
            let mlProgram = exists("model.mil") && exists("weights/weight.bin")
            let neuralNetwork = exists("model.espresso.net")
            return exists("coremldata.bin") && (mlProgram || neuralNetwork)
        }
    }

    static func isDownloaded(variant: String) -> Bool {
        let folder = localModelFolder(variant: variant)
        let marked = [completionMarker, legacyCompletionMarker].contains { name in
            FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
        }
        return marked && hasRequiredFiles(in: folder)
    }

    private static func setComplete(_ complete: Bool, folder: URL) {
        let marker = folder.appendingPathComponent(completionMarker)
        if complete {
            _ = FileManager.default.createFile(atPath: marker.path, contents: Data())
        } else {
            try? FileManager.default.removeItem(at: marker)
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(legacyCompletionMarker))
        }
    }

    func prepare(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws {
        if pipe != nil { return }
        var folder = Self.localModelFolder(variant: variant)

        if !Self.isDownloaded(variant: variant) {
            do {
                // The download resumes: already complete files (checked via metadata) aren't downloaded again.
                folder = try await download(progress: progress)
            } catch {
                // No internet, but the model looks complete on disk: try to load it anyway.
                guard !(error is CancellationError), Self.hasRequiredFiles(in: folder) else { throw error }
            }
            guard Self.hasRequiredFiles(in: folder) else {
                throw SpeechEngineError.modelUnavailable("the download of model \(variant) is incomplete")
            }
            Self.setComplete(true, folder: folder)
        }

        progress(.loading)
        let pipe: WhisperKit
        do {
            pipe = try await load(folder: folder)
        } catch {
            try Task.checkCancellation()
            Log.asr.error("The model didn't load (\(error.localizedDescription, privacy: .public)); repairing it.")
            // 1) re-check all the files (only what is missing or invalid is downloaded)
            Self.setComplete(false, folder: folder)
            folder = try await download(progress: progress)
            progress(.loading)
            do {
                pipe = try await load(folder: folder)
            } catch {
                // 2) last resort: a full download, from scratch
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: folder)
                folder = try await download(progress: progress)
                progress(.loading)
                pipe = try await load(folder: folder)
            }
            Self.setComplete(true, folder: folder)
        }

        self.pipe = pipe

        // Warm-up: the first inference lazily initializes some Core ML resources.
        let warmup = DecodingOptions(verbose: false, task: .transcribe, language: "en", temperatureFallbackCount: 0,
                                     usePrefillPrompt: true, skipSpecialTokens: true, withoutTimestamps: true)
        _ = try? await pipe.transcribe(audioArray: [Float](repeating: 0, count: 16_000), decodeOptions: warmup)
    }

    private func download(progress: @escaping @Sendable (ModelLoadProgress) -> Void) async throws -> URL {
        progress(.downloading(0))
        return try await WhisperKit.download(variant: variant, downloadBase: Self.downloadBase, progressCallback: { value in
            progress(.downloading(value.fractionCompleted))
        })
    }

    private func load(folder: URL) async throws -> WhisperKit {
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: Self.downloadBase,
            modelFolder: folder.path,
            tokenizerFolder: Self.downloadBase,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        return try await WhisperKit(config)
    }

    func transcribe(_ samples: [Float], language: DictationLanguage, vocabulary: [String]) async throws -> SpeechTranscript {
        guard let pipe else { throw SpeechEngineError.notLoaded }

        var promptTokens: [Int]?
        if !vocabulary.isEmpty, let tokenizer = pipe.tokenizer {
            // The dictionary as "previous text": Whisper prefers these spellings. Whole terms only, as many as fit.
            let prompt = promptTerms(vocabulary, tokenizer: tokenizer)
            if !prompt.tokens.isEmpty { promptTokens = prompt.tokens }
        }

        // The language is always forced (no detection): Whisper transcribes in the chosen language and doesn't
        // translate (see DictationLanguage).
        // No chunkingStrategy: long recordings are split here, into pieces short enough for their whole text to fit
        // next to the prompt (WhisperKit's own split makes pieces of up to 30 s, whose end was lost).
        let options = DecodingOptions(
            verbose: false,
            task: .transcribe,
            language: language.code,
            temperature: 0,
            temperatureFallbackCount: 3,
            usePrefillPrompt: true,
            detectLanguage: false,
            skipSpecialTokens: true,
            withoutTimestamps: true,
            promptTokens: promptTokens
        )
        let audio = AudioAnalysis.padded(samples, trailingSilence: 0.2, minimumDuration: 1.0)
        let budget = AudioSplitter.textTokens(promptTokens: promptTokens?.count ?? 0)
        let pieces = AudioSplitter.split(audio, maxSeconds: AudioSplitter.maxPieceSeconds(textTokens: budget))
            .map { Array(audio[$0]) }
        let results = try await decode(pieces, options: options, budget: budget, splitsLeft: 2, pipe: pipe)
        let text = results.map(\.text).joined(separator: " ")

        // Each word's probability, from those of its tokens: they come with every transcription, so without
        // the word-timing step (wordTimestamps) and without delay.
        guard let tokenizer = pipe.tokenizer else { return SpeechTranscript(text: text) }
        let segments = results.flatMap(\.segments).map { Self.words(in: $0, tokenizer: tokenizer) }
        return SpeechTranscript(text: text, words: WordConfidence.joined(segments))
    }

    /// Each piece decoded in a window of its own (WhisperKit runs them in parallel), the results in order. A piece
    /// whose text used up the whole budget was cut off before its end: it is cut in two at its quietest point and
    /// decoded again (at most splitsLeft times in a row).
    private func decode(_ pieces: [[Float]], options: DecodingOptions, budget: Int, splitsLeft: Int,
                        pipe: WhisperKit) async throws -> [TranscriptionResult] {
        let outcomes = await pipe.transcribeWithResults(audioArrays: pieces, decodeOptions: options)
        guard outcomes.count == pieces.count else {
            // WhisperKit answers a malformed request with a single failure: that error is thrown here.
            _ = try outcomes.first?.get()
            throw SpeechEngineError.transcriptionFailed("\(outcomes.count) results for \(pieces.count) pieces of audio")
        }
        var results: [TranscriptionResult] = []
        for (piece, outcome) in zip(pieces, outcomes) {
            let pieceResults = try outcome.get()
            if splitsLeft > 0, let tokenizer = pipe.tokenizer,
               Self.textTokenCount(pieceResults, tokenizer: tokenizer) >= budget,
               let halves = AudioSplitter.halves(piece) {
                Log.asr.notice("A piece of \(piece.count / 16_000) s filled its \(budget) tokens; decoding it again in two halves.")
                results += try await decode(halves.map { Array(piece[$0]) }, options: options, budget: budget,
                                            splitsLeft: splitsLeft - 1, pipe: pipe)
            } else {
                results += pieceResults
            }
        }
        return results
    }

    /// The text tokens of a piece's results (without the special ones: start of transcript, language, end).
    private static func textTokenCount(_ results: [TranscriptionResult], tokenizer: WhisperTokenizer) -> Int {
        results.flatMap(\.segments).reduce(0) { count, segment in
            count + segment.tokens.filter { $0 < tokenizer.specialTokens.specialTokenBegin }.count
        }
    }

    /// How many dictionary terms (from the start of the list) reach Whisper; nil while the model isn't loaded.
    func vocabularyReach(_ vocabulary: [String]) -> Int? {
        guard let tokenizer = pipe?.tokenizer else { return nil }
        return promptTerms(vocabulary, tokenizer: tokenizer).count
    }

    /// The first terms that fit whole in the prompt (at most maxPromptTerms terms and maxPromptTokens tokens).
    private func promptTerms(_ vocabulary: [String], tokenizer: WhisperTokenizer) -> (count: Int, tokens: [Int]) {
        if let cache = promptCache, cache.vocabulary == vocabulary { return (cache.count, cache.tokens) }
        var result: (count: Int, tokens: [Int]) = (0, [])
        if !vocabulary.isEmpty {
            for count in 1...min(vocabulary.count, Self.maxPromptTerms) {
                let prompt = " " + vocabulary.prefix(count).joined(separator: ", ")
                let tokens = tokenizer.encode(text: prompt).filter { $0 < tokenizer.specialTokens.specialTokenBegin }
                if tokens.count > Self.maxPromptTokens { break }
                result = (count, tokens)
            }
        }
        promptCache = (vocabulary, result.count, result.tokens)
        return result
    }

    /// A segment's words, with their probabilities. Special tokens (<|ro|>, the end token) are left out, and tokens
    /// that split a UTF-8 character (e.g. "ș") are joined until the text is valid.
    private static func words(in segment: TranscriptionSegment, tokenizer: WhisperTokenizer) -> [TranscribedWord] {
        var pieces: [TokenPiece] = []
        var tokens: [Int] = []
        var logProbs: [Float] = []
        for (index, token) in segment.tokens.enumerated() where token < tokenizer.specialTokens.specialTokenBegin {
            tokens.append(token)
            // tokenLogProbs[i] = [the chosen token: its log-probability], aligned with tokens.
            if index < segment.tokenLogProbs.count, let logProb = segment.tokenLogProbs[index][token] {
                logProbs.append(logProb)
            }
            let text = tokenizer.decode(tokens: tokens)
            // A UTF-8 character has at most 4 bytes: after 4 tokens we stop joining.
            if !text.contains("\u{FFFD}") || tokens.count >= 4 {
                pieces.append(TokenPiece(text: text, logProbs: logProbs))
                tokens.removeAll()
                logProbs.removeAll()
            }
        }
        if !tokens.isEmpty {
            pieces.append(TokenPiece(text: tokenizer.decode(tokens: tokens), logProbs: logProbs))
        }
        return WordConfidence.words(from: pieces)
    }

    func unload() async {
        await pipe?.unloadModels()
        pipe = nil
    }
}
