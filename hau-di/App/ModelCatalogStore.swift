import Foundation
import Combine

/// Modelele Claude din setari: cele la care are acces cheia (GET /v1/models, reincarcata zilnic) si care au pret
/// in lista de preturi (de pe pay.cx.ro/hau-di/pricing/, citita saptamanal). Ambele se pastreaza pe disc, ca sa fie
/// disponibile imediat la pornire si fara retea. Se reincarca si la schimbarea cheii, la deschiderea setarilor AI,
/// dupa corecturi si cand API-ul spune ca modelul nu mai exista (404).
@MainActor
final class ModelCatalogStore: ObservableObject {
    // GET /v1/models
    @Published private(set) var models: [ClaudeModelInfo] = []
    @Published private(set) var fetchedAt: Date?
    @Published private(set) var isLoading = false
    @Published private(set) var lastError: String?
    // Lista de preturi (pay.cx.ro/hau-di/pricing/)
    @Published private(set) var prices: PriceList = .bundled
    /// nil = se foloseste copia inclusa in aplicatie.
    @Published private(set) var pricesFetchedAt: Date?
    @Published private(set) var pricesError: String?
    /// Parametrii refuzati de API (400), pe model (ID fara data): "speed" (fast mode), "fallbacks".
    @Published private(set) var rejected: [String: Set<String>] = [:]

    private static let modelsMaxAge: TimeInterval = 24 * 3600
    private static let pricesMaxAge: TimeInterval = 7 * 24 * 3600
    /// Dupa o eroare (fara retea, server cazut) nu reincercam la fiecare dictare.
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
            // Lista descarcata ramane, daca nu e mai veche decat copia din aplicatie (dupa o actualizare).
            if let cached = cache.prices, cached.stamp >= PriceList.bundled.stamp {
                prices = cached
                pricesFetchedAt = cache.pricesFetchedAt
            }
        }
    }

    // MARK: - Modelele afisate si alegerea modelului

    /// Accesibile cheii si cu pret cunoscut.
    var available: [ClaudeModelInfo] {
        ModelCatalog.priced(models, in: prices)
    }

    var groups: [ClaudeModelGroup] {
        ModelCatalog.grouped(available)
    }

    /// ID-ul folosit efectiv pentru selectia din setari (vezi ModelCatalog.resolve).
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

    /// Fast mode se poate cere: modelul il are in lista de preturi si API-ul nu l-a refuzat.
    func mayUseFastMode(_ id: String) -> Bool {
        prices.entry(for: id)?.supportsFastMode == true && !rejectedFeatures(for: id).contains("speed")
    }

    // MARK: - Reincarcare

    /// Reincarca ce e vechi: modelele o data pe zi, preturile o data pe saptamana.
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

    /// `manual`: ceruta din setari; reincarca si preturile si uita parametrii refuzati, ca sa fie incercati din nou
    /// (Anthropic poate activa fast mode pe un model mai tarziu).
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
                Log.ai.info("Lista de modele: \(list.count) modele")
            } catch {
                lastError = error.localizedDescription
                Log.ai.error("Lista de modele: \(error.localizedDescription, privacy: .public)")
            }
            isLoading = false
        }
    }

    /// Citeste lista de preturi. Trimite ID-ul aleator al instalarii si versiunea aplicatiei (doar aici),
    /// ca autorul sa vada cate instalari folosesc aplicatia; serverul noteaza si data si IP-ul.
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
                // Castiga lista mai noua: dupa o actualizare, copia din aplicatie poate fi mai noua decat cea de pe server.
                prices = list.stamp >= PriceList.bundled.stamp ? list : .bundled
                pricesFetchedAt = Date()
                pricesError = nil
                save()
                let updated = list.updated ?? "?"
                Log.ai.info("Preturi: \(list.models.count) modele, actualizate \(updated, privacy: .public)")
            } catch {
                let message = Self.describe(error)
                pricesError = message
                Log.ai.error("Preturi: \(message, privacy: .public)")
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

    /// Tine minte parametrii pe care API-ul i-a refuzat pentru model (raportati de ClaudeCorrector.correct).
    func noteRejected(_ features: Set<String>, for model: String) {
        guard !features.isEmpty else { return }
        let key = ClaudeModels.baseID(model)
        let merged = rejectedFeatures(for: key).union(features)
        guard merged != rejected[key] else { return }
        rejected[key] = merged
        save()
        Log.ai.info("\(key, privacy: .public) refuza: \(merged.sorted().joined(separator: ", "), privacy: .public)")
    }

    private func save() {
        let cache = Cache(fetchedAt: fetchedAt, models: models, rejected: rejected,
                          prices: pricesFetchedAt == nil ? nil : prices, pricesFetchedAt: pricesFetchedAt)
        guard let data = try? JSONEncoder().encode(cache) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }
}
