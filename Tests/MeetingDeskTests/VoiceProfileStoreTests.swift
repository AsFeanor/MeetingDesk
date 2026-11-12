import XCTest
@testable import MeetingDesk

final class VoiceProfileStoreTests: XCTestCase {
    private var fixture: URL!

    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("voice-profiles-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixture { try FileManager.default.removeItem(at: fixture) }
    }

    private func person() -> VoiceProfile {
        VoiceProfile(name: "Onur", modelID: "campplus-v2", samples: [[1, 0]])
    }

    func testProfilesSurviveReloadAndExplicitDeletion() throws {
        let root = fixture.appendingPathComponent("voices", isDirectory: true)
        let store = VoiceProfileStore(root: root)
        XCTAssertEqual(try store.load(), [])
        let profile = person()
        try store.save([profile])
        XCTAssertEqual(try VoiceProfileStore(root: root).load(), [profile])
        try store.save([])
        XCTAssertEqual(try VoiceProfileStore(root: root).load(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["voice-profiles.json"])
    }

    func testPrivateFileAndNewDirectoryPermissions() throws {
        let root = fixture.appendingPathComponent("voices", isDirectory: true)
        let store = VoiceProfileStore(root: root)
        try store.save([person()])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.save([])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testDoesNotChangeAnExistingArchiveDirectoryPermissions() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        try VoiceProfileStore(root: fixture).save([person()])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
    }

    func testCorruptExistingArchiveIsPreservedEvenIfCallerTriesSavingEmptyList() throws {
        let store = VoiceProfileStore(root: fixture)
        let corrupt = Data("{broken private profile file".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testNewerSchemaAndInvalidStoredVectorsAreRejectedWithoutReplacement() throws {
        let store = VoiceProfileStore(root: fixture)
        try store.save([person()])
        let valid = try Data(contentsOf: store.fileURL)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: valid) as? [String: Any])
        object["version"] = 2
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([person()]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), newer)
        object["version"] = 1
        var rows = try XCTUnwrap(object["profiles"] as? [[String: Any]])
        rows[0]["samples"] = [[0.0, 0.0]]
        object["profiles"] = rows
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
    }

    func testInvalidNewProfilesCannotOverwriteValidStore() throws {
        let store = VoiceProfileStore(root: fixture)
        let profile = person()
        try store.save([profile])
        let before = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.save([profile, profile]))
        var malformed = profile
        malformed.samples = [[1, 0], [0, 0, 1]]
        XCTAssertThrowsError(try store.save([malformed]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), before)
    }

    func testSymbolicLinkCannotRedirectProfileWrites() throws {
        let target = fixture.appendingPathComponent("unrelated.json")
        let original = Data("keep".utf8)
        try original.write(to: target)
        let root = fixture.appendingPathComponent("profiles", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = VoiceProfileStore(root: root)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: target), original)
    }
}
