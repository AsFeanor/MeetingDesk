import XCTest
@testable import MeetingDesk

/// Synthetic URLProtocol responses only. These tests never boot a runtime or contact a network.
final class ArchiveQuestionTransportTests: XCTestCase {
    override func tearDown() {
        ArchiveAnswerURLProtocol.reset(nil)
        super.tearDown()
    }

    func testVerifiedRuntimeAndLocalModelPrecedeSingleShortAnswerRequest() async throws {
        let context = try await syntheticContext()
        ArchiveAnswerURLProtocol.reset { request in
            XCTAssertEqual(request.url?.scheme, "http")
            XCTAssertEqual(request.url?.host, "127.0.0.1")
            XCTAssertEqual(request.url?.port, 11471)
            XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
            if request.url?.path == "/api/chat" {
                let body = try self.object(self.bodyData(request))
                XCTAssertEqual(body["model"] as? String, OllamaSummaryService.modelName)
                for key in ["stream", "think", "truncate", "shift"] { XCTAssertEqual(body[key] as? Bool, false) }
                let options = try XCTUnwrap(body["options"] as? [String: Any])
                XCTAssertEqual(options["num_thread"] as? Int, 4)
                return .ok(request, try self.answerEnvelope(context: context))
            }
            return try self.readyMetadata(request)
        }
        let service = OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self])
        let answer = try await service.answerArchiveQuestion(context: context)
        XCTAssertEqual(ArchiveAnswerURLProtocol.paths(), ["/api/version", "/api/tags", "/api/show", "/api/chat"])
        XCTAssertEqual(answer.paragraphs.count, 1)
        XCTAssertEqual(answer.paragraphs[0].text, "İpek ödeme entegrasyonunu kontrol edecek.")
        XCTAssertEqual(answer.paragraphs[0].quote, context.sources[0].text)
        XCTAssertEqual(answer.paragraphs[0].source.meetingID, context.sources[0].meetingID)
        XCTAssertEqual(answer.paragraphs[0].source.segmentID, "payment-source")
        XCTAssertEqual(answer.paragraphs[0].source.start, 24)
    }

    func testEmptyRetrievalReturnsAbstentionBeforeAnyRuntimeProbe() async throws {
        let index = ArchiveQuestionIndex()
        let context = try await index.retrieve(question: "Ödeme için ne konuştuk?")
        ArchiveAnswerURLProtocol.reset { _ in XCTFail("No evidence must cause no request"); throw URLError(.cannotConnectToHost) }
        let result = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
        XCTAssertTrue(result.abstained)
        XCTAssertTrue(result.paragraphs.isEmpty)
        XCTAssertTrue(ArchiveAnswerURLProtocol.paths().isEmpty)
    }

    func testUnsupportedOrMalformedRuntimeNeverReceivesQuestionOrSources() async throws {
        let context = try await syntheticContext()
        for metadata: [String: Any] in [
            ["version": "0.40.10"], ["version": "0.40.11-rc.1"], ["version": "unknown PRIVATE"], [:], ["version": 40]
        ] {
            ArchiveAnswerURLProtocol.reset { request in
                XCTAssertEqual(request.httpMethod, "GET")
                XCTAssertNil(request.httpBody)
                return .ok(request, try self.json(metadata))
            }
            do {
                _ = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
                XCTFail("Unverified runtime accepted")
            } catch { XCTAssertFalse(error.localizedDescription.contains("PRIVATE")) }
            XCTAssertEqual(ArchiveAnswerURLProtocol.paths(), ["/api/version"])
        }
    }

    func testMissingDuplicateAndCloudModelMetadataNeverReceivesChatOrDownloads() async throws {
        let context = try await syntheticContext()
        let local: [String: Any] = ["name": OllamaSummaryService.modelName]
        let variants: [[String: Any]] = [
            ["models": []], ["models": [local, local]],
            ["models": [["name": OllamaSummaryService.modelName, "remote_host": "https://outside.invalid"]]],
            ["models": [["name": OllamaSummaryService.modelName, "details": ["remote_model": "cloud"]]]]
        ]
        for tags in variants {
            ArchiveAnswerURLProtocol.reset { request in
                if request.url?.path == "/api/version" { return .ok(request, try self.json(["version": "0.40.11"])) }
                XCTAssertEqual(request.url?.path, "/api/tags")
                return .ok(request, try self.json(tags))
            }
            do {
                _ = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
                XCTFail("Unverified model accepted")
            } catch { }
            XCTAssertEqual(ArchiveAnswerURLProtocol.paths(), ["/api/version", "/api/tags"])
        }
        ArchiveAnswerURLProtocol.reset { request in
            if request.url?.path == "/api/show" {
                return .ok(request, try self.json(["details": ["format": "safetensors"], "remote_host": "https://outside.invalid"]))
            }
            return try self.readyMetadata(request)
        }
        do {
            _ = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
            XCTFail("Remote show metadata accepted")
        } catch { }
        XCTAssertEqual(ArchiveAnswerURLProtocol.paths(), ["/api/version", "/api/tags", "/api/show"])
    }

    func testSessionDisablesProxyCookiesAndCacheForPrivateQuestionTransport() throws {
        let service = OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self])
        let session = try XCTUnwrap(Mirror(reflecting: service).children.first { $0.label == "session" }?.value as? URLSession)
        let configuration = session.configuration
        XCTAssertNotNil(configuration.connectionProxyDictionary)
        XCTAssertTrue(configuration.connectionProxyDictionary?.isEmpty == true)
        XCTAssertNil(configuration.httpCookieStorage)
        XCTAssertNil(configuration.urlCache)
        XCTAssertEqual(configuration.requestCachePolicy, .reloadIgnoringLocalCacheData)
    }

    func testRedirectAndNonlocalChatResponseFailWithoutFollowingDestination() async throws {
        let context = try await syntheticContext()
        for nonlocal in [false, true] {
            ArchiveAnswerURLProtocol.reset { request in
                if request.url?.path == "/api/chat" {
                    return ArchiveAnswerURLProtocol.Response(status: nonlocal ? 200 : 307,
                        data: try self.answerEnvelope(context: context),
                        url: nonlocal ? URL(string: "https://outside.invalid/api/chat")! : request.url!,
                        headers: ["Location": "https://outside.invalid/api/chat"])
                }
                return try self.readyMetadata(request)
            }
            do {
                _ = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
                XCTFail("Unsafe response accepted")
            } catch { }
            XCTAssertEqual(ArchiveAnswerURLProtocol.paths(), ["/api/version", "/api/tags", "/api/show", "/api/chat"])
            XCTAssertTrue(ArchiveAnswerURLProtocol.requests().allSatisfy { $0.url?.host == "127.0.0.1" })
        }
    }

    func testInvalidCitationQuoteAndIncompleteOutputFailOnceWithoutAutomaticRetry() async throws {
        let context = try await syntheticContext()
        let variants: [[String: Any]] = [
            ["answer": "İpek yapacak.", "source": "unknown", "quote": context.sources[0].text],
            ["answer": "İpek yapacak.", "source": context.sources[0].id, "quote": "Uydurulan kaynak"],
            ["answer": "İpek yapacak.", "source": context.sources[0].id, "quote": ""]
        ]
        for fact in variants {
            ArchiveAnswerURLProtocol.reset { request in
                if request.url?.path == "/api/chat" { return .ok(request, try self.envelope(["abstain": false, "facts": [fact]])) }
                return try self.readyMetadata(request)
            }
            do {
                _ = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
                XCTFail("Invalid evidence accepted")
            } catch { XCTAssertTrue(error is ArchiveQuestionFailure, "The controlled evidence error should be preserved") }
            XCTAssertEqual(ArchiveAnswerURLProtocol.paths().filter { $0 == "/api/chat" }.count, 1)
        }
        ArchiveAnswerURLProtocol.reset { request in
            if request.url?.path == "/api/chat" { return .ok(request, try self.answerEnvelope(context: context, doneReason: "length")) }
            return try self.readyMetadata(request)
        }
        do {
            _ = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
            XCTFail("Incomplete answer accepted")
        } catch { XCTAssertTrue(error is ArchiveQuestionFailure) }
        XCTAssertEqual(ArchiveAnswerURLProtocol.paths().filter { $0 == "/api/chat" }.count, 1)
    }

    func testExplicitModelAbstentionReturnsNoGeneratedTextAndNoRetry() async throws {
        let context = try await syntheticContext()
        ArchiveAnswerURLProtocol.reset { request in
            if request.url?.path == "/api/chat" { return .ok(request, try self.envelope(["abstain": true, "facts": []])) }
            return try self.readyMetadata(request)
        }
        let answer = try await OllamaSummaryService(protocolClasses: [ArchiveAnswerURLProtocol.self]).answerArchiveQuestion(context: context)
        XCTAssertTrue(answer.abstained)
        XCTAssertTrue(answer.paragraphs.isEmpty)
        XCTAssertEqual(ArchiveAnswerURLProtocol.paths().filter { $0 == "/api/chat" }.count, 1)
    }

    private func syntheticContext() async throws -> ArchiveQuestionContext {
        var meeting = Meeting(title: "Synthetic payments")
        meeting.segments = [.init(id: "payment-source", speaker: "speaker", start: 24, end: 30,
            text: "İpek ödeme entegrasyonunu kontrol edecek.")]
        let index = ArchiveQuestionIndex()
        try await index.replace(meetings: [meeting])
        return try await index.retrieve(question: "Ödeme entegrasyonunu kim kontrol edecek?")
    }

    private func readyMetadata(_ request: URLRequest) throws -> ArchiveAnswerURLProtocol.Response {
        switch request.url?.path {
        case "/api/version": return .ok(request, try json(["version": "0.40.11"]))
        case "/api/tags": return .ok(request, try json(["models": [["name": OllamaSummaryService.modelName]]]))
        case "/api/show": return .ok(request, try json(["details": ["format": "safetensors"]]))
        default: XCTFail("Unexpected endpoint or model download"); throw URLError(.unsupportedURL)
        }
    }

    private func answerEnvelope(context: ArchiveQuestionContext, doneReason: String = "stop") throws -> Data {
        try envelope(["abstain": false, "facts": [["answer": "İpek ödeme entegrasyonunu kontrol edecek.",
            "source": context.sources[0].id, "quote": context.sources[0].text]]], doneReason: doneReason)
    }
    private func envelope(_ wire: [String: Any], doneReason: String = "stop") throws -> Data {
        try json(["done": true, "done_reason": doneReason,
            "message": ["role": "assistant", "content": String(decoding: try json(wire), as: UTF8.self)]])
    }
    private func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value) }
    private func object(_ data: Data) throws -> [String: Any] { try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]) }
    private func bodyData(_ request: URLRequest) throws -> Data {
        if let body = request.httpBody { return body }
        // URLSession may turn an in-memory body into a stream before URLProtocol sees it.
        let stream = try XCTUnwrap(request.httpBodyStream)
        stream.open(); defer { stream.close() }
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count >= 0 else { throw URLError(.cannotDecodeRawData) }
            if count == 0 { return result }
            result.append(contentsOf: buffer.prefix(count))
            guard result.count <= 1_000_000 else { throw URLError(.dataLengthExceedsMaximum) }
        }
    }
}

private final class ArchiveAnswerURLProtocol: URLProtocol, @unchecked Sendable {
    struct Response {
        let status: Int
        let data: Data
        let url: URL
        var headers: [String: String] = [:]
        static func ok(_ request: URLRequest, _ data: Data) -> Response { .init(status: 200, data: data, url: request.url!) }
    }
    typealias Handler = (URLRequest) throws -> Response
    private static let lock = NSLock()
    private static var handler: Handler?
    private static var captured: [URLRequest] = []
    static func reset(_ value: Handler?) { lock.lock(); defer { lock.unlock() }; handler = value; captured = [] }
    static func requests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return captured }
    static func paths() -> [String] { requests().map { $0.url?.path ?? "" } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.captured.append(request); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.cannotConnectToHost) }
            let result = try handler(request)
            let response = HTTPURLResponse(url: result.url, statusCode: result.status,
                httpVersion: "HTTP/1.1", headerFields: result.headers)!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: result.data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { }
}
