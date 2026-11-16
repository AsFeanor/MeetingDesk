import XCTest
@testable import MeetingDesk

final class WorkspaceCatalogTests: XCTestCase {
    private func temporary() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-Organization-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testMissingCatalogDoesNotCreateFilesAndAtomicSaveIsPrivateAndIsolated() throws {
        let root = temporary(), other = temporary()
        let store = WorkspaceCatalogStore(root: root)
        XCTAssertEqual(try store.load(), WorkspaceCatalog())
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        let project = MeetingProject(name: "Ürün")
        let series = MeetingSeries(name: "Haftalık", projectID: project.id)
        let catalog = WorkspaceCatalog(projects: [project], series: [series])
        try store.save(catalog, replacing: WorkspaceCatalog())
        XCTAssertEqual(try store.load(), catalog)
        XCTAssertEqual(try WorkspaceCatalogStore(root: other).load(), WorkspaceCatalog())
        let attributes = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [".workspace-catalog.json"])
        var renamed = catalog; renamed.projects[0].name = "Yeni ad"
        try store.save(renamed, replacing: catalog)
        XCTAssertEqual(try store.load(), renamed)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.url.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCorruptAndExternallyChangedCatalogsArePreserved() throws {
        let store = WorkspaceCatalogStore(root: temporary())
        let initial = WorkspaceCatalog(projects: [.init(name: "İlk")])
        try store.save(initial)
        let changed = WorkspaceCatalog(projects: [.init(name: "Dışarıdan")])
        try store.save(changed)
        XCTAssertThrowsError(try store.save(initial, replacing: initial))
        XCTAssertEqual(try store.load(), changed)
        let bad = Data("not-json".utf8)
        try bad.write(to: store.url)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save(initial))
        XCTAssertEqual(try Data(contentsOf: store.url), bad)
    }

    func testInvalidUUIDRelationshipsAndNamesAreRejectedButNamesDoNotDefineIdentity() throws {
        let first = MeetingProject(name: "Aynı ad"), second = MeetingProject(name: "Aynı ad")
        XCTAssertNotEqual(first.id, second.id)
        XCTAssertNoThrow(try WorkspaceCatalog(projects: [first, second]).validate())
        XCTAssertThrowsError(try WorkspaceCatalog(projects: [first, first]).validate())
        XCTAssertThrowsError(try WorkspaceCatalog(series: [.init(name: "Seri", projectID: UUID())]).validate())
        XCTAssertThrowsError(try WorkspaceCatalog.cleanName("   \n"))
        XCTAssertThrowsError(try WorkspaceCatalog.cleanName(String(repeating: "x", count: 121)))
        XCTAssertEqual(try WorkspaceCatalog.cleanName("  Ürün  "), "Ürün")
    }

    func testOldArchiveWithoutMembershipStillDecodes() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(Meeting(title: "Eski toplantı"))) as? [String: Any])
        object.removeValue(forKey: "projectID"); object.removeValue(forKey: "seriesID")
        let reopened = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(reopened.projectID); XCTAssertNil(reopened.seriesID)
        XCTAssertEqual(reopened.title, "Eski toplantı")
    }

    @MainActor func testExplicitMembershipPersistsAndDeletionRequiresDetach() throws {
        let root = temporary()
        let store = AppStore(root: root, initializeSystemServices: false)
        let first = try XCTUnwrap(store.createProject(name: "Aynı ad"))
        let second = try XCTUnwrap(store.createProject(name: "Aynı ad"))
        let series = try XCTUnwrap(store.createSeries(name: "Haftalık", projectID: first))
        let meeting = store.newMeeting(), unrelated = store.newMeeting()
        XCTAssertFalse(store.assignMeeting(meeting.id, projectID: second, seriesID: series))
        XCTAssertFalse(store.assignMeeting(meeting.id, projectID: UUID(), seriesID: nil))
        XCTAssertTrue(store.assignMeeting(meeting.id, projectID: first, seriesID: series))
        XCTAssertFalse(store.deleteSeries(id: series))
        XCTAssertFalse(store.deleteProject(id: first))
        let reopened = AppStore(root: root, initializeSystemServices: false)
        XCTAssertEqual(reopened.workspaceCatalog, store.workspaceCatalog)
        XCTAssertEqual(reopened.meetings.first { $0.id == meeting.id }?.projectID, first)
        XCTAssertEqual(reopened.meetings.first { $0.id == meeting.id }?.seriesID, series)
        XCTAssertNil(reopened.meetings.first { $0.id == unrelated.id }?.projectID)
        XCTAssertTrue(store.assignMeeting(meeting.id, projectID: nil, seriesID: nil))
        XCTAssertTrue(store.deleteSeries(id: series))
        XCTAssertTrue(store.deleteProject(id: first))
        XCTAssertTrue(store.workspaceCatalog.projects.contains { $0.id == second })
        XCTAssertNil(try store.library.load().meetings.first { $0.id == meeting.id }?.projectID)
    }

    @MainActor func testBusyWorkAndFailedSaveDoNotChangeMembershipOrCatalog() throws {
        let store = AppStore(root: temporary(), initializeSystemServices: false)
        let project = try XCTUnwrap(store.createProject(name: "Ürün"))
        let meeting = store.newMeeting()
        store.isBusy = true
        XCTAssertNil(store.createProject(name: "Bekle"))
        XCTAssertFalse(store.assignMeeting(meeting.id, projectID: project, seriesID: nil))
        XCTAssertFalse(store.renameProject(id: project, name: "Bekle"))
        store.isBusy = false
        let file = store.library.directory(for: meeting.id).appendingPathComponent("meeting.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertFalse(store.assignMeeting(meeting.id, projectID: project, seriesID: nil))
        XCTAssertNil(store.meetings.first { $0.id == meeting.id }?.projectID)
        let catalogFile = WorkspaceCatalogStore(root: store.library.root).url
        try Data("corrupt".utf8).write(to: catalogFile)
        XCTAssertFalse(store.renameProject(id: project, name: "Başka"))
        XCTAssertEqual(store.workspaceCatalog.projects.first?.name, "Ürün")
        XCTAssertEqual(try String(contentsOf: catalogFile, encoding: .utf8), "corrupt")
    }

    @MainActor func testStaleAssignmentSnapshotCannotOverwriteNewerProjectOrSeriesMembership() throws {
        let store = AppStore(root: temporary(), initializeSystemServices: false)
        let first = try XCTUnwrap(store.createProject(name: "İlk"))
        let second = try XCTUnwrap(store.createProject(name: "İkinci"))
        let firstSeries = try XCTUnwrap(store.createSeries(name: "Birinci seri", projectID: first))
        let secondSeries = try XCTUnwrap(store.createSeries(name: "İkinci seri", projectID: first))
        let meeting = store.newMeeting()
        let unassignedSnapshot = MeetingOrganizationMembership(meeting: meeting)
        XCTAssertTrue(store.assignMeeting(meeting.id, projectID: first, seriesID: firstSeries, expectedMembership: unassignedSnapshot))
        XCTAssertFalse(store.assignMeeting(meeting.id, projectID: second, seriesID: nil, expectedMembership: unassignedSnapshot))
        let assigned = try XCTUnwrap(store.meetings.first { $0.id == meeting.id })
        XCTAssertEqual(assigned.projectID, first); XCTAssertEqual(assigned.seriesID, firstSeries)
        let seriesSnapshot = MeetingOrganizationMembership(meeting: assigned)
        XCTAssertTrue(store.assignMeeting(meeting.id, projectID: first, seriesID: secondSeries, expectedMembership: seriesSnapshot))
        XCTAssertFalse(store.assignMeeting(meeting.id, projectID: first, seriesID: nil, expectedMembership: seriesSnapshot))
        let persisted = try XCTUnwrap(store.library.load().meetings.first { $0.id == meeting.id })
        XCTAssertEqual(persisted.projectID, first); XCTAssertEqual(persisted.seriesID, secondSeries)
        XCTAssertNotNil(store.errorMessage)
    }

    @MainActor func testRestoringTranscriptPreservesCurrentMembership() throws {
        let store = AppStore(root: temporary(), initializeSystemServices: false)
        let project = try XCTUnwrap(store.createProject(name: "Ürün"))
        let meeting = store.newMeeting()
        try store.library.saveTranscriptVersion(meeting)
        XCTAssertTrue(store.assignMeeting(meeting.id, projectID: project, seriesID: nil))
        store.restorePreviousTranscript()
        XCTAssertEqual(store.selected?.projectID, project)
        XCTAssertEqual(try store.library.load().meetings.first?.projectID, project)
    }
}
