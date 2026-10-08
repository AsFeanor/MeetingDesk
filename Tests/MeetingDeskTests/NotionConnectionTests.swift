import XCTest
import AppKit
import Combine
@testable import MeetingDesk

@MainActor
final class NotionConnectionTests: XCTestCase {
    private let parentID = "3ec94d30-7a7e-809a-9f65-c951bd66d659"
    private let otherParentID = "92b4b345-13a6-43ce-b345-8f02ec94d925"
    private let pageID = "147ccc14-c73d-4e37-8712-6f760899834a"
    private let token = "ntn_synthetic_connection_lifecycle_test_token"

    func testExportStaysBusyUntilAllAppendsSettleAndPersistsPageBeforeTheyFinish() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID, blockFirstAppend: true)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        let task = Task { try await connection.export(document: document(), title: "Deneme toplantısı") }
        await transport.waitForBlockedAppend()

        XCTAssertTrue(connection.isExporting)
        XCTAssertFalse(connection.canExport)
        XCTAssertTrue(connection.exportMayHaveSucceeded)
        XCTAssertEqual(connection.incompleteExportURL, NotionPageIdentifier.pageURL(pageID))
        XCTAssertTrue(defaults.bool(forKey: "MeetingDeskNotionUncertainExport"))
        XCTAssertEqual(defaults.string(forKey: "MeetingDeskNotionIncompleteExport"), NotionPageIdentifier.pageURL(pageID).absoluteString)
        XCTAssertTrue(connection.statusMessage.contains("aktarılıyor"))
        XCTAssertFalse(connection.statusMessage.contains(token))
        XCTAssertThrowsError(try connection.saveConnection(token: "", parentPage: otherParentID))
        XCTAssertThrowsError(try connection.disconnect())
        connection.acknowledgeIncompleteExport()
        XCTAssertTrue(connection.exportMayHaveSucceeded)

        // A new process sees the saved recovery gate even while the first process is suspended.
        let restored = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        XCTAssertFalse(restored.isExporting)
        XCTAssertTrue(restored.exportMayHaveSucceeded)
        XCTAssertFalse(restored.canExport)
        XCTAssertEqual(restored.incompleteExportURL, connection.incompleteExportURL)

        await transport.releaseAppend()
        let receipt = try await task.value
        XCTAssertFalse(connection.isExporting)
        XCTAssertTrue(connection.canExport)
        XCTAssertFalse(connection.exportMayHaveSucceeded)
        XCTAssertNil(connection.incompleteExportURL)
        XCTAssertEqual(connection.lastExportURL, receipt.url)
        XCTAssertEqual(defaults.string(forKey: "MeetingDeskNotionLastExport"), receipt.url.absoluteString)
        XCTAssertNil(defaults.object(forKey: "MeetingDeskNotionUncertainExport"))
        XCTAssertNil(defaults.object(forKey: "MeetingDeskNotionIncompleteExport"))
        let requests = await transport.requests
        XCTAssertEqual(requests.count, 3) // Create + content + footer: busy lasts through both appends.
        XCTAssertEqual(requests.filter { $0.httpMethod == "POST" }.count, 1)
    }

    func testNotionExportBlocksRecordingAndApplicationRelaunchUntilRemoteWritesFinish() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDeskNotionGate-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID, blockFirstAppend: true)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        let store = AppStore(root: root, initializeSystemServices: false, notionConnection: connection)
        let delegate = MeetingAppDelegate()
        delegate.configure(with: store)
        var forwardedChanges = 0
        let observation = store.objectWillChange.sink { forwardedChanges += 1 }
        defer { observation.cancel() }

        let task = Task { try await connection.export(document: document(), title: "Deneme toplantısı") }
        await transport.waitForBlockedAppend()
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.recorder.isRecording)
        XCTAssertFalse(store.hasPendingRecordingSession)
        XCTAssertTrue(store.workInProgress)
        XCTAssertGreaterThan(forwardedChanges, 0)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateCancel)
        await store.startRecording()
        XCTAssertTrue(store.meetings.isEmpty)
        XCTAssertFalse(store.recorder.isRecording)

        await transport.releaseAppend()
        _ = try await task.value
        XCTAssertFalse(store.workInProgress)
        XCTAssertEqual(delegate.applicationShouldTerminate(NSApplication.shared), .terminateNow)
    }

    func testPartialFailureSurvivesRelaunchAndDisconnectWithoutAnImplicitSecondPage() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID, firstAppendStatus: 503)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        do {
            _ = try await connection.export(document: document(), title: "Deneme toplantısı")
            XCTFail("Expected partial export")
        } catch let failure as NotionExportFailure {
            XCTAssertEqual(failure.createdPageURL, NotionPageIdentifier.pageURL(pageID))
        }
        XCTAssertFalse(connection.isExporting)
        XCTAssertTrue(connection.exportMayHaveSucceeded)
        XCTAssertFalse(connection.canExport)
        XCTAssertFalse(connection.statusMessage.contains(token))
        XCTAssertFalse(connection.statusMessage.contains("SERVER_PRIVATE_CONTENT"))

        let restored = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        XCTAssertTrue(restored.exportMayHaveSucceeded)
        XCTAssertEqual(restored.incompleteExportURL, NotionPageIdentifier.pageURL(pageID))
        do {
            _ = try await restored.export(document: document(), title: "İkinci deneme")
            XCTFail("An unacknowledged partial export must not create another page")
        } catch { }
        let before = await transport.requests.count
        XCTAssertEqual(before, 2)
        try restored.disconnect()
        XCTAssertFalse(restored.hasToken)
        XCTAssertEqual(credentials.deleteCount, 1)
        XCTAssertEqual(restored.incompleteExportURL, NotionPageIdentifier.pageURL(pageID))
        XCTAssertTrue(defaults.bool(forKey: "MeetingDeskNotionUncertainExport"))
        XCTAssertNotNil(defaults.string(forKey: "MeetingDeskNotionIncompleteExport"))
        XCTAssertNil(defaults.string(forKey: "MeetingDeskNotionParentPage"))

        try restored.saveConnection(token: token, parentPage: parentID)
        XCTAssertFalse(restored.canExport)
        restored.acknowledgeIncompleteExport()
        XCTAssertTrue(restored.canExport)
        XCTAssertNil(restored.incompleteExportURL)
        XCTAssertFalse(restored.exportMayHaveSucceeded)
    }

    func testInitialUnauthorizedResponseClearsUncertainGateAndDoesNotLeakServerContent() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID, createStatus: 401)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        do {
            _ = try await connection.export(document: document(), title: "Deneme toplantısı")
            XCTFail("Expected unauthorized response")
        } catch let failure as NotionExportFailure {
            XCTAssertFalse(failure.exportMayHaveSucceeded)
            XCTAssertNil(failure.createdPageURL)
        }
        XCTAssertFalse(connection.isExporting)
        XCTAssertFalse(connection.exportMayHaveSucceeded)
        XCTAssertNil(connection.incompleteExportURL)
        XCTAssertTrue(connection.canExport)
        XCTAssertFalse(defaults.bool(forKey: "MeetingDeskNotionUncertainExport"))
        XCTAssertTrue(connection.statusMessage.contains("kabul edilmedi"))
        XCTAssertFalse(connection.statusMessage.contains("SERVER_PRIVATE_CONTENT"))
        XCTAssertFalse(connection.statusMessage.contains(token))
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testLostCreateResponseKeepsDurableUnknownWriteGateWithoutFakePageLink() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID, loseCreateResponse: true)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        do {
            _ = try await connection.export(document: document(), title: "Deneme toplantısı")
            XCTFail("Expected lost response")
        } catch let failure as NotionExportFailure {
            XCTAssertTrue(failure.exportMayHaveSucceeded)
            XCTAssertNil(failure.createdPageURL)
        }
        XCTAssertFalse(connection.isExporting)
        XCTAssertTrue(connection.exportMayHaveSucceeded)
        XCTAssertNil(connection.incompleteExportURL)
        XCTAssertFalse(connection.canExport)
        let restored = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        XCTAssertTrue(restored.exportMayHaveSucceeded)
        XCTAssertFalse(restored.canExport)
        XCTAssertNil(restored.incompleteExportURL)
        XCTAssertTrue(restored.statusMessage.contains("Önceki aktarım"))
        let count = await transport.requests.count
        XCTAssertEqual(count, 1)
    }

    func testParentOnlySaveKeepsExistingCredentialAndFailedValidationLeavesConnectionUntouched() throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport)
        try connection.saveConnection(token: " \n ", parentPage: "https://app.notion.com/p/" + otherParentID.replacingOccurrences(of: "-", with: ""))
        XCTAssertEqual(credentials.token, token)
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(connection.parentPageInput, otherParentID)
        XCTAssertEqual(defaults.string(forKey: "MeetingDeskNotionParentPage"), otherParentID)
        XCTAssertTrue(connection.hasToken)
        XCTAssertTrue(connection.canExport)

        XCTAssertThrowsError(try connection.saveConnection(token: "ntn_new_valid_synthetic_token", parentPage: "https://attacker.example/" + parentID))
        XCTAssertThrowsError(try connection.saveConnection(token: "short", parentPage: parentID))
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(connection.parentPageInput, otherParentID)
        XCTAssertEqual(credentials.token, token)
        XCTAssertFalse(defaults.dictionaryRepresentation().values.contains { ($0 as? String) == token })
    }

    func testCredentialSaveFailureDoesNotPersistNewParent() throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        credentials.failSave = true
        let connection = makeConnection(defaults: defaults, credentials: credentials,
                                        transport: NotionConnectionTestTransport(pageID: pageID))
        XCTAssertThrowsError(try connection.saveConnection(token: "ntn_new_valid_synthetic_token", parentPage: otherParentID))
        XCTAssertEqual(connection.parentPageInput, parentID)
        XCTAssertEqual(defaults.string(forKey: "MeetingDeskNotionParentPage"), parentID)
        XCTAssertEqual(credentials.token, token)
    }

    func testPreviewMakesNoCredentialCallsDuringInitializationRefreshDisconnectOrExport() async throws {
        let (suite, defaults) = try isolatedDefaults()
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NotionTestCredentials(token: token)
        let transport = NotionConnectionTestTransport(pageID: pageID)
        let connection = makeConnection(defaults: defaults, credentials: credentials, transport: transport, loadCredentials: false)
        connection.refresh()
        try connection.disconnect()
        XCTAssertThrowsError(try connection.saveConnection(token: token, parentPage: parentID))
        do {
            _ = try await connection.export(document: document(), title: "Önizleme")
            XCTFail("Preview export must be disabled")
        } catch { }
        XCTAssertEqual(credentials.loadCount, 0)
        XCTAssertEqual(credentials.saveCount, 0)
        XCTAssertEqual(credentials.deleteCount, 0)
        let count = await transport.requests.count
        XCTAssertEqual(count, 0)
    }

    private func isolatedDefaults() throws -> (String, UserDefaults) {
        let suite = "MeetingDeskNotionLifecycleTests-" + UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defaults.set(parentID, forKey: "MeetingDeskNotionParentPage")
        return (suite, defaults)
    }

    private func makeConnection(defaults: UserDefaults, credentials: NotionTestCredentials,
                                transport: NotionConnectionTestTransport, loadCredentials: Bool = true) -> NotionConnection {
        let service = NotionExportService(transport: { try await transport.send($0) }, sleep: { _ in }, minimumRequestInterval: 0)
        return NotionConnection(loadCredentials: loadCredentials, defaults: defaults, service: service, credentialStore: credentials.store)
    }

    private func document() -> MeetingShareDocument {
        MeetingShareDocument(blocks: [
            MeetingExportBlock(kind: .paragraph, text: "PAYLAŞILACAK DENEME METNİ", markdown: "PAYLAŞILACAK DENEME METNİ"),
            MeetingExportBlock(kind: .footer, text: "Kaynakları kontrol edin.", markdown: "Kaynakları kontrol edin.")
        ])
    }
}

private final class NotionTestCredentials {
    var token: String?
    var loadCount = 0
    var saveCount = 0
    var deleteCount = 0
    var failSave = false
    init(token: String?) { self.token = token }
    var store: NotionCredentialStore {
        NotionCredentialStore(load: { self.loadCount += 1; return self.token },
                              save: { value in
                                  self.saveCount += 1
                                  if self.failSave { throw MeetingError.message("Sentetik anahtar kaydetme hatası.") }
                                  self.token = value
                              }, delete: { self.deleteCount += 1; self.token = nil })
    }
}

private actor NotionConnectionTestTransport {
    let pageID: String
    let createStatus: Int
    let firstAppendStatus: Int
    let blockFirstAppend: Bool
    let loseCreateResponse: Bool
    private(set) var requests: [URLRequest] = []
    private var appendBlocked = false
    private var blockWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseContinuation: CheckedContinuation<Void, Never>?

    init(pageID: String, createStatus: Int = 200, firstAppendStatus: Int = 200,
         blockFirstAppend: Bool = false, loseCreateResponse: Bool = false) {
        self.pageID = pageID; self.createStatus = createStatus; self.firstAppendStatus = firstAppendStatus
        self.blockFirstAppend = blockFirstAppend; self.loseCreateResponse = loseCreateResponse
    }

    func waitForBlockedAppend() async {
        if appendBlocked { return }
        await withCheckedContinuation { blockWaiters.append($0) }
    }

    func releaseAppend() {
        releaseContinuation?.resume()
        releaseContinuation = nil
    }

    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let index = requests.count
        requests.append(request)
        if index == 0 && loseCreateResponse { throw URLError(.networkConnectionLost) }
        if index == 1 && blockFirstAppend {
            appendBlocked = true
            let waiters = blockWaiters; blockWaiters = []
            // Set the continuation before notifying tests; they can safely release immediately.
            await withCheckedContinuation { continuation in
                releaseContinuation = continuation
                waiters.forEach { $0.resume() }
            }
        }
        let status = index == 0 ? createStatus : index == 1 ? firstAppendStatus : 200
        let body: [String: Any]
        if status != 200 { body = ["message": "SERVER_PRIVATE_CONTENT " + (request.value(forHTTPHeaderField: "Authorization") ?? ""), "code": "synthetic_failure"] }
        else if index == 0 { body = ["id": pageID, "url": NotionPageIdentifier.pageURL(pageID).absoluteString] }
        else { body = ["object": "list", "results": [], "has_more": false] }
        return (try JSONSerialization.data(withJSONObject: body),
                HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}
