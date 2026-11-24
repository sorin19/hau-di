import Foundation
import Combine

/// The Claude models in the settings: those the key has access to (GET /v1/models, reloaded daily) and that have a
/// price in the price list (from pay.cx.ro/hau-di/pricing/, fetched weekly). Both are kept on disk, so they are
/// available right away at launch and without a network. Also reloaded when the key changes, when the AI settings
/// open, after corrections and when the API says the model no longer exists (404).
@MainActor
final class ModelCatalogStore: ObservableObject {
    // GET /v1/models
    @Published private(set) var models: [ClaudeModelInfo] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    // Price list (pay.cx.ro/hau-di/pricing/)
    @Published private(set) var prices: PriceList = .bundled
    /// nil = the copy bundled with the app is used.
    @Published private(set) var pricesFetchedAt: Date?
    @Published private(set) var pricesError: String?
    /// Parameters rejected by the API (400), per model (ID without the date): "speed" (fast mode), "fallbacks".
    @Published private(set) var rejected: [String: Set<String>] = [:]

    private static let modelsMaxAge: TimeInterval = 24 * 3600
    private static let pricesMaxAge: TimeInterval = 7 * 24 * 3600
    /// After an error (no network, server down) we don't retry on every dictation.
    private static let retryAfterError: TimeInterval = 3600

    private let fileURL: URL
    private let pricesURL: URL
    private let installID: String
    private let client: AnthropicClient
    private let session: URLSession
    private var modelsAttempt: Date?
    private var pricesAttempt: Date?
    private var pricesLoading = false

    private struct Cache: Codable {
        var fetchedAt: Date?
        var models: [ClaudeModelInfo]
        var rejected: [String: Set<String>]
        var prices: PriceList?
        var pricesFetchedAt: Date?
    }

    private struct HTTPStatusError: Error {
        let code: Int
    }

    init(fileURL: URL, pricesURL: URL, installID: String, client: AnthropicClient = AnthropicClient(),
         session: URLSession = .shared) {
        self.fileURL = fileURL
        self.pricesURL = pricesURL
        self.installID = installID
        self.client = client
        self.session = session
        if let data = try? Data(contentsOf: fileURL), let cache = try? JSONDecoder().decode(Cache.self, from: data) {
            models = cache.models
            fetchedAt = cache.fetchedAt
            rejected = cache.rejected
            // The downloaded list stays, unless it is older than the copy in the app (after an update).
            if let cached = cache.prices, cached.stamp >= PriceList.bundled.stamp {
                prices = cached
                pricesFetchedAt = cache.pricesFetchedAt
            }
        }
    }

    // MARK: - Displayed models and model selection

    /// Accessible to the key and with a known price.
    var available: [ClaudeModelInfo] {
        ModelCatalog.priced(models, in: prices)
    }

    var groups: [ClaudeModelGroup] {
        ModelCatalog.grouped(available)
    }

    /// The ID actually used for the selection in the settings (see ModelCatalog.resolve).
    func resolvedID(for selection: String) -> String {
        ModelCatalog.resolve(selection, in: available)
    }

    func info(for id: String) -> ClaudeModelInfo? {
        ModelCatalog.info(id, in: models)
    }

    func displayName(for id: String) -> String {
        info(for: id)?.displayName ?? ClaudeModels.displayName(for: id)
    }

    func rejectedFeatures(for id: String) -> Set<String> {
        rejected[ClaudeModels.baseID(id)] ?? []
    }

    /// Fast mode can be requested: the model has it in the price list and the API hasn't rejected it.
    func mayUseFastMode(_ id: String) -> Bool {
        prices.entry(for: id)?.supportsFastMode == true && !rejectedFeatures(for: id).contains("speed")
    }

    // MARK: - Reloading

    /// Reloads what is stale: the models once a day, the prices once a week.
    func refreshIfStale(apiKey: String?) {
        if Self.isDue(lastSuccess: models.isEmpty ? nil : fetchedAt, lastAttempt: modelsAttempt, maxAge: Self.modelsMaxAge) {
            refresh(apiKey: apiKey)
        }
        if Self.isDue(lastSuccess: pricesFetchedAt, lastAttempt: pricesAttempt, maxAge: Self.pricesMaxAge) {
            refreshPrices()
        }
    }

    private static func isDue(lastSuccess: Date?, lastAttempt: Date?, maxAge: TimeInterval) -> Bool {
        let now = Date()
        if let lastAttempt, now.timeIntervalSince(lastAttempt) < retryAfterError { return false }
        guard let lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) >= maxAge
    }

    /// `manual`: requested from the settings; also reloads the prices and forgets the rejected parameters, so they are
    /// tried again (Anthropic may enable fast mode on a model later).
    func refresh(apiKey: String?, manual: Bool = false) {
        if manual { refreshPrices() }
        guard !isLoading, let key = apiKey?.trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty else { return }
        isLoading = true
        lastError = nil
        modelsAttempt = Date()
        Task {
            do {
                let list = try await client.listModels(apiKey: key)
                models = list
                fetchedAt = Date()
                if manual { rejected = [:] }
                save()
                Log.ai.info("Model list: \(list.count) models")
            } catch {
                lastError = error.localizedDescription
                Log.ai.error("Model list: \(error.localizedDescription, privacy: .public)")
            }
            isLoading = false
        }
    }

    /// Fetches the price list. Sends the random install ID and the app version (only here),
    /// so the author can see how many installs use the app; the server also records the date and the IP.
    func refreshPrices() {
        guard !pricesLoading else { return }
        pricesLoading = true
        pricesAttempt = Date()
        let request: URLRequest = {
            var request = URLRequest(url: pricesURL, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
            request.setValue(installID, forHTTPHeaderField: "X-Hau-Di-Install")
            request.setValue(AppInfo.version, forHTTPHeaderField: "X-Hau-Di-Version")
            return request
        }()
        let session = self.session
        Task {
            do {
                let (data, response) = try await session.data(for: request)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else { throw HTTPStatusError(code: status) }
                let list = try PriceList.decode(data)
                // The newer list wins: after an update, the copy in the app can be newer than the one on the server.
                prices = list.stamp >= PriceList.bundled.stamp ? list : .bundled
                pricesFetchedAt = Date()
                pricesError = nil
                save()
                let updated = list.updated ?? "?"
                Log.ai.info("Prices: \(list.models.count) models, updated \(updated, privacy: .public)")
            } catch {
                let message = Self.describe(error)
                pricesError = message
                Log.ai.error("Prices: \(message, privacy: .public)")
            }
            pricesLoading = false
        }
    }

    nonisolated private static func describe(_ error: Error) -> String {
        switch error {
        case let status as HTTPStatusError: return "HTTP \(status.code)"
        case is DecodingError, is PriceList.ValidationError: return "invalid file"
        default: return error.localizedDescription
        }
    }

    /// Remembers the parameters the API rejected for the model (reported by ClaudeCorrector.correct).
    func noteRejected(_ features: Set<String>, for model: String) {
        guard !features.isEmpty else { return }
        let key = ClaudeModels.baseID(model)
        let merged = rejectedFeatures(for: key).union(features)
        guard merged != rejected[key] else { return }
        rejected[key] = merged
        save()
        Log.ai.info("\(key, privacy: .public) rejects: \(merged.sorted().joined(separator: ", "), privacy: .public)")
    }

    private func save() {
        let cache = Cache(fetchedAt: fetchedAt, models: models, rejected: rejected,
                          prices: pricesFetchedAt == nil ? nil : prices, pricesFetchedAt: pricesFetchedAt)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
