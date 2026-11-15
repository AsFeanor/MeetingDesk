import CryptoKit
import XCTest
@testable import MeetingDesk

/// Explicit local-only replay. No private paths or meeting content are fixtures.
final class TranscriptArchiveReplayTests: XCTestCase {
    func testReadOnlyProjectionOnExplicitLocalArchives() throws {
        let env = ProcessInfo.processInfo.environment
        guard let pathsJSON = env["MEETINGDESK_TRANSCRIPT_REPLAY_INPUTS"], let output = env["MEETINGDESK_TRANSCRIPT_REPLAY_OUTPUT"] else {
            throw XCTSkip("Optional read-only local transcript replay; no archives are accessed by default.")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(pathsJSON.utf8))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .deferredToDate
        var reports = [[String: Any]]()
        for path in paths {
            let url = URL(fileURLWithPath: path)
            let before = try Data(contentsOf: url)
            let meeting = try decoder.decode(Meeting.self, from: before)
            let projected = TranscriptEchoProjection.project(meeting.segments)
            var reading = meeting; reading.segments = projected.segments
            let blocks = TranscriptConversation.blocks(in: reading)
            let flattened = blocks.flatMap(\.segments)
            XCTAssertEqual(flattened, TranscriptConversation.orderedSegments(projected.segments))
            let allIDs = Set(meeting.segments.map(\.id))
            XCTAssertEqual(Set(flattened.map(\.id)).union(projected.hiddenSegmentIDs), allIDs)
            XCTAssertTrue(meeting.segments.filter { projected.hiddenSegmentIDs.contains($0.id) }.allSatisfy { SpeakerTranscriptAlignment.source(for: $0) == .microphone })
            let beforeSteps = zip(meeting.segments, meeting.segments.dropFirst()).filter { $1.start < $0.start }.count
            let afterSteps = zip(flattened, flattened.dropFirst()).filter { $1.start < $0.start }.count
            XCTAssertEqual(afterSteps, 0)
            XCTAssertEqual(try Data(contentsOf: url), before)
            reports.append(["archiveSHA256": SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined(),
                "originalSegments": meeting.segments.count, "originalBacksteps": beforeSteps,
                "hiddenDuplicateMicSegments": projected.hiddenSegmentIDs.count, "matchedMicWords": projected.matchedWordCount,
                "retainedSegments": flattened.count, "readingCards": blocks.count, "remainingBacksteps": afterSteps,
                "oneWordCardsBefore": meeting.segments.filter { $0.text.split(whereSeparator: \.isWhitespace).count <= 1 }.count,
                "oneWordCardsAfter": blocks.filter { $0.text.split(whereSeparator: \.isWhitespace).count <= 1 }.count,
                "identifiedPeople": SpeakerReviewQueue.identifiedGroups(in: meeting).count,
                "pendingReviewGroups": SpeakerReviewQueue.pendingSpeakerIDs(in: meeting).count,
                "archiveUnchanged": true, "originalContentRetained": true])
        }
        let url = URL(fileURLWithPath: output)
        try JSONSerialization.data(withJSONObject: ["networkUsed": false, "recordingsModified": false, "reports": reports], options: [.prettyPrinted, .sortedKeys]).write(to: url)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
