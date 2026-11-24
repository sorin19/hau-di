import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HauDiCore

/// Raspunsul real GET /v1/models (noiembrie 2026), scurtat la 6 modele cu situatii diferite.
private let modelsSample = #"""
{"data":[
 {"type":"model","id":"claude-fable-5-2","display_name":"Claude Fable 5.2","created_at":"2026-11-09T18:30:00Z","line":"fable",
  "max_input_tokens":1000000,"max_tokens":128000,
  "capabilities":{"batch":{"supported":true},
   "effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}},
   "structured_outputs":{"supported":true},
   "thinking":{"supported":true,"types":{"enabled":{"supported":false},"adaptive":{"supported":true},"disabled":{"supported":false},"between_tools":{"supported":false}}}},
  "lifecycle":"active","deprecated_at":null,"retires_at":null},
 {"type":"model","id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-21T16:24:00Z","line":"opus",
  "max_input_tokens":1000000,"max_tokens":128000,
  "capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":true},"max":{"supported":true}},
   "structured_outputs":{"supported":true}},
  "lifecycle":"active","deprecated_at":null,"retires_at":null},
 {"type":"model","id":"claude-sonnet-4-6","display_name":"Claude Sonnet 4.6","created_at":"2026-02-17T00:00:00Z","line":"sonnet",
  "max_input_tokens":1000000,"max_tokens":128000,
  "capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":false},"max":{"supported":true}},
   "structured_outputs":{"supported":true}},
  "lifecycle":"active","deprecated_at":null,"retires_at":null},
 {"type":"model","id":"claude-opus-4-5-20251101","display_name":"Claude Opus 4.5","created_at":"2025-11-24T00:00:00Z","line":"opus",
  "max_input_tokens":200000,"max_tokens":64000,
  "capabilities":{"effort":{"supported":true,"low":{"supported":true},"medium":{"supported":true},"high":{"supported":true},"xhigh":{"supported":false},"max":{"supported":false}},
   "structured_outputs":{"supported":true}},
  "lifecycle":"active","deprecated_at":null,"retires_at":null},
 {"type":"model","id":"claude-haiku-4-5-20251001","display_name":"Claude Haiku 4.5","created_at":"2025-10-15T00:00:00Z","line":"haiku",
  "max_input_tokens":200000,"max_tokens":64000,
  "capabilities":{"effort":{"supported":false,"low":{"supported":false},"medium":{"supported":false},"high":{"supported":false},"xhigh":{"supported":false},"max":{"supported":false}},
   "structured_outputs":{"supported":true}},
  "lifecycle":"active","deprecated_at":null,"retires_at":null},
 {"type":"model","id":"claude-sonnet-4-5-20250929","display_name":"Claude Sonnet 4.5","created_at":"2025-09-29T00:00:00Z","line":"sonnet",
  "max_input_tokens":200000,"max_tokens":64000,
  "capabilities":{"effort":{"supported":false,"low":{"supported":false},"medium":{"supported":false},"high":{"supported":false},"xhigh":{"supported":false},"max":{"supported":false}},
   "structured_outputs":{"supported":true}},
  "lifecycle":"deprecated","deprecated_at":"2026-09-30T18:30:00Z","retires_at":"2026-11-30T17:00:00Z"}
],"has_more":false,"first_id":"claude-fable-5-2","last_id":"claude-sonnet-4-5-20250929"}
"""#

private func date(_ iso: String) -> Date {
    ISO8601DateFormatter().date(from: iso)!
}

final class ModelCatalogTests: XCTestCase {
    private func sampleModels() throws -> [ClaudeModelInfo] {
        try ModelCatalog.parsePage(Data(modelsSample.utf8)).models
    }

    func testParsePage() throws {
        let page = try ModelCatalog.parsePage(Data(modelsSample.utf8))
        XCTAssertFalse(page.hasMore)
        XCTAssertEqual(page.lastID, "claude-sonnet-4-5-20250929")
        XCTAssertEqual(page.models.count, 6)

        let opus = try XCTUnwrap(page.models.first { $0.id == "claude-opus-5-5" })
        XCTAssertEqual(opus.displayName, "Claude Opus 5.5")
        XCTAssertEqual(opus.line, "opus")
        XCTAssertEqual(opus.efforts, [.low, .medium, .high, .xhigh, .max])
        XCTAssertEqual(opus.maxOutputTokens, 128_000)
        XCTAssertTrue(opus.structuredOutputs)
        XCTAssertFalse(opus.isDeprecated)
        XCTAssertNil(opus.retiresOn)

        let byID = Dictionary(uniqueKeysWithValues: page.models.map { ($0.id, $0) })
        XCTAssertEqual(byID["claude-sonnet-4-6"]?.efforts, [.low, .medium, .high, .max])
        XCTAssertEqual(byID["claude-opus-4-5-20251101"]?.efforts, [.low, .medium, .high])
        XCTAssertEqual(byID["claude-opus-4-5-20251101"]?.maxOutputTokens, 64_000)
        XCTAssertEqual(byID["claude-haiku-4-5-20251001"]?.efforts, [])
        let sonnet45 = try XCTUnwrap(byID["claude-sonnet-4-5-20250929"])
        XCTAssertTrue(sonnet45.isDeprecated)
        XCTAssertEqual(sonnet45.retiresOn, "2026-11-30")
        XCTAssertFalse(sonnet45.isRetired(at: date("2026-11-23T12:00:00Z")))
        XCTAssertTrue(sonnet45.isRetired(at: date("2026-11-30T17:00:00Z")))
    }

    func testModelWithoutCapabilities() throws {
        let json = #"{"data":[{"id":"claude-opus-6","created_at":"2027-01-01T00:00:00Z"}],"has_more":false}"#
        let model = try XCTUnwrap(ModelCatalog.parsePage(Data(json.utf8)).models.first)
        // Fara `capabilities.effort` nu trimitem efort (un nivel neacceptat ar da 400).
        XCTAssertEqual(model.efforts, [])
        XCTAssertTrue(model.structuredOutputs)
        XCTAssertEqual(model.line, "opus")
        XCTAssertEqual(model.displayName, "Claude Opus 6")
        XCTAssertEqual(model.lifecycle, "active")
    }

    func testModelsWithoutStructuredOutputsAreHidden() throws {
        let json = #"{"data":[{"id":"claude-opus-9","created_at":"2028-01-01T00:00:00Z","line":"opus","capabilities":{"structured_outputs":{"supported":false}}}],"has_more":false}"#
        let extra = try ModelCatalog.parsePage(Data(json.utf8)).models
        let list = try sampleModels() + extra
        XCTAssertFalse(extra[0].structuredOutputs)
        XCTAssertFalse(ModelCatalog.grouped(list).flatMap(\.models).contains { $0.id == "claude-opus-9" })
        XCTAssertEqual(ModelCatalog.resolve("latest:opus", in: list), "claude-opus-5-5")
    }

    func testResolve() throws {
        let list = try sampleModels()
        let now = date("2026-11-23T12:00:00Z")
        XCTAssertEqual(ModelCatalog.resolve("latest:opus", in: list, now: now), "claude-opus-5-5")
        XCTAssertEqual(ModelCatalog.resolve("latest:fable", in: list, now: now), "claude-fable-5-2")
        // Cel mai nou activ: Sonnet 4.5 e depreciat, deci Sonnet 4.6.
        XCTAssertEqual(ModelCatalog.resolve("latest:sonnet", in: list, now: now), "claude-sonnet-4-6")
        XCTAssertEqual(ModelCatalog.resolve("latest:sonnet", in: list.filter { $0.id != "claude-sonnet-4-6" }, now: now),
                       "claude-sonnet-4-5-20250929")
        XCTAssertEqual(ModelCatalog.resolve("claude-opus-4-5-20251101", in: list, now: now), "claude-opus-4-5-20251101")
        // Alias fara data pentru un model listat cu data: ramane alias-ul (API-ul il accepta).
        XCTAssertEqual(ModelCatalog.resolve("claude-opus-4-5", in: list, now: now), "claude-opus-4-5")
        // Depreciat, dar inca servit: ramane cel ales.
        XCTAssertEqual(ModelCatalog.resolve("claude-sonnet-4-5-20250929", in: list, now: now), "claude-sonnet-4-5-20250929")
        // Dupa data retragerii (lista din cache inca il are): cel mai nou Sonnet.
        XCTAssertEqual(ModelCatalog.resolve("claude-sonnet-4-5-20250929", in: list, now: date("2026-12-01T00:00:00Z")),
                       "claude-sonnet-4-6")
        // Scos din API: cel mai nou din aceeasi familie; familie disparuta: cel mai nou Opus.
        XCTAssertEqual(ModelCatalog.resolve("claude-haiku-3-5", in: list, now: now), "claude-haiku-4-5-20251001")
        XCTAssertEqual(ModelCatalog.resolve("claude-mythos-5-2", in: list, now: now), "claude-opus-5-5")
        // Lista inca neincarcata: ID-ul ales, sau ultimul model cunoscut al familiei.
        XCTAssertEqual(ModelCatalog.resolve("claude-sonnet-5-5", in: [], now: now), "claude-sonnet-5-5")
        XCTAssertEqual(ModelCatalog.resolve("latest:haiku", in: [], now: now), "claude-haiku-5-5")
        XCTAssertEqual(ModelCatalog.resolve("", in: [], now: now), "claude-opus-5-5")
    }

    func testEffortMapping() throws {
        let list = try sampleModels()
        let opus45 = ModelCatalog.info("claude-opus-4-5", in: list)
        XCTAssertEqual(opus45?.id, "claude-opus-4-5-20251101")
        XCTAssertEqual(ModelCatalog.effort(.max, for: opus45), .high)
        XCTAssertEqual(ModelCatalog.effort(.low, for: opus45), .low)
        let sonnet46 = ModelCatalog.info("claude-sonnet-4-6", in: list)
        XCTAssertEqual(ModelCatalog.effort(.xhigh, for: sonnet46), .high)
        XCTAssertEqual(ModelCatalog.effort(.max, for: sonnet46), .max)
        XCTAssertNil(ModelCatalog.effort(.low, for: ModelCatalog.info("claude-haiku-4-5", in: list)))
        // Model necunoscut (lista neincarcata): nivelul ales.
        XCTAssertEqual(ModelCatalog.effort(.xhigh, for: nil), .xhigh)
        // Doar niveluri mai mari decat cel ales: cel mai mic dintre ele.
        XCTAssertEqual(ModelCatalog.effort(.low, for: ClaudeModelInfo(id: "claude-test-1", efforts: [.high, .max])), .high)
    }

    func testGroupedForSettings() throws {
        let groups = ModelCatalog.grouped(try sampleModels())
        XCTAssertEqual(groups.map(\.line), ["opus", "sonnet", "haiku", "fable"])
        XCTAssertEqual(groups[0].models.map(\.id), ["claude-opus-5-5", "claude-opus-4-5-20251101"])
        XCTAssertEqual(groups[1].models.map(\.id), ["claude-sonnet-4-6", "claude-sonnet-4-5-20250929"])
        // Familie noua, necunoscuta: la final.
        let extra = ClaudeModelInfo(id: "claude-zeta-1", createdAt: "2027-01-01T00:00:00Z")
        XCTAssertEqual(ModelCatalog.grouped(try sampleModels() + [extra]).last?.line, "zeta")
    }

    func testOnlyPricedModelsAreListed() throws {
        let prices = try PriceList.decode(Data(#"{"format":1,"models":[{"id":"claude-opus-5-5","input":4,"output":20},{"id":"claude-haiku-4-5","input":1,"output":5}]}"#.utf8))
        let shown = ModelCatalog.priced(try sampleModels(), in: prices)
        XCTAssertEqual(shown.map(\.id), ["claude-opus-5-5", "claude-haiku-4-5-20251001"])
        XCTAssertEqual(ModelCatalog.resolve("latest:sonnet", in: shown), "claude-sonnet-5-5")
        XCTAssertEqual(ModelCatalog.resolve("claude-opus-4-5-20251101", in: shown), "claude-opus-5-5")
        // Copia din aplicatie acopera toate modelele din raspunsul real /v1/models.
        XCTAssertEqual(ModelCatalog.priced(try sampleModels(), in: .bundled).count, 6)
    }

    func testModelNames() {
        XCTAssertEqual(ClaudeModels.displayName(for: "claude-opus-4-5-20251101"), "Claude Opus 4.5")
        XCTAssertEqual(ClaudeModels.displayName(for: "claude-opus-5"), "Claude Opus 5")
        XCTAssertEqual(ClaudeModels.displayName(for: "claude-3-5-sonnet-20241022"), "claude-3-5-sonnet-20241022")
        XCTAssertEqual(ClaudeModels.displayName(for: "gpt-4o"), "gpt-4o")
        XCTAssertEqual(ClaudeModels.baseID("claude-haiku-4-5-20251001"), "claude-haiku-4-5")
        XCTAssertEqual(ClaudeModels.baseID("claude-opus-5-5"), "claude-opus-5-5")
        XCTAssertEqual(ClaudeModels.line(of: "claude-sonnet-4-5-20250929"), "sonnet")
        XCTAssertEqual(ClaudeModels.line(of: "claude-3-5-sonnet-20241022"), "")
        XCTAssertEqual(ClaudeModels.selectionTitle("latest:opus"), "Latest Opus")
        XCTAssertEqual(ClaudeModels.selectionTitle("claude-opus-5-5"), "Claude Opus 5.5")
        XCTAssertEqual(ModelCatalog.displayDate("2026-11-23"), "2026-11-23")
    }

    func testFastModeAndFallbackGates() {
        XCTAssertTrue(ClaudeOptions(model: "claude-opus-5-5", fastMode: true).fastMode)
        XCTAssertTrue(ClaudeOptions(model: "claude-fable-5-2", fastMode: true).fastMode)
        XCTAssertFalse(ClaudeOptions(model: "claude-opus-5-5", fastMode: false).fastMode)
        XCTAssertFalse(ClaudeOptions(model: "claude-haiku-5-5", fastMode: true).fastMode)
        // Opus 4.8: fast mode doar ca previzualizare, cu acces cerut separat.
        XCTAssertFalse(ClaudeOptions(model: "claude-opus-4-8", fastMode: true).fastMode)
        XCTAssertFalse(ClaudeOptions(model: "claude-opus-5-5", fastMode: true, rejectedFeatures: ["speed"]).fastMode)
        // Model fara pret in lista: fara fast mode si fara fallback.
        XCTAssertFalse(ClaudeOptions(model: "claude-opus-6", fastMode: true).fastMode)
        XCTAssertFalse(ClaudeOptions(model: "claude-opus-6").serverSideFallback)
        // ... pana apare in lista de preturi.
        let prices = PriceList(models: [.init(id: "claude-opus-6", input: 4, output: 20, fast: true, fallbacks: true)])
        XCTAssertTrue(ClaudeOptions(model: "claude-opus-6", fastMode: true, prices: prices).fastMode)
        XCTAssertTrue(ClaudeOptions(model: "claude-opus-6", prices: prices).serverSideFallback)
        XCTAssertFalse(ClaudeOptions(model: "claude-opus-6", rejectedFeatures: ["fallbacks"], prices: prices).serverSideFallback)
        XCTAssertTrue(ClaudeOptions(model: "claude-sonnet-5-5").serverSideFallback)
        XCTAssertFalse(ClaudeOptions(model: "claude-haiku-5-5").serverSideFallback)
        XCTAssertFalse(ClaudeOptions(model: "claude-haiku-4-5-20251001").serverSideFallback)
    }

    func testRequestWithoutEffortAndCappedTokens() throws {
        let options = ClaudeOptions(model: "claude-haiku-4-5-20251001", effort: nil, fastMode: true, maxOutputTokens: 3_000)
        let transcript = String(repeating: "a", count: 2_000)
        let (body, betas) = ClaudeCorrector.buildRequest(transcript: transcript, context: nil, config: CorrectionConfig(),
                                                         options: options, useFastMode: true)
        // 2048 + 2 x 2000 = 6048, dar modelul are plafonul 3000 (in realitate 64000).
        XCTAssertEqual(body.maxTokens, 3_000)
        XCTAssertNil(body.speed)
        XCTAssertNil(body.fallbacks)
        XCTAssertEqual(betas, [])
        let json = try XCTUnwrap(String(data: try AnthropicClient.encode(body), encoding: .utf8))
        XCTAssertFalse(json.contains("effort"))
        XCTAssertTrue(json.contains("\"output_config\":{\"format\":"))
    }
}

final class ModelLearningTests: XCTestCase {
    private func makeClient() -> AnthropicClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, session: URLSession(configuration: configuration))
    }

    private static let ok = Data(#"{"model":"claude-opus-6","content":[{"type":"text","text":"{\"text\":\"ok\"}"}],"stop_reason":"end_turn"}"#.utf8)

    private static func badRequest(_ message: String) -> Data {
        Data(#"{"type":"error","error":{"type":"invalid_request_error","message":"\#(message)"}}"#.utf8)
    }

    func testRejectedFastModeIsReported() async throws {
        var calls = 0
        MockURLProtocol.handler = { _, body in
            calls += 1
            let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            return json?["speed"] != nil ? (400, Self.badRequest("speed: not supported")) : (200, Self.ok)
        }
        let outcome = try await ClaudeCorrector(client: makeClient()).correct(
            transcript: "ok", context: nil, config: CorrectionConfig(),
            options: ClaudeOptions(model: "claude-opus-5-5", fastMode: true, timeout: 10), apiKey: "k")
        XCTAssertEqual(outcome.text, "ok")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(outcome.rejectedFeatures, ["speed"])
    }

    func testRejectedFallbackIsReported() async throws {
        var calls = 0
        MockURLProtocol.handler = { _, body in
            calls += 1
            let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            return json?["fallbacks"] != nil ? (400, Self.badRequest("fallbacks: not supported")) : (200, Self.ok)
        }
        let outcome = try await ClaudeCorrector(client: makeClient()).correct(
            transcript: "ok", context: nil, config: CorrectionConfig(),
            options: ClaudeOptions(model: "claude-sonnet-5-5", fastMode: true, timeout: 10), apiKey: "k")
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(outcome.rejectedFeatures, ["fallbacks"])
        XCTAssertNil(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-beta"))
    }

    func testKnownModelSendsNoTrialParameters() async throws {
        var calls = 0
        MockURLProtocol.handler = { _, _ in
            calls += 1
            return (200, Self.ok)
        }
        let outcome = try await ClaudeCorrector(client: makeClient()).correct(
            transcript: "ok", context: nil, config: CorrectionConfig(),
            options: ClaudeOptions(model: "claude-haiku-4-5-20251001", effort: nil, fastMode: true, timeout: 10), apiKey: "k")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(outcome.rejectedFeatures, [])
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNil(object["speed"])
        XCTAssertNil(object["fallbacks"])
        XCTAssertNil((object["output_config"] as? [String: Any])?["effort"])
    }

    func testPersistentBadRequestIsThrownWithoutLearning() async throws {
        var calls = 0
        MockURLProtocol.handler = { _, _ in
            calls += 1
            return (400, Self.badRequest("prompt is too long"))
        }
        do {
            _ = try await ClaudeCorrector(client: makeClient()).correct(
                transcript: "ok", context: nil, config: CorrectionConfig(),
                options: ClaudeOptions(model: "claude-opus-5-5", fastMode: true, timeout: 10), apiKey: "k")
            XCTFail("trebuia sa arunce")
        } catch let error as AnthropicError {
            XCTAssertEqual(error, .http(status: 400, type: "invalid_request_error", message: "prompt is too long"))
        }
        // Cu fast, fara fast, fara fallback: apoi renuntam.
        XCTAssertEqual(calls, 3)
    }

    func testListModelsFollowsPages() async throws {
        var urls: [String] = []
        MockURLProtocol.handler = { request, _ in
            urls.append(request.url?.absoluteString ?? "")
            if request.url?.query?.contains("after_id=") == true {
                return (200, Data(#"{"data":[{"id":"claude-haiku-5-5","display_name":"Claude Haiku 5.5","created_at":"2026-10-07T18:00:00Z","line":"haiku","capabilities":{"effort":{"supported":true,"low":{"supported":true}}}}],"has_more":false,"last_id":"claude-haiku-5-5"}"#.utf8))
            }
            return (200, Data(#"{"data":[{"id":"claude-opus-5-5","display_name":"Claude Opus 5.5","created_at":"2026-09-21T16:24:00Z","line":"opus"}],"has_more":true,"first_id":"claude-opus-5-5","last_id":"claude-opus-5-5"}"#.utf8))
        }
        let models = try await makeClient().listModels(apiKey: "k")
        XCTAssertEqual(models.map(\.id), ["claude-opus-5-5", "claude-haiku-5-5"])
        XCTAssertEqual(models.last?.efforts, [.low])
        XCTAssertEqual(urls, ["https://api.anthropic.com/v1/models?limit=1000",
                              "https://api.anthropic.com/v1/models?limit=1000&after_id=claude-opus-5-5"])
        XCTAssertEqual(MockURLProtocol.lastRequest?.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(MockURLProtocol.lastRequest?.httpMethod, "GET")
    }

    func testListModelsReportsHTTPErrors() async throws {
        MockURLProtocol.handler = { _, _ in
            (401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        do {
            _ = try await makeClient().listModels(apiKey: "bad")
            XCTFail("trebuia sa arunce")
        } catch let error as AnthropicError {
            XCTAssertEqual(error.errorDescription, "Invalid API key (401).")
        }
    }
}

final class PriceListTests: XCTestCase {
    func testBundledCopy() {
        let list = PriceList.bundled
        XCTAssertEqual(list.format, 1)
        XCTAssertEqual(list.updated, "2026-11-23")
        XCTAssertEqual(list.models.count, 18)
        XCTAssertEqual(list.entry(for: "claude-opus-5-5")?.supportsFastMode, true)
        XCTAssertEqual(list.entry(for: "claude-fable-5-2")?.supportsFastMode, true)
        XCTAssertEqual(list.entry(for: "claude-opus-4-8")?.supportsFastMode, false)
        XCTAssertEqual(list.entry(for: "claude-sonnet-5-5")?.supportsServerSideFallback, true)
        XCTAssertEqual(list.entry(for: "claude-haiku-5-5")?.supportsServerSideFallback, false)
        // Fast mode: dublu, cu multiplicatorii de cache peste ($8 / $40 pe Opus 5.5).
        XCTAssertEqual(list.pricing(for: "claude-opus-5-5", fast: true), ModelPricing(input: 8, cacheWrite5m: 10, cacheRead: 0.4, output: 40))
        // Haiku 5.5: alt pret peste 100.000 de tokeni de prompt.
        XCTAssertEqual(list.pricing(for: "claude-haiku-5-5", promptTokens: 100_000)?.input, 0.10)
        XCTAssertEqual(list.pricing(for: "claude-haiku-5-5", promptTokens: 100_001)?.output, 2.50)
    }

    func testDefaultsForMissingFields() throws {
        let list = try PriceList.decode(Data(#"""
        {"format":1,"updated":"2026-12-01","note":"campurile necunoscute se ignora",
         "models":[{"id":"claude-opus-6","input":4,"output":20,"fast":true,"fast_multiplier":3,
                    "long_prompt":{"above":200000,"input":8,"output":40}}]}
        """#.utf8))
        let entry = try XCTUnwrap(list.entry(for: "claude-opus-6-20270101"))
        XCTAssertEqual(entry.pricing(promptTokens: 0, fast: false), ModelPricing(input: 4, cacheWrite5m: 5, cacheRead: 0.4, output: 20))
        XCTAssertEqual(entry.pricing(promptTokens: 0, fast: true).output, 60)
        XCTAssertEqual(entry.pricing(promptTokens: 300_000, fast: false), ModelPricing(input: 8, cacheWrite5m: 10, cacheRead: 0.8, output: 40))
        XCTAssertFalse(entry.supportsServerSideFallback)
        XCTAssertEqual(list.label(for: "claude-opus-6"), "$4 / $20")
        XCTAssertNil(list.entry(for: "claude-opus-6-5"))
    }

    func testInvalidListsAreRejected() {
        func check(_ json: String, _ expected: PriceList.ValidationError, line: UInt = #line) {
            XCTAssertThrowsError(try PriceList.decode(Data(json.utf8)), line: line) { error in
                XCTAssertEqual(error as? PriceList.ValidationError, expected, line: line)
            }
        }
        check(#"{"format":2,"models":[{"id":"claude-opus-6","input":4,"output":20}]}"#, .format(2))
        check(#"{"format":1,"models":[]}"#, .empty)
        check(#"{"format":1,"models":[{"id":"claude-opus-6","input":0,"output":20}]}"#, .invalid("claude-opus-6"))
        check(#"{"format":1,"models":[{"id":"claude-opus-6","input":4,"output":20,"cache_read":-1}]}"#, .invalid("claude-opus-6"))
        check(#"{"format":1,"models":[{"id":"gpt-5","input":4,"output":20}]}"#, .invalid("gpt-5"))
        check(#"{"format":1,"models":[{"id":"claude-opus-6","input":4,"output":20},{"id":"claude-opus-6","input":5,"output":25}]}"#,
              .invalid("claude-opus-6"))
        check(#"{"format":1,"models":[{"id":"claude-opus-6","input":4,"output":20,"fast_multiplier":0.5}]}"#, .invalid("claude-opus-6"))
        XCTAssertThrowsError(try PriceList.decode(Data("<html>404</html>".utf8)))
    }

    func testModifiedFromServer() throws {
        let list = try PriceList.decode(Data(#"{"format":1,"updated":"2026-11-23","modified":"2026-11-24 10:15:00","models":[{"id":"claude-opus-5-5","input":4,"output":20}]}"#.utf8))
        XCTAssertEqual(list.modified, "2026-11-24 10:15:00")
        XCTAssertEqual(list.stamp, "2026-11-24 10:15:00")
        XCTAssertNil(PriceList.bundled.modified)
        XCTAssertEqual(PriceList.bundled.stamp, "2026-11-23")
        // Salvata pe server in aceeasi zi cu copia din aplicatie: lista de pe server castiga.
        XCTAssertGreaterThanOrEqual(PriceList(updated: "2026-11-23", modified: "2026-11-23 09:00:00", models: []).stamp,
                                    PriceList.bundled.stamp)
        XCTAssertEqual(ModelCatalog.displayDateTime(list.stamp), "2026-11-24 10:15")
        XCTAssertEqual(ModelCatalog.displayDateTime("2026-11-23"), "2026-11-23")
        XCTAssertNil(ModelCatalog.displayDateTime(""))
    }

    func testCostUsesGivenPrices() {
        let prices = PriceList(models: [.init(id: "claude-opus-5-5", input: 1, output: 2, cacheWrite: 0, cacheRead: 0)])
        let usage = CorrectionUsage(model: "claude-opus-5-5", inputTokens: 1_000_000, outputTokens: 1_000_000,
                                    cacheReadTokens: 0, cacheWriteTokens: 0, fastMode: false, prices: prices)
        XCTAssertEqual(usage.costUSD ?? 0, 3, accuracy: 1e-12)
        XCTAssertNil(CorrectionUsage(model: "claude-sonnet-5-5", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                     cacheWriteTokens: 0, fastMode: false, prices: prices).costUSD)
    }
}
