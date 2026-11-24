import Foundation

/// Optiuni de apel catre Claude.
public struct ClaudeOptions: Sendable, Equatable {
    /// ID-ul modelului, deja ales din lista API (ModelCatalog.resolve).
    public var model: String
    /// nil = nu trimitem efort (modelul nu are niveluri de efort).
    public var effort: EffortLevel?
    /// Fast mode: cerut de utilizator si posibil pentru model (lista de preturi, fara refuz de la API).
    public var fastMode: Bool
    /// Fallback server-side la refuz, daca modelul il are (lista de preturi, fara refuz de la API).
    public var serverSideFallback: Bool
    /// Plafonul de raspuns al modelului (din /v1/models), daca e cunoscut.
    public var maxOutputTokens: Int?
    /// Preturile cu care se calculeaza costul (lista descarcata sau copia din aplicatie).
    public var prices: PriceList
    public var timeout: TimeInterval

    /// `rejectedFeatures`: parametrii pe care API-ul i-a refuzat deja pentru model ("speed", "fallbacks").
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
    /// Tokeni + cost estimat (pret de lista).
    public var usage: CorrectionUsage?
    /// Parametrii refuzati de model (400) si scosi din cerere: "speed", "fallbacks". Aplicatia ii tine minte.
    public var rejectedFeatures: Set<String> = []
}

/// Modelul a raspuns (deci requestul s-a platit), dar rezultatul nu poate fi folosit.
public struct CorrectionError: Error, LocalizedError, Equatable {
    public var reason: AnthropicError
    public var usage: CorrectionUsage?
    /// Ca in CorrectionOutcome: parametrii refuzati de model inainte de raspunsul care n-a putut fi folosit.
    public var rejectedFeatures: Set<String> = []

    public var errorDescription: String? { reason.errorDescription }
}

/// Corectie de text / date / intentie prin Claude.
public final class ClaudeCorrector: @unchecked Sendable {
    private let client: AnthropicClient

    public init(client: AnthropicClient = AnthropicClient()) {
        self.client = client
    }

    /// Construieste request-ul (expus separat pentru teste).
    public static func buildRequest(transcript: String, context: CorrectionContext?, config: CorrectionConfig,
                                    options: ClaudeOptions, useFastMode: Bool,
                                    useFallbacks: Bool = true) -> (body: MessagesRequest, betas: [String]) {
        let system = CorrectionPrompt.systemPrompt(config: config)
        let user = CorrectionPrompt.userMessage(transcript: transcript, context: context)
        // Spatiu pentru gandirea adaptiva + raspuns (raspunsul are aproximativ lungimea transcrierii).
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

    /// Extrage textul final din raspuns si verifica ca e plauzibil.
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
        // Plasa de siguranta: daca rezultatul e mult mai lung decat dictarea, probabil modelul a
        // "raspuns" in loc sa corecteze -> refuzam rezultatul si folosim transcrierea bruta.
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
        // Fast mode si fallback-ul nu apar in /v1/models (vin din lista de preturi, care poate gresi): la 400 le scoatem
        // pe rand. Parametrul scos ultimul inainte de un raspuns reusit e cel refuzat; il raportam, ca aplicatia
        // sa nu-l mai trimita.
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
                // Fast mode are limita de rata separata: la 429 reincercam la viteza standard.
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
                // O singura reincercare pentru erori tranzitorii, daca mai e timp.
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
