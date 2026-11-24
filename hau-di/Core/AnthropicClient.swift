import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Client minimal pentru Claude Messages API (HTTP direct: Swift nu are SDK oficial Anthropic).
// Documentatie: https://platform.claude.com/docs/en/api/messages

/// Valoare JSON arbitrara (pentru schema structured outputs).
public indirect enum JSONValue: Codable, Equatable, Sendable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case object([String: JSONValue])
    case array([JSONValue])
    case null

    private struct Key: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ string: String) { stringValue = string }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public func encode(to encoder: Encoder) throws {
        switch self {
        case .string(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .number(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .bool(let value):
            var container = encoder.singleValueContainer()
            try container.encode(value)
        case .null:
            var container = encoder.singleValueContainer()
            try container.encodeNil()
        case .array(let values):
            var container = encoder.unkeyedContainer()
            for value in values { try container.encode(value) }
        case .object(let dict):
            var container = encoder.container(keyedBy: Key.self)
            for key in dict.keys.sorted() {
                try container.encode(dict[key]!, forKey: Key(key))
            }
        }
    }

    public init(from decoder: Decoder) throws {
        if let container = try? decoder.container(keyedBy: Key.self) {
            var dict: [String: JSONValue] = [:]
            for key in container.allKeys {
                dict[key.stringValue] = try container.decode(JSONValue.self, forKey: key)
            }
            self = .object(dict)
            return
        }
        if var container = try? decoder.unkeyedContainer() {
            var values: [JSONValue] = []
            while !container.isAtEnd { values.append(try container.decode(JSONValue.self)) }
            self = .array(values)
            return
        }
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(Double.self) { self = .number(value) }
        else { self = .string(try container.decode(String.self)) }
    }
}

// MARK: - Request

public struct MessagesRequest: Encodable, Sendable {
    public struct SystemBlock: Encodable, Sendable {
        public var type: String = "text"
        public var text: String
        public var cacheControl: CacheControl?

        public init(text: String, cacheControl: CacheControl? = nil) {
            self.text = text
            self.cacheControl = cacheControl
        }

        enum CodingKeys: String, CodingKey {
            case type, text
            case cacheControl = "cache_control"
        }
    }

    public struct CacheControl: Encodable, Sendable {
        public var type: String = "ephemeral"
        public init() {}
    }

    public struct Message: Encodable, Sendable {
        public var role: String
        public var content: String

        public init(role: String, content: String) {
            self.role = role
            self.content = content
        }
    }

    public struct OutputConfig: Encodable, Sendable {
        public var effort: String?
        public var format: OutputFormat?

        public init(effort: String? = nil, format: OutputFormat? = nil) {
            self.effort = effort
            self.format = format
        }
    }

    public struct OutputFormat: Encodable, Sendable {
        public var type: String = "json_schema"
        public var schema: JSONValue

        public init(schema: JSONValue) {
            self.schema = schema
        }
    }

    public var model: String
    public var maxTokens: Int
    public var system: [SystemBlock]
    public var messages: [Message]
    public var outputConfig: OutputConfig?
    /// Fallback server-side la refuz: "default" (necesita beta server-side-fallback-2026-07-01).
    public var fallbacks: String?
    /// "fast" = fast mode (doar Opus 5.5).
    public var speed: String?

    public init(model: String, maxTokens: Int, system: [SystemBlock], messages: [Message],
                outputConfig: OutputConfig? = nil, fallbacks: String? = nil, speed: String? = nil) {
        self.model = model
        self.maxTokens = maxTokens
        self.system = system
        self.messages = messages
        self.outputConfig = outputConfig
        self.fallbacks = fallbacks
        self.speed = speed
    }

    enum CodingKeys: String, CodingKey {
        case model
        case maxTokens = "max_tokens"
        case system, messages
        case outputConfig = "output_config"
        case fallbacks, speed
    }
}

// MARK: - Response

public struct MessagesResponse: Decodable, Sendable {
    public struct ContentBlock: Decodable, Sendable {
        public var type: String
        public var text: String?
    }

    public struct Usage: Decodable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?
        public var cacheReadInputTokens: Int?
        public var cacheCreationInputTokens: Int?
        public var speed: String?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
            case cacheReadInputTokens = "cache_read_input_tokens"
            case cacheCreationInputTokens = "cache_creation_input_tokens"
            case speed
        }
    }

    public var id: String?
    public var model: String?
    public var content: [ContentBlock]
    public var stopReason: String?
    public var usage: Usage?

    enum CodingKeys: String, CodingKey {
        case id, model, content
        case stopReason = "stop_reason"
        case usage
    }

    /// Textul raspunsului: doar blocurile `text` (raspunsul poate contine si `thinking` / `fallback`).
    public var text: String {
        content.filter { $0.type == "text" }.compactMap(\.text).joined()
    }
}

struct APIErrorEnvelope: Decodable {
    struct Inner: Decodable {
        var type: String?
        var message: String?
    }
    var error: Inner?
}

public enum AnthropicError: Error, LocalizedError, Equatable {
    case missingAPIKey
    case http(status: Int, type: String?, message: String)
    case refused
    case truncated
    case invalidOutput(String)
    case timeout
    case transport(String)
    case cancelled

    public var errorDescription: String? {
        switch self {
        case .missingAPIKey:
            return "Missing Anthropic API key."
        case .http(let status, _, let message):
            switch status {
            case 401: return "Invalid API key (401)."
            case 403: return "The API key does not have access to this model (403)."
            case 404: return "Model not available for your account (404)."
            case 429: return "Rate limit reached (429). Try again in a moment."
            case 529: return "The Anthropic API is overloaded (529)."
            default: return "API error \(status): \(message)"
            }
        case .refused:
            return "The model refused the request."
        case .truncated:
            return "The response was truncated (max_tokens)."
        case .invalidOutput(let detail):
            return "Unexpected response from the model: \(detail)"
        case .timeout:
            return "The AI correction timed out."
        case .transport(let detail):
            return "Network error: \(detail)"
        case .cancelled:
            return "Canceled."
        }
    }

    public var isRetryable: Bool {
        switch self {
        case .http(let status, _, _): return status == 429 || status == 529 || status >= 500
        case .transport: return true
        default: return false
        }
    }
}

public final class AnthropicClient: @unchecked Sendable {
    /// Versiunea de API trimisa in header-ul `anthropic-version`.
    public static let apiVersion = "2026-10-21"
    public static let serverSideFallbackBeta = "server-side-fallback-2026-07-01"

    public let baseURL: URL
    private let session: URLSession

    public init(baseURL: URL = URL(string: "https://api.anthropic.com")!, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
    }

    func makeURLRequest(path: String, method: String, apiKey: String, betas: [String], timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "anthropic-version")
        if !betas.isEmpty {
            request.setValue(betas.joined(separator: ","), forHTTPHeaderField: "anthropic-beta")
        }
        return request
    }

    public static func encode(_ request: MessagesRequest) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(request)
    }

    /// POST /v1/messages
    public func createMessage(_ body: MessagesRequest, apiKey: String, betas: [String] = [], timeout: TimeInterval = 30) async throws -> MessagesResponse {
        var request = makeURLRequest(path: "v1/messages", method: "POST", apiKey: apiKey, betas: betas, timeout: timeout)
        request.httpBody = try Self.encode(body)
        let data = try await perform(request)
        do {
            return try JSONDecoder().decode(MessagesResponse.self, from: data)
        } catch {
            throw AnthropicError.invalidOutput("invalid JSON response")
        }
    }

    /// GET /v1/models: toate modelele la care are acces cheia (cu paginare), cu capabilitatile lor.
    public func listModels(apiKey: String, timeout: TimeInterval = 15) async throws -> [ClaudeModelInfo] {
        var models: [ClaudeModelInfo] = []
        var after: String?
        for _ in 0..<10 {
            var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
            var query = [URLQueryItem(name: "limit", value: "1000")]
            if let after { query.append(URLQueryItem(name: "after_id", value: after)) }
            components.queryItems = query
            var request = makeURLRequest(path: "v1/models", method: "GET", apiKey: apiKey, betas: [], timeout: timeout)
            request.url = components.url
            let data = try await perform(request)
            let page: (models: [ClaudeModelInfo], hasMore: Bool, lastID: String?)
            do {
                page = try ModelCatalog.parsePage(data)
            } catch {
                throw AnthropicError.invalidOutput("model list")
            }
            models += page.models
            guard page.hasMore, let last = page.lastID else { break }
            after = last
        }
        return models
    }

    /// GET /v1/models?limit=1 - valideaza cheia fara costuri.
    public func validateKey(_ apiKey: String, timeout: TimeInterval = 15) async throws {
        var components = URLComponents(url: baseURL.appendingPathComponent("v1/models"), resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "limit", value: "1")]
        var request = makeURLRequest(path: "v1/models", method: "GET", apiKey: apiKey, betas: [], timeout: timeout)
        request.url = components.url
        _ = try await perform(request)
    }

    private func perform(_ request: URLRequest) async throws -> Data {
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            switch error.code {
            case .timedOut: throw AnthropicError.timeout
            case .cancelled: throw AnthropicError.cancelled
            default: throw AnthropicError.transport(error.localizedDescription)
            }
        } catch is CancellationError {
            throw AnthropicError.cancelled
        } catch {
            throw AnthropicError.transport(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw AnthropicError.transport("non-HTTP response")
        }
        guard (200..<300).contains(http.statusCode) else {
            let envelope = try? JSONDecoder().decode(APIErrorEnvelope.self, from: data)
            let message = envelope?.error?.message ?? String(data: data.prefix(300), encoding: .utf8) ?? ""
            throw AnthropicError.http(status: http.statusCode, type: envelope?.error?.type, message: message)
        }
        return data
    }
}
