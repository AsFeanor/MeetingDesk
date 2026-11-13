import XCTest
@testable import MeetingDesk

final class OllamaSummaryServiceTests: XCTestCase {
    override func tearDown() {
        OllamaSummaryStub.setHandler(nil)
        super.tearDown()
    }

    func testWholeMeetingInputKeepsEverySourceAndOnlyProvidedRealIdentity() throws {
        var meeting = sampleMeeting()
        meeting.segments = (0..<180).map { i in
            TranscriptSegment(id: "archive-\(i)", speaker: i == 0 ? "known" : "raw-channel-\(i)",
                              start: Double(i), end: Double(i + 1), text: "Özgün metin \(i), \"alıntı\" 👩🏽‍💻\nTamamı.")
        }
        meeting.speakerNames = ["known": "İpek", "raw-channel-1": "Konuşmacı 2", "raw-channel-2": "Mikrofon"]
        let request = try OllamaSummaryService.chatRequest(meeting: meeting)
        let requestBody = try object(XCTUnwrap(request.httpBody))
        XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:11471/api/chat")
        XCTAssertEqual(requestBody["model"] as? String, "qwen3.5:9b-q4_K_M")
        for key in ["stream", "think", "truncate", "shift"] { XCTAssertEqual(requestBody[key] as? Bool, false, key) }
        let options = try XCTUnwrap(requestBody["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 65_536)
        XCTAssertEqual(options["num_predict"] as? Int, 4_096)
        XCTAssertEqual(options["temperature"] as? Double, 0.2)
        let messages = try XCTUnwrap(requestBody["messages"] as? [[String: Any]])
        let user = try XCTUnwrap(messages.last?["content"] as? String)
        let sourceText = try XCTUnwrap(user.components(separatedBy: "SOURCES_JSON:\n").last)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(sourceText.utf8)) as? [[String: Any]])
        XCTAssertEqual(rows.count, 180, "No first-N source cap or fragment combine")
        for (i, row) in rows.enumerated() {
            XCTAssertEqual(row["id"] as? String, "s\(i + 1)")
            XCTAssertEqual(row["text"] as? String, meeting.segments[i].text)
            XCTAssertNil(row["start"]); XCTAssertNil(row["end"]); XCTAssertNil(row["speaker"])
        }
        XCTAssertEqual(rows[0]["providedSpeakerName"] as? String, "İpek")
        XCTAssertNil(rows[1]["providedSpeakerName"])
        XCTAssertNil(rows[2]["providedSpeakerName"])
        XCTAssertFalse(user.contains("raw-channel-"))
        let system = try XCTUnwrap(messages.first?["content"] as? String)
        XCTAssertTrue(system.contains("ALL distinct"))
        XCTAssertTrue(system.contains("later cancellations"))
        XCTAssertTrue(system.contains("owner=null"))
    }

    func testChronologicalAliasesAndEvidenceMappingAreStableForUnsortedArchive() throws {
        var meeting = sampleMeeting()
        meeting.segments = [
            .init(id: "late", speaker: "a", start: 5, end: 8, text: "Later."),
            .init(id: "early", speaker: "b", start: 0, end: 3, text: "First."),
            .init(id: "same-time", speaker: "c", start: 0, end: 2, text: "Second, simultaneous.")
        ]
        var wire = validWire()
        wire["decisions"] = [["text": "Agreed outcome.", "evidence": ["s1", "s3"]]]
        let result = try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting)
        XCTAssertEqual(result.decisions[0].evidence, ["early", "late"])
        let again = try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting)
        XCTAssertEqual(result, again)
    }

    func testStrictRequiredFieldsTypesAndEvidenceRejectInvalidNotes() throws {
        let valid = validWire()
        for field in ["summary", "decisions", "actions", "questions", "ideas", "topics"] {
            var missing = valid; missing.removeValue(forKey: field)
            XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(missing), meeting: sampleMeeting()), field)
        }
        var extra = valid; extra["invented"] = "ignored?"
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(extra), meeting: sampleMeeting()))
        for badFact: [String: Any] in [
            ["text": "Claim", "evidence": []],
            ["text": "Claim", "evidence": ["not-a-source"]],
            ["text": "Claim", "evidence": ["s1"], "id": "generated"],
            ["text": "   ", "evidence": ["s1"]],
            ["text": 12, "evidence": ["s1"]]
        ] {
            var wire = valid; wire["decisions"] = [badFact]
            XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: sampleMeeting()))
        }
        var wrongType = valid; wrongType["actions"] = "none"
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wrongType), meeting: sampleMeeting()))
    }

    func testTemplateIDsAreRequiredAndMustMatchSelectedTemplate() throws {
        for template in MeetingTemplate.allCases {
            var meeting = sampleMeeting(); meeting.templateRawValue = template.rawValue
            var wire = validWire()
            let topic: [String: Any] = ["title": "Konu", "text": "• Kısa bağlam.", "evidence": ["s1"],
                                        "sectionID": template.contextSections[0].id]
            wire["topics"] = [topic]
            XCTAssertNoThrow(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
            var missing = topic; missing.removeValue(forKey: "sectionID"); wire["topics"] = [missing]
            XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
            var wrong = topic; wrong["sectionID"] = "invented-section"; wire["topics"] = [wrong]
            XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
        }
    }

    func testGroundedOwnerExactDateAndOwnerlessActionArePreserved() throws {
        var meeting = sampleMeeting()
        meeting.segments[0].text = "I will update the instructions by next Friday."
        meeting.speakerNames = ["raw-a": "İpek"]
        let ownerless: [String: Any] = ["text": "Check export.", "owner": NSNull(), "due": NSNull(), "evidence": ["s1"]]
        let assigned: [String: Any] = ["text": "Update instructions.", "owner": "İpek", "due": "next Friday", "evidence": ["s1"]]
        var wire = validWire(); wire["actions"] = [ownerless, assigned]
        let result = try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting)
        XCTAssertNil(result.actions[0].owner); XCTAssertNil(result.actions[0].due)
        XCTAssertEqual(result.actions[1].owner, "İpek"); XCTAssertEqual(result.actions[1].due, "next Friday")
        var wrong = assigned; wrong["owner"] = "Invented person"; wire["actions"] = [wrong]
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
        wrong = assigned; wrong["due"] = "2026-12-18"; wire["actions"] = [wrong]
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
        wrong = assigned; wrong["owner"] = "Konuşmacı 1"; wire["actions"] = [wrong]
        meeting.speakerNames = ["raw-a": "Konuşmacı 1"]
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
        wrong = assigned; wrong["owner"] = "s1"; wire["actions"] = [wrong]
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting))
    }

    func testAllDistinctActionsSurviveWithoutArtificialCapsAndIDsAreDeterministic() throws {
        let meeting = sampleMeeting()
        var wire = validWire()
        wire["actions"] = (0..<55).map { i -> [String: Any] in
            ["text": "Explicit pending task \(i).", "owner": NSNull(), "due": NSNull(), "evidence": ["s1"]]
        }
        let first = try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting)
        let second = try OllamaSummaryService.notes(from: envelope(wire), meeting: meeting)
        XCTAssertEqual(first.actions.count, 55)
        XCTAssertEqual(Set(first.actions.map(\.id)).count, 55)
        XCTAssertEqual(first, second)
        let schema = OllamaSummaryService.schema(template: .general)
        let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
        let actions = try XCTUnwrap(properties["actions"] as? [String: Any])
        XCTAssertNil(actions["maxItems"])
    }

    func testIncompleteOrTokenLimitedResponsesNeverProducePartialNotes() throws {
        for reason in ["length", "max_tokens", "", "unload"] {
            XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(validWire(), reason: reason), meeting: sampleMeeting()))
        }
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: envelope(validWire(), done: false), meeting: sampleMeeting()))
        var response = try object(envelope(validWire())); response.removeValue(forKey: "done_reason")
        XCTAssertThrowsError(try OllamaSummaryService.notes(from: json(response), meeting: sampleMeeting()))
    }

    func testInvalidSourcesAndExcessiveInputAreRejectedWithoutTrimming() throws {
        var meeting = sampleMeeting(); meeting.segments.append(meeting.segments[0])
        XCTAssertThrowsError(try OllamaSummaryService.chatRequest(meeting: meeting))
        meeting = sampleMeeting(); meeting.segments[0].start = .nan
        XCTAssertThrowsError(try OllamaSummaryService.chatRequest(meeting: meeting))
        meeting = sampleMeeting(); meeting.segments[0].text = String(repeating: "a", count: 1_000_001)
        XCTAssertThrowsError(try OllamaSummaryService.chatRequest(meeting: meeting))
    }

    func testStatusDistinguishesOfflineMissingAndLocalSafetensorsReady() async throws {
        let service = OllamaSummaryService(protocolClasses: [OllamaSummaryStub.self])
        OllamaSummaryStub.setHandler { _ in throw URLError(.cannotConnectToHost) }
        let unavailable = await service.status(); XCTAssertEqual(unavailable, .serviceUnavailable)
        XCTAssertEqual(unavailable.label, "Özet motoru hazır değil")
        OllamaSummaryStub.setHandler { request in
            if request.url?.path == "/api/version" { return (200, try self.json(["version": "0.40.11"]), request.url!) }
            return (200, try self.json(["models": []]), request.url!)
        }
        let missing = await service.status(); XCTAssertEqual(missing, .modelMissing)
        OllamaSummaryStub.setHandler { request in
            if request.url?.path == "/api/version" { return (200, try self.json(["version": "0.40.11"]), request.url!) }
            if request.url?.path == "/api/tags" { return (200, try self.json(self.tags()), request.url!) }
            return (200, try self.json(["details": ["format": "safetensors", "family": "qwen3_5"]]), request.url!)
        }
        let ready = await service.status(); XCTAssertEqual(ready, .ready)
    }

    func testRuntimeSemanticVersionBoundary() {
        for version in ["0.40.11", "0.40.11+build.7", "0.40.12", "0.40.12-rc.1", "0.41.0", "1.0.0"] {
            XCTAssertTrue(OllamaSummaryService.isSupportedRuntimeVersion(version), version)
        }
        for version in ["0.40.10", "0.39.99", "0.40.11-rc.1", "0.40.12-01", "00.40.11", "0.40",
                        "v0.40.11", "0.40.11 ", "0.40.11\n", "0.40.11.1", "", "PRIVATE UNKNOWN"] {
            XCTAssertFalse(OllamaSummaryService.isSupportedRuntimeVersion(version), version)
        }
    }

    func testOldMissingOrMalformedRuntimeNeverReceivesMeetingContent() async throws {
        let responses: [Data] = try [
            json(["version": "0.40.10"]), json(["version": "0.40.11-rc.1"]), json([:]),
            json(["version": 40]), json(["version": "PRIVATE UNKNOWN"]), Data("not-json".utf8)
        ]
        for response in responses {
            let service = OllamaSummaryService(protocolClasses: [OllamaSummaryStub.self])
            OllamaSummaryStub.setHandler { request in
                XCTAssertEqual(request.url?.path, "/api/version")
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertEqual(request.timeoutInterval, 8)
                XCTAssertNil(request.httpBody)
                return (200, response, request.url!)
            }
            let status = await service.status(); XCTAssertEqual(status, .updateRequired)
            XCTAssertEqual(status.label, "Toplantı güncellenmeli")
            do { _ = try await service.summarize(meeting: sampleMeeting()); XCTFail("Unsupported runtime accepted") }
            catch {
                XCTAssertFalse(error.localizedDescription.contains("PRIVATE UNKNOWN"))
                XCTAssertFalse(error.localizedDescription.contains("Ollama"))
            }
            XCTAssertEqual(OllamaSummaryStub.requests().count, 2)
            XCTAssertTrue(OllamaSummaryStub.requests().allSatisfy { $0.url?.path == "/api/version" })
        }
    }

    func testRemoteOrCloudMetadataNeverReceivesMeetingContent() async throws {
        for poisoned in [
            ["remote_host": "https://ollama.com"], ["remote_model": "remote-name"],
            ["details": ["remote_host": "https://outside.invalid"]], ["name": "qwen3.5:cloud"]
        ] as [[String: Any]] {
            let service = OllamaSummaryService(protocolClasses: [OllamaSummaryStub.self])
            OllamaSummaryStub.setHandler { request in
                if request.url?.path == "/api/version" { return (200, try self.json(["version": "0.40.11"]), request.url!) }
                if request.url?.path == "/api/tags" { return (200, try self.json(self.tags()), request.url!) }
                if request.url?.path == "/api/show" {
                    var show: [String: Any] = ["details": ["format": "safetensors"]]
                    for (key, value) in poisoned { show[key] = value }
                    return (200, try self.json(show), request.url!)
                }
                XCTFail("Meeting content must not be requested for remote models")
                return (500, Data(), request.url!)
            }
            do { _ = try await service.summarize(meeting: sampleMeeting()); XCTFail("Remote model accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("outside.invalid")) }
            XCTAssertFalse(OllamaSummaryStub.requests().contains { $0.url?.path == "/api/chat" })
        }
        XCTAssertFalse(OllamaSummaryService.isLocalModelMetadata(["name": "qwen3.5:9b-cloud"]))
        XCTAssertFalse(OllamaSummaryService.isLocalModelMetadata(["remote_host": 12]))
    }

    func testNonlocalResponseAndRedirectAreRejectedBeforeChat() async throws {
        for (code, url) in [(200, URL(string: "https://outside.invalid/api/version")!),
                            (307, URL(string: "http://127.0.0.1:11471/api/version")!)] {
            let service = OllamaSummaryService(protocolClasses: [OllamaSummaryStub.self])
            OllamaSummaryStub.setHandler { _ in (code, try self.json(self.tags()), url) }
            do { _ = try await service.summarize(meeting: sampleMeeting()); XCTFail("Nonlocal/redirect accepted") }
            catch { XCTAssertFalse(error.localizedDescription.contains("outside.invalid")) }
            XCTAssertEqual(OllamaSummaryStub.requests().count, 1)
            XCTAssertTrue(OllamaSummaryStub.requests().allSatisfy { OllamaSummaryService.isLoopback($0.url) })
        }
        XCTAssertFalse(OllamaSummaryService.isLoopback(URL(string: "http://127.0.0.1:11471@outside.invalid")))
        XCTAssertFalse(OllamaSummaryService.isLoopback(URL(string: "https://127.0.0.1:11471")))
        XCTAssertFalse(OllamaSummaryService.isLoopback(URL(string: "http://127.0.0.1:11434")), "The default vendor-app port is not our private runtime")
    }

    func testSummaryUsesOneCompleteLocalChatRequestAndSafeErrors() async throws {
        let service = OllamaSummaryService(protocolClasses: [OllamaSummaryStub.self])
        OllamaSummaryStub.setHandler { request in
            switch request.url?.path {
            case "/api/version": return (200, try self.json(["version": "0.40.12"]), request.url!)
            case "/api/tags": return (200, try self.json(self.tags()), request.url!)
            case "/api/show": return (200, try self.json(["details": ["format": "safetensors"]]), request.url!)
            case "/api/chat": return (200, try self.envelope(self.validWire()), request.url!)
            default: XCTFail("Unexpected request"); throw URLError(.badURL)
            }
        }
        let notes = try await service.summarize(meeting: sampleMeeting())
        XCTAssertEqual(notes.summary, "A concise supported summary.")
        XCTAssertEqual(OllamaSummaryStub.requests().filter { $0.url?.path == "/api/chat" }.count, 1)
        XCTAssertTrue(OllamaSummaryStub.requests().allSatisfy { OllamaSummaryService.isLoopback($0.url) })
        OllamaSummaryStub.setHandler { request in (500, Data("PRIVATE RAW ERROR".utf8), request.url!) }
        do { _ = try await service.summarize(meeting: sampleMeeting()); XCTFail("HTTP error accepted") }
        catch {
            XCTAssertFalse(error.localizedDescription.contains("PRIVATE RAW ERROR"))
            XCTAssertFalse(error.localizedDescription.contains("Ollama"))
        }
    }

    func testCancellationPropagatesRatherThanBecomingModelFailure() async throws {
        let service = OllamaSummaryService(protocolClasses: [OllamaSummaryStub.self])
        OllamaSummaryStub.setHandler { _ in throw URLError(.cancelled) }
        do { _ = try await service.summarize(meeting: sampleMeeting()); XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
    }

    private func sampleMeeting() -> Meeting {
        Meeting(title: "Synthetic meeting", segments: [
            .init(id: "archived-original", speaker: "raw-a", start: 0, end: 5,
                  text: "We agreed to improve the export. A check is still needed.")
        ])
    }

    private func validWire() -> [String: Any] {
        ["summary": "A concise supported summary.", "decisions": [], "actions": [], "questions": [], "ideas": [],
         "topics": [["title": "Export", "text": "• Discussed export quality.", "sectionID": "discussion", "evidence": ["s1"]]]]
    }

    private func tags() -> [String: Any] { ["models": [["name": "qwen3.5:9b-q4_K_M", "model": "qwen3.5:9b-q4_K_M"]]] }
    private func json(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func envelope(_ wire: [String: Any], done: Bool = true, reason: String = "stop") throws -> Data {
        try json(["done": done, "done_reason": reason, "message": ["role": "assistant", "content": String(decoding: json(wire), as: UTF8.self)]])
    }
}

private final class OllamaSummaryStub: URLProtocol {
    typealias Handler = (URLRequest) throws -> (Int, Data, URL)
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var received: [URLRequest] = []
    static func setHandler(_ value: Handler?) {
        lock.lock(); defer { lock.unlock() }; handler = value; received = []
    }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return received }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.received.append(request); let handler = Self.handler; Self.lock.unlock()
        do {
            let result = try XCTUnwrap(handler)(request)
            let response = HTTPURLResponse(url: result.2, statusCode: result.0, httpVersion: "HTTP/1.1",
                                           headerFields: ["Content-Type": "application/json", "Location": "https://outside.invalid"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.1)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
