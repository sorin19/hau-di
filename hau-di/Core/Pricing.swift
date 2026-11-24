import Foundation

/// A model's prices, in USD per million tokens (the effective ones for a request: long prompt, fast mode).
public struct ModelPricing: Sendable, Equatable {
    public var input: Double
    public var cacheWrite5m: Double
    public var cacheRead: Double
    public var output: Double

    public init(input: Double, cacheWrite5m: Double, cacheRead: Double, output: Double) {
        self.input = input
        self.cacheWrite5m = cacheWrite5m
        self.cacheRead = cacheRead
        self.output = output
    }

    /// Fast mode: the cache multipliers apply on top of the fast price.
    public func scaled(by factor: Double) -> ModelPricing {
        ModelPricing(input: input * factor, cacheWrite5m: cacheWrite5m * factor,
                     cacheRead: cacheRead * factor, output: output * factor)
    }
}

/// The price list + what /v1/models does not say (fast mode, fallback on refusal), kept by the author in price.json
/// on pay.cx.ro (served at https://pay.cx.ro/hau-di/pricing/), based on
/// https://platform.claude.com/docs/en/about-claude/pricing.
/// The app fetches it once a week; until then (or offline) it uses the bundled copy (`bundled`).
/// The settings show only the models that are both in /v1/models (accessible to the key) and here (known price).
public struct PriceList: Codable, Equatable, Sendable {
    /// Different prices when the prompt (input + cache) exceeds `above` tokens (e.g. Haiku 5.5 above 100,000).
    public struct LongPrompt: Codable, Equatable, Sendable {
        public var above: Int
        public var input: Double
        public var output: Double
        public var cacheWrite: Double?
        public var cacheRead: Double?

        enum CodingKeys: String, CodingKey {
            case above, input, output
            case cacheWrite = "cache_write"
            case cacheRead = "cache_read"
        }
    }

    public struct Entry: Codable, Equatable, Sendable {
        /// The ID from /v1/models, without the date: "claude-opus-4-5" also covers "claude-opus-4-5-20251101".
        public var id: String
        public var input: Double
        public var output: Double
        /// The 5-minute cache write; missing = 1.25 x input.
        public var cacheWrite: Double?
        /// The cache read; missing = 0.1 x input.
        public var cacheRead: Double?
        public var longPrompt: LongPrompt?
        /// Fast mode on the Claude API, without a beta (`speed: "fast"`).
        public var fast: Bool?
        /// How much fast mode costs relative to the standard price; missing = 2.
        public var fastMultiplier: Double?
        /// Server-side fallback on refusal (`fallbacks: "default"`).
        public var fallbacks: Bool?

        public init(id: String, input: Double, output: Double, cacheWrite: Double? = nil, cacheRead: Double? = nil,
                    longPrompt: LongPrompt? = nil, fast: Bool? = nil, fastMultiplier: Double? = nil, fallbacks: Bool? = nil) {
            self.id = id
            self.input = input
            self.output = output
            self.cacheWrite = cacheWrite
            self.cacheRead = cacheRead
            self.longPrompt = longPrompt
            self.fast = fast
            self.fastMultiplier = fastMultiplier
            self.fallbacks = fallbacks
        }

        enum CodingKeys: String, CodingKey {
            case id, input, output, fast, fallbacks
            case cacheWrite = "cache_write"
            case cacheRead = "cache_read"
            case longPrompt = "long_prompt"
            case fastMultiplier = "fast_multiplier"
        }

        public var supportsFastMode: Bool { fast == true }
        public var supportsServerSideFallback: Bool { fallbacks == true }

        /// The prices for a request: the long-prompt ones if applicable, and multiplied for fast mode.
        public func pricing(promptTokens: Int, fast: Bool) -> ModelPricing {
            var price: ModelPricing
            if let long = longPrompt, promptTokens > long.above {
                price = ModelPricing(input: long.input, cacheWrite5m: long.cacheWrite ?? long.input * 1.25,
                                     cacheRead: long.cacheRead ?? long.input * 0.1, output: long.output)
            } else {
                price = ModelPricing(input: input, cacheWrite5m: cacheWrite ?? input * 1.25,
                                     cacheRead: cacheRead ?? input * 0.1, output: output)
            }
            if fast { price = price.scaled(by: fastMultiplier ?? 2) }
            return price
        }

        /// Positive values, a Claude model ID, a fast multiplier of at least 1.
        var isValid: Bool {
            let optional = [cacheWrite, cacheRead, longPrompt?.cacheWrite, longPrompt?.cacheRead].compactMap { $0 }
            let required = [input, output] + (longPrompt.map { [$0.input, $0.output] } ?? [])
            return id.hasPrefix("claude-")
                && required.allSatisfy { $0.isFinite && $0 > 0 }
                && optional.allSatisfy { $0.isFinite && $0 >= 0 }
                && (longPrompt?.above ?? 1) > 0
                && (fastMultiplier ?? 1) >= 1
        }
    }

    public enum ValidationError: Error, Equatable {
        /// Unknown format (a file for a newer version of the app).
        case format(Int)
        case empty
        /// A model with invalid values or a duplicate ID.
        case invalid(String)
    }

    /// 1 = the format above. A new format can be published without breaking old versions.
    public var format: Int
    /// The day of the last update ("2026-11-23"), written by hand in the file.
    public var updated: String?
    /// When price.json was last saved on the server ("2026-11-24 10:15:00"); the server adds it.
    public var modified: String?
    public var source: String?
    public var models: [Entry]

    public init(format: Int = 1, updated: String? = nil, modified: String? = nil, source: String? = nil, models: [Entry]) {
        self.format = format
        self.updated = updated
        self.modified = modified
        self.source = source
        self.models = models
    }

    /// The list's timestamp, for "newest wins" and for display: `modified`, otherwise `updated`.
    public var stamp: String { modified ?? updated ?? "" }

    /// Reads and validates a list; an invalid one is rejected as a whole (the app keeps the previous one).
    public static func decode(_ data: Data) throws -> PriceList {
        let list = try JSONDecoder().decode(PriceList.self, from: data)
        guard list.format == 1 else { throw ValidationError.format(list.format) }
        guard !list.models.isEmpty else { throw ValidationError.empty }
        var seen = Set<String>()
        for entry in list.models {
            guard entry.isValid, seen.insert(entry.id).inserted else { throw ValidationError.invalid(entry.id) }
        }
        return list
    }

    /// A model's entry: exact ID or ID + date suffix ("-20261101"). nil if the model is not in the list,
    /// so that a new model (e.g. "claude-opus-5-6") does not get another model's price by mistake.
    public func entry(for model: String) -> Entry? {
        models.first { entry in
            if model == entry.id { return true }
            guard model.hasPrefix(entry.id + "-") else { return false }
            let suffix = model.dropFirst(entry.id.count + 1)
            return suffix.count == 8 && suffix.allSatisfy(\.isNumber)
        }
    }

    public func pricing(for model: String, promptTokens: Int = 0, fast: Bool = false) -> ModelPricing? {
        entry(for: model)?.pricing(promptTokens: promptTokens, fast: fast)
    }

    /// "$4 / $20" (input / output, per million tokens), for the model list; nil if the price is unknown.
    public func label(for model: String) -> String? {
        guard let price = pricing(for: model) else { return nil }
        return Self.dollars(price.input) + " / " + Self.dollars(price.output)
    }

    static func dollars(_ value: Double) -> String {
        value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// The copy bundled with the app: price.json from pay.cx.ro (served at /hau-di/pricing/) as of `updated`.
    public static let bundled: PriceList = (try? decode(Data(bundledJSON.utf8))) ?? PriceList(models: [])

    static let bundledJSON = #"""
{
	"format": 1,
	"updated": "2026-11-23",
	"source": "https://platform.claude.com/docs/en/about-claude/pricing",
	"help": "Preturi de lista in USD per milion de tokeni. id = ID-ul din /v1/models, fara data (claude-opus-4-5 acopera si claude-opus-4-5-20251101). cache_write = scriere in cache pe 5 minute (lipsa = 1.25 x input), cache_read = citire din cache (lipsa = 0.1 x input). fast = are fast mode pe Claude API fara beta; costa input/output x fast_multiplier (lipsa = 2). fallbacks = are fallback server-side la refuz. long_prompt = alte preturi cand promptul (intrare + cache) depaseste above tokeni. In hau-di apar doar modelele de aici care sunt si in /v1/models pentru cheia utilizatorului.",
	"models": [
		{ "id": "claude-fable-5-2",  "input": 8,   "output": 40,  "cache_write": 10,    "cache_read": 0.2,  "fast": true,  "fallbacks": true },
		{ "id": "claude-mythos-5-2", "input": 8,   "output": 40,  "cache_write": 10,    "cache_read": 0.2,  "fast": true,  "fallbacks": false },
		{ "id": "claude-fable-5-1",  "input": 10,  "output": 50,  "cache_write": 12.5,  "cache_read": 0.25, "fast": false, "fallbacks": true },
		{ "id": "claude-mythos-5-1", "input": 10,  "output": 50,  "cache_write": 12.5,  "cache_read": 0.25, "fast": false, "fallbacks": false },
		{ "id": "claude-fable-5",    "input": 10,  "output": 50,  "cache_write": 12.5,  "cache_read": 1,    "fast": false, "fallbacks": false },
		{ "id": "claude-mythos-5",   "input": 10,  "output": 50,  "cache_write": 12.5,  "cache_read": 1,    "fast": false, "fallbacks": false },
		{ "id": "claude-opus-5-5",   "input": 4,   "output": 20,  "cache_write": 5,     "cache_read": 0.2,  "fast": true,  "fallbacks": true },
		{ "id": "claude-opus-5",     "input": 5,   "output": 25,  "cache_write": 6.25,  "cache_read": 0.5,  "fast": false, "fallbacks": true },
		{ "id": "claude-opus-4-8",   "input": 5,   "output": 25,  "cache_write": 6.25,  "cache_read": 0.5,  "fast": false, "fallbacks": false },
		{ "id": "claude-opus-4-7",   "input": 5,   "output": 25,  "cache_write": 6.25,  "cache_read": 0.5,  "fast": false, "fallbacks": false },
		{ "id": "claude-opus-4-6",   "input": 5,   "output": 25,  "cache_write": 6.25,  "cache_read": 0.5,  "fast": false, "fallbacks": false },
		{ "id": "claude-opus-4-5",   "input": 5,   "output": 25,  "cache_write": 6.25,  "cache_read": 0.5,  "fast": false, "fallbacks": false },
		{ "id": "claude-sonnet-5-5", "input": 2,   "output": 10,  "cache_write": 2.5,   "cache_read": 0.1,  "fast": false, "fallbacks": true },
		{ "id": "claude-sonnet-5",   "input": 2,   "output": 10,  "cache_write": 2.5,   "cache_read": 0.2,  "fast": false, "fallbacks": false },
		{ "id": "claude-sonnet-4-6", "input": 3,   "output": 15,  "cache_write": 3.75,  "cache_read": 0.3,  "fast": false, "fallbacks": false },
		{ "id": "claude-sonnet-4-5", "input": 3,   "output": 15,  "cache_write": 3.75,  "cache_read": 0.3,  "fast": false, "fallbacks": false },
		{ "id": "claude-haiku-5-5",  "input": 0.1, "output": 0.5, "cache_write": 0.125, "cache_read": 0.01, "fast": false, "fallbacks": false,
		  "long_prompt": { "above": 100000, "input": 0.5, "output": 2.5, "cache_write": 0.625, "cache_read": 0.05 } },
		{ "id": "claude-haiku-4-5",  "input": 1,   "output": 5,   "cache_write": 1.25,  "cache_read": 0.1,  "fast": false, "fallbacks": false }
	]
}
"""#
}

/// The tokens and cost of a Claude correction (saved in the history).
public struct CorrectionUsage: Codable, Hashable, Sendable {
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var fastMode: Bool
    /// nil if the model has no price in the list.
    public var costUSD: Double?

    public init(model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int, cacheWriteTokens: Int,
                fastMode: Bool, prices: PriceList = .bundled) {
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.fastMode = fastMode
        self.costUSD = Self.cost(model: model, inputTokens: inputTokens, outputTokens: outputTokens,
                                 cacheReadTokens: cacheReadTokens, cacheWriteTokens: cacheWriteTokens, fastMode: fastMode,
                                 prices: prices)
    }

    public var promptTokens: Int { inputTokens + cacheReadTokens + cacheWriteTokens }

    public static func cost(model: String, inputTokens: Int, outputTokens: Int, cacheReadTokens: Int,
                            cacheWriteTokens: Int, fastMode: Bool, prices: PriceList = .bundled) -> Double? {
        let prompt = inputTokens + cacheReadTokens + cacheWriteTokens
        guard let price = prices.pricing(for: model, promptTokens: prompt, fast: fastMode) else { return nil }
        let total = Double(inputTokens) * price.input
            + Double(cacheWriteTokens) * price.cacheWrite5m
            + Double(cacheReadTokens) * price.cacheRead
            + Double(outputTokens) * price.output
        return total / 1_000_000
    }

    /// From the API response: the model that actually responded (may be the fallback) and the speed used.
    public static func from(response: MessagesResponse, requestedModel: String, fastRequested: Bool,
                            prices: PriceList = .bundled) -> CorrectionUsage? {
        guard let usage = response.usage else { return nil }
        let fast = usage.speed.map { $0 == "fast" } ?? fastRequested
        return CorrectionUsage(
            model: response.model ?? requestedModel,
            inputTokens: usage.inputTokens ?? 0,
            outputTokens: usage.outputTokens ?? 0,
            cacheReadTokens: usage.cacheReadInputTokens ?? 0,
            cacheWriteTokens: usage.cacheCreationInputTokens ?? 0,
            fastMode: fast,
            prices: prices
        )
    }
}

public enum CostFormat {
    /// $0.0041 for small amounts, $0.123 under one dollar, $12.34 above.
    public static func usd(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }
}
