import XCTest
@testable import MeetingDesk

final class NotionExportTests: XCTestCase {
    private let parentID = "3ec94d30-7a7e-809a-9f65-c951bd66d659"
    private let pageID = "147ccc14-c73d-4e37-8712-6f760899834a"
    private let toggleID = "21f2a5b0-c6e4-4a12-9181-a425339e25cd"
    private let token = "ntn_synthetic_token_for_injected_tests_only"

    func testPageLinksNormalizeUUIDAndRejectUntrustedOrAmbiguousDestinations() throws {
        for input in [parentID, parentID.replacingOccurrences(of: "-", with: ""),
                      "https://app.notion.com/p/3ec94d307a7e809a9f65c951bd66d659?source=copy_link",
                      "https://www.notion.so/workspace/Toplantilar-3ec94d307a7e809a9f65c951bd66d659",
                      "https://team.notion.site/Toplantilar-\(parentID)"] {
            XCTAssertEqual(try NotionPageIdentifier.parse(input), parentID)
        }
        for input in ["https://example.com/\(parentID)", "http://www.notion.so/\(parentID)",
                      "https://notion.so.attacker.example/\(parentID)", "https://notion.so:8443/\(parentID)",
                      "https://secret@notion.so/\(parentID)", "https://www.notion.so/only-a-title",
                      "3ec94d3-07a7e-809a-9f65-c951bd66d659", "../../../pages"] {
            XCTAssertThrowsError(try NotionPageIdentifier.parse(input), input)
        }
    }

    func testUntrustedOrWrongPageResponseURLAlwaysFallsBackToKnownPage() {
        let expected = "https://www.notion.so/" + pageID.replacingOccurrences(of: "-", with: "")
        for proposed in ["https://attacker.example/token", "https://www.notion.so/\(parentID)",
                         "https://token@www.notion.so/\(pageID)", "notion://\(pageID)"] {
            XCTAssertEqual(NotionPageIdentifier.pageURL(pageID, proposed: proposed).absoluteString, expected)
        }
        let valid = "https://www.notion.so/Meeting-" + pageID.replacingOccurrences(of: "-", with: "")
        XCTAssertEqual(NotionPageIdentifier.pageURL(pageID, proposed: valid).absoluteString, valid)
    }

    func testUnicodeChunksPreserveEntireTurkishTextAndKeepEveryRichTextUnderLimit() {
        let original = String(repeating: "İstanbul görüşmesi 🧑🏽‍💻 e\u{301} ", count: 1700)
        let chunks = NotionExportPlan.textChunks(original)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertEqual(chunks.joined(), original)
        XCTAssertTrue(chunks.allSatisfy { $0.utf16.count <= 2000 })
        let enormousGrapheme = "e" + String(repeating: "\u{301}", count: 6000)
        XCTAssertEqual(NotionExportPlan.textChunks(enormousGrapheme).joined(), enormousGrapheme)
        XCTAssertTrue(NotionExportPlan.textChunks(enormousGrapheme).allSatisfy { $0.utf16.count <= 2000 })
    }

    func testSelectedScopeAndPrivateNotesArePreservedByNativeNotionBlocks() throws {
        let meeting = fixture()
        for scope in MeetingShareScope.allCases {
            let document = MeetingExport.document(meeting, options: MeetingShareOptions(scope: scope))
            let plan = NotionExportPlan(document: document)
            let json = try serialized(plan)
            XCTAssertFalse(json.contains("ÖZEL KENDİ NOTUM"))
            XCTAssertEqual(plan.hasTranscript, scope == .fullTranscript)
            XCTAssertEqual(json.contains("GİZLİ TRANSKRİPT AYRINTISI"), scope == .fullTranscript)
            XCTAssertEqual(json.contains("ÖZET METNİ"), scope != .actions)
            XCTAssertEqual(json.contains("AKSİYON METNİ"), scope != .summary)
            XCTAssertFalse(json.contains("<a id="))
            XCTAssertFalse(json.contains("](#"))
        }
        let included = NotionExportPlan(document: MeetingExport.document(meeting, options: MeetingShareOptions(scope: .actions, includePersonalNotes: true)))
        XCTAssertTrue(try serialized(included).contains("ÖZEL KENDİ NOTUM"))
    }

    func testCompletedActionsBecomeCheckedNativeTodosAndKeepUnassignedFieldsAndEvidence() {
        let plan = NotionExportPlan(document: MeetingExport.document(fixture(), options: MeetingShareOptions(scope: .actions)))
        let action = plan.beforeTranscript.first { $0.type == "to_do" }
        XCTAssertEqual(action?.checked, true)
        XCTAssertTrue(action?.text.joined().contains("Sorumlu: Belirtilmedi · Tarih: Belirtilmedi") == true)
        XCTAssertTrue(action?.text.joined().contains("Kaynak: 02:14") == true)
        XCTAssertFalse(action?.text.joined().hasPrefix("☑") == true)
    }

    func testLongDocumentsSplitByBlockCountAndEncodedPayloadBytesWithoutTruncation() throws {
        let tiny = (0..<251).map { NotionExportBlock(type: "paragraph", text: ["satır \($0)"]) }
        XCTAssertEqual(try NotionExportPlan.batches(tiny).map(\.count), [100, 100, 51])
        let large = (0..<12).map { index in
            NotionExportBlock(type: "paragraph", text: Array(repeating: String(repeating: "界", count: 2000), count: 16) + ["son \(index)"])
        }
        let batches = try NotionExportPlan.batches(large)
        XCTAssertGreaterThan(batches.count, 1)
        XCTAssertEqual(batches.flatMap { $0 }.count, large.count)
        for batch in batches {
            XCTAssertLessThanOrEqual(try JSONSerialization.data(withJSONObject: ["children": batch.map(\.json)]).count, 400_000)
            XCTAssertLessThanOrEqual(batch.count, 100)
        }
    }

    func testNativeExportCreatesOnePageAndAppendsTranscriptInsideCollapsibleBlock() async throws {
        let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID)
        let service = makeService(recorder)
        let receipt = try await service.export(document: MeetingExport.document(fixture(), options: MeetingShareOptions(scope: .fullTranscript)),
                                               title: "Haftalık görüşme", parentPageID: parentID, token: token)
        XCTAssertEqual(receipt.pageID, pageID)
        XCTAssertEqual(receipt.url, NotionPageIdentifier.pageURL(pageID))
        let requests = await recorder.requests
        XCTAssertEqual(requests.count, 5)
        XCTAssertEqual(requests.first?.httpMethod, "POST")
        XCTAssertEqual(requests.first?.url?.path, "/v1/pages")
        for request in requests {
            XCTAssertEqual(request.url?.scheme, "https")
            XCTAssertEqual(request.url?.host, "api.notion.com")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer " + token)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Notion-Version"), "2026-03-11")
            XCTAssertLessThanOrEqual(try XCTUnwrap(request.httpBody).count, 400_000)
        }
        let body = try json(try XCTUnwrap(requests.first?.httpBody))
        XCTAssertEqual((body["parent"] as? [String: Any])?["page_id"] as? String, parentID)
        XCTAssertNil(body["children"])
        XCTAssertEqual(requests[3].url?.path, "/v1/blocks/\(toggleID)/children")
        let toggleBody = try json(try XCTUnwrap(requests[2].httpBody))
        let toggle = (toggleBody["children"] as? [[String: Any]])?.first
        XCTAssertEqual(toggle?["type"] as? String, "toggle")
        XCTAssertNil((toggle?["toggle"] as? [String: Any])?["children"])
        let uploaded = requests.compactMap(\.httpBody).compactMap { String(data: $0, encoding: .utf8) }.joined()
        XCTAssertTrue(uploaded.contains("GİZLİ TRANSKRİPT AYRINTISI"))
        XCTAssertFalse(uploaded.contains("ÖZEL KENDİ NOTUM"))
    }

    func testRateLimitedAndOverloadedResponsesRespectRetryAfterAndRetryBoundedly() async throws {
        for code in [429, 529] {
            let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID,
                                               failures: [0: .http(code, ["Retry-After": "2"], ["code": "rate_limited"])])
            _ = try await makeService(recorder).export(document: MeetingShareDocument(blocks: []), title: "Deneme", parentPageID: parentID, token: token)
            let requestCount = await recorder.requestCount()
            XCTAssertEqual(requestCount, 2)
            let delays = await recorder.delays
            XCTAssertEqual(delays.count, 1)
            XCTAssertGreaterThanOrEqual(delays[0], 2)
        }
    }

    func testLongRetryAfterAndBlockedIntegrationAreSurfacedWithoutEarlyRetry() async throws {
        for response in [NotionTestTransport.Failure.http(429, ["Retry-After": "90"], [:]),
                         .http(429, ["Retry-After": "1"], ["additional_data": ["rate_limit_reason": "public_api_request_blocked"]])] {
            let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID, failures: [0: response])
            do {
                _ = try await makeService(recorder).export(document: MeetingShareDocument(blocks: []), title: "Deneme", parentPageID: parentID, token: token)
                XCTFail("Expected rate limit failure")
            } catch let failure as NotionExportFailure {
                XCTAssertFalse(failure.exportMayHaveSucceeded)
                XCTAssertNil(failure.createdPageURL)
            }
            let requestCount = await recorder.requestCount()
            XCTAssertEqual(requestCount, 1)
            let delays = await recorder.delays
            XCTAssertTrue(delays.isEmpty)
        }
    }

    func testRepeatedRateLimitsStopAfterThreeRetriesWithoutUncertainWrite() async throws {
        let limited = NotionTestTransport.Failure.http(429, ["Retry-After": "1"], [:])
        let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID, failures: [0: limited, 1: limited, 2: limited, 3: limited])
        do {
            _ = try await makeService(recorder).export(document: MeetingShareDocument(blocks: []), title: "Deneme", parentPageID: parentID, token: token)
            XCTFail("Expected retry exhaustion")
        } catch let failure as NotionExportFailure {
            XCTAssertFalse(failure.exportMayHaveSucceeded)
        }
        let requestCount = await recorder.requestCount(), delays = await recorder.delays
        XCTAssertEqual(requestCount, 4)
        XCTAssertEqual(delays.count, 3)
        XCTAssertGreaterThanOrEqual(delays[0], 1)
        XCTAssertGreaterThanOrEqual(delays[1], 2)
        XCTAssertGreaterThanOrEqual(delays[2], 4)
    }

    func testUncertainCreateWriteIsNotRetriedAndCommittedPageLinkIsPreserved() async throws {
        for committed in [false, true] {
            let extra: [String: Any] = committed ? ["committed_resource_id": pageID] : [:]
            let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID,
                failures: [0: .http(503, [:], ["additional_data": extra, "message": "secret \(token)"])])
            do {
                _ = try await makeService(recorder).export(document: MeetingShareDocument(blocks: []), title: "Deneme", parentPageID: parentID, token: token)
                XCTFail("Expected uncertain failure")
            } catch let failure as NotionExportFailure {
                XCTAssertTrue(failure.exportMayHaveSucceeded)
                XCTAssertEqual(failure.createdPageURL, committed ? NotionPageIdentifier.pageURL(pageID) : nil)
                XCTAssertFalse(failure.localizedDescription.contains(token))
            }
            let requestCount = await recorder.requestCount()
            XCTAssertEqual(requestCount, 1)
        }
    }

    func testAppendFailureAndLostResponseKeepKnownPartialPageWithoutRecreatingIt() async throws {
        for failure in [NotionTestTransport.Failure.http(401, [:], ["message": token]), .network] {
            let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID, failures: [1: failure])
            do {
                _ = try await makeService(recorder).export(document: MeetingExport.document(fixture(), options: MeetingShareOptions()),
                                                         title: "Deneme", parentPageID: parentID, token: token)
                XCTFail("Expected partial export")
            } catch let failure as NotionExportFailure {
                XCTAssertTrue(failure.exportMayHaveSucceeded)
                XCTAssertEqual(failure.createdPageURL, NotionPageIdentifier.pageURL(pageID))
                XCTAssertFalse(failure.localizedDescription.contains(token))
            }
            let requestCount = await recorder.requestCount()
            XCTAssertEqual(requestCount, 2)
            let requests = await recorder.requests
            XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
        }
    }

    func testCredentialsAndParentValidationFailBeforeAnyRemoteWrite() async throws {
        let recorder = NotionTestTransport(pageID: pageID, toggleID: toggleID)
        for invalid in ["", "short", "ntn_\n\(token)", "Bearer \(token)"] {
            do {
                _ = try await makeService(recorder).export(document: MeetingShareDocument(blocks: []), title: "Deneme", parentPageID: parentID, token: invalid)
                XCTFail("Invalid token accepted")
            } catch { XCTAssertFalse(error.localizedDescription.contains(invalid) && !invalid.isEmpty) }
        }
        do {
            _ = try await makeService(recorder).export(document: MeetingShareDocument(blocks: []), title: "Deneme", parentPageID: "https://attacker.example/\(parentID)", token: token)
            XCTFail("Invalid parent accepted")
        } catch { }
        let requestCount = await recorder.requestCount()
        XCTAssertEqual(requestCount, 0)
    }

    @MainActor
    func testPreviewConnectionAvoidsCredentialAccessAndRestoresUncertainExportGate() throws {
        let suite = "MeetingDeskNotionTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(parentID, forKey: "MeetingDeskNotionParentPage")
        defaults.set(true, forKey: "MeetingDeskNotionUncertainExport")
        defaults.set(NotionPageIdentifier.pageURL(pageID).absoluteString, forKey: "MeetingDeskNotionIncompleteExport")
        let connection = NotionConnection(loadCredentials: false, defaults: defaults)
        XCTAssertFalse(connection.hasToken)
        XCTAssertFalse(connection.canExport)
        XCTAssertTrue(connection.exportMayHaveSucceeded)
        XCTAssertEqual(connection.incompleteExportURL, NotionPageIdentifier.pageURL(pageID))
        connection.acknowledgeIncompleteExport()
        XCTAssertFalse(connection.exportMayHaveSucceeded)
        XCTAssertNil(connection.incompleteExportURL)
        XCTAssertFalse(defaults.bool(forKey: "MeetingDeskNotionUncertainExport"))
        XCTAssertFalse(connection.canExport)
    }

    private func makeService(_ recorder: NotionTestTransport) -> NotionExportService {
        NotionExportService(transport: { request in try await recorder.send(request) },
                            sleep: { delay in await recorder.recordDelay(delay) }, minimumRequestInterval: 0)
    }

    private func json(_ data: Data) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func serialized(_ plan: NotionExportPlan) throws -> String {
        String(data: try JSONSerialization.data(withJSONObject: (plan.beforeTranscript + plan.transcript + plan.afterTranscript).map(\.json)), encoding: .utf8)!
    }

    private func fixture() -> Meeting {
        var meeting = Meeting(title: "Haftalık görüşme")
        meeting.personalNotes = "ÖZEL KENDİ NOTUM"
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "Mikrofon", start: 134, end: 140, text: "GİZLİ TRANSKRİPT AYRINTISI")]
        meeting.notes = MeetingNotes(summary: "ÖZET METNİ", decisions: [EvidenceItem(id: "d1", text: "KARAR METNİ", evidence: ["s1"])],
                                     actions: [ActionItem(id: "a1", text: "AKSİYON METNİ", owner: nil, due: nil, evidence: ["s1"])],
                                     questions: [], ideas: [], topics: [])
        meeting.completedActions = ["a1"]
        return meeting
    }
}

private actor NotionTestTransport {
    enum Failure {
        case http(Int, [String: String], [String: Any])
        case network
    }
    let pageID: String
    let toggleID: String
    let failures: [Int: Failure]
    private(set) var requests: [URLRequest] = []
    private(set) var delays: [Double] = []

    init(pageID: String, toggleID: String, failures: [Int: Failure] = [:]) {
        self.pageID = pageID; self.toggleID = toggleID; self.failures = failures
    }

    func requestCount() -> Int { requests.count }
    func recordDelay(_ delay: Double) { delays.append(delay) }

    func send(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        if let failure = failures[index] {
            switch failure {
            case .network: throw URLError(.networkConnectionLost)
            case .http(let code, let headers, let body):
                return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: code, httpVersion: nil, headerFields: headers)!)
            }
        }
        let body: [String: Any]
        if request.httpMethod == "POST" {
            body = ["id": pageID, "url": NotionPageIdentifier.pageURL(pageID).absoluteString]
        } else { body = ["object": "list", "results": [["id": toggleID, "type": "toggle"]], "has_more": false] }
        return (try JSONSerialization.data(withJSONObject: body), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
