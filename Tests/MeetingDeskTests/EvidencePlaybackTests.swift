import XCTest
@testable import MeetingDesk

final class EvidencePlaybackTests: XCTestCase {
    @MainActor func testSilentEvidencePreviewStopsAndReleasesPlayerBeforeFileEnd() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("evidence-playback-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "evidence-playback-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: defaults)
        var meeting = store.newMeeting()
        meeting.duration = 5; meeting.audioFileName = "silent.wav"
        meeting.segments = [.init(id: "clip", speaker: "Ses", start: 1, end: 1.1, text: "Sentetik kaynak", audioSource: .mixed)]
        XCTAssertTrue(store.update(meeting.id) { $0 = meeting })
        try silentWAV(seconds: 5).write(to: try XCTUnwrap(store.library.audioURL(for: meeting)))
        let excerpt = try XCTUnwrap(store.availableEvidenceExcerpts(in: meeting, evidence: ["clip"]).first)
        XCTAssertEqual(excerpt.duration, 3, accuracy: 0.001)
        store.playEvidenceExcerpt(excerpt, meetingID: meeting.id)
        defer { store.stopPlayback() }
        guard store.isPlaying else { throw XCTSkip("This host cannot start local audio playback. Only synthetic digital silence was attempted.") }
        XCTAssertEqual(store.playingEvidenceID, excerpt.id)
        try await Task.sleep(for: .milliseconds(3300))
        XCTAssertFalse(store.isPlaying)
        XCTAssertNil(store.playingEvidenceID)
        XCTAssertEqual(store.playbackDuration, 0, "Automatic evidence completion releases the player so retention can proceed")
    }
    private func silentWAV(seconds: UInt32) -> Data {
        let bytes = seconds * 16000 * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + bytes); text("WAVEfmt "); u32(16); u16(1); u16(1); u32(16000); u32(32000); u16(2); u16(16)
        text("data"); u32(bytes); data.append(Data(repeating: 0, count: Int(bytes)))
        return data
    }
}
