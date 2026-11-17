import Foundation
import XCTest
@testable import MeetingDesk

final class SummaryFailureStatusTests: XCTestCase {
    @MainActor
    func testSummaryFailureDetailRemainsAfterAlertIsDismissed() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(root: root, initializeSystemServices: false)
        let detail = "Özet modeli başlatılamadı; önceki notlar korunuyor."
        store.runProcessing(message: "Özet hazırlanıyor", preserveErrorInStatus: true) {
            throw MeetingError.message(detail)
        }
        try await waitForProcessing(store)
        XCTAssertEqual(store.errorMessage, detail)
        XCTAssertEqual(store.statusMessage, detail)
        store.errorMessage = nil
        XCTAssertEqual(store.statusMessage, detail)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testOtherProcessingKeepsExistingGenericFailureStatusByDefault() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(root: root, initializeSystemServices: false)
        store.runProcessing(message: "İşlem sürüyor") { throw MeetingError.message("Synthetic detail") }
        try await waitForProcessing(store)
        XCTAssertEqual(store.errorMessage, "Synthetic detail")
        XCTAssertEqual(store.statusMessage, "İşlem tamamlanamadı. Yeniden deneyebilirsin.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    func testCancelledSummaryKeepsCancellationStatusWithoutFailureAlert() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = AppStore(root: root, initializeSystemServices: false)
        store.runProcessing(message: "Özet hazırlanıyor", preserveErrorInStatus: true) {
            withUnsafeCurrentTask { $0?.cancel() }
            throw CancellationError()
        }
        try await waitForProcessing(store)
        XCTAssertNil(store.errorMessage)
        XCTAssertEqual(store.statusMessage, "İşlem iptal edildi. Yerel kayıt korunuyor.")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    @MainActor
    private func waitForProcessing(_ store: AppStore) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while store.isBusy && ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(1)) }
        XCTAssertFalse(store.isBusy)
    }
}
