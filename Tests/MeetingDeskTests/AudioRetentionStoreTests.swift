import XCTest
@testable import MeetingDesk

@MainActor
final class AudioRetentionStoreTests: XCTestCase {
    private let policyKey = "meetingdesk.audioRetentionPolicy"
    private let now = Date(timeIntervalSince1970: 1_700_000_000)

    func testNewAndMalformedPreferencesLeaveAutomaticDeletionDisabled() throws {
        for invalid: Data? in [nil, Data("broken".utf8), Data("{\"days\":0}".utf8),
                               Data("{\"days\":3651}".utf8), Data("{\"days\":\"7\"}".utf8)] {
            let fixture = try makeFixture()
            if let invalid { fixture.defaults.set(invalid, forKey: policyKey) }
            let store = makeStore(fixture)
            let before = try fixture.library.load().meetings
            XCTAssertEqual(store.audioRetentionPolicy, .disabled)
            store.runAudioRetentionCleanup(now: now, force: true)
            XCTAssertEqual(store.meetings, before)
            XCTAssertEqual(try fixture.library.load().meetings, before)
            XCTAssertEqual(fixture.trash.calls, [])
            XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.audioFiles[0].path))
            XCTAssertFalse(store.workInProgress)
        }
    }

    func testCustomPolicyIsPersistedInIsolatedDefaultsAndReloadedWithoutAutomaticCleanup() throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let custom = try AudioRetentionPolicy(days: 37)
        store.setAudioRetentionPolicy(custom)
        XCTAssertEqual(store.audioRetentionPolicy, custom)
        let encoded = try XCTUnwrap(fixture.defaults.data(forKey: policyKey))
        XCTAssertEqual(try JSONDecoder().decode(AudioRetentionPolicy.self, from: encoded), custom)
        XCTAssertTrue(fixture.trash.calls.isEmpty)
        let reloaded = makeStore(fixture)
        XCTAssertEqual(reloaded.audioRetentionPolicy, custom)
        XCTAssertEqual(reloaded.meetings, store.meetings)
        XCTAssertTrue(fixture.trash.calls.isEmpty)
        reloaded.setAudioRetentionPolicy(.disabled)
        XCTAssertEqual(reloaded.audioRetentionPolicy, .disabled)
        XCTAssertEqual(makeStore(fixture).audioRetentionPolicy, .disabled)
        reloaded.runAudioRetentionCleanup(now: now, force: true)
        XCTAssertTrue(fixture.trash.calls.isEmpty)
    }

    func testBusyMicrophoneCheckAndPlaybackDeferCleanupThenIdleCleanupPreservesTextAndMetadata() throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        store.setAudioRetentionPolicy(try AudioRetentionPolicy(days: 7))
        let original = try XCTUnwrap(store.selected)
        let originalArchive = try archiveBytes(fixture.library.directory(for: original.id))
        let policyData = fixture.defaults.data(forKey: policyKey)
        for gate in 0..<3 {
            store.isBusy = gate == 0
            store.showMicrophoneCheck = gate == 1
            store.isPlaying = gate == 2
            store.runAudioRetentionCleanup(now: now, force: true)
            XCTAssertEqual(store.selected, original, "gate \(gate)")
            XCTAssertEqual(try fixture.library.load().meetings, [original], "gate \(gate)")
            XCTAssertEqual(try archiveBytes(fixture.library.directory(for: original.id)), originalArchive, "gate \(gate)")
            XCTAssertTrue(fixture.trash.calls.isEmpty, "gate \(gate)")
            // Changing the policy while processing or checking a microphone is rejected.
            if gate < 2 {
                store.setAudioRetentionPolicy(try AudioRetentionPolicy(days: 30))
                XCTAssertEqual(store.audioRetentionPolicy.days, 7)
                XCTAssertEqual(fixture.defaults.data(forKey: policyKey), policyData)
            }
        }
        store.isBusy = false
        store.showMicrophoneCheck = false
        store.isPlaying = false
        // A deferred pass is retried without requiring the force flag.
        store.runAudioRetentionCleanup(now: now)
        var expected = original
        expected.audioFileName = nil
        expected.audioDeletedAt = now
        expected.audioDeletionPending = nil
        XCTAssertEqual(store.selected, expected)
        XCTAssertEqual(try fixture.library.load().meetings, [expected])
        XCTAssertEqual(store.selectedID, original.id)
        XCTAssertEqual(Set(fixture.trash.calls.map(\.lastPathComponent)),
                       Set(["recording.m4a", "recording-microphone.m4a", "recording-system.m4a"]))
        for file in fixture.audioFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        XCTAssertFalse(store.workInProgress)
        XCTAssertNil(store.errorMessage)
        XCTAssertTrue(try XCTUnwrap(store.audioRetentionStatus).contains("Transkript ve özetler korundu"))
    }

    func testHistoryRestorationAfterExpiryNeverResurrectsAudioOrDropsPersonalAndReviewDetails() throws {
        let fixture = try makeFixture()
        let store = makeStore(fixture)
        let original = try XCTUnwrap(store.selected)
        try fixture.library.saveTranscriptVersion(original)
        try fixture.library.saveNotesVersion(original)
        let transcriptFolder = fixture.library.directory(for: original.id).appendingPathComponent(".transcript-history")
        let notesFolder = fixture.library.directory(for: original.id).appendingPathComponent(".notes-history")
        let transcriptBefore = try archiveBytes(transcriptFolder)
        let notesBefore = try archiveBytes(notesFolder)
        store.setAudioRetentionPolicy(try AudioRetentionPolicy(days: 7))
        store.runAudioRetentionCleanup(now: now, force: true)
        let expired = try XCTUnwrap(store.selected)
        XCTAssertNil(expired.audioFileName)
        XCTAssertEqual(expired.audioDeletedAt, now)
        XCTAssertEqual(expired.reviewedAt, original.reviewedAt)
        XCTAssertEqual(expired.personalNotes, original.personalNotes)
        XCTAssertEqual(expired.segments, original.segments)
        XCTAssertEqual(expired.notes, original.notes)
        XCTAssertEqual(try archiveBytes(transcriptFolder), transcriptBefore)
        XCTAssertEqual(try archiveBytes(notesFolder), notesBefore)
        XCTAssertEqual(try fixture.library.latestTranscriptVersion(for: original.id)?.audioFileName, "recording.m4a")

        store.restorePreviousNotes()
        XCTAssertEqual(store.selected, expired)
        store.restorePreviousTranscript()
        XCTAssertEqual(store.selected, expired)
        XCTAssertEqual(try fixture.library.load().meetings, [expired])
        for file in fixture.audioFiles { XCTAssertFalse(FileManager.default.fileExists(atPath: file.path)) }
        let transcriptAfter = try archiveBytes(transcriptFolder)
        let notesAfter = try archiveBytes(notesFolder)
        for (name, bytes) in transcriptBefore { XCTAssertEqual(transcriptAfter[name], bytes) }
        for (name, bytes) in notesBefore { XCTAssertEqual(notesAfter[name], bytes) }
        XCTAssertEqual(fixture.trash.calls.count, 3)
    }

    func testFreshAudioInAnOldMeetingIsNotExpired() throws {
        let fixture = try makeFixture(savedAt: now.addingTimeInterval(-3_600))
        let store = makeStore(fixture)
        let original = try XCTUnwrap(store.selected)
        XCTAssertGreaterThan(now.timeIntervalSince(original.createdAt), 300 * 86_400)
        store.setAudioRetentionPolicy(try AudioRetentionPolicy(days: 7))
        store.runAudioRetentionCleanup(now: now, force: true)
        XCTAssertEqual(store.selected, original)
        XCTAssertEqual(try fixture.library.load().meetings, [original])
        XCTAssertTrue(fixture.trash.calls.isEmpty)
        for file in fixture.audioFiles { XCTAssertTrue(FileManager.default.fileExists(atPath: file.path)) }
    }

    func testPausedAudioPlayerDefersCleanupUntilItsHandleIsReleased() throws {
        let fixture = try makeFixture(wave: true)
        let store = makeStore(fixture)
        store.setAudioRetentionPolicy(try AudioRetentionPolicy(days: 7))
        let original = try XCTUnwrap(store.selected)
        store.seek(0.5) // Allocates a real player for synthetic PCM without starting playback.
        XCTAssertNil(store.errorMessage)
        XCTAssertGreaterThan(store.playbackDuration, 0)
        XCTAssertFalse(store.isPlaying)
        store.runAudioRetentionCleanup(now: now, force: true)
        XCTAssertEqual(store.selected, original)
        XCTAssertTrue(fixture.trash.calls.isEmpty)
        store.stopPlayback()
        store.runAudioRetentionCleanup(now: now)
        XCTAssertNil(store.selected?.audioFileName)
        XCTAssertEqual(store.selected?.audioDeletedAt, now)
        XCTAssertEqual(fixture.trash.calls.map(\.lastPathComponent), ["recording.wav"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.audioFiles[0].path))
    }

    private struct Fixture {
        let library: MeetingLibrary
        let defaults: UserDefaults
        let trash: SandboxedTrash
        let audioFiles: [URL]
    }

    private func makeFixture(savedAt: Date? = nil, wave: Bool = false) throws -> Fixture {
        let sandbox = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-AudioRetentionStore-\(UUID())")
        let library = MeetingLibrary(root: sandbox.appendingPathComponent("archive", isDirectory: true))
        let trash = SandboxedTrash(root: sandbox.appendingPathComponent("fake-trash", isDirectory: true))
        let suite = "MeetingDesk.AudioRetentionStoreTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: sandbox)
        }
        let date = savedAt ?? now.addingTimeInterval(-30 * 86_400)
        var meeting = Meeting(title: "Sentetik saklama testi")
        meeting.createdAt = now.addingTimeInterval(-400 * 86_400)
        meeting.audioFileName = wave ? "recording.wav" : "recording.m4a"
        meeting.audioSavedAt = date
        meeting.duration = 42
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 1, end: 2, text: "Sentetik kaynak metni")]
        meeting.notes = MeetingNotes(summary: "Korunacak sentetik özet", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        meeting.personalNotes = "Korunacak özel not"
        meeting.speakerNames = ["A": "Sentetik konuşmacı"]
        meeting.reviewedAt = now.addingTimeInterval(-2 * 86_400)
        meeting.templateRawValue = MeetingTemplate.team.rawValue
        meeting.notesTemplateRawValue = MeetingTemplate.team.rawValue
        meeting.notesNeedRefresh = false
        meeting.transcriptSourceSeparated = true
        meeting.microphoneDeviceID = "synthetic-input"
        meeting.microphoneDeviceName = "Sentetik mikrofon"
        meeting.microphoneGain = 2
        try library.save(meeting)
        let directory = library.directory(for: meeting.id)
        let names = wave ? ["recording.wav"] : ["recording.m4a", "recording-microphone.m4a", "recording-system.m4a"]
        let files = names.map { directory.appendingPathComponent($0) }
        for (index, file) in files.enumerated() {
            try (wave ? syntheticWave() : Data([UInt8(index), 1, 2, 3])).write(to: file)
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: file.path)
        }
        return Fixture(library: library, defaults: defaults, trash: trash, audioFiles: files)
    }

    private func makeStore(_ fixture: Fixture) -> AppStore {
        let service = AudioRetentionService(library: fixture.library, trashItem: { file in try fixture.trash.move(file) })
        return AppStore(root: fixture.library.root, initializeSystemServices: false,
                        audioRetentionDefaults: fixture.defaults, audioRetentionService: service)
    }

    private func archiveBytes(_ folder: URL) throws -> [String: Data] {
        guard let enumerator = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey]) else { return [:] }
        var result: [String: Data] = [:]
        for case let file as URL in enumerator {
            if try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
                let relative = String(file.path.dropFirst(folder.path.count + 1))
                result[relative] = try Data(contentsOf: file)
            }
        }
        return result
    }

    private func syntheticWave() -> Data {
        // A one-second, mono, silent PCM fixture; no device recording is performed.
        let sampleRate: UInt32 = 8_000
        let sampleBytes: UInt32 = sampleRate * 2
        var data = Data("RIFF".utf8)
        func littleEndian<T: FixedWidthInteger>(_ value: T) {
            var value = value.littleEndian
            withUnsafeBytes(of: &value) { data.append(contentsOf: $0) }
        }
        littleEndian(UInt32(36) + sampleBytes)
        data.append(Data("WAVEfmt ".utf8))
        littleEndian(UInt32(16)); littleEndian(UInt16(1)); littleEndian(UInt16(1))
        littleEndian(sampleRate); littleEndian(sampleRate * 2)
        littleEndian(UInt16(2)); littleEndian(UInt16(16))
        data.append(Data("data".utf8)); littleEndian(sampleBytes)
        data.append(Data(count: Int(sampleBytes)))
        return data
    }
}

private final class SandboxedTrash {
    let root: URL
    var calls: [URL] = []
    init(root: URL) { self.root = root }
    func move(_ file: URL) throws -> URL? {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let destination = root.appendingPathComponent(UUID().uuidString + "-" + file.lastPathComponent)
        try FileManager.default.moveItem(at: file, to: destination)
        calls.append(file)
        return destination
    }
}
