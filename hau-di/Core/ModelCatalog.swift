import Foundation

/// A Claude model as returned by GET /v1/models (only what the app uses).
/// The list comes from the API, so new models show up on their own and retired ones disappear.
public struct ClaudeModelInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var displayName: String
    /// ISO 8601 ("2026-09-21T16:24:00Z"): alphabetical order is also chronological order.
    public var createdAt: String
    /// The family ("opus", "sonnet", "haiku", "fable"): the `line` field from the API.
    public var line: String
    /// "active" or "deprecated" (the `lifecycle` field).
    public var lifecycle: String
    /// When it is retired (ISO 8601), if announced.
    public var retiresAt: String?
    /// The supported effort levels (empty = the model has no effort setting).
    public var efforts: [EffortLevel]
    public var structuredOutputs: Bool
    /// The output token cap (`max_tokens` from the API).
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

    /// Deprecated: still works, but has a retirement date.
    public var isDeprecated: Bool { lifecycle == "deprecated" }

    /// The retirement date, for display: "2026-11-30T17:00:00Z" -> "2026-11-30".
    public var retiresOn: String? {
        retiresAt.flatMap(ModelCatalog.displayDate)
    }

    /// Already retired (the retirement date has passed, but the cached list still contains it).
    public func isRetired(at date: Date) -> Bool {
        guard let retiresAt, let when = ISO8601DateFormatter().date(from: retiresAt) else { return false }
        return when <= date
    }
}

/// The models of one family, for the list in the settings.
public struct ClaudeModelGroup: Identifiable, Sendable {
    public var line: String
    /// Newest first.
    public var models: [ClaudeModelInfo]
    public var id: String { line }
}

public enum ModelCatalog {
    /// The "newest model in the family" selection, for example "latest:opus".
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

    /// One page of the GET /v1/models response.
    public static func parsePage(_ data: Data) throws -> (models: [ClaudeModelInfo], hasMore: Bool, lastID: String?) {
        let page = try JSONDecoder().decode(Page.self, from: data)
        let models = page.data.map { raw -> ClaudeModelInfo in
            let capabilities = raw.capabilities
            // Without `capabilities.effort` we do not know which levels the model has, so we send no effort at all
            // (an unsupported effort = a 400 error; without effort, the model uses its default level).
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
                // Excluded only if the API explicitly says it is unsupported (the correction needs schema-based JSON).
                structuredOutputs: capabilities?.flag("structured_outputs") ?? true,
                maxOutputTokens: raw.maxTokens
            )
        }
        return (models, page.hasMore ?? false, page.lastID)
    }

    /// "2026-11-30T17:00:00Z" or "2026-11-30" -> "2026-11-30" (ISO: no day/month ambiguity in any language).
    public static func displayDate(_ iso: String) -> String? {
        let parts = iso.prefix(10).split(separator: "-")
        guard parts.count == 3 else { return nil }
        return "\(parts[0])-\(parts[1])-\(parts[2])"
    }

    /// "2026-11-24 10:15:00" -> "2026-11-24 10:15"; a date alone ("2026-11-23") -> "2026-11-23".
    public static func displayDateTime(_ text: String) -> String? {
        guard let day = displayDate(text) else { return nil }
        let time = text.dropFirst(10).trimmingCharacters(in: CharacterSet(charactersIn: " T"))
        return time.count >= 5 ? day + " " + time.prefix(5) : day
    }

    /// The models shown in the settings: accessible to the key (/v1/models) and priced in the list (price.json).
    public static func priced(_ models: [ClaudeModelInfo], in prices: PriceList) -> [ClaudeModelInfo] {
        models.filter { prices.entry(for: $0.id) != nil }
    }

    // MARK: - Choosing the model and the effort

    /// The model in the list: exact ID, or the same model with/without the date suffix
    /// ("claude-opus-4-5" = "claude-opus-4-5-20251101").
    public static func info(_ id: String, in models: [ClaudeModelInfo]) -> ClaudeModelInfo? {
        models.first { $0.id == id } ?? models.first { ClaudeModels.baseID($0.id) == ClaudeModels.baseID(id) }
    }

    /// The ID actually used for a selection ("claude-opus-5-5" or "latest:opus"):
    /// - "latest:<family>": the newest active model in the family;
    /// - an ID that is no longer in the list (or past its retirement date): the newest model in the same family;
    /// - no list (not loaded yet): the chosen ID, or the latest known model of the family.
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

    /// The newest model in the family (with schema-based JSON responses); deprecated ones only if there is no other.
    static func newest(inLine line: String, _ models: [ClaudeModelInfo]) -> String? {
        let inLine = models.filter { $0.line == line && $0.structuredOutputs }
        let active = inLine.filter { !$0.isDeprecated }
        return (active.isEmpty ? inLine : active).max { $0.createdAt < $1.createdAt }?.id
    }

    /// The effort sent: the chosen one, if the model has it; otherwise the nearest lower one (or the lowest it has).
    /// nil = no effort is sent (the model has no effort levels). Unknown model (list not loaded): the chosen one.
    public static func effort(_ preferred: EffortLevel, for info: ClaudeModelInfo?) -> EffortLevel? {
        guard let info else { return preferred }
        guard !info.efforts.isEmpty else { return nil }
        if info.efforts.contains(preferred) { return preferred }
        let lower = info.efforts.filter { $0.rank < preferred.rank }
        return lower.max { $0.rank < $1.rank } ?? info.efforts.min { $0.rank < $1.rank }
    }

    /// The families in settings order; new, unknown ones go at the end, alphabetically.
    static let lineOrder = ["opus", "sonnet", "haiku", "fable", "mythos"]

    /// The models for the settings list, by family; without those that cannot respond with schema-based JSON.
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
    /// `capabilities.<path>.supported` from /v1/models; nil if missing.
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
