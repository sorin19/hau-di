import Foundation

/// Un model Claude asa cum il intoarce GET /v1/models (doar ce foloseste aplicatia).
/// Lista vine din API, ca modelele noi sa apara singure, iar cele retrase sa dispara.
public struct ClaudeModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    /// ISO 8601 ("2026-09-21T16:24:00Z"): ordinea alfabetica e si cea cronologica.
    public var createdAt: String
    /// Familia ("opus", "sonnet", "haiku", "fable"): campul `line` din API.
    public var line: String
    /// "active" sau "deprecated" (campul `lifecycle`).
    public var lifecycle: String
    /// Cand se retrage (ISO 8601), daca e anuntat.
    public var retiresAt: String?
    /// Nivelurile de efort acceptate (gol = modelul nu are efort).
    public var efforts: [EffortLevel]
    public var structuredOutputs: Bool
    /// Plafonul de raspuns (`max_tokens` din API).
    public var maxOutputTokens: Int?

    public init(id: String, displayName: String? = nil, createdAt: String = "", line: String? = nil,
                lifecycle: String = "active", retiresAt: String? = nil, efforts: [EffortLevel] = EffortLevel.allCases,
                structuredOutputs: Bool = true, maxOutputTokens: Int? = nil) {
        self.id = id
        self.displayName = displayName ?? ClaudeModels.displayName(for: id)
        self.createdAt = createdAt
        self.line = line ?? ClaudeModels.line(of: id)
        self.lifecycle = lifecycle
        self.retiresAt = retiresAt
        self.efforts = efforts
        self.structuredOutputs = structuredOutputs
        self.maxOutputTokens = maxOutputTokens
    }

    /// Depreciat: inca merge, dar are o data de retragere.
    public var isDeprecated: Bool { lifecycle == "deprecated" }

    /// Data retragerii, pentru afisare: "2026-11-30T17:00:00Z" -> "2026-11-30".
    public var retiresOn: String? {
        retiresAt.flatMap(ModelCatalog.displayDate)
    }

    /// Retras deja (data de retragere a trecut, dar lista din cache inca il contine).
    public func isRetired(at date: Date) -> Bool {
        guard let retiresAt, let when = ISO8601DateFormatter().date(from: retiresAt) else { return false }
        return when <= date
    }
}

/// Modelele unei familii, pentru lista din setari.
public struct ClaudeModelGroup: Identifiable, Sendable {
    public var line: String
    /// Cel mai nou primul.
    public var models: [ClaudeModelInfo]
    public var id: String { line }
}

public enum ModelCatalog {
    /// Selectia „cel mai nou model din familie”, de exemplu "latest:opus".
    public static let latestPrefix = "latest:"

    // MARK: - GET /v1/models

    struct Page: Decodable {
        struct Model: Decodable {
            var id: String
            var displayName: String?
            var createdAt: String?
            var line: String?
            var lifecycle: String?
            var retiresAt: String?
            var maxTokens: Int?
            var capabilities: JSONValue?

            enum CodingKeys: String, CodingKey {
                case id, line, lifecycle, capabilities
                case displayName = "display_name"
                case createdAt = "created_at"
                case retiresAt = "retires_at"
                case maxTokens = "max_tokens"
            }
        }

        var data: [Model]
        var hasMore: Bool?
        var lastID: String?

        enum CodingKeys: String, CodingKey {
            case data
            case hasMore = "has_more"
            case lastID = "last_id"
        }
    }

    /// O pagina din raspunsul GET /v1/models.
    public static func parsePage(_ data: Data) throws -> (models: [ClaudeModelInfo], hasMore: Bool, lastID: String?) {
        let page = try JSONDecoder().decode(Page.self, from: data)
        let models = page.data.map { raw -> ClaudeModelInfo in
            let capabilities = raw.capabilities
            // Fara `capabilities.effort` nu stim ce niveluri are modelul: nu trimitem efort deloc
            // (efort neacceptat = eroare 400; fara efort, modelul foloseste nivelul lui implicit).
            let efforts = capabilities?.flag("effort") == true
                ? EffortLevel.allCases.filter { capabilities?.flag("effort", $0.rawValue) == true }
                : []
            return ClaudeModelInfo(
                id: raw.id,
                displayName: raw.displayName,
                createdAt: raw.createdAt ?? "",
                line: raw.line,
                lifecycle: raw.lifecycle ?? "active",
                retiresAt: raw.retiresAt,
                efforts: efforts,
                // Exclus doar cand API-ul spune explicit ca nu are (corectia cere raspuns JSON cu schema).
                structuredOutputs: capabilities?.flag("structured_outputs") ?? true,
                maxOutputTokens: raw.maxTokens
            )
        }
        return (models, page.hasMore ?? false, page.lastID)
    }

    /// "2026-11-30T17:00:00Z" sau "2026-11-30" -> "2026-11-30" (ISO: fara ambiguitate zi/luna in orice limba).
    public static func displayDate(_ iso: String) -> String? {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[0])-\(parts[1])-\(parts[2])"
    }

    /// "2026-11-24 10:15:00" -> "2026-11-24 10:15"; doar data ("2026-11-23") -> "2026-11-23".
    public static func displayDateTime(_ text: String) -> String? {
        guard let day = displayDate(text) else { return nil }
        let time = text.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: " T"))
        return time.count >= 5 ? day + " " + time.prefix(5) : day
    }

    /// Modelele afisate in setari: accesibile cheii (/v1/models) si cu pret in lista (price.json).
    public static func priced(_ models: [ClaudeModelInfo], in prices: PriceList) -> [ClaudeModelInfo] {
        models.filter { prices.entry(for: $0.id) != nil }
    }

    // MARK: - Alegerea modelului si a efortului

    /// Modelul din lista: ID exact, sau acelasi model cu/fara sufixul de data ("claude-opus-4-5" = "claude-opus-4-5-20251101").
    public static func info(_ id: String, in models: [ClaudeModelInfo]) -> ClaudeModelInfo? {
        models.first { $0.id == id } ?? models.first { ClaudeModels.baseID($0.id) == ClaudeModels.baseID(id) }
    }

    /// ID-ul folosit efectiv pentru o selectie ("claude-opus-5-5" sau "latest:opus"):
    /// - "latest:<familie>": cel mai nou model activ din familie;
    /// - un ID care nu mai e in lista (sau a trecut data retragerii): cel mai nou model din aceeasi familie;
    /// - fara lista (inca neincarcata): ID-ul ales, sau ultimul model cunoscut al familiei.
    public static func resolve(_ selection: String, in models: [ClaudeModelInfo], now: Date = Date()) -> String {
        let available = models.filter { !$0.isRetired(at: now) }
        if selection.hasPrefix(latestPrefix) {
            let line = String(selection.dropFirst(latestPrefix.count))
            return newest(inLine: line, available) ?? ClaudeModels.defaultModel(forLine: line)
        }
        let id = selection.isEmpty ? ClaudeModels.defaultModelID : selection
        guard !models.isEmpty, info(id, in: available) == nil else { return id }
        return newest(inLine: ClaudeModels.line(of: id), available)
            ?? newest(inLine: "opus", available)
            ?? ClaudeModels.defaultModelID
    }

    /// Cel mai nou model din familie (cu raspuns JSON cu schema); cele depreciate doar daca nu exista altul.
    static func newest(inLine line: String, _ models: [ClaudeModelInfo]) -> String? {
        let inLine = models.filter { $0.line == line && $0.structuredOutputs }
        let active = inLine.filter { !$0.isDeprecated }
        return (active.isEmpty ? inLine : active).max { $0.createdAt < $1.createdAt }?.id
    }

    /// Efortul trimis: cel ales, daca modelul il are; altfel cel mai apropiat mai mic (sau cel mai mic pe care il are).
    /// nil = nu trimitem efort (modelul nu are niveluri de efort). Model necunoscut (lista neincarcata): cel ales.
    public static func effort(_ preferred: EffortLevel, for info: ClaudeModelInfo?) -> EffortLevel? {
        guard let info else { return preferred }
        guard !info.efforts.isEmpty else { return nil }
        if info.efforts.contains(preferred) { return preferred }
        let lower = info.efforts.filter { $0.rank < preferred.rank }
        return lower.max { $0.rank < $1.rank } ?? info.efforts.min { $0.rank < $1.rank }
    }

    /// Familiile in ordinea din setari; cele noi, necunoscute, la final, alfabetic.
    static let lineOrder = ["opus", "sonnet", "haiku", "fable", "mythos"]

    /// Modelele pentru lista din setari, pe familii; fara cele care nu pot raspunde JSON cu schema.
    public static func grouped(_ models: [ClaudeModelInfo]) -> [ClaudeModelGroup] {
        let models = models.filter(\.structuredOutputs)
        let lines = Set(models.map(\.line))
        let ordered = lineOrder.filter(lines.contains) + lines.subtracting(lineOrder).sorted()
        return ordered.map { line in
            ClaudeModelGroup(line: line, models: models.filter { $0.line == line }.sorted { $0.createdAt > $1.createdAt })
        }
    }
}

extension JSONValue {
    /// `capabilities.<cale>.supported` din /v1/models; nil daca lipseste.
    func flag(_ path: String...) -> Bool? {
        var node: JSONValue? = self
        for key in path {
            guard case .object(let dict)? = node else { return nil }
            node = dict[key]
        }
        guard case .object(let leaf)? = node, case .bool(let value)? = leaf["supported"] else { return nil }
        return value
    }
}
