import XCTest
@testable import MeetingDesk

/// Explicit opt-in only. Connects to the already-running private runtime; never boots a
/// runtime, pulls a model or reads the user's archive. Exactly three synthetic chat requests.
final class ArchiveQuestionLocalSmokeTests: XCTestCase {
    func testOptInLocalModelWithThreeSyntheticQuestions() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["MEETINGDESK_LOCAL_QA_CHECK"] == "1",
            "Set MEETINGDESK_LOCAL_QA_CHECK=1 only when the bundled local runtime is already running.")
        let fixtures = [
            Fixture(title: "Synthetic Turkish owner", text: "İpek ödeme entegrasyonunu cuma günü kontrol edecek.",
                question: "Ödeme entegrasyonunu kim kontrol edecek?"),
            Fixture(title: "Synthetic English decision", text: "We agreed to keep the customer portal read-only until the migration is finished.",
                question: "What did we decide about the customer portal?"),
            Fixture(title: "Synthetic missing budget", text: "Launch planning focused on color choices and page headings.",
                question: "What budget did we agree for the launch?")
        ]
        let answers = try await withThrowingTaskGroup(of: [ArchiveAnswer].self) { group in
            group.addTask {
                let service = OllamaSummaryService()
                var results: [ArchiveAnswer] = []
                for fixture in fixtures {
                    try Task.checkCancellation()
                    var meeting = Meeting(title: fixture.title)
                    meeting.createdAt = Date(timeIntervalSince1970: 1_800_000_000)
                    meeting.segments = [.init(id: "synthetic-source", speaker: "a", start: 12, end: 18, text: fixture.text)]
                    let index = ArchiveQuestionIndex()
                    try await index.replace(meetings: [meeting])
                    let context = try await index.retrieve(question: fixture.question)
                    guard !context.sources.isEmpty else { throw MeetingError.message("Synthetic smoke fixture retrieved no sources.") }
                    results.append(try await Self.complete(context: context, service: service))
                }
                return results
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 180_000_000_000)
                throw MeetingError.message("Local Q&A smoke check exceeded its three-minute total limit.")
            }
            defer { group.cancelAll() }
            guard let result = try await group.next() else { throw MeetingError.message("Local Q&A smoke check returned no result.") }
            return result
        }
        XCTAssertEqual(answers.count, 3)
        XCTAssertFalse(answers[0].abstained, "The explicitly named owner should be answerable.")
        XCTAssertTrue(answers[0].paragraphs.contains { $0.quote.contains("İpek") })
        XCTAssertFalse(answers[1].abstained, "The explicit portal decision should be answerable.")
        XCTAssertTrue(answers[1].paragraphs.contains { $0.quote.contains("read-only") })
        XCTAssertTrue(answers[2].abstained, "A missing launch budget must not be inferred.")
        XCTAssertTrue(answers[2].paragraphs.isEmpty)
        for (fixture, answer) in zip(fixtures, answers) {
            for paragraph in answer.paragraphs {
                XCTAssertTrue(fixture.text.contains(paragraph.quote))
                XCTAssertEqual(paragraph.source.segmentID, "synthetic-source")
                XCTAssertEqual(paragraph.source.start, 12)
            }
        }
    }

    /// An optional, separate test-only port keeps the live application's fixed
    /// listener untouched. The production request body and answer parser are used.
    private static func complete(context: ArchiveQuestionContext, service: OllamaSummaryService) async throws -> ArchiveAnswer {
        guard ProcessInfo.processInfo.environment["MEETINGDESK_LOCAL_QA_ISOLATED_RUNTIME"] == "1" else {
            return try await service.answerArchiveQuestion(context: context)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [:]
        configuration.httpCookieStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 150
        let session = URLSession(configuration: configuration, delegate: SmokeRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:11479/api/chat")!)
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body = try ArchiveQuestionPrompt.requestBody(context: context)
        // Optional bounded CPU smoke covers the same prompt/model/parser on hosts
        // where a tool-launched process cannot create a Metal context. This does
        // not change production settings or claim full-context/GPU acceptance.
        if ProcessInfo.processInfo.environment["MEETINGDESK_LOCAL_QA_CPU_CHECK"] == "1" {
            var options = try XCTUnwrap(body["options"] as? [String: Any])
            options["num_gpu"] = 0; options["num_ctx"] = 2_048
            options["num_thread"] = 2; options["num_predict"] = 512
            body["options"] = options
        }
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.url?.host == "127.0.0.1", http.url?.port == 11479 else { throw ArchiveQuestionFailure.invalidResponse }
        return try ArchiveQuestionPrompt.answer(from: data, context: context)
    }
    private final class SmokeRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private struct Fixture: Sendable {
        let title: String
        let text: String
        let question: String
    }
}
