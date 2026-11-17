import CryptoKit
import Foundation
import XCTest
@testable import MeetingDesk

@MainActor final class WhisperModelStoreTests: XCTestCase {
    private func fixture() throws -> (URL, [WhisperModelFile], [String: Data]) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WhisperModelTests-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let contents = ["config.json": Data("config".utf8), "weights.safetensors": Data("weights".utf8)]
        let files = contents.sorted { $0.key < $1.key }.map { name, data in
            WhisperModelFile(name: name, bytes: Int64(data.count), sha256: SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined())
        }
        return (root, files, contents)
    }

    func testVerifiedCacheIsReusedWithoutNetworkAndTamperingIsRejected() async throws {
        let (root, pins, contents) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, files: pins) { _, pin, progress in
            let incoming = root.appendingPathComponent(UUID().uuidString)
            try XCTUnwrap(contents[pin.name]).write(to: incoming)
            progress(1); return incoming
        }
        try await store.prepare { _ in }
        let directory = try await store.verifiedDirectory()
        let ready = await store.isReady(); XCTAssertTrue(ready)
        let offline = WhisperModelStore(root: root, files: pins) { _, _, _ in
            XCTFail("Verified cache triggered a download"); throw URLError(.notConnectedToInternet)
        }
        try await offline.prepare { _ in }
        var bytes = try Data(contentsOf: directory.appendingPathComponent("weights.safetensors"))
        bytes[0] ^= 1
        try bytes.write(to: directory.appendingPathComponent("weights.safetensors"))
        do { _ = try await offline.verifiedDirectory(); XCTFail("Tampered model accepted") }
        catch { XCTAssertTrue(error is WhisperModelFailure) }
    }

    func testCorruptDownloadNeverPublishesPartialModel() async throws {
        let (root, pins, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, files: pins) { _, pin, _ in
            let incoming = root.appendingPathComponent(UUID().uuidString)
            try Data(repeating: 0, count: Int(pin.bytes)).write(to: incoming)
            return incoming
        }
        do { try await store.prepare { _ in }; XCTFail("Corrupt download accepted") }
        catch { XCTAssertTrue(error is WhisperModelFailure) }
        let ready = await store.isReady(); XCTAssertFalse(ready)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(WhisperModelPin.revision).path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }

    func testCancelledDownloadCleansOwnedStaging() async throws {
        let (root, pins, _) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let store = WhisperModelStore(root: root, files: pins) { _, _, _ in throw CancellationError() }
        do { try await store.prepare { _ in }; XCTFail("Cancellation ignored") }
        catch { XCTAssertTrue(error is CancellationError) }
        let ready = await store.isReady(); XCTAssertFalse(ready)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), [])
    }
}
