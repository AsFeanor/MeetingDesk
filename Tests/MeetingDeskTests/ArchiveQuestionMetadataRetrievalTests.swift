import XCTest
@testable import MeetingDesk

final class ArchiveQuestionMetadataRetrievalTests: XCTestCase {
    func testMiaLatestQuestionUsesTitleAndArchivedDateWithoutRequiringNameInsideTranscript() async throws {
        let old = meeting(title: "Mia haftalık", date: 100, text: "Eski öneri henüz kabul edilmedi.")
        let latest = meeting(title: "Mia haftalık", date: 200, text: "Kiracı depozitosu için banka kontrolü yapacağız.")
        let newerUnrelated = meeting(title: "Müşteri görüşmesi", date: 300, text: "Mia için eski bir örnekten söz ettik.")
        let index = ArchiveQuestionIndex()
        try await index.replace(meetings: [old, latest, newerUnrelated])
        for question in ["Mia ile en son ne konuştuk?", "Mia ile enson ne konuştuk?", "Mia ile son toplantıda ne konuştuk?", "What did we discuss in the latest Mia meeting?", "What did we last discuss with Mia?"] {
            let context = try await index.retrieve(question: question)
            XCTAssertEqual(context.sources.map(\.meetingID), [latest.id], question)
            XCTAssertEqual(context.sources[0].text, latest.segments[0].text)
            XCTAssertTrue(context.disclosure.contains("kayıt tarihine göre"))
            XCTAssertTrue(context.disclosure.contains("sınırlı bir seçki"))
        }
    }

    func testConfirmedParticipantMetadataCanFindMeetingButNeverRewritesItsEvidence() async throws {
        var meeting = meeting(title: "Haftalık ekip görüşmesi", date: 100, text: "Ödeme entegrasyonunu kontrol edeceğiz.")
        meeting.speakerNames = ["a": "Mia"]
        let index = ArchiveQuestionIndex()
        try await index.replace(meetings: [meeting])
        let context = try await index.retrieve(question: "Mia ile ne konuştuk?")
        XCTAssertEqual(context.sources.map(\.meetingID), [meeting.id])
        XCTAssertEqual(context.sources[0].text, "Ödeme entegrasyonunu kontrol edeceğiz.")
        XCTAssertFalse(context.sources[0].text.contains("Mia"))
    }

    func testLatestMetadataSelectionHonorsExplicitScope() async throws {
        let old = meeting(title: "Mia haftalık", date: 100, text: "Depozitoyu kontrol edeceğiz.")
        let latest = meeting(title: "Mia haftalık", date: 200, text: "Banka kontrolünü yapacağız.")
        let index = ArchiveQuestionIndex()
        try await index.replace(meetings: [old, latest])
        let scoped = try await index.retrieve(question: "Mia ile en son ne konuştuk?", meetingIDs: [old.id])
        XCTAssertEqual(scoped.sources.map(\.meetingID), [old.id])
        let empty = try await index.retrieve(question: "Mia ile en son ne konuştuk?", meetingIDs: [])
        XCTAssertTrue(empty.sources.isEmpty)
    }

    func testBroadMeetingQuestionSpreadsCompleteSourcesAcrossTimelineWithinCap() async throws {
        var meeting = meeting(title: "Mia haftalık", date: 100, text: "Başlangıç.")
        meeting.segments = (0..<100).map { .init(id: "source-\($0)", speaker: "a", start: Double($0), end: Double($0 + 1), text: "Özgün konuşma içeriği \($0).") }
        let index = ArchiveQuestionIndex()
        try await index.replace(meetings: [meeting])
        let context = try await index.retrieve(question: "Mia ile en son ne konuştuk?")
        XCTAssertEqual(context.sources.count, ArchiveQuestionIndex.maximumPassages)
        XCTAssertTrue(context.sources.contains { $0.segmentID == "source-0" })
        XCTAssertTrue(context.sources.contains { $0.segmentID == "source-99" })
        XCTAssertTrue(context.sources.contains { $0.start > 40 && $0.start < 60 })
        XCTAssertEqual(context.sources.map(\.start), context.sources.map(\.start).sorted())
        for source in context.sources { XCTAssertEqual(source.text, meeting.segments[Int(source.start)].text) }
        XCTAssertTrue(context.disclosure.contains("tamamını kapsamaz"))
    }

    private func meeting(title: String, date: TimeInterval, text: String) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.createdAt = Date(timeIntervalSince1970: date)
        meeting.segments = [.init(id: "source", speaker: "a", start: 0, end: 5, text: text)]
        return meeting
    }
}
