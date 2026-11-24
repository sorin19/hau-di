import Foundation

/// Options for a call to Claude.
public struct ClaudeOptions: Sendable, Equatable {
    /// The model ID, already picked from the API list (ModelCatalog.resolve).
    public var model: String
    /// nil = no effort is sent (the model has no effort levels).
    public var effort: EffortLevel?
    /// Fast mode: requested by the user and available for the model (price list, not rejected by the API).
    public var fastMode: Bool
    /// Server-side fallback on refusal, if the model has it (price list, not rejected by the API).
    public var serverSideFallback: Bool
    /// The model's output token cap (from /v1/models), if known.
    public var maxOutputTokens: Int?
    /// The prices used to compute the cost (the downloaded list or the copy bundled with the app).
    public var prices: PriceList
    public var timeout: TimeInterval

    /// `rejectedFeatures`: the parameters the API has already rejected for the model ("speed", "fallbacks").
    public init(model: String = ClaudeModels.defaultModelID, effort: EffortLevel? = .low, fastMode: Bool = false,
                rejectedFeatures: Set<String> = [], maxOutputTokens: Int? = nil, prices: PriceList = .bundled,
                timeout: TimeInterval = 10) {
        let entry = prices.entry(for: model)
        self.model = model
        self.effort = effort
        self.fastMode = fastMode && entry?.supportsFastMode == true && !rejectedFeatures.contains("speed")
        self.serverSideFallback = entry?.supportsServerSideFallback == true && !rejectedFeatures.contains("fallbacks")
        self.maxOutputTokens = maxOutputTokens
        self.prices = prices
        self.timeout = timeout
    }
}

public struct CorrectionOutcome: Sendable, Equatable {
    public var text: String
    public var servedBy: String?
    public var duration: TimeInterval
    public var inputTokens: Int?
    public var outputTokens: Int?
    public var cacheReadTokens: Int?
    /// Tokens + estimated cost (list price).
    public var usage: CorrectionUsage?
    /// Parameters the model rejected (400), removed from the request: "speed", "fallbacks". The app remembers them.
    public var rejectedFeatures: Set<String> = []
}

/// The model responded (so the request was paid for), but the result cannot be used.
public struct CorrectionError: Error, LocalizedError, Equatable {
    public var reason: AnthropicError
    public var usage: CorrectionUsage?
    /// As in CorrectionOutcome: the parameters the model rejected before the response that could not be used.
    public var rejectedFeatures: Set<String> = []

    public var errorDescription: String? { reason.errorDescription }
}

/// Text / data / intent correction through Claude.
public final class ClaudeCorrector: @unchecked Sendable {
    private let client: AnthropicClient

    public init(client: AnthropicClient = AnthropicClient()) {
        self.client = client
    }

    /// Builds the request (exposed separately for tests).
    public static func buildRequest(transcript: String, context: CorrectionContext?, config: CorrectionConfig,
                                    options: ClaudeOptions, useFastMode: Bool,
                                    useFallbacks: Bool = true) -> (body: MessagesRequest, betas: [String]) {
        let system = CorrectionPrompt.systemPrompt(config: config)
        let user = CorrectionPrompt.userMessage(transcript: transcript, context: context)
        // Room for adaptive thinking + the response (the response is roughly as long as the transcript).
        var maxTokens = min(16_000, 2_048 + transcript.count * 2)
        if let cap = options.maxOutputTokens { maxTokens = min(maxTokens, cap) }
        let fallbacks = (useFallbacks && options.serverSideFallback) ? "default" : nil
        let body = MessagesRequest(
            model: options.model,
            maxTokens: maxTokens,
            system: [.init(text: system, cacheControl: .init())],
            messages: [.init(role: "user", content: user)],
            outputConfig: .init(effort: options.effort?.rawValue, format: .init(schema: CorrectionPrompt.outputSchema)),
            fallbacks: fallbacks,
            speed: (useFastMode && options.fastMode) ? "fast" : nil
        )
        let betas = fallbacks != nil ? [AnthropicClient.serverSideFallbackBeta] : []
        return (body, betas)
    }

    /// Extracts the final text from the response and checks that it is plausible.
    public static func parse(_ response: MessagesResponse, transcript: String) throws -> String {
        switch response.stopReason {
        case "refusal": throw AnthropicError.refused
        case "max_tokens": throw AnthropicError.truncated
        default: break
        }
        let raw = response.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { throw AnthropicError.invalidOutput("empty response") }
        struct Payload: Decodable { var text: String }
        guard let data = raw.data(using: .utf8), let payload = try? JSONDecoder().decode(Payload.self, from: data) else {
            throw AnthropicError.invalidOutput("JSON does not match the schema")
        }
        let text = payload.text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Safety net: if the result is much longer than the dictation, the model probably
        // "answered" instead of correcting -> we reject the result and use the raw transcript.
        let limit = max(transcript.count * 3, transcript.count + 400)
        if text.count > limit {
            throw AnthropicError.invalidOutput("suspiciously long result")
        }
        return text
    }

    public func correct(transcript: String, context: CorrectionContext?, config: CorrectionConfig,
                        options: ClaudeOptions, apiKey: String) async throws -> CorrectionOutcome {
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw AnthropicError.missingAPIKey }
        let started = Date()
        var useFast = options.fastMode
        var useFallbacks = options.serverSideFallback
        var attempt = 0
        // Fast mode and the fallback are not in /v1/models (they come from the price list, which can be wrong):
        // on a 400 we drop them one at a time. The parameter dropped last before a successful response is the
        // rejected one; we report it so the app stops sending it.
        var removed: String?
        var rejected = Set<String>()

        while true {
            attempt += 1
            let (body, betas) = Self.buildRequest(transcript: transcript, context: context, config: config,
                                                  options: options, useFastMode: useFast, useFallbacks: useFallbacks)
            let remaining = options.timeout - Date().timeIntervalSince(started)
            guard remaining > 0.5 else { throw AnthropicError.timeout }
            do {
                let response = try await client.createMessage(body, apiKey: key, betas: betas, timeout: remaining)
                if let removed { rejected.insert(removed) }
                let usage = CorrectionUsage.from(response: response, requestedModel: body.model,
                                                 fastRequested: body.speed == "fast", prices: options.prices)
                let text: String
                do {
                    text = try Self.parse(response, transcript: transcript)
                } catch let error as AnthropicError {
                    throw CorrectionError(reason: error, usage: usage, rejectedFeatures: rejected)
                }
                return CorrectionOutcome(
                    text: text,
                    servedBy: response.model,
                    duration: Date().timeIntervalSince(started),
                    inputTokens: response.usage?.inputTokens,
                    outputTokens: response.usage?.outputTokens,
                    cacheReadTokens: response.usage?.cacheReadInputTokens,
                    usage: usage,
                    rejectedFeatures: rejected
                )
            } catch let error as AnthropicError {
                // Fast mode has a separate rate limit: on a 429 we retry at standard speed.
                if case .http(429, _, _) = error, useFast {
                    useFast = false
                    continue
                }
                if case .http(400, _, _) = error {
                    if useFast {
                        useFast = false
                        removed = "speed"
                        continue
                    }
                    if useFallbacks {
                        useFallbacks = false
                        removed = "fallbacks"
                        continue
                    }
                }
                // A single retry for transient errors, if there is still time.
                if error.isRetryable, attempt < 2, options.timeout - Date().timeIntervalSince(started) > 2 {
                    try await Task.sleep(nanoseconds: 300_000_000)
                    continue
                }
                throw error
            }
        }
    }

    public func validate(apiKey: String) async throws {
        try await client.validateKey(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
