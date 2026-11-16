import Foundation
import XCTest
@testable import MeetingDesk

final class GlossaryStoreTests: XCTestCase {
    private var fixture: URL!
    override func setUpWithError() throws {
        fixture = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: fixture, withIntermediateDirectories: true)
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: fixture) }
    private var entry: GlossaryEntry { GlossaryEntry(canonical: "Lifesycle", variants: ["life cycle"]) }

    func testMissingDictionaryIsBackwardCompatibleAndRoundTripsDeletion() throws {
        let store = GlossaryStore(root: fixture)
        XCTAssertEqual(try store.load(), [])
        let value = entry
        try store.save([value])
        XCTAssertEqual(try GlossaryStore(root: fixture).load(), [value])
        try store.save([])
        XCTAssertEqual(try store.load(), [])
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.path), [".transcript-glossary.json"])
    }

    func testNewDirectoryAndAtomicReplacementsUsePrivatePermissions() throws {
        let root = fixture.appendingPathComponent("isolated", isDirectory: true)
        let store = GlossaryStore(root: root)
        try store.save([entry])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: root.path)[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        try store.save([])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: store.fileURL.path)[.posixPermissions] as? NSNumber)?.intValue, 0o600)
    }

    func testCallerRootIsIsolatedAndExistingDirectoryPermissionsStayUntouched() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path)
        let first = GlossaryStore(root: fixture), second = GlossaryStore(root: fixture.appendingPathComponent("other"))
        try first.save([entry])
        XCTAssertEqual(try second.load(), [])
        XCTAssertEqual((try FileManager.default.attributesOfItem(atPath: fixture.path)[.posixPermissions] as? NSNumber)?.intValue, 0o755)
        XCTAssertEqual(first.fileURL.deletingLastPathComponent(), fixture.standardizedFileURL)
    }

    func testCorruptArchiveCannotBeReplacedWithAnEmptyList() throws {
        let store = GlossaryStore(root: fixture), corrupt = Data("{broken".utf8)
        try corrupt.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), corrupt)
    }

    func testNewerSchemaAndAmbiguousStoredDataArePreserved() throws {
        let store = GlossaryStore(root: fixture)
        try store.save([entry])
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
        object["version"] = 2
        let newer = try JSONSerialization.data(withJSONObject: object)
        try newer.write(to: store.fileURL)
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), newer)
        object["version"] = 1
        let rows = try XCTUnwrap(object["entries"] as? [[String: Any]])
        object["entries"] = rows + rows
        let ambiguous = try JSONSerialization.data(withJSONObject: object)
        try ambiguous.write(to: store.fileURL)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), ambiguous)
    }

    func testInvalidCandidateCannotOverwriteValidArchive() throws {
        let store = GlossaryStore(root: fixture), value = entry
        try store.save([value])
        let original = try Data(contentsOf: store.fileURL)
        XCTAssertThrowsError(try store.save([value, value]))
        XCTAssertThrowsError(try store.save([value, GlossaryEntry(canonical: "Other", variants: ["LİFE CYCLE"])]))
        XCTAssertEqual(try Data(contentsOf: store.fileURL), original)
    }

    func testSymbolicLinkAndDirectoryCannotRedirectDictionaryWrites() throws {
        let target = fixture.appendingPathComponent("unrelated.json"), original = Data("keep".utf8)
        try original.write(to: target)
        let root = fixture.appendingPathComponent("dictionary", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let store = GlossaryStore(root: root)
        try FileManager.default.createSymbolicLink(at: store.fileURL, withDestinationURL: target)
        XCTAssertThrowsError(try store.load())
        XCTAssertThrowsError(try store.save([]))
        XCTAssertEqual(try Data(contentsOf: target), original)
        try FileManager.default.removeItem(at: store.fileURL)
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        XCTAssertThrowsError(try store.save([]))
    }

    func testNonDirectoryOrSymbolicLinkRootIsRejected() throws {
        let file = fixture.appendingPathComponent("file")
        try Data("keep".utf8).write(to: file)
        XCTAssertThrowsError(try GlossaryStore(root: file).save([]))
        let link = fixture.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture)
        XCTAssertThrowsError(try GlossaryStore(root: link).save([]))
    }
}
