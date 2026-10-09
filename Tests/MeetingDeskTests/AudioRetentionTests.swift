import XCTest
@testable import MeetingDesk

final class AudioRetentionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private let day: TimeInterval = 86_400

    func testPolicyDefaultsOffAndRejectsInvalidInitialAndDecodedDurations() throws {
        XCTAssertNil(AudioRetentionPolicy.disabled.days)
        for days in [1, 7, 3650] {
            XCTAssertEqual(try AudioRetentionPolicy(days: days).days, days)
            XCTAssertEqual(try JSONDecoder().decode(AudioRetentionPolicy.self, from: JSONEncoder().encode(AudioRetentionPolicy(days: days))).days, days)
        }
        for days in [0, -1, 3651, Int.max] {
            XCTAssertThrowsError(try AudioRetentionPolicy(days: days))
            XCTAssertThrowsError(try JSONDecoder().decode(AudioRetentionPolicy.self, from: Data("{\"days\":\(days)}".utf8)))
        }
        XCTAssertEqual(try JSONDecoder().decode(AudioRetentionPolicy.self, from: Data("{}".utf8)), .disabled)
    }

    func testOldMeetingArchivesDecodeWithoutRetentionMetadata() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Meeting(title: "Eski toplantı"))) as? [String: Any])
        object.removeValue(forKey: "audioSavedAt")
        object.removeValue(forKey: "audioDeletedAt")
        object.removeValue(forKey: "audioDeletionPending")
        let decoded = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(decoded.audioSavedAt)
        XCTAssertNil(decoded.audioDeletedAt)
        XCTAssertNil(decoded.audioDeletionPending)
    }

    func testDisabledPolicyDoesNotMoveAudioOrRewriteLegacyMetadata() throws {
        let fixture = try fixture(age: 90, legacy: true)
        let before = try Data(contentsOf: fixture.metadata)
        let mover = TestMover(trash: fixture.trash)
        let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: .disabled, now: now)
        XCTAssertEqual(result.updatedMeetings, [fixture.meeting])
        XCTAssertEqual(result.removedRecordingCount, 0)
        XCTAssertEqual(mover.moved, [])
        XCTAssertEqual(try Data(contentsOf: fixture.metadata), before)
    }

    func testExpiryStartsAtExactDurationAndDoesNotRoundByCalendarDay() throws {
        let fixture = try fixture(age: 7)
        let mover = TestMover(trash: fixture.trash)
        let retention = service(fixture, mover)
        let policy = try AudioRetentionPolicy(days: 7)
        let early = retention.cleanup(meetings: [fixture.meeting], policy: policy, now: now.addingTimeInterval(-1))
        XCTAssertEqual(early.removedRecordingCount, 0)
        XCTAssertEqual(mover.moved, [])
        let expired = retention.cleanup(meetings: early.updatedMeetings, policy: policy, now: now)
        XCTAssertEqual(expired.removedRecordingCount, 1)
        XCTAssertEqual(expired.updatedMeetings.first?.audioDeletedAt, now)
    }

    func testAllOwnedTracksMoveTogetherAndTextNotesHistoryAndUnrelatedFilesRemain() throws {
        let fixture = try fixture(age: 40)
        try fixture.library.saveNotesVersion(fixture.meeting)
        try fixture.library.saveTranscriptVersion(fixture.meeting)
        let protectedNames = ["transcript.txt", "notes.md", "personal.txt", "unrelated.m4a", "recording-extra.m4a"]
        for name in protectedNames { try Data(name.utf8).write(to: fixture.directory.appendingPathComponent(name)) }
        let notesHistory = try fixture.library.latestNotesVersion(for: fixture.meeting.id)
        let transcriptHistory = try fixture.library.latestTranscriptVersion(for: fixture.meeting.id)
        let mover = TestMover(trash: fixture.trash)
        let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        let current = try XCTUnwrap(result.updatedMeetings.first)
        XCTAssertEqual(result.removedRecordingCount, 1)
        XCTAssertEqual(result.movedFileCount, 3)
        XCTAssertEqual(Set(mover.moved.map(\.lastPathComponent)), Set(["recording.m4a", "recording-microphone.m4a", "recording-system.m4a"]))
        XCTAssertNil(current.audioFileName)
        XCTAssertNil(current.audioDeletionPending)
        XCTAssertEqual(current.audioDeletedAt, now)
        XCTAssertEqual(current.segments, fixture.meeting.segments)
        XCTAssertEqual(current.notes, fixture.meeting.notes)
        XCTAssertEqual(current.personalNotes, fixture.meeting.personalNotes)
        XCTAssertEqual(current.speakerNames, fixture.meeting.speakerNames)
        XCTAssertEqual(current.completedActions, fixture.meeting.completedActions)
        XCTAssertEqual(try fixture.library.load().meetings, [current])
        XCTAssertEqual(try fixture.library.latestNotesVersion(for: current.id), notesHistory)
        XCTAssertEqual(try fixture.library.latestTranscriptVersion(for: current.id), transcriptHistory)
        for name in protectedNames { XCTAssertEqual(try Data(contentsOf: fixture.directory.appendingPathComponent(name)), Data(name.utf8)) }
        let repeated = service(fixture, mover).cleanup(meetings: result.updatedMeetings, policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(repeated.removedRecordingCount, 0)
        XCTAssertEqual(mover.moved.count, 3)
    }

    func testLegacyMeetingRecordedLaterUsesNewestTrackDateAndPersistsBaseline() throws {
        let fixture = try fixture(age: 90, legacy: true)
        let recent = now.addingTimeInterval(-2 * day)
        try FileManager.default.setAttributes([.modificationDate: recent], ofItemAtPath: fixture.track("recording-system.m4a").path)
        let mover = TestMover(trash: fixture.trash)
        let retention = service(fixture, mover)
        let result = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(result.removedRecordingCount, 0)
        XCTAssertEqual(result.updatedMeetings.first?.audioSavedAt, recent)
        XCTAssertEqual(try fixture.library.load().meetings, result.updatedMeetings)
        XCTAssertEqual(mover.moved, [])
        let later = retention.cleanup(meetings: result.updatedMeetings, policy: try AudioRetentionPolicy(days: 30), now: recent.addingTimeInterval(30 * day))
        XCTAssertEqual(later.removedRecordingCount, 1)
    }

    func testImportedMovieRecordingAndItsKnownSidecarsAreSupported() throws {
        var fixture = try fixture(age: 40)
        try FileManager.default.moveItem(at: fixture.track("recording.m4a"), to: fixture.track("recording.mov"))
        fixture.meeting.audioFileName = "recording.mov"
        try fixture.library.save(fixture.meeting)
        let mover = TestMover(trash: fixture.trash)
        let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(result.removedRecordingCount, 1)
        XCTAssertTrue(mover.moved.contains { $0.lastPathComponent == "recording.mov" })
    }

    func testFutureCreationOrModificationDatesAreSkippedWithoutRewriting() throws {
        for changeCreation in [false, true] {
            var fixture = try fixture(age: 40)
            let future = now.addingTimeInterval(day)
            if changeCreation {
                fixture.meeting.createdAt = future
                try fixture.library.save(fixture.meeting)
            } else { try FileManager.default.setAttributes([.modificationDate: future], ofItemAtPath: fixture.track("recording-system.m4a").path) }
            let before = try Data(contentsOf: fixture.metadata)
            let mover = TestMover(trash: fixture.trash)
            let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
            XCTAssertEqual(result.removedRecordingCount, 0)
            XCTAssertEqual(mover.moved, [])
            XCTAssertEqual(try Data(contentsOf: fixture.metadata), before)
        }
    }

    func testProtectedMeetingAndRecoveryFolderBlockAllMovesAndMetadataChanges() throws {
        for recovery in [false, true] {
            let fixture = try fixture(age: 90, legacy: true)
            if recovery { try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent(".recording-recovery"), withIntermediateDirectories: false) }
            let before = try Data(contentsOf: fixture.metadata)
            let mover = TestMover(trash: fixture.trash)
            let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now,
                                                        protectedMeetingIDs: recovery ? [] : [fixture.meeting.id])
            XCTAssertEqual(result.removedRecordingCount, 0)
            XCTAssertEqual(mover.moved, [])
            XCTAssertEqual(try Data(contentsOf: fixture.metadata), before)
        }
    }

    func testMetadataFilenameTraversalAndUnknownAudioNamesCannotBeDeleted() throws {
        for name in ["meeting.json", "recording.json", "../recording.m4a", "recording.m4a/../meeting.json", "other.m4a", "recording-microphone.m4a", "recording.🦊"] {
            var fixture = try fixture(age: 40)
            fixture.meeting.audioFileName = name
            try fixture.library.save(fixture.meeting)
            let before = try Data(contentsOf: fixture.metadata)
            let mover = TestMover(trash: fixture.trash)
            let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
            XCTAssertEqual(result.removedRecordingCount, 0, name)
            XCTAssertEqual(mover.moved, [], name)
            XCTAssertEqual(try Data(contentsOf: fixture.metadata), before, name)
        }
    }

    func testUnreadableForeignAndStaleMetadataAreNotOverwritten() throws {
        for kind in ["unreadable", "foreign", "stale"] {
            let fixture = try fixture(age: 40)
            if kind == "unreadable" { try Data("broken json".utf8).write(to: fixture.metadata) }
            else {
                var saved = fixture.meeting
                if kind == "foreign" { saved.id = UUID() } else { saved.personalNotes = "New unsaved-in-cache note" }
                try JSONEncoder().encode(saved).write(to: fixture.metadata)
            }
            let before = try Data(contentsOf: fixture.metadata)
            let mover = TestMover(trash: fixture.trash)
            let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
            XCTAssertEqual(result.removedRecordingCount, 0)
            XCTAssertEqual(mover.moved, [])
            XCTAssertEqual(try Data(contentsOf: fixture.metadata), before)
        }
    }

    func testSymlinkRootAndUUIDDirectoryCannotEscapeManagedArchive() throws {
        for linkRoot in [true, false] {
            let fixture = try fixture(age: 40)
            let original = linkRoot ? fixture.library.root : fixture.directory
            let external = fixture.container.appendingPathComponent("outside")
            try FileManager.default.moveItem(at: original, to: external)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)
            let mover = TestMover(trash: fixture.trash)
            let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
            XCTAssertEqual(result.removedRecordingCount, 0)
            XCTAssertEqual(mover.moved, [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.track("recording.m4a").path))
        }
    }

    func testSymlinkMainSourceAndMetadataFilesAreRejectedBeforeAnyTrackMoves() throws {
        for name in ["recording.m4a", "recording-system.m4a", "meeting.json"] {
            let fixture = try fixture(age: 40)
            let original = fixture.directory.appendingPathComponent(name)
            let external = fixture.container.appendingPathComponent("external-\(name)")
            try FileManager.default.moveItem(at: original, to: external)
            try FileManager.default.createSymbolicLink(at: original, withDestinationURL: external)
            let bytes = try Data(contentsOf: external)
            let mover = TestMover(trash: fixture.trash)
            let result = service(fixture, mover).cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
            XCTAssertEqual(result.removedRecordingCount, 0)
            XCTAssertEqual(mover.moved, [])
            XCTAssertEqual(try Data(contentsOf: external), bytes)
        }
    }

    func testPartialMovePersistsPendingBaselineAndRetryCompletesOnlyRemainingFiles() throws {
        let fixture = try fixture(age: 40, legacy: true)
        let mover = TestMover(trash: fixture.trash)
        mover.failingName = "recording-microphone.m4a"
        let retention = service(fixture, mover)
        let first = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        let pending = try XCTUnwrap(first.updatedMeetings.first)
        XCTAssertEqual(first.removedRecordingCount, 0)
        XCTAssertEqual(first.failureMessages.count, 1)
        XCTAssertEqual(first.movedFileCount, 1)
        XCTAssertEqual(pending.audioFileName, "recording.m4a")
        XCTAssertEqual(pending.audioDeletionPending, true)
        XCTAssertEqual(pending.audioSavedAt, now.addingTimeInterval(-40 * day))
        XCTAssertNil(pending.audioDeletedAt)
        XCTAssertEqual(try fixture.library.load().meetings, [pending])
        mover.failingName = nil
        let retry = retention.cleanup(meetings: first.updatedMeetings, policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(retry.removedRecordingCount, 1)
        XCTAssertEqual(retry.movedFileCount, 2)
        XCTAssertTrue(retry.failureMessages.isEmpty)
        XCTAssertNil(retry.updatedMeetings.first?.audioFileName)
        XCTAssertEqual(mover.moved.count, 3)
    }

    func testBaselineOrPendingSaveFailurePreventsAnyMove() throws {
        for legacy in [false, true] {
            let fixture = try fixture(age: 40, legacy: legacy)
            let mover = TestMover(trash: fixture.trash)
            let retention = AudioRetentionService(library: fixture.library, trashItem: mover.move, saveMeeting: { _ in throw TestError.save })
            let result = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
            XCTAssertEqual(result.removedRecordingCount, 0)
            XCTAssertEqual(result.failureMessages.count, 1)
            XCTAssertEqual(mover.moved, [])
            XCTAssertEqual(result.updatedMeetings, [fixture.meeting])
            XCTAssertEqual(try fixture.library.load().meetings, [fixture.meeting])
        }
    }

    func testFinalSaveFailureKeepsPendingCacheEqualToDiskAndRetryFinishesMetadata() throws {
        let fixture = try fixture(age: 40)
        let mover = TestMover(trash: fixture.trash)
        let retention = AudioRetentionService(library: fixture.library, trashItem: mover.move, saveMeeting: { meeting in
            if meeting.audioFileName == nil { throw TestError.save }
            try fixture.library.save(meeting)
        })
        let first = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(first.removedRecordingCount, 0)
        XCTAssertEqual(first.movedFileCount, 3)
        XCTAssertEqual(first.failureMessages.count, 1)
        XCTAssertEqual(first.updatedMeetings.first?.audioDeletionPending, true)
        XCTAssertEqual(first.updatedMeetings.first?.audioFileName, "recording.m4a")
        XCTAssertEqual(try fixture.library.load().meetings, first.updatedMeetings)
        let retry = service(fixture, mover).cleanup(meetings: first.updatedMeetings, policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(retry.removedRecordingCount, 1)
        XCTAssertEqual(retry.movedFileCount, 0)
        XCTAssertNil(retry.updatedMeetings.first?.audioFileName)
        XCTAssertEqual(mover.moved.count, 3)
    }

    func testSaveFailureAfterAtomicWriteReflectsOnlyDurableMetadataAndStopsMoves() throws {
        let fixture = try fixture(age: 40, legacy: true)
        let mover = TestMover(trash: fixture.trash)
        let retention = AudioRetentionService(library: fixture.library, trashItem: mover.move, saveMeeting: { meeting in
            try fixture.library.save(meeting)
            throw TestError.save
        })
        let result = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(result.removedRecordingCount, 0)
        XCTAssertEqual(result.failureMessages.count, 1)
        XCTAssertEqual(mover.moved, [])
        XCTAssertEqual(try fixture.library.load().meetings, result.updatedMeetings)
        XCTAssertNotNil(result.updatedMeetings.first?.audioSavedAt)
    }

    func testConcurrentReplacementBeforeSecondMoveIsPreservedAndLeavesPendingMarker() throws {
        let fixture = try fixture(age: 40)
        let mover = TestMover(trash: fixture.trash)
        let replacement = Data("new recording bytes must survive".utf8)
        let retention = AudioRetentionService(library: fixture.library, trashItem: { url in
            let moved = try mover.move(url)
            if url.lastPathComponent == "recording.m4a" {
                try replacement.write(to: fixture.track("recording-microphone.m4a"), options: .atomic)
                try FileManager.default.setAttributes([.modificationDate: self.now], ofItemAtPath: fixture.track("recording-microphone.m4a").path)
            }
            return moved
        })
        let result = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(result.removedRecordingCount, 0)
        XCTAssertEqual(mover.moved.count, 1)
        XCTAssertEqual(try Data(contentsOf: fixture.track("recording-microphone.m4a")), replacement)
        XCTAssertEqual(result.updatedMeetings.first?.audioDeletionPending, true)
        XCTAssertEqual(try fixture.library.load().meetings, result.updatedMeetings)
        let retry = service(fixture, mover).cleanup(meetings: result.updatedMeetings, policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(retry.removedRecordingCount, 0)
        XCTAssertNil(retry.updatedMeetings.first?.audioDeletionPending)
        XCTAssertEqual(retry.updatedMeetings.first?.audioSavedAt, now)
        XCTAssertEqual(mover.moved.count, 1)
    }

    func testRecoveryAppearingDuringCleanupProtectsAllRemainingSources() throws {
        let fixture = try fixture(age: 40)
        let mover = TestMover(trash: fixture.trash)
        let retention = AudioRetentionService(library: fixture.library, trashItem: { url in
            let moved = try mover.move(url)
            try FileManager.default.createDirectory(at: fixture.directory.appendingPathComponent(".recording-recovery"), withIntermediateDirectories: false)
            return moved
        })
        let result = retention.cleanup(meetings: [fixture.meeting], policy: try AudioRetentionPolicy(days: 30), now: now)
        XCTAssertEqual(result.removedRecordingCount, 0)
        XCTAssertEqual(mover.moved.count, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.track("recording-microphone.m4a").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.track("recording-system.m4a").path))
        XCTAssertEqual(try fixture.library.load().meetings, result.updatedMeetings)
    }

    private func service(_ fixture: Fixture, _ mover: TestMover) -> AudioRetentionService {
        AudioRetentionService(library: fixture.library, trashItem: mover.move)
    }

    private func fixture(age: Double, legacy: Bool = false) throws -> Fixture {
        let container = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-AudioRetention-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: container) }
        let library = MeetingLibrary(root: container.appendingPathComponent("archive"))
        let trash = container.appendingPathComponent("synthetic-trash")
        try FileManager.default.createDirectory(at: trash, withIntermediateDirectories: true)
        var meeting = Meeting(title: "Sentetik toplantı")
        meeting.createdAt = now.addingTimeInterval(-max(age, 90) * day)
        meeting.audioFileName = "recording.m4a"
        meeting.audioSavedAt = legacy ? nil : now.addingTimeInterval(-age * day)
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 3, text: "Bu sentetik bir testtir.")]
        meeting.notes = MeetingNotes(summary: "Korunan özet", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        meeting.personalNotes = "Korunan özel not"
        meeting.speakerNames = ["A": "Konuşmacı"]
        meeting.completedActions = ["a1"]
        try library.save(meeting)
        let fixture = Fixture(container: container, library: library, trash: trash, meeting: meeting)
        for name in ["recording.m4a", "recording-microphone.m4a", "recording-system.m4a"] {
            try Data(name.utf8).write(to: fixture.track(name))
            try FileManager.default.setAttributes([.modificationDate: now.addingTimeInterval(-age * day)], ofItemAtPath: fixture.track(name).path)
        }
        return fixture
    }

    private struct Fixture {
        var container: URL
        var library: MeetingLibrary
        var trash: URL
        var meeting: Meeting
        var directory: URL { library.directory(for: meeting.id) }
        var metadata: URL { directory.appendingPathComponent("meeting.json") }
        func track(_ name: String) -> URL { directory.appendingPathComponent(name) }
    }

    private final class TestMover {
        let trash: URL
        var moved: [URL] = []
        var failingName: String?
        init(trash: URL) { self.trash = trash }
        func move(_ file: URL) throws -> URL? {
            if file.lastPathComponent == failingName { throw TestError.move }
            let target = trash.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
            try FileManager.default.moveItem(at: file, to: target)
            moved.append(file)
            return target
        }
    }
    private enum TestError: Error { case move, save }
}
