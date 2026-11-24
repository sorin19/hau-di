import Foundation

/// Preturile unui model, in USD per milion de tokeni (cele efective pentru o cerere: prompt lung, fast mode).
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

    /// Fast mode: multiplicatorii de cache se aplica peste pretul fast.
    public func scaled(by factor: Double) -> ModelPricing {
        ModelPricing(input: input * factor, cacheWrite5m: cacheWrite5m * factor,
                     cacheRead: cacheRead * factor, output: output * factor)
    }
}

/// Lista de preturi + ce nu spune /v1/models (fast mode, fallback la refuz), tinuta de autor in price.json pe pay.cx.ro
/// (servita la https://pay.cx.ro/hau-di/pricing/) dupa https://platform.claude.com/docs/en/about-claude/pricing.
/// Aplicatia o citeste o data pe saptamana; pana atunci (sau fara retea) foloseste copia inclusa (`bundled`).
/// In setari apar doar modelele care sunt si in /v1/models (accesibile cheii), si aici (cu pret cunoscut).
public struct PriceList: Codable, Equatable, Sendable {
    /// Alte preturi cand promptul (intrare + cache) depaseste `above` tokeni (ex: Haiku 5.5 peste 100.000).
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
        /// ID-ul din /v1/models, fara data: "claude-opus-4-5" acopera si "claude-opus-4-5-20251101".
        public var id: String
        public var input: Double
        public var output: Double
        /// Scrierea in cache pe 5 minute; lipsa = 1,25 x input.
        public var cacheWrite: Double?
        /// Citirea din cache; lipsa = 0,1 x input.
        public var cacheRead: Double?
        public var longPrompt: LongPrompt?
        /// Fast mode pe Claude API, fara beta (`speed: "fast"`).
        public var fast: Bool?
        /// Cat costa fast mode fata de pretul standard; lipsa = 2.
        public var fastMultiplier: Double?
        /// Fallback server-side la refuz (`fallbacks: "default"`).
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

        /// Preturile pentru o cerere: cu prompt lung, daca e cazul, si inmultite pentru fast mode.
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

        /// Valori pozitive, ID de model Claude, multiplicator fast de cel putin 1.
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
        /// Format necunoscut (fisier pentru o versiune mai noua a aplicatiei).
        case format(Int)
        case empty
        /// Model cu valori gresite sau ID repetat.
        case invalid(String)
    }

    /// 1 = formatul de mai sus. Un format nou poate fi publicat fara sa strice versiunile vechi.
    public var format: Int
    /// Ziua ultimei actualizari ("2026-11-23"), scrisa de mana in fisier.
    public var updated: String?
    /// Cand a fost salvat ultima data price.json pe server ("2026-11-24 10:15:00"); il adauga serverul.
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

    /// Momentul listei, pentru „castiga cea mai noua” si pentru afisare: `modified`, altfel `updated`.
    public var stamp: String { modified ?? updated ?? "" }

    /// Citeste si verifica o lista; una gresita e refuzata intreaga (aplicatia o pastreaza pe cea de dinainte).
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

    /// Intrarea unui model: ID exact sau ID + sufix de data ("-20261101"). nil daca modelul nu e in lista,
    /// ca un model nou (ex: "claude-opus-5-6") sa nu primeasca din greseala pretul altuia.
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

    /// "$4 / $20" (intrare / iesire, per milion de tokeni), pentru lista de modele; nil daca pretul nu e cunoscut.
    public func label(for model: String) -> String? {
        guard let price = pricing(for: model) else { return nil }
        return Self.dollars(price.input) + " / " + Self.dollars(price.output)
    }

    static func dollars(_ value: Double) -> String {
        value == value.rounded() ? String(format: "$%.0f", value) : String(format: "$%.2f", value)
    }

    /// Copia inclusa in aplicatie: price.json de pe pay.cx.ro (servit la /hau-di/pricing/), la data din `updated`.
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

/// Tokenii si costul unei corecturi Claude (salvate in istoric).
public struct CorrectionUsage: Codable, Hashable, Sendable {
    public var model: String
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheWriteTokens: Int
    public var fastMode: Bool
    /// nil daca modelul nu are pret in lista.
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

    /// Din raspunsul API: modelul care a raspuns efectiv (poate fi fallback-ul) si viteza folosita.
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
    /// $0.0041 pentru sume mici, $0.123 sub un dolar, $12.34 peste.
    public static func usd(_ value: Double) -> String {
        if value == 0 { return "$0" }
        if value < 0.01 { return String(format: "$%.4f", value) }
        if value < 1 { return String(format: "$%.3f", value) }
        return String(format: "$%.2f", value)
    }
}
