import Foundation
import WhisperKit

/// Whisper rulat local prin WhisperKit (Core ML, Neural Engine pe Apple Silicon).
actor WhisperKitEngine: SpeechEngine {
    private let variant: String
    private var pipe: WhisperKit?
    /// Prompt-ul cu dictionarul pentru ultima lista primita (se recalculeaza doar cand lista se schimba).
    private var promptCache: (vocabulary: [String], count: Int, tokens: [Int])?

    /// Dictionarul ajunge la Whisper ca "text anterior": cel mult atatia termeni si tokeni (Whisper accepta pana la
    /// 224 de tokeni de context; mai mult ar lua din atentia data audio-ului).
    static let maxPromptTerms = 60
    static let maxPromptTokens = 120

    init(variant: String) {
        self.variant = variant
    }

    static var downloadBase: URL { AppPaths.whisperKitBase }

    /// Structura creata de WhisperKit.download: <base>/models/argmaxinc/whisperkit-coreml/openai_whisper-<variant>
    static func localModelFolder(variant: String) -> URL {
        downloadBase
            .appendingPathComponent("models/argmaxinc/whisperkit-coreml", isDirectory: true)
            .appendingPathComponent("openai_whisper-\(variant)", isDirectory: true)
    }

    /// Scris de noi doar dupa ce WhisperKit.download s-a terminat cu succes.
    private static let completionMarker = ".hau-di-download-complete"
    /// Marcajul scris inainte de redenumire (Haudi): modelele descarcate atunci raman valabile.
    private static let legacyCompletionMarker = ".haudi-download-complete"

    /// Fisierele esentiale exista. Folderele singure nu ajung: o descarcare intrerupta
    /// (ex: aplicatia repornita din Xcode) lasa foldere .mlmodelc incomplete.
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
                // Descarcarea se reia: fisierele deja complete (verificate prin metadate) nu se descarca din nou.
                folder = try await download(progress: progress)
            } catch {
                // Fara internet, dar modelul pare complet pe disc: incercam totusi sa-l incarcam.
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
            Log.asr.error("Modelul nu s-a incarcat (\(error.localizedDescription, privacy: .public)); il repar.")
            // 1) re-verificam toate fisierele (se descarca doar ce lipseste sau e invalid)
            Self.setComplete(false, folder: folder)
            folder = try await download(progress: progress)
            progress(.loading)
            do {
                pipe = try await load(folder: folder)
            } catch {
                // 2) ultima varianta: descarcare completa, de la zero
                try Task.checkCancellation()
                try? FileManager.default.removeItem(at: folder)
                folder = try await download(progress: progress)
                progress(.loading)
                pipe = try await load(folder: folder)
            }
            Self.setComplete(true, folder: folder)
        }

        self.pipe = pipe

        // Incalzire: prima inferenta initializeaza lenes unele resurse Core ML.
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
            // Dictionarul ca "previous text": Whisper prefera aceste grafii. Doar termeni intregi, cati incap.
            let prompt = promptTerms(vocabulary, tokenizer: tokenizer)
            if !prompt.tokens.isEmpty { promptTokens = prompt.tokens }
        }

        // Limba e mereu impusa (fara detectie): Whisper transcrie in limba aleasa, nu traduce (vezi DictationLanguage).
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
            promptTokens: promptTokens,
            chunkingStrategy: .vad
        )
        let audio = AudioAnalysis.padded(samples, trailingSilence: 0.2, minimumDuration: 1.0)
        let results = try await pipe.transcribe(audioArray: audio, decodeOptions: options)
        let text = results.map(\.text).joined(separator: " ")

        // Probabilitatea fiecarui cuvant, din cele ale token-urilor: vin la orice transcriere, deci fara
        // pasul de timpi pe cuvinte (wordTimestamps) si fara intarziere.
        guard let tokenizer = pipe.tokenizer else { return SpeechTranscript(text: text) }
        let segments = results.flatMap(\.segments).map { Self.words(in: $0, tokenizer: tokenizer) }
        return SpeechTranscript(text: text, words: WordConfidence.joined(segments))
    }

    /// Cati termeni din dictionar (de la inceputul listei) ajung la Whisper; nil cat timp modelul nu e incarcat.
    func vocabularyReach(_ vocabulary: [String]) -> Int? {
        guard let tokenizer = pipe?.tokenizer else { return nil }
        return promptTerms(vocabulary, tokenizer: tokenizer).count
    }

    /// Primii termeni care incap intregi in prompt (cel mult maxPromptTerms termeni si maxPromptTokens tokeni).
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

    /// Cuvintele unui segment, cu probabilitatea lor. Token-urile speciale (<|ro|>, sfarsitul) nu intra, iar cei care
    /// impart un caracter UTF-8 (ex: „ș”) se lipesc pana textul e valid.
    private static func words(in segment: TranscriptionSegment, tokenizer: WhisperTokenizer) -> [TranscribedWord] {
        var pieces: [TokenPiece] = []
        var tokens: [Int] = []
        var logProbs: [Float] = []
        for (index, token) in segment.tokens.enumerated() where token < tokenizer.specialTokens.specialTokenBegin {
            tokens.append(token)
            // tokenLogProbs[i] = [token-ul ales: log-probabilitatea lui], aliniat cu tokens.
            if index < segment.tokenLogProbs.count, let logProb = segment.tokenLogProbs[index][token] {
                logProbs.append(logProb)
            }
            let text = tokenizer.decode(tokens: tokens)
            // Un caracter UTF-8 are cel mult 4 octeti: dupa 4 token-uri nu mai lipim.
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
