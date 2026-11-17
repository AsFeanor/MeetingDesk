import XCTest
@testable import MeetingDesk

/// Every fixture is a disposable temporary archive. No test calls macOS Trash.
final class MeetingDeletionTests: XCTestCase {
    func testWholeMeetingDirectoryMovesTogetherAndRestoresWithoutTouchingOtherArchives() throws {
        let root = temporaryRoot()
        let library = MeetingLibrary(root: root)
        let target = sampleMeeting(title: "Silinecek toplantı")
        let other = sampleMeeting(title: "Korunacak toplantı")
        try library.save(target); try library.save(other)
        try library.saveTranscriptVersion(target); try library.saveNotesVersion(target)
        let directory = library.directory(for: target.id)
        for name in ["recording.m4a", "recording-microphone.m4a", "recording-system.m4a", ".recording-recovery/recovery.json"] {
            let file = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic-\(name)".utf8).write(to: file)
        }
        let profiles = root.appendingPathComponent(".voice-profiles/profiles.json")
        try FileManager.default.createDirectory(at: profiles.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profileBytes = Data("global profiles stay outside the meeting directory".utf8)
        try profileBytes.write(to: profiles)
        let project = MeetingProject(name: "Yapay proje")
        let catalogStore = WorkspaceCatalogStore(root: root)
        let catalog = WorkspaceCatalog(projects: [project], series: [MeetingSeries(name: "Yapay seri", projectID: project.id)])
        try catalogStore.save(catalog)
        let catalogBytes = try Data(contentsOf: catalogStore.url)
        let targetBefore = try files(in: directory)
        let otherBefore = try files(in: library.directory(for: other.id))
        let fakeTrash = root.deletingLastPathComponent().appendingPathComponent("fake-trash", isDirectory: true)

        let receipt = try XCTUnwrap(library.moveMeetingToTrash(target, trashItem: fakeTrashMover(fakeTrash)))
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
        XCTAssertEqual(try files(in: receipt), targetBefore)
        XCTAssertEqual(try files(in: library.directory(for: other.id)), otherBefore)
        XCTAssertEqual(try Data(contentsOf: profiles), profileBytes)
        XCTAssertEqual(try Data(contentsOf: catalogStore.url), catalogBytes)
        XCTAssertEqual(try catalogStore.load(), catalog)
        XCTAssertEqual(try library.load().meetings, [other])

        try FileManager.default.moveItem(at: receipt, to: directory)
        XCTAssertEqual(try files(in: directory), targetBefore)
        XCTAssertEqual(Set(try library.load().meetings.map(\.id)), Set([target.id, other.id]))
    }

    func testStaleDiskSnapshotAndNoOpTrashAreRejected() throws {
        let library = MeetingLibrary(root: temporaryRoot())
        let original = sampleMeeting()
        try library.save(original)
        var changed = original; changed.personalNotes = "Dışarıdan kaydedilen yeni not"
        try library.save(changed)
        var calls = 0
        XCTAssertThrowsError(try library.moveMeetingToTrash(original, trashItem: { _ in calls += 1; return nil }))
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(try library.load().meetings, [changed])
        XCTAssertThrowsError(try library.moveMeetingToTrash(changed, trashItem: { _ in calls += 1; return nil }))
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(try library.load().meetings, [changed])
    }

    func testMeetingDirectoryAndMetadataSymlinksNeverAuthorizeTrash() throws {
        for metadataLink in [false, true] {
            let root = temporaryRoot()
            let library = MeetingLibrary(root: root)
            let meeting = sampleMeeting()
            try library.save(meeting)
            let directory = library.directory(for: meeting.id)
            let external = root.deletingLastPathComponent().appendingPathComponent("outside", isDirectory: true)
            try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
            let untouched = external.appendingPathComponent("must-stay.txt")
            try Data("outside-data".utf8).write(to: untouched)
            if metadataLink {
                let metadata = directory.appendingPathComponent("meeting.json")
                let externalMetadata = external.appendingPathComponent("meeting.json")
                try FileManager.default.moveItem(at: metadata, to: externalMetadata)
                try FileManager.default.createSymbolicLink(at: metadata, withDestinationURL: externalMetadata)
            } else {
                let moved = external.appendingPathComponent("meeting", isDirectory: true)
                try FileManager.default.moveItem(at: directory, to: moved)
                try FileManager.default.createSymbolicLink(at: directory, withDestinationURL: moved)
            }
            var calls = 0
            XCTAssertThrowsError(try library.moveMeetingToTrash(meeting, trashItem: { _ in calls += 1; return nil }))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try Data(contentsOf: untouched), Data("outside-data".utf8))
        }
    }

    func testTrashFailurePreservesSelectionPlaybackMeetingAndArchive() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let meeting = try seed(sampleMeeting(), in: store)
            store.playbackTime = 7; store.playbackDuration = 30; store.isPlaying = true
            let before = try files(in: root)
            XCTAssertFalse(store.moveMeetingToTrash(meeting.id, expectedMeeting: meeting, trashItem: { _ in throw TestFailure.denied }))
            XCTAssertEqual(store.meetings, [meeting]); XCTAssertEqual(store.selectedID, meeting.id)
            XCTAssertEqual(store.playbackTime, 7); XCTAssertEqual(store.playbackDuration, 30); XCTAssertTrue(store.isPlaying)
            XCTAssertEqual(try files(in: root), before)
            XCTAssertFalse(store.isDeletingMeeting)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testSelectedMeetingDisappearsOnlyAfterTrashAndCannotBeRecreatedDuringMove() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let first = try seed(sampleMeeting(title: "İlk"), in: store)
            let selected = try seed(sampleMeeting(title: "Silinecek"), in: store)
            let last = try seed(sampleMeeting(title: "Son"), in: store)
            store.selectedID = selected.id
            store.playbackTime = 7; store.playbackDuration = 30; store.isPlaying = true
            let mover = fakeTrashMover(root.deletingLastPathComponent().appendingPathComponent("fake-trash"))
            var calls = 0
            XCTAssertTrue(store.moveMeetingToTrash(selected.id, expectedMeeting: selected, trashItem: { url in
                calls += 1
                XCTAssertTrue(store.isDeletingMeeting); XCTAssertTrue(store.workInProgress)
                XCTAssertFalse(store.canMoveMeetingToTrash(first.id))
                XCTAssertEqual(store.selectedID, selected.id); XCTAssertTrue(store.meetings.contains(selected))
                XCTAssertTrue(store.isPlaying)
                XCTAssertFalse(store.update(selected.id) { $0.personalNotes = "Must not recreate the deleted directory" })
                return try mover(url)
            }))
            XCTAssertEqual(calls, 1)
            XCTAssertEqual(store.meetings.map(\.id), [first.id, last.id])
            XCTAssertEqual(store.selectedID, last.id)
            XCTAssertEqual(store.playbackTime, 0); XCTAssertEqual(store.playbackDuration, 0); XCTAssertFalse(store.isPlaying)
            XCTAssertFalse(store.isDeletingMeeting); XCTAssertFalse(store.workInProgress)
            XCTAssertEqual(Set(try store.library.load().meetings.map(\.id)), Set([first.id, last.id]))
        }
    }

    func testDeletingOtherMeetingPreservesCurrentSelectionAndPlaybackIndicators() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let selected = try seed(sampleMeeting(title: "Dinlenen"), in: store)
            let other = try seed(sampleMeeting(title: "Diğer"), in: store)
            store.selectedID = selected.id
            store.playbackTime = 9; store.playbackDuration = 40; store.isPlaying = true
            XCTAssertTrue(store.moveMeetingToTrash(other.id, expectedMeeting: other,
                trashItem: fakeTrashMover(root.deletingLastPathComponent().appendingPathComponent("fake-trash"))))
            XCTAssertEqual(store.selectedID, selected.id)
            XCTAssertEqual(store.playbackTime, 9); XCTAssertEqual(store.playbackDuration, 40); XCTAssertTrue(store.isPlaying)
            XCTAssertEqual(store.meetings, [selected])
        }
    }

    func testDeletingLastMeetingClearsSelection() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let meeting = try seed(sampleMeeting(), in: store)
            XCTAssertTrue(store.moveMeetingToTrash(meeting.id,
                trashItem: fakeTrashMover(root.deletingLastPathComponent().appendingPathComponent("fake-trash"))))
            XCTAssertTrue(store.meetings.isEmpty); XCTAssertNil(store.selectedID)
            XCTAssertEqual(try store.library.load().meetings, [])
        }
    }

    func testBusyMicrophoneAndOverlappingShareLeasesBlockDeletionWithoutCallingTrash() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let meeting = try seed(sampleMeeting(), in: store)
            var calls = 0
            let forbiddenMove: (URL) throws -> URL? = { _ in calls += 1; return nil }
            store.isBusy = true
            XCTAssertFalse(store.moveMeetingToTrash(meeting.id, trashItem: forbiddenMove))
            store.isBusy = false; store.showMicrophoneCheck = true
            XCTAssertFalse(store.moveMeetingToTrash(meeting.id, trashItem: forbiddenMove))
            store.showMicrophoneCheck = false
            let first = store.beginMeetingSharingSession(), second = store.beginMeetingSharingSession()
            XCTAssertFalse(store.moveMeetingToTrash(meeting.id, trashItem: forbiddenMove))
            store.endMeetingSharingSession(first); store.endMeetingSharingSession(first)
            XCTAssertFalse(store.canMoveMeetingToTrash(meeting.id))
            store.endMeetingSharingSession(second)
            XCTAssertTrue(store.canMoveMeetingToTrash(meeting.id))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try store.library.load().meetings, [meeting])
        }
    }

    func testChangedConfirmationAndAmbiguousIDCannotDeleteAnyDirectory() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let meeting = try seed(sampleMeeting(), in: store)
            XCTAssertTrue(store.update(meeting.id) { $0.title = "Yeni başlık" })
            let changed = try XCTUnwrap(store.selected)
            var calls = 0
            XCTAssertFalse(store.moveMeetingToTrash(meeting.id, expectedMeeting: meeting, trashItem: { _ in calls += 1; return nil }))
            store.meetings.append(changed)
            XCTAssertFalse(store.moveMeetingToTrash(meeting.id, trashItem: { _ in calls += 1; return nil }))
            XCTAssertEqual(calls, 0)
            XCTAssertEqual(try store.library.load().meetings, [changed])
        }
    }

    func testDeletedCarryoverSourcesBecomeUnavailableAndOriginalLinksRestoreWithTrash() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            var source = sampleMeeting(title: "Önceki")
            source.createdAt = Date(timeIntervalSince1970: 100)
            source.notes = MeetingNotes(summary: "Önceki iş", decisions: [], actions: [ActionItem(id: "a1", text: "Takip işini yap", owner: nil, due: nil, evidence: ["s1"])], questions: [], ideas: [], topics: [])
            source = try seed(source, in: store)
            var current = sampleMeeting(title: "Sonraki")
            current.createdAt = Date(timeIntervalSince1970: 200); current.previousMeetingID = source.id
            current = try seed(current, in: store)
            store.selectedID = current.id
            let remainingBefore = try files(in: store.library.directory(for: current.id))
            let trash = root.deletingLastPathComponent().appendingPathComponent("fake-trash")
            XCTAssertTrue(store.moveMeetingToTrash(source.id, trashItem: fakeTrashMover(trash)))
            let reminder = CarryoverActions.reminder(for: current, previousMeetingID: current.previousMeetingID,
                in: store.meetings, previousLinks: store.previousMeetingLinks)
            XCTAssertEqual(reminder.issue, .unavailableSource); XCTAssertTrue(reminder.tasks.isEmpty)
            XCTAssertEqual(store.selected?.previousMeetingID, source.id)
            XCTAssertEqual(try files(in: store.library.directory(for: current.id)), remainingBefore)
            XCTAssertTrue(GlobalWorkItems.snapshot(meetings: store.meetings, catalog: store.workspaceCatalog).rows.isEmpty)
            store.completeCarryoverAction(sourceMeetingID: source.id, actionID: "a1", in: current.id)
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.library.directory(for: source.id).path))

            try FileManager.default.moveItem(at: trash.appendingPathComponent(source.id.uuidString), to: store.library.directory(for: source.id))
            store.reload()
            let restoredCurrent = try XCTUnwrap(store.meetings.first { $0.id == current.id })
            let restored = CarryoverActions.reminder(for: restoredCurrent, previousMeetingID: restoredCurrent.previousMeetingID,
                in: store.meetings, previousLinks: store.previousMeetingLinks)
            XCTAssertEqual(restored.tasks.count, 1); XCTAssertEqual(restored.tasks.first?.sourceMeetingID, source.id)
        }
    }

    private func temporaryRoot() -> URL {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-DeletionTests-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: base) }
        return base.appendingPathComponent("archive", isDirectory: true)
    }

    private func sampleMeeting(title: String = "Örnek toplantı") -> Meeting {
        var meeting = Meeting(title: title)
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 5, text: "Tamamen yapay test konuşması.")]
        meeting.personalNotes = "Yapay kişisel not"
        return meeting
    }

    @MainActor @discardableResult private func seed(_ meeting: Meeting, in store: AppStore) throws -> Meeting {
        try store.library.save(meeting)
        store.meetings.append(meeting); store.selectedID = meeting.id
        return meeting
    }

    private func fakeTrashMover(_ destination: URL) -> (URL) throws -> URL? {
        { source in
            try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
            let moved = destination.appendingPathComponent(source.lastPathComponent, isDirectory: true)
            try FileManager.default.moveItem(at: source, to: moved)
            return moved
        }
    }

    private func files(in directory: URL) throws -> [String: Data] {
        guard let iterator = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil) else { return [:] }
        var result: [String: Data] = [:]
        for case let file as URL in iterator {
            guard try FileManager.default.attributesOfItem(atPath: file.path)[.type] as? FileAttributeType == .typeRegular else { continue }
            result[String(file.path.dropFirst(directory.path.count + 1))] = try Data(contentsOf: file)
        }
        return result
    }

    private enum TestFailure: Error { case denied }
}
