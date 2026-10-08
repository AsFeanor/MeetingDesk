import XCTest
import AVFoundation
@testable import MeetingDesk

final class OpenAIServiceTests: XCTestCase {
    private var session: URLSession!

    override func setUp() {
        super.setUp()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OpenAIStubProtocol.self]
        session = URLSession(configuration: configuration)
    }

    override func tearDown() {
        session.invalidateAndCancel()
        OpenAIStubProtocol.handler = nil
        super.tearDown()
    }

    func testDiarizationContractPreservesOriginalTextAndSpeakerTimes() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
        try Data("mock WAV payload".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        OpenAIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/audio/transcriptions")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = String(decoding: try Self.requestBody(request), as: UTF8.self)
            XCTAssertTrue(body.contains("name=\"model\"\r\n\r\ngpt-4o-transcribe-diarize"))
            XCTAssertTrue(body.contains("name=\"response_format\"\r\n\r\ndiarized_json"))
            XCTAssertTrue(body.contains("name=\"chunking_strategy\"\r\n\r\nauto"))
            XCTAssertTrue(body.contains("filename=\"meeting.wav\""))
            XCTAssertTrue(body.contains("Content-Type: audio/wav"))
            XCTAssertFalse(body.contains("name=\"prompt\""))
            return (200, Data(#"{"segments":[{"id":"seg_1","speaker":"A","start":0.4,"end":4.1,"text":"Bunu kaldıralım. Keep Stripe as an option."},{"id":"seg_2","speaker":"B","start":3.7,"end":5.1,"text":"Agreed."}]}"#.utf8))
        }
        let segments = try await OpenAIService(apiKey: "test-key", session: session).transcribe(audioURL: url)
        XCTAssertEqual(segments.map(\.id), ["part1-seg_1", "part1-seg_2"])
        XCTAssertEqual(segments[0].speaker, "Konuşmacı A")
        XCTAssertEqual(segments[0].text, "Bunu kaldıralım. Keep Stripe as an option.")
        XCTAssertEqual(segments[0].start, 0.4)
        XCTAssertEqual(segments[1].start, 3.7, "Overlapping speech must retain original timestamps")
    }

    func testSummaryUsesStrictSchemaAndRetainsUnassignedActions() async throws {
        let expected = MeetingNotes(summary: "Tenant expense akışı sadeleştirilecek.",
                                    decisions: [.init(id: "decision-1", text: "Tenant expense butonunu kaldırın.", evidence: ["seg-a"])],
                                    actions: [.init(id: "action-1", text: "Butonu kaldırın.", owner: nil, due: nil, evidence: ["seg-a"])],
                                    questions: [], ideas: [.init(id: "idea-1", text: "Stripe seçeneğini araştırın.", evidence: ["seg-b"])], topics: [])
        OpenAIStubProtocol.handler = { request in
            XCTAssertEqual(request.url?.path, "/v1/chat/completions")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Self.requestBody(request)) as? [String: Any])
            XCTAssertEqual(body["model"] as? String, "gpt-4.1-mini")
            let format = try XCTUnwrap(body["response_format"] as? [String: Any])
            XCTAssertEqual(format["type"] as? String, "json_schema")
            let specification = try XCTUnwrap(format["json_schema"] as? [String: Any])
            XCTAssertEqual(specification["strict"] as? Bool, true)
            let schema = try XCTUnwrap(specification["schema"] as? [String: Any])
            XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), Set(["summary", "decisions", "actions", "questions", "ideas", "topics"]))
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            let messages = try XCTUnwrap(body["messages"] as? [[String: String]])
            let system = try XCTUnwrap(messages.first?["content"])
            XCTAssertTrue(system.contains("UNTRUSTED"))
            XCTAssertTrue(system.contains("owner and due must be null"))
            XCTAssertTrue(system.contains("Turkish"))
            let input = try XCTUnwrap(messages.last?["content"]?.data(using: .utf8))
            let source = try XCTUnwrap(JSONSerialization.jsonObject(with: input) as? [String: Any])
            XCTAssertEqual((source["segments"] as? [[String: Any]])?.count, 2)
            return (200, try Self.completion(expected))
        }
        let result = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: Self.meeting)
        XCTAssertEqual(result, expected)
        XCTAssertNil(result.actions[0].owner)
        XCTAssertNil(result.actions[0].due)
    }

    func testInvalidEvidenceDoesNotTurnIntoAnApparentlySourcedNote() async throws {
        let notes = MeetingNotes(summary: "Özet", decisions: [.init(id: "d1", text: "Kaldırın", evidence: ["invented-segment"])],
                                 actions: [], questions: [], ideas: [], topics: [])
        OpenAIStubProtocol.handler = { _ in (200, try Self.completion(notes)) }
        do {
            _ = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: Self.meeting)
            XCTFail("Unknown source IDs must be rejected")
        } catch { XCTAssertTrue(error.localizedDescription.contains("kaynak bağlantıları")) }
    }

    func testInventedCalendarDateAndOwnerAreRejected() async throws {
        for action in [ActionItem(id: "a1", text: "Kaldırın", owner: nil, due: "2026-10-09", evidence: ["seg-a"]),
                       ActionItem(id: "a1", text: "Kaldırın", owner: "Alice", due: nil, evidence: ["seg-a"])] {
            let notes = MeetingNotes(summary: "Özet", decisions: [], actions: [action], questions: [], ideas: [], topics: [])
            OpenAIStubProtocol.handler = { _ in (200, try Self.completion(notes)) }
            do {
                _ = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: Self.meeting)
                XCTFail("Invented owners/deadlines must be rejected")
            } catch { XCTAssertTrue(error.localizedDescription.contains("kaydedilmedi")) }
        }
    }

    func testStatedDuePhraseIsPreservedWithoutResolvingADate() async throws {
        var meeting = Self.meeting
        meeting.segments[0].text = "Ayşe will remove the button next Friday."
        let notes = MeetingNotes(summary: "Özet", decisions: [],
                                 actions: [.init(id: "a1", text: "Butonu kaldırın", owner: "Ayşe", due: "next Friday", evidence: ["seg-a"])],
                                 questions: [], ideas: [], topics: [])
        OpenAIStubProtocol.handler = { _ in (200, try Self.completion(notes)) }
        let result = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: meeting)
        XCTAssertEqual(result.actions[0].due, "next Friday")
    }

    func testServiceRefusalAndIncompleteResultAreNotSavedAsNotes() async throws {
        for value in [#"{"choices":[{"message":{"content":null,"refusal":"cannot comply"},"finish_reason":"stop"}]}"#,
                      #"{"choices":[{"message":{"content":"{","refusal":null},"finish_reason":"length"}]}"#,
                      #"{"choices":[{"message":{"content":"{broken","refusal":null},"finish_reason":"stop"}]}"#] {
            OpenAIStubProtocol.handler = { _ in (200, Data(value.utf8)) }
            do {
                _ = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: Self.meeting)
                XCTFail("Refused, incomplete, and malformed notes must be rejected")
            } catch { XCTAssertFalse(error.localizedDescription.contains("test-key")) }
        }
    }

    func testHTTPFailuresDoNotEchoSecretsOrMeetingText() async throws {
        for status in [401, 429, 503] {
            OpenAIStubProtocol.handler = { _ in (status, Data("sensitive transcript and test-key".utf8)) }
            do {
                _ = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: Self.meeting)
                XCTFail("HTTP \(status) must fail")
            } catch {
                XCTAssertFalse(error.localizedDescription.contains("test-key"))
                XCTAssertFalse(error.localizedDescription.contains("sensitive transcript"))
            }
        }
    }

    func testOversizedTranscriptIsNotSilentlyTruncatedOrSent() async throws {
        var meeting = Self.meeting
        meeting.segments[0].text = String(repeating: "x", count: 900_100)
        OpenAIStubProtocol.handler = { _ in XCTFail("No partial transcript may be sent"); return (200, Data()) }
        do {
            _ = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: meeting)
            XCTFail("Oversized transcript must fail explicitly")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Hiçbir bölüm atlanmadı")) }
    }

    func testNetworkCancellationRemainsCancellation() async throws {
        OpenAIStubProtocol.handler = { _ in throw URLError(.cancelled) }
        do {
            _ = try await OpenAIService(apiKey: "test-key", session: session).summarize(meeting: Self.meeting)
            XCTFail("Cancelled request must fail")
        } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testLargeAudioIsCompressedCompletelyBeforeOneRequest() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let writer = try AVAssetWriter(outputURL: directory.appendingPathComponent("codec-check.m4a"), fileType: .m4a)
        guard writer.canApply(outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 48_000.0,
                                               AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 64_000], forMediaType: .audio) else {
            throw XCTSkip("This sandboxed test process cannot access the native AAC encoder. Full-duration compression needs native app QA.")
        }
        let source = directory.appendingPathComponent("original.wav")
        try Self.writeLargeSilentWAV(source)
        let originalSize = try XCTUnwrap(source.resourceValues(forKeys: [.fileSizeKey]).fileSize)
        XCTAssertGreaterThan(originalSize, 24_000_000)
        var calls = 0
        OpenAIStubProtocol.handler = { request in
            calls += 1
            let body = try Self.requestBody(request)
            let header = Data("Content-Type: audio/mp4\r\n\r\n".utf8)
            let range = try XCTUnwrap(body.range(of: header))
            let contentType = try XCTUnwrap(request.value(forHTTPHeaderField: "Content-Type"))
            let boundary = try XCTUnwrap(contentType.components(separatedBy: "boundary=").last)
            let tail = Data("\r\n--\(boundary)--\r\n".utf8)
            let end = try XCTUnwrap(body.range(of: tail, options: .backwards))
            let compressed = body.subdata(in: range.upperBound..<end.lowerBound)
            XCTAssertLessThan(compressed.count, 24_000_000)
            XCTAssertLessThan(compressed.count, 680_000, "AAC must actually honor the requested 64kbps bitrate")
            let check = directory.appendingPathComponent("received.m4a")
            try compressed.write(to: check)
            let file = try AVAudioFile(forReading: check)
            XCTAssertEqual(Double(file.length) / file.processingFormat.sampleRate, 70, accuracy: 0.1,
                           "The complete recording, not a prefix, must be uploaded")
            return (200, Data(#"{"segments":[{"id":"seg1","speaker":"A","start":0,"end":70,"text":"Test transcript"}]}"#.utf8))
        }
        let result = try await OpenAIService(apiKey: "test-key", session: session).transcribe(audioURL: source)
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(result.first?.end, 70)
        XCTAssertEqual(try source.resourceValues(forKeys: [.fileSizeKey]).fileSize, originalSize)
    }

    private static var meeting: Meeting {
        Meeting(title: "Accounting discussion", segments: [
            .init(id: "seg-a", speaker: "Konuşmacı A", start: 0, end: 4, text: "Remove the tenant expense button. We agreed to do this."),
            .init(id: "seg-b", speaker: "Konuşmacı B", start: 5, end: 9, text: "Stripe is one option we should investigate.")
        ])
    }

    private static func completion(_ notes: MeetingNotes) throws -> Data {
        let content = String(decoding: try JSONEncoder().encode(notes), as: UTF8.self)
        return try JSONSerialization.data(withJSONObject: ["choices": [["message": ["content": content, "refusal": NSNull()], "finish_reason": "stop"]]])
    }

    private static func requestBody(_ request: URLRequest) throws -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count < 0 { throw stream.streamError ?? URLError(.cannotDecodeContentData) }
            if count == 0 { break }
            data.append(buffer, count: count)
        }
        return data
    }

    private static func writeLargeSilentWAV(_ url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false))
        var settings = format.settings
        settings[AVLinearPCMIsNonInterleaved] = false
        let file = try AVAudioFile(forWriting: url, settings: settings)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48_000))
        buffer.frameLength = 48_000
        for channel in 0..<2 { memset(buffer.floatChannelData![channel], 0, 48_000 * MemoryLayout<Float>.size) }
        for _ in 0..<70 { try file.write(from: buffer) }
    }
}

private final class OpenAIStubProtocol: URLProtocol {
    static var handler: ((URLRequest) throws -> (Int, Data))?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        do {
            let (status, data) = try handler(request)
            let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: data)
            client?.urlProtocolDidFinishLoading(self)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
