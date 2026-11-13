import Foundation
import XCTest
@testable import MeetingDesk

final class LocalSummaryBackendTests: XCTestCase {
    func testNewAndUnknownPreferencesChooseQwenWhileExplicitAppleIsRespected() throws {
        let name = "MeetingDesk.LocalSummaryBackendTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        XCTAssertEqual(LocalSummaryBackend.selection(in: defaults), .qwen)
        defaults.set("unknown-provider", forKey: LocalSummaryBackend.defaultsKey)
        XCTAssertEqual(LocalSummaryBackend.selection(in: defaults), .qwen)
        defaults.set(LocalSummaryBackend.apple.rawValue, forKey: LocalSummaryBackend.defaultsKey)
        XCTAssertEqual(LocalSummaryBackend.selection(in: defaults), .apple)
    }

    @MainActor
    func testStorePersistsAndRestoresUserSelectedBackendWithoutStartingRuntime() throws {
        let name = "MeetingDesk.LocalSummaryBackendStoreTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: defaults)
        XCTAssertEqual(first.localSummaryBackend, .qwen)
        first.localSummaryBackend = .apple
        XCTAssertEqual(defaults.string(forKey: LocalSummaryBackend.defaultsKey), "apple")
        let restored = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: defaults)
        XCTAssertEqual(restored.localSummaryBackend, .apple)
        XCTAssertFalse(first.preparingLocalSummaryModel)
        XCTAssertFalse(restored.preparingLocalSummaryModel)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testQwenNotesHaveDistinctProviderMetadataAndAppleKeepsLegacyIdentifier() {
        XCTAssertEqual(LocalSummaryBackend.qwen.notesEngine, "local-qwen3.5:9b")
        XCTAssertEqual(LocalSummaryBackend.apple.notesEngine, ProcessingMode.local.rawValue)
        XCTAssertNotEqual(LocalSummaryBackend.qwen.notesEngine, LocalSummaryBackend.apple.notesEngine)
    }
}
