import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import HauDiCore

final class HotkeyTests: XCTestCase {
    func testPressedKeysFromFlags() {
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x0080_0100), [.function])
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x0008_0000 | 0x40), [.rightOption])
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x0010_0000 | 0x08 | 0x0008_0000 | 0x20), [.leftCommand, .leftOption])
        // Family bit without a side bit: we infer the side from the event's keyCode.
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x0008_0000, changedKeyCode: 61), [.rightOption])
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x0004_0000), [.leftControl])
        // A side bit left without an active family -> ignored.
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x40), [])
        XCTAssertEqual(ModifierKey.pressedKeys(flags: 0x100), [])
    }

    func testPushToTalk() {
        var sm = HotkeyStateMachine(hotkey: .fn)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 0), [.pressBegan])
        XCTAssertEqual(sm.modifiersChanged([], at: 1.2), [.pressEnded])
        XCTAssertEqual(sm.state, .idle)
    }

    func testDoubleTapHandsFree() {
        var sm = HotkeyStateMachine(hotkey: .fn)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 0), [.pressBegan])
        XCTAssertEqual(sm.modifiersChanged([], at: 0.1), [.tapped])
        XCTAssertEqual(sm.modifiersChanged([.function], at: 0.3), [.handsFreeStarted])
        XCTAssertEqual(sm.modifiersChanged([], at: 0.4), [])
        XCTAssertEqual(sm.state, .handsFree)
        XCTAssertEqual(sm.keyDown(at: 1.0), [])
        XCTAssertEqual(sm.modifiersChanged([.function], at: 3.0), [.handsFreeStopRequested])
        XCTAssertEqual(sm.modifiersChanged([], at: 3.1), [])
        XCTAssertEqual(sm.state, .idle)
    }

    func testSecondTapAfterWindowStartsNormalPress() {
        var sm = HotkeyStateMachine(hotkey: .fn)
        _ = sm.modifiersChanged([.function], at: 0)
        XCTAssertEqual(sm.modifiersChanged([], at: 0.1), [.tapped])
        XCTAssertEqual(sm.modifiersChanged([.function], at: 1.0), [.pressBegan])
    }

    func testHandsFreeDisabled() {
        var sm = HotkeyStateMachine(hotkey: .fn, handsFreeEnabled: false)
        _ = sm.modifiersChanged([.function], at: 0)
        XCTAssertEqual(sm.modifiersChanged([], at: 0.1), [.tapped])
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 0.2), [.pressBegan])
    }

    func testAbortOnKeyDown() {
        var sm = HotkeyStateMachine(hotkey: .fn)
        _ = sm.modifiersChanged([.function], at: 0)
        XCTAssertEqual(sm.keyDown(at: 0.2), [.pressAborted])
        XCTAssertEqual(sm.modifiersChanged([], at: 0.5), [])
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 1.0), [.pressBegan])
    }

    func testLongHoldIgnoresOtherKeys() {
        // After 1.5 s of dictation, an extra key or modifier (e.g. to stop the screensaver) no longer cancels it.
        var sm = HotkeyStateMachine(hotkey: .fn)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 0), [.pressBegan])
        XCTAssertEqual(sm.keyDown(at: 1.4), [.pressAborted])
        _ = sm.modifiersChanged([], at: 1.6)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 2), [.pressBegan])
        XCTAssertEqual(sm.keyDown(at: 70), [])
        XCTAssertEqual(sm.modifiersChanged([.function, .leftShift], at: 71), [])
        XCTAssertEqual(sm.modifiersChanged([.function], at: 72), [])
        XCTAssertEqual(sm.modifiersChanged([], at: 80), [.pressEnded])
        XCTAssertEqual(sm.state, .idle)
    }

    func testAbortOnExtraModifier() {
        var sm = HotkeyStateMachine(hotkey: .controlOption)
        XCTAssertEqual(sm.modifiersChanged([.leftControl, .leftOption], at: 0), [.pressBegan])
        XCTAssertEqual(sm.modifiersChanged([.leftControl, .leftOption, .leftCommand], at: 0.5), [.pressAborted])
        XCTAssertEqual(sm.modifiersChanged([.leftControl], at: 0.6), [])
        XCTAssertEqual(sm.modifiersChanged([], at: 0.7), [])
        XCTAssertEqual(sm.state, .idle)
    }

    func testSideAgnosticAndSideSpecific() {
        var agnostic = HotkeyStateMachine(hotkey: .controlOption)
        XCTAssertEqual(agnostic.modifiersChanged([.rightControl, .leftOption], at: 0), [.pressBegan])

        var specific = HotkeyStateMachine(hotkey: .rightOption)
        XCTAssertEqual(specific.modifiersChanged([.leftOption], at: 0), [])
        XCTAssertEqual(specific.modifiersChanged([], at: 0.1), [])
        XCTAssertEqual(specific.modifiersChanged([.rightOption], at: 0.2), [.pressBegan])
    }

    func testPartialReleaseOfChord() {
        var sm = HotkeyStateMachine(hotkey: .controlOption)
        _ = sm.modifiersChanged([.leftControl, .leftOption], at: 0)
        XCTAssertEqual(sm.modifiersChanged([.leftOption], at: 1.0), [.pressEnded])
        XCTAssertEqual(sm.state, .waitingForRelease)
        XCTAssertEqual(sm.modifiersChanged([.leftControl, .leftOption], at: 1.2), [])
        XCTAssertEqual(sm.modifiersChanged([], at: 1.4), [])
        XCTAssertEqual(sm.state, .idle)
    }

    func testOtherModifierHeldDoesNotTrigger() {
        var sm = HotkeyStateMachine(hotkey: .fn)
        XCTAssertEqual(sm.modifiersChanged([.leftShift], at: 0), [])
        XCTAssertEqual(sm.modifiersChanged([.leftShift, .function], at: 0.1), [])
        XCTAssertEqual(sm.state, .idle)
    }

    func testResetDuringHandsFree() {
        var sm = HotkeyStateMachine(hotkey: .fn)
        _ = sm.modifiersChanged([.function], at: 0)
        _ = sm.modifiersChanged([], at: 0.1)
        _ = sm.modifiersChanged([.function], at: 0.2)
        _ = sm.modifiersChanged([], at: 0.3)
        XCTAssertEqual(sm.state, .handsFree)
        sm.reset()
        XCTAssertEqual(sm.state, .idle)
        XCTAssertEqual(sm.modifiersChanged([.function], at: 2), [.pressBegan])
    }

    func testRecordingAndDisplay() {
        XCTAssertFalse(Hotkey.fromRecording([.leftControl, .leftOption]).sideSpecific)
        XCTAssertTrue(Hotkey.fromRecording([.rightOption]).sideSpecific)
        XCTAssertTrue(Hotkey.fromRecording([.function]).sideSpecific)

        var capture = HotkeyCapture()
        XCTAssertNil(capture.update([.leftControl]))
        XCTAssertNil(capture.update([.leftControl, .leftOption]))
        XCTAssertNil(capture.update([.leftOption]))
        XCTAssertEqual(capture.update([]), Hotkey(keys: [.leftControl, .leftOption], sideSpecific: false))
        XCTAssertNil(capture.update([]))

        XCTAssertEqual(Hotkey.fn.displayString, "fn")
        XCTAssertEqual(Hotkey.rightOption.displayString, "Right ⌥")
        XCTAssertEqual(Hotkey.controlOption.displayString, "⌃⌥")
        XCTAssertEqual(Hotkey(keys: [.function, .leftControl], sideSpecific: false).displayString, "fn⌃")
        XCTAssertTrue(Hotkey(keys: [.leftCommand], sideSpecific: false).isRiskySingleModifier)
        XCTAssertFalse(Hotkey.rightOption.isRiskySingleModifier)
        XCTAssertFalse(Hotkey.fn.isRiskySingleModifier)
    }

    func testHotkeyCodable() throws {
        let data = try JSONEncoder().encode(Hotkey.controlOption)
        XCTAssertEqual(try JSONDecoder().decode(Hotkey.self, from: data), Hotkey.controlOption)
    }
}

final class TextProcessingTests: XCTestCase {
    func testCleaner() {
        XCTAssertEqual(TranscriptCleaner.clean("[BLANK_AUDIO]"), "")
        XCTAssertEqual(TranscriptCleaner.clean("  Salut   ce faci?  "), "Salut ce faci?")
        XCTAssertEqual(TranscriptCleaner.clean("(muzică) Bună ziua"), "Bună ziua")
        XCTAssertEqual(TranscriptCleaner.clean("Mulțumim pentru vizionare!"), "")
        XCTAssertEqual(TranscriptCleaner.clean("Thanks for watching."), "")
        XCTAssertEqual(TranscriptCleaner.clean("Mulțumesc."), "Mulțumesc.")
        XCTAssertEqual(TranscriptCleaner.clean("Linia unu\n  linia doi"), "Linia unu\nlinia doi")
        XCTAssertEqual(TranscriptCleaner.clean("Am trimis [anexa] ieri"), "Am trimis [anexa] ieri")
    }

    func testNormalized() {
        XCTAssertEqual(TranscriptCleaner.normalized("Știți, ĂȘTIA!"), "stiti astia")
    }

    func testSmartSpacing() {
        XCTAssertEqual(SmartSpacing.adjust("lume", precedingText: "Salut"), " lume")
        XCTAssertEqual(SmartSpacing.adjust("lume", precedingText: "Salut "), "lume")
        XCTAssertEqual(SmartSpacing.adjust(", ok", precedingText: "Da"), ", ok")
        XCTAssertEqual(SmartSpacing.adjust("text", precedingText: nil), "text")
        XCTAssertEqual(SmartSpacing.adjust("text", precedingText: "("), "text")
        XCTAssertEqual(SmartSpacing.adjust("Apoi", precedingText: "Gata."), " Apoi")
        XCTAssertEqual(SmartSpacing.adjust("rand", precedingText: "linie\n"), "rand")
    }

    func testAudioAnalysis() {
        XCTAssertFalse(AudioAnalysis.containsSpeech([Float](repeating: 0, count: 16_000)))
        let tone = (0..<16_000).map { Float(sin(Double($0) * 0.05) * 0.1) }
        XCTAssertTrue(AudioAnalysis.containsSpeech(tone))
        XCTAssertEqual(AudioAnalysis.padded([Float](repeating: 0.1, count: 100), trailingSilence: 0.25, minimumDuration: 1.0).count, 16_000)
        XCTAssertEqual(AudioAnalysis.padded([Float](repeating: 0.1, count: 32_000), trailingSilence: 0.25, minimumDuration: 1.0).count, 36_000)
    }
}

final class CorrectionTests: XCTestCase {
    let config = CorrectionConfig(
        level: .standard,
        dictionary: ["hau-di", "  ", "Kubernetes"],
        snippets: [Snippet(trigger: "semnatura mea", expansion: "Cu bine,\nAna"), Snippet(trigger: "", expansion: "x")],
        customInstructions: "Foloseste virgula Oxford."
    )

    func testSystemPrompt() {
        let prompt = CorrectionPrompt.systemPrompt(config: config)
        XCTAssertTrue(prompt.contains("- hau-di\n- Kubernetes"))
        XCTAssertTrue(prompt.contains("\"semnatura mea\" → \"Cu bine,\nAna\""))
        XCTAssertFalse(prompt.contains("→ \"x\""))
        XCTAssertTrue(prompt.contains("Foloseste virgula Oxford."))
        XCTAssertTrue(prompt.contains("level: STANDARD"))
        XCTAssertTrue(prompt.contains("Use \"\\n\" for line breaks"))
        XCTAssertTrue(prompt.contains("never the cedilla forms"))
        let minimal = CorrectionPrompt.systemPrompt(config: CorrectionConfig(level: .minimal))
        XCTAssertTrue(minimal.contains("level: MINIMAL"))
        XCTAssertFalse(minimal.contains("User dictionary"))
        XCTAssertFalse(minimal.contains("Voice snippets"))
    }

    func testDiacriticsSetting() {
        let with = CorrectionPrompt.systemPrompt(config: CorrectionConfig())
        XCTAssertTrue(with.contains("must use correct diacritics"))
        XCTAssertFalse(with.contains("WITHOUT diacritics"))
        let without = CorrectionPrompt.systemPrompt(config: CorrectionConfig(useDiacritics: false))
        XCTAssertTrue(without.contains("The user writes WITHOUT diacritics"))
        XCTAssertFalse(without.contains("must use correct diacritics"))
        XCTAssertTrue(without.contains("## Language\n- The user dictates in Romanian"))
        XCTAssertTrue(without.contains("## Text correction"))
        XCTAssertFalse(without.contains("\n\n\n"))
    }

    func testStripDiacritics() {
        XCTAssertEqual(Diacritics.strip("Știința și țara: ăâî ĂÂÎ ȘȚ ş ţ Ş Ţ"), "Stiinta si tara: aai AAI ST s t S T")
        XCTAssertEqual(Diacritics.strip("café, naïve, Ærø, straße"), "cafe, naive, Ærø, straße")
        XCTAssertEqual(Diacritics.strip("❤️ 👍🏽 ok"), "❤️ 👍🏽 ok")
        XCTAssertEqual(Diacritics.strip("fara diacritice"), "fara diacritice")
    }

    func testUserMessage() {
        let context = CorrectionContext(appName: "Slack", bundleID: "com.tinyspeck.slackmacgap", windowTitle: "general",
                                        textBeforeCursor: String(repeating: "a", count: 1000) + "END",
                                        date: Date(timeIntervalSince1970: 1_795_000_000))
        let message = CorrectionPrompt.userMessage(transcript: "salut ce faci", context: context)
        XCTAssertTrue(message.contains("Active app: Slack (com.tinyspeck.slackmacgap)"))
        XCTAssertTrue(message.contains("Window title: general"))
        XCTAssertFalse(message.contains("language"))
        XCTAssertTrue(message.contains("<transcript>\nsalut ce faci\n</transcript>"))
        XCTAssertTrue(message.contains("aEND"))
        XCTAssertFalse(message.contains(String(repeating: "a", count: 401)))
        XCTAssertTrue(message.hasPrefix("<context>\nDate: "))
        XCTAssertEqual(CorrectionPrompt.userMessage(transcript: "x", context: nil), "<transcript>\nx\n</transcript>")
    }

    func testBuildRequestOpus() throws {
        let options = ClaudeOptions(model: "claude-opus-5-5", effort: .low, fastMode: true, timeout: 10)
        let (body, betas) = ClaudeCorrector.buildRequest(transcript: "salut", context: nil, config: config, options: options, useFastMode: true)
        XCTAssertEqual(body.model, "claude-opus-5-5")
        XCTAssertEqual(body.fallbacks, "default")
        XCTAssertEqual(body.speed, "fast")
        XCTAssertEqual(betas, ["server-side-fallback-2026-07-01"])

        let json = try XCTUnwrap(String(data: try AnthropicClient.encode(body), encoding: .utf8))
        XCTAssertTrue(json.contains("\"max_tokens\":2058"))
        XCTAssertTrue(json.contains("\"output_config\":{\"effort\":\"low\",\"format\":{\"schema\":"))
        XCTAssertTrue(json.contains("\"type\":\"json_schema\""))
        XCTAssertTrue(json.contains("\"additionalProperties\":false"))
        XCTAssertTrue(json.contains("\"cache_control\":{\"type\":\"ephemeral\"}"))
        XCTAssertTrue(json.contains("\"fallbacks\":\"default\""))
        XCTAssertFalse(json.contains("temperature"))
        XCTAssertFalse(json.contains("thinking"))
    }

    func testBuildRequestHaiku() throws {
        let options = ClaudeOptions(model: "claude-haiku-5-5", effort: .low, fastMode: true, timeout: 10)
        let (body, betas) = ClaudeCorrector.buildRequest(transcript: "salut", context: nil, config: config, options: options, useFastMode: true)
        XCTAssertNil(body.fallbacks)
        XCTAssertNil(body.speed)
        XCTAssertEqual(betas, [])
        let json = try XCTUnwrap(String(data: try AnthropicClient.encode(body), encoding: .utf8))
        XCTAssertFalse(json.contains("fallbacks"))
        XCTAssertFalse(json.contains("speed"))
    }

    func testParseResponse() throws {
        let payload = """
        {"id":"msg_1","type":"message","role":"assistant","model":"claude-opus-5-5",
         "content":[{"type":"thinking","thinking":"","signature":"abc"},{"type":"text","text":"{\\"text\\": \\"Salut, ce faci?\\"}"}],
         "stop_reason":"end_turn","usage":{"input_tokens":1200,"output_tokens":20,"cache_read_input_tokens":1100}}
        """
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(try ClaudeCorrector.parse(response, transcript: "salut ce faci"), "Salut, ce faci?")
        XCTAssertEqual(response.usage?.cacheReadInputTokens, 1100)
    }

    func testParseFallbackBlocks() throws {
        let payload = """
        {"model":"claude-opus-4-8","content":[{"type":"fallback","from":{"model":"claude-opus-5-5"},"to":{"model":"claude-opus-4-8"}},
         {"type":"text","text":"{\\"text\\":\\"ok\\"}"}],"stop_reason":"end_turn"}
        """
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(payload.utf8))
        XCTAssertEqual(try ClaudeCorrector.parse(response, transcript: "ok"), "ok")
    }

    func testParseErrors() throws {
        func response(_ text: String, stop: String = "end_turn") throws -> MessagesResponse {
            let escaped = text.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            let json = "{\"content\":[{\"type\":\"text\",\"text\":\"\(escaped)\"}],\"stop_reason\":\"\(stop)\"}"
            return try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        }
        XCTAssertThrowsError(try ClaudeCorrector.parse(try response("{\"text\":\"x\"}", stop: "refusal"), transcript: "x")) {
            XCTAssertEqual($0 as? AnthropicError, .refused)
        }
        XCTAssertThrowsError(try ClaudeCorrector.parse(try response("{\"text\":\"x", stop: "max_tokens"), transcript: "x")) {
            XCTAssertEqual($0 as? AnthropicError, .truncated)
        }
        XCTAssertThrowsError(try ClaudeCorrector.parse(try response("Iata textul corectat"), transcript: "x"))
        let long = String(repeating: "raspuns ", count: 100)
        XCTAssertThrowsError(try ClaudeCorrector.parse(try response("{\"text\":\"\(long)\"}"), transcript: "ce e un api"))
        XCTAssertEqual(try ClaudeCorrector.parse(try response("{\"text\":\"\"}"), transcript: "ăăă"), "")
    }
}

// MARK: - Client with a mock URLProtocol (no network)

final class MockURLProtocol: URLProtocol {
    nonisolated(unsafe) static var handler: ((URLRequest, Data?) -> (Int, Data))?
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        var body = request.httpBody
        if body == nil, let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                if read <= 0 { break }
                data.append(buffer, count: read)
            }
            stream.close()
            body = data
        }
        Self.lastRequest = request
        Self.lastBody = body
        let (status, data) = Self.handler?(request, body) ?? (500, Data())
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["content-type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class ClientTests: XCTestCase {
    func makeCorrector() -> ClaudeCorrector {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let session = URLSession(configuration: configuration)
        return ClaudeCorrector(client: AnthropicClient(baseURL: URL(string: "https://api.anthropic.com")!, session: session))
    }

    func testRoundTrip() async throws {
        MockURLProtocol.handler = { _, _ in
            (200, Data(#"{"model":"claude-opus-5-5","content":[{"type":"text","text":"{\"text\":\"Bună ziua!\"}"}],"stop_reason":"end_turn","usage":{"input_tokens":10,"output_tokens":5}}"#.utf8))
        }
        let outcome = try await makeCorrector().correct(
            transcript: "buna ziua", context: CorrectionContext(appName: "Notes"), config: CorrectionConfig(),
            options: ClaudeOptions(model: "claude-opus-5-5", effort: .low, fastMode: false, timeout: 10), apiKey: " sk-test ")
        XCTAssertEqual(outcome.text, "Bună ziua!")
        XCTAssertEqual(outcome.servedBy, "claude-opus-5-5")
        XCTAssertEqual(outcome.usage?.model, "claude-opus-5-5")
        let expected: Double = (10.0 * 4.0 + 5.0 * 20.0) / 1_000_000.0
        XCTAssertEqual(outcome.usage?.costUSD ?? 0, expected, accuracy: 1e-12)

        let request = try XCTUnwrap(MockURLProtocol.lastRequest)
        XCTAssertEqual(request.url?.absoluteString, "https://api.anthropic.com/v1/messages")
        XCTAssertEqual(request.httpMethod, "POST")
        XCTAssertEqual(request.value(forHTTPHeaderField: "x-api-key"), "sk-test")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-version"), "2026-10-21")
        XCTAssertEqual(request.value(forHTTPHeaderField: "anthropic-beta"), "server-side-fallback-2026-07-01")
        let body = try XCTUnwrap(MockURLProtocol.lastBody)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(object["model"] as? String, "claude-opus-5-5")
        XCTAssertNil(object["speed"])
    }

    func testHTTPErrorMapping() async throws {
        MockURLProtocol.handler = { _, _ in
            (401, Data(#"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#.utf8))
        }
        do {
            _ = try await makeCorrector().correct(transcript: "x", context: nil, config: CorrectionConfig(),
                                                  options: ClaudeOptions(), apiKey: "bad")
            XCTFail("should have thrown")
        } catch let error as AnthropicError {
            XCTAssertEqual(error, .http(status: 401, type: "authentication_error", message: "invalid x-api-key"))
            XCTAssertEqual(error.errorDescription, "Invalid API key (401).")
        }
    }

    func testFastModeFallsBackOn429() async throws {
        var calls = 0
        MockURLProtocol.handler = { _, body in
            calls += 1
            let json = (try? JSONSerialization.jsonObject(with: body ?? Data())) as? [String: Any]
            if json?["speed"] as? String == "fast" {
                return (429, Data(#"{"type":"error","error":{"type":"rate_limit_error","message":"slow down"}}"#.utf8))
            }
            return (200, Data(#"{"content":[{"type":"text","text":"{\"text\":\"ok\"}"}],"stop_reason":"end_turn"}"#.utf8))
        }
        let outcome = try await makeCorrector().correct(transcript: "ok", context: nil, config: CorrectionConfig(),
                                                        options: ClaudeOptions(model: "claude-opus-5-5", effort: .low, fastMode: true, timeout: 10),
                                                        apiKey: "k")
        XCTAssertEqual(outcome.text, "ok")
        XCTAssertEqual(calls, 2)
    }

    func testRejectedOutputStillReportsCost() async throws {
        MockURLProtocol.handler = { _, _ in
            (200, Data(#"{"model":"claude-haiku-5-5","content":[{"type":"text","text":"nu e json"}],"stop_reason":"end_turn","usage":{"input_tokens":2000,"output_tokens":40}}"#.utf8))
        }
        do {
            _ = try await makeCorrector().correct(transcript: "x", context: nil, config: CorrectionConfig(),
                                                  options: ClaudeOptions(model: "claude-haiku-5-5"), apiKey: "k")
            XCTFail("should have thrown")
        } catch let error as CorrectionError {
            XCTAssertEqual(error.usage?.model, "claude-haiku-5-5")
            let expected: Double = (2000.0 * 0.10 + 40.0 * 0.50) / 1_000_000.0
            XCTAssertEqual(error.usage?.costUSD ?? 0, expected, accuracy: 1e-12)
            XCTAssertEqual(error.errorDescription, AnthropicError.invalidOutput("JSON does not match the schema").errorDescription)
        }
    }

    func testMissingKey() async {
        do {
            _ = try await makeCorrector().correct(transcript: "x", context: nil, config: CorrectionConfig(), options: ClaudeOptions(), apiKey: "  ")
            XCTFail("should have thrown")
        } catch {
            XCTAssertEqual(error as? AnthropicError, .missingAPIKey)
        }
    }
}

final class HistoryTests: XCTestCase {
    var directory: URL!

    override func setUp() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hau-di-history-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: directory)
    }

    func entry(_ text: String, _ date: Date, cost: Bool = true) -> HistoryEntry {
        let usage = cost ? CorrectionUsage(model: "claude-opus-5-5", inputTokens: 1000, outputTokens: 100,
                                           cacheReadTokens: 1200, cacheWriteTokens: 0, fastMode: false) : nil
        return HistoryEntry(date: date, appName: "App", rawText: "raw " + text, finalText: text, engine: "whisper",
                            correctedBy: cost ? "claude-opus-5-5" : nil, audioDuration: 2, transcriptionTime: 0.3,
                            correctionTime: cost ? 1.2 : nil, note: nil, usage: usage)
    }

    func testAppendReloadNewestFirst() {
        let url = directory.appendingPathComponent("history.jsonl")
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let store = HistoryStore(fileURL: url, now: { now })
        store.append(entry("a", now.addingTimeInterval(-300)))
        store.append(entry("b", now.addingTimeInterval(-200)))
        store.append(entry("c", now.addingTimeInterval(-100)))
        XCTAssertEqual(store.load().map(\.finalText), ["c", "b", "a"])
        let reloaded = HistoryStore(fileURL: url, now: { now }).load()
        XCTAssertEqual(reloaded.map(\.finalText), ["c", "b", "a"])
        XCTAssertEqual(reloaded.first?.usage?.model, "claude-opus-5-5")
        XCTAssertEqual(reloaded.first?.costUSD ?? 0, 0.00624, accuracy: 1e-9)
        let lines = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n") ?? []
        XCTAssertEqual(lines.count, 3)
    }

    func testRetentionThreeMonths() {
        let url = directory.appendingPathComponent("history.jsonl")
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let day: TimeInterval = 86_400
        let writer = HistoryStore(fileURL: url, now: { now.addingTimeInterval(-200 * day) })
        writer.append(entry("vechi", now.addingTimeInterval(-120 * day)))
        writer.append(entry("recent", now.addingTimeInterval(-30 * day)))
        let store = HistoryStore(fileURL: url, now: { now })
        XCTAssertEqual(store.load().map(\.finalText), ["recent"])
        // The file was rewritten without the old entry.
        XCTAssertEqual(HistoryStore(fileURL: url, now: { now }).load().count, 1)
    }

    func testLegacyJSONMigration() throws {
        let url = directory.appendingPathComponent("history.jsonl")
        let legacy = directory.appendingPathComponent("history.json")
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted]
        // An entry in the old format (without the usage field).
        let old = HistoryEntry(date: now.addingTimeInterval(-50), appName: "Notes", rawText: "r", finalText: "vechi",
                               engine: "whisper", correctedBy: nil, audioDuration: 1, transcriptionTime: 0.2,
                               correctionTime: nil, note: nil)
        try encoder.encode([old]).write(to: legacy)
        let store = HistoryStore(fileURL: url, legacyFileURL: legacy, now: { now })
        store.append(entry("nou", now))
        XCTAssertEqual(store.load().map(\.finalText), ["nou", "vechi"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: legacy.path))
        XCTAssertEqual(HistoryStore(fileURL: url, legacyFileURL: legacy, now: { now }).load().map(\.finalText), ["nou", "vechi"])
    }

    func testCorruptLineIgnoredRemoveAndClear() throws {
        let url = directory.appendingPathComponent("history.jsonl")
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let store = HistoryStore(fileURL: url, now: { now })
        let keep = entry("pastrat", now)
        store.append(keep)
        let handle = try FileHandle(forWritingTo: url)
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: Data("{rupt\n".utf8))
        try handle.close()
        let fresh = HistoryStore(fileURL: url, now: { now })
        XCTAssertEqual(fresh.load().map(\.finalText), ["pastrat"])
        fresh.append(entry("al doilea", now.addingTimeInterval(1)))
        XCTAssertEqual(fresh.remove(id: keep.id).map(\.finalText), ["al doilea"])
        fresh.clear()
        XCTAssertTrue(HistoryStore(fileURL: url, now: { now }).load().isEmpty)
    }

    func testSummaryBetweenAndCSV() {
        let now = Date(timeIntervalSince1970: 1_795_000_000)
        let entries = [entry("unu", now), entry("doi, \"trei\"", now.addingTimeInterval(-3600)),
                       entry("fara AI", now.addingTimeInterval(-7200), cost: false)]
        let lastHour = entries.between(now.addingTimeInterval(-3600), now)
        XCTAssertEqual(lastHour.count, 2)
        let summary = HistorySummary(entries: entries)
        XCTAssertEqual(summary.count, 3)
        XCTAssertEqual(summary.correctedCount, 2)
        XCTAssertEqual(summary.totalCostUSD, 0.01248, accuracy: 1e-9)
        XCTAssertEqual(summary.averageCostUSD ?? 0, 0.00624, accuracy: 1e-9)
        XCTAssertEqual(summary.inputTokens, 4400)
        let csv = HistoryCSV.make(entries)
        XCTAssertTrue(csv.hasPrefix("date,app,window,model,cost_usd,input_tokens,cache_read_tokens,cache_write_tokens,"
            + "output_tokens,fast_mode,audio_s,transcription_s,correction_s,engine,raw_text,final_text,note,"
            + "raw_text_marked,word_probabilities\n"))
        XCTAssertTrue(csv.contains("\"doi, \"\"trei\"\"\""))
        XCTAssertTrue(csv.contains(",claude-opus-5-5,0.006240,1000,1200,0,100,no,"))
        XCTAssertEqual(csv.split(separator: "\n").count, 4)
    }
}

final class HistoryRangeTests: XCTestCase {
    func testRanges() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Bucharest")!
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        let now = formatter.date(from: "2026-11-21 15:30:00")!
        func check(_ range: HistoryRange, _ from: String, _ to: String) {
            let dates = range.dates(now: now, calendar: calendar)
            XCTAssertEqual(formatter.string(from: dates.from), from, range.title)
            XCTAssertEqual(formatter.string(from: dates.to), to, range.title)
        }
        // 21.11.2026 is a Saturday; the week starts on Monday, 16.11, however the calendar is set up.
        calendar.firstWeekday = 1
        check(.today, "2026-11-21 00:00:00", "2026-11-21 23:59:59")
        check(.thisWeek, "2026-11-16 00:00:00", "2026-11-21 23:59:59")
        check(.thisMonth, "2026-11-01 00:00:00", "2026-11-21 23:59:59")
        XCTAssertEqual(HistoryRange.all.dates(now: now, calendar: calendar).from, .distantPast)
        XCTAssertEqual(HistoryRange.all.dates(now: now, calendar: calendar).to, .distantFuture)
        XCTAssertEqual(HistoryRange.allCases.map(\.title), ["Today", "This week", "This month", "All time"])
        // Sunday belongs to the week that started on Monday; Monday is the very start of it.
        let sunday = formatter.date(from: "2026-11-22 10:00:00")!
        XCTAssertEqual(formatter.string(from: HistoryRange.thisWeek.dates(now: sunday, calendar: calendar).from), "2026-11-16 00:00:00")
        let monday = formatter.date(from: "2026-11-23 08:00:00")!
        XCTAssertEqual(formatter.string(from: HistoryRange.thisWeek.dates(now: monday, calendar: calendar).from), "2026-11-23 00:00:00")
    }
}

final class PricingTests: XCTestCase {
    func testCosts() {
        let opus = CorrectionUsage(model: "claude-opus-5-5", inputTokens: 1000, outputTokens: 100,
                                   cacheReadTokens: 1200, cacheWriteTokens: 0, fastMode: false)
        XCTAssertEqual(opus.costUSD ?? 0, 0.00624, accuracy: 1e-12)
        let fast = CorrectionUsage(model: "claude-opus-5-5", inputTokens: 1000, outputTokens: 100,
                                   cacheReadTokens: 1200, cacheWriteTokens: 0, fastMode: true)
        XCTAssertEqual(fast.costUSD ?? 0, 0.01248, accuracy: 1e-12)
        let haiku = CorrectionUsage(model: "claude-haiku-5-5", inputTokens: 500, outputTokens: 50,
                                    cacheReadTokens: 0, cacheWriteTokens: 1500, fastMode: false)
        XCTAssertEqual(haiku.costUSD ?? 0, 0.0002625, accuracy: 1e-12)
        let haikuLong = CorrectionUsage(model: "claude-haiku-5-5", inputTokens: 150_000, outputTokens: 0,
                                        cacheReadTokens: 0, cacheWriteTokens: 0, fastMode: false)
        XCTAssertEqual(haikuLong.costUSD ?? 0, 0.075, accuracy: 1e-12)
        let sonnet = CorrectionUsage(model: "claude-sonnet-5-5", inputTokens: 100, outputTokens: 10,
                                     cacheReadTokens: 1000, cacheWriteTokens: 200, fastMode: false)
        let sonnetExpected: Double = (100.0 * 2.0 + 10.0 * 10.0 + 1000.0 * 0.10 + 200.0 * 2.5) / 1_000_000.0
        XCTAssertEqual(sonnet.costUSD ?? 0, sonnetExpected, accuracy: 1e-12)
        XCTAssertNil(CorrectionUsage(model: "claude-necunoscut", inputTokens: 1, outputTokens: 1, cacheReadTokens: 0,
                                     cacheWriteTokens: 0, fastMode: false).costUSD)
    }

    func testModelMatching() {
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-opus-5-5")?.input, 4)
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-opus-5-5-20261101")?.input, 4)
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-opus-5")?.input, 5)
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-sonnet-5")?.cacheRead, 0.20)
        XCTAssertNil(PriceList.bundled.pricing(for: "claude-opus-5-50"))
        XCTAssertNil(PriceList.bundled.pricing(for: "claude-opus-5-6"))
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-opus-5-20261101")?.input, 5)
        XCTAssertEqual(ClaudeModels.displayName(for: "claude-haiku-5-5"), "Claude Haiku 5.5")
        XCTAssertEqual(ClaudeModels.displayName(for: "claude-opus-4-8"), "Claude Opus 4.8")
        // All the models in /v1/models (November 2026) have a price, including those with a date suffix.
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-opus-4-5-20251101")?.input, 5)
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-haiku-4-5-20251001")?.output, 5)
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-sonnet-4-5-20250929")?.output, 15)
        XCTAssertEqual(PriceList.bundled.pricing(for: "claude-fable-5-2")?.cacheWrite5m, 10)
        XCTAssertEqual(PriceList.bundled.label(for: "claude-opus-5-5"), "$4 / $20")
        XCTAssertEqual(PriceList.bundled.label(for: "claude-haiku-5-5"), "$0.10 / $0.50")
        XCTAssertNil(PriceList.bundled.label(for: "claude-opus-6"))
    }

    func testUsageFromResponseAndFormat() throws {
        let json = #"{"model":"claude-opus-5-5","content":[],"stop_reason":"end_turn","usage":{"input_tokens":1000,"output_tokens":100,"cache_read_input_tokens":1200,"cache_creation_input_tokens":0,"speed":"fast"}}"#
        let response = try JSONDecoder().decode(MessagesResponse.self, from: Data(json.utf8))
        let usage = try XCTUnwrap(CorrectionUsage.from(response: response, requestedModel: "x", fastRequested: false))
        XCTAssertTrue(usage.fastMode)
        XCTAssertEqual(usage.costUSD ?? 0, 0.01248, accuracy: 1e-12)
        XCTAssertEqual(CostFormat.usd(0.00624), "$0.0062")
        XCTAssertEqual(CostFormat.usd(0.5), "$0.500")
        XCTAssertEqual(CostFormat.usd(12.5), "$12.50")
        XCTAssertEqual(CostFormat.usd(0), "$0")
    }
}

final class LogoGeometryTests: XCTestCase {
    func testShapeRegions() {
        // The middle arms (the X), the walls of the loops, the holes and the outside.
        XCTAssertTrue(LogoGeometry.contains(x: 1000, y: 1000))
        XCTAssertTrue(LogoGeometry.contains(x: -1000, y: -1000))
        XCTAssertTrue(LogoGeometry.contains(x: 4000, y: 0))
        XCTAssertTrue(LogoGeometry.contains(x: -4000, y: 0))
        XCTAssertFalse(LogoGeometry.contains(x: 3000, y: 0))   // the right hole
        XCTAssertFalse(LogoGeometry.contains(x: -3000, y: 0))  // the left hole
        XCTAssertFalse(LogoGeometry.contains(x: 0, y: 1000))   // above the center
        XCTAssertFalse(LogoGeometry.contains(x: 4500, y: 0))   // outside
        // The tips of the arms fall on the ellipses (the parametric angles are consistent).
        for sector in [LogoGeometry.outer, LogoGeometry.hole] {
            XCTAssertEqual(sector.rx * cos(sector.angle), sector.tipX, accuracy: 1.5)
            XCTAssertEqual(sector.ry * sin(sector.angle), sector.tipY, accuracy: 1.5)
        }
    }

    func testStripes() {
        let stripes = LogoGeometry.stripes(count: 19, ratio: 0.3)
        XCTAssertEqual(stripes.count, 19)
        XCTAssertEqual(stripes[9].lowerBound + stripes[9].upperBound, 0, accuracy: 1e-9)  // the middle stripe is centered
        let pitch = stripes[1].lowerBound - stripes[0].lowerBound
        XCTAssertEqual(pitch, LogoGeometry.width / 19, accuracy: 1e-9)
        XCTAssertEqual(stripes[0].upperBound - stripes[0].lowerBound, pitch * 0.3, accuracy: 1e-9)
        XCTAssertTrue(LogoGeometry.stripes(count: 0, ratio: 0.3).isEmpty)
    }

    func testMenuBarPixelGrid() {
        let layout = LogoGeometry.MenuBar.self
        XCTAssertEqual(layout.width, 28.5)
        // On Retina (2x): each stripe is exactly 1 px wide and starts on a whole pixel.
        for stripe in layout.stripes {
            let x = stripe.x * 2
            XCTAssertEqual(x, x.rounded(), accuracy: 1e-6)
            XCTAssertEqual(stripe.width * 2, 1, accuracy: 1e-6)
        }
        XCTAssertEqual(layout.stripes.first!.x, 0.5, accuracy: 1e-6)
        XCTAssertEqual(layout.stripes.last!.x + layout.stripes.last!.width, layout.width - 0.5, accuracy: 1e-6)
        // The rhombus: 17 px at 2x, ~57% of the logo's height, with the 1 pt gap around it.
        XCTAssertEqual(layout.rhombusHeight * 2, 17)
        let logoHeight = LogoGeometry.height * layout.scale
        XCTAssertLessThanOrEqual(logoHeight, layout.height)
        XCTAssertEqual(layout.rhombusHeight / logoHeight, 0.57, accuracy: 0.02)
        XCTAssertEqual((layout.haloScale - 1) * layout.rhombusHeight / 2, 2.0.squareRoot(), accuracy: 1e-9)
    }

    func testRhombusOutline() {
        let curves = LogoGeometry.rhombusCurves
        XCTAssertEqual(curves.count, 19)
        // The outline closes at the start point, and the normalized height is 1.
        XCTAssertEqual(curves.last!.x, LogoGeometry.rhombusStart.x, accuracy: 1e-9)
        XCTAssertEqual(curves.last!.y, LogoGeometry.rhombusStart.y, accuracy: 1e-9)
        let ys = curves.map(\.y)
        XCTAssertEqual(ys.max()! - ys.min()!, 1, accuracy: 1e-3)
        let xs = curves.map(\.x)
        XCTAssertEqual((xs.max()! - xs.min()!) / (ys.max()! - ys.min()!), LogoGeometry.rhombusAspect, accuracy: 0.002)
    }
}

final class BrandToneTests: XCTestCase {
    func testHSLConversion() {
        // hsl(219, 99%, 53%) = rgb(17, 100, 254), the blue from the logo.
        let blue = BrandTone.blue.rgb(onDark: true)
        XCTAssertEqual(blue.r * 255, 17, accuracy: 1)
        XCTAssertEqual(blue.g * 255, 100, accuracy: 1)
        XCTAssertEqual(blue.b * 255, 254, accuracy: 1)
        // On a light background: +16% lightness (gray stays the same).
        let redLight = BrandTone.red.rgb(onDark: false)
        let redDark = BrandTone.red.rgb(onDark: true)
        XCTAssertGreaterThan(redLight.g, redDark.g)
        let grayLight = BrandTone.gray.rgb(onDark: false)
        let grayDark = BrandTone.gray.rgb(onDark: true)
        XCTAssertEqual(grayLight.r, grayDark.r, accuracy: 1e-12)
        // Red (h = 1) stays in the first hue sector.
        XCTAssertGreaterThan(redDark.r, redDark.g)
        XCTAssertGreaterThan(redDark.r, redDark.b)
    }
}

final class CorrectionTimeoutTests: XCTestCase {
    func testShortAndLongDictation() {
        let timeouts = CorrectionTimeouts.defaults
        XCTAssertEqual(timeouts.timeout(forAudio: 1.2), 5)
        XCTAssertEqual(timeouts.timeout(forAudio: 5), 5)
        XCTAssertEqual(timeouts.timeout(forAudio: 5.1), 20)
        XCTAssertEqual(timeouts.timeout(forAudio: 42), 20)
        XCTAssertEqual(timeouts.timeout(forAudio: nil), 20)
        let custom = CorrectionTimeouts(longDictationThreshold: 8, short: 3, long: 20)
        XCTAssertEqual(custom.timeout(forAudio: 7.9), 3)
        XCTAssertEqual(custom.timeout(forAudio: 8.5), 20)
    }
}

final class RomanianCountTests: XCTestCase {
    func testPlural() {
        XCTAssertEqual(RomanianCount.format(0, singular: "dictare", plural: "dictari"), "0 dictari")
        XCTAssertEqual(RomanianCount.format(1, singular: "dictare", plural: "dictari"), "1 dictare")
        XCTAssertEqual(RomanianCount.format(7, singular: "dictare", plural: "dictari"), "7 dictari")
        XCTAssertEqual(RomanianCount.format(19, singular: "dictare", plural: "dictari"), "19 dictari")
        XCTAssertEqual(RomanianCount.format(20, singular: "dictare", plural: "dictari"), "20 de dictari")
        XCTAssertEqual(RomanianCount.format(100, singular: "dictare", plural: "dictari"), "100 de dictari")
        XCTAssertEqual(RomanianCount.format(101, singular: "dictare", plural: "dictari"), "101 dictari")
        XCTAssertEqual(RomanianCount.format(119, singular: "dictare", plural: "dictari"), "119 dictari")
        XCTAssertEqual(RomanianCount.format(125, singular: "dictare", plural: "dictari"), "125 de dictari")
    }
}
