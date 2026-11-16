import XCTest
@testable import MeetingDesk

final class WorkspaceDetailSnapshotTests: XCTestCase {
    private func meeting() -> Meeting {
        var meeting = Meeting(title: "Sentetik ayrıntılar")
        meeting.duration = 90
        meeting.segments = [
            .init(id: "mic", speaker: "system:A", start: 2, end: 4, text: "Mikrofon", audioSource: .microphone),
            .init(id: "sys", speaker: "system:B", start: 10, end: 14, text: "Sistem", audioSource: .system),
            .init(id: "mix", speaker: "system:C", start: 20, end: 21, text: "Karma", audioSource: .mixed)
        ]
        meeting.notes = MeetingNotes(summary: "Özet",
            decisions: [.init(id: "d", text: "Karar", evidence: ["sys", "mic", "mic"])],
            actions: [.init(id: "a", text: "Görev", owner: nil, due: nil, evidence: ["mix", "mic"])],
            questions: [], ideas: [], topics: [])
        return meeting
    }

    func testSnapshotPreservesParticipantsAndExcerptValidationAndSourceChecksAreOncePerChannel() {
        let value = meeting()
        var checks: [PlaybackSource: Int] = [:]
        let snapshot = WorkspaceDetailSnapshot.build(meeting: value) { source in
            checks[source, default: 0] += 1
            return true
        }
        XCTAssertEqual(snapshot.meetingID, value.id)
        XCTAssertEqual(snapshot.participants, WorkspaceParticipants.entries(in: value))
        XCTAssertEqual(snapshot.identifiedParticipantCount, snapshot.participants.filter(\.isIdentified).count)
        let ids = ["mix", "mic", "sys", "mic"]
        XCTAssertEqual(snapshot.excerpts(for: ids), EvidenceAudioPreview.excerpts(in: value, evidence: ids))
        XCTAssertEqual(checks, [.microphone: 1, .system: 1, .mixed: 1])
        for _ in 0..<20 { _ = snapshot.excerpts(for: ids) }
        XCTAssertEqual(checks, [.microphone: 1, .system: 1, .mixed: 1], "Drawing notes must not probe the filesystem again")
    }

    func testUnavailableSourceIsExcludedForEveryItemWithoutRepeatedChecks() {
        var value = meeting()
        value.segments.append(.init(id: "mic2", speaker: "system:A", start: 30, end: 33, text: "İkinci", audioSource: .microphone))
        value.notes?.ideas = [.init(id: "i", text: "Fikir", evidence: ["mic2", "mic"])]
        var checks: [PlaybackSource: Int] = [:]
        let snapshot = WorkspaceDetailSnapshot.build(meeting: value) { source in
            checks[source, default: 0] += 1
            return source != .microphone
        }
        XCTAssertEqual(snapshot.excerpts(for: ["mic", "sys", "mic2", "mix"]).map(\.segmentID), ["sys", "mix"])
        XCTAssertEqual(checks[.microphone], 1)
        XCTAssertNotNil(snapshot.segmentsByID["mic"], "Unavailable audio does not hide the text source")
    }

    func testDuplicateInvalidMissingAndUnreferencedEvidenceNeverGetsAnAudioExcerpt() {
        var value = meeting()
        value.segments.append(value.segments[0])
        value.segments.append(.init(id: "invalid", speaker: "system:A", start: .nan, end: 10, text: "Geçersiz"))
        value.segments.append(.init(id: "unreferenced", speaker: "system:A", start: 50, end: 53, text: "Not kaynağı değil"))
        value.notes?.questions = [.init(id: "q", text: "Soru", evidence: ["invalid", "missing"])]
        let snapshot = WorkspaceDetailSnapshot.build(meeting: value) { _ in true }
        XCTAssertTrue(snapshot.excerpts(for: ["mic", "invalid", "missing", "unreferenced"]).isEmpty)
        XCTAssertEqual(snapshot.segmentsByID["mic"], value.segments[0], "Text source keeps previous first-match semantics")
        XCTAssertNil(snapshot.segmentsByID["missing"])
    }

    func testUnreferencedTranscriptPreviewReusesAvailabilityAndRejectsStaleOrAmbiguousSegments() {
        var value = meeting()
        let unreferenced = TranscriptSegment(id: "other", speaker: "system:A", start: 40, end: 44, text: "Another source", audioSource: .system)
        value.segments.append(unreferenced)
        var checks = 0
        let snapshot = WorkspaceDetailSnapshot.build(meeting: value) { _ in checks += 1; return true }
        for _ in 0..<100 { XCTAssertTrue(snapshot.canPreview(unreferenced)) }
        XCTAssertEqual(checks, 3, "Playback redraws must not probe files or rebuild a full source index")
        var edited = unreferenced; edited.text = "Changed"
        XCTAssertFalse(snapshot.canPreview(edited))
        value.segments.append(unreferenced)
        XCTAssertFalse(WorkspaceDetailSnapshot.build(meeting: value) { _ in true }.canPreview(unreferenced))
        XCTAssertFalse(WorkspaceDetailSnapshot.build(meeting: meeting()) { _ in false }.canPreview(meeting().segments[0]))
    }

    func testActualMeetingChangesProduceFreshDataWithoutMutatingPriorSnapshot() {
        var value = meeting()
        let original = value
        let before = WorkspaceDetailSnapshot.build(meeting: value) { _ in true }
        let person = SpeakerReviewPerson(name: "Deniz")
        value.speakerReviewPeople = [person]
        value.speakerReviewAssignments = ["system:A": person.id]
        value.segments.removeAll { $0.id == "sys" }
        let after = WorkspaceDetailSnapshot.build(meeting: value) { _ in true }
        XCTAssertEqual(before.excerpts(for: ["sys"]).count, 1)
        XCTAssertTrue(after.excerpts(for: ["sys"]).isEmpty)
        XCTAssertEqual(after.identifiedParticipantCount, 1)
        XCTAssertEqual(after.participants.first?.name, "Deniz")
        XCTAssertEqual(before.participants, WorkspaceParticipants.entries(in: original))
        XCTAssertEqual(original.segments.count, 3)
    }
}
