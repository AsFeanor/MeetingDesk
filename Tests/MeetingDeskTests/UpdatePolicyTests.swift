import XCTest
import Combine
@testable import MeetingDesk

final class UpdatePolicyTests: XCTestCase {
    private let publicKey = Data((1...32).map(UInt8.init)).base64EncodedString()

    private func configuration(privateUpdates: Bool = false, feed: String? = nil) throws -> UpdateConfiguration {
        try UpdateConfiguration(info: [
            "MeetingDeskUpdateRepository": "AsFeanor/MeetingDesk",
            "MeetingDeskPrivateUpdates": privateUpdates,
            "SUPublicEDKey": publicKey,
            "SUFeedURL": feed ?? (privateUpdates
                ? "https://api.github.com/repos/AsFeanor/MeetingDesk/contents/appcast.xml?ref=main"
                : "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/appcast.xml")
        ])
    }

    func testUnconfiguredBuildCannotStartUpdater() {
        XCTAssertThrowsError(try UpdateConfiguration(info: [:]))
        for key in ["", "not-a-key", Data(repeating: 1, count: 31).base64EncodedString(), publicKey + "\n"] {
            XCTAssertFalse(UpdateConfiguration.isValidPublicKey(key))
        }
        XCTAssertTrue(UpdateConfiguration.isValidPublicKey(publicKey))
    }

    func testConfiguredPublicFeedStaysInsideExpectedRepository() throws {
        let config = try configuration()
        let feeds = [
            "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/appcast.xml",
            "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/Distribution/appcast.xml",
            "https://github.com/AsFeanor/MeetingDesk/releases/latest/download/appcast.xml"
        ]
        for feed in feeds { XCTAssertTrue(config.acceptsFeedURL(URL(string: feed)!), feed) }
        for feed in [
            "http://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/appcast.xml",
            "https://raw.githubusercontent.com/Other/MeetingDesk/main/appcast.xml",
            "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/other-branch/appcast.xml",
            "https://raw.githubusercontent.com@evil.test/AsFeanor/MeetingDesk/main/appcast.xml",
            "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/appcast.xml?token=secret",
            "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/appcast.xml#fragment",
            "https://raw.githubusercontent.com:443/AsFeanor/MeetingDesk/main/appcast.xml",
            "https://raw.githubusercontent.com/AsFeanor/MeetingDesk/main/%61ppcast.xml"
        ] {
            XCTAssertFalse(config.acceptsFeedURL(URL(string: feed)!), feed)
            XCTAssertThrowsError(try configuration(feed: feed), feed)
        }
    }

    func testPrivateFeedDoesNotAcceptCrossRepositoryOrQueryChanges() throws {
        let config = try configuration(privateUpdates: true)
        XCTAssertTrue(config.acceptsFeedURL(config.feedURL))
        for feed in [
            "https://api.github.com/repos/Other/MeetingDesk/contents/appcast.xml?ref=main",
            "https://api.github.com/repos/AsFeanor/MeetingDesk/contents/appcast.xml?ref=main&token=secret",
            "https://api.github.com/repos/AsFeanor/MeetingDesk/contents/appcast.xml?ref=other",
            "https://github.com/AsFeanor/MeetingDesk/releases/latest/download/appcast.xml"
        ] { XCTAssertFalse(config.acceptsFeedURL(URL(string: feed)!), feed) }
    }

    func testPrivateDownloadSwitchesGitHubMediaTypeWithoutLeakingToken() throws {
        let config = try configuration(privateUpdates: true)
        let request = NSMutableURLRequest(url: URL(string: "https://api.github.com/repos/AsFeanor/MeetingDesk/releases/assets/123456")!)
        for (header, value) in try config.feedHeaders(token: "test-read-only-token") {
            request.setValue(value, forHTTPHeaderField: header)
        }
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github.raw+json")
        try config.configureDownloadRequest(request, token: "test-read-only-token")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/octet-stream")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-read-only-token")
        request.url = URL(string: "https://api.github.com/repos/Other/MeetingDesk/releases/assets/123456")!
        XCTAssertThrowsError(try config.configureDownloadRequest(request, token: "test-read-only-token"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(request.value(forHTTPHeaderField: "Accept"))
    }

    func testPublicUpdateNeverAddsCredentialsAndArchiveMustMatchRepository() throws {
        let config = try configuration()
        let url = URL(string: "https://github.com/AsFeanor/MeetingDesk/releases/download/v0.3.0/Toplanti.zip")!
        let request = NSMutableURLRequest(url: url)
        request.setValue("Bearer old-private-token", forHTTPHeaderField: "Authorization")
        try config.configureDownloadRequest(request, token: "ignored-token")
        XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
        XCTAssertTrue(try config.feedHeaders(token: "ignored-token").isEmpty)
        for candidate in [
            "https://evil.test/Toplanti.zip",
            "https://github.com/Other/MeetingDesk/releases/download/v0.3.0/Toplanti.zip",
            "https://github.com/AsFeanor/MeetingDesk/releases/download/v0.3.0/../Toplanti.zip",
            "https://github.com/AsFeanor/MeetingDesk/releases/download/v0.3.0/%2e%2e",
            "https://github.com/AsFeanor/MeetingDesk/releases/download/v0.3.0/Toplanti.zip?token=secret",
            "https://api.github.com/repos/AsFeanor/MeetingDesk/releases/assets/123456"
        ] { XCTAssertFalse(config.acceptsDownloadURL(URL(string: candidate)!), candidate) }
    }

    func testPrivateAssetIDsAndTokenHeaderInjectionAreRejected() throws {
        let config = try configuration(privateUpdates: true)
        for id in ["0", "../123", "123/extra", "123?access_token=secret", "%31%32%33"] {
            XCTAssertFalse(config.acceptsDownloadURL(URL(string: "https://api.github.com/repos/AsFeanor/MeetingDesk/releases/assets/\(id)")!))
        }
        for token in [nil, "", "token\r\nInjected: true", "contains space", "türkçe", String(repeating: "x", count: 1025)] {
            XCTAssertThrowsError(try config.feedHeaders(token: token))
        }
    }

    func testRepositoryMetadataCannotIntroduceASecondPathOrURL() {
        for repo in ["", "/repo", "owner/", "owner/../repo", "owner/repo/other", "https://github.com/owner/repo", "owner/repo%2Fother", "owner/..", "owner/.git/other"] {
            XCTAssertFalse(UpdateConfiguration.isValidRepository(repo), repo)
        }
        XCTAssertTrue(UpdateConfiguration.isValidRepository("AsFeanor/MeetingDesk"))
    }

    func testWorkStartingAfterUpdateCheckDefersInstallUntilCompletion() async throws {
        let installed = expectation(description: "Deferred update resumed")
        let counts = await MainActor.run { InstallationCalls() }
        try await MainActor.run {
            let gate = UpdateInstallationGate()
            try gate.requireIdle() // The check began while idle.
            gate.setWorkInProgress(true) // Recording/transcription started during download.
            XCTAssertThrowsError(try gate.requireIdle())
            XCTAssertTrue(gate.postponeIfBusy { counts.values.append("installed"); installed.fulfill() })
            XCTAssertTrue(counts.values.isEmpty)
            gate.setWorkInProgress(true)
            XCTAssertTrue(counts.values.isEmpty)
            gate.setWorkInProgress(false)
            XCTAssertTrue(counts.values.isEmpty)
            gate.setWorkInProgress(false)
            try gate.requireIdle()
            counts.gate = gate
        }
        await fulfillment(of: [installed], timeout: 1)
        await MainActor.run { XCTAssertEqual(counts.values, ["installed"]) }
    }

    func testIdleInstallationIsLeftWithSparkleAndNewerPendingStageSupersedesOld() async {
        let installed = expectation(description: "Latest deferred stage resumed")
        let counts = await MainActor.run { InstallationCalls() }
        await MainActor.run {
            let gate = UpdateInstallationGate()
            XCTAssertFalse(gate.postponeIfBusy { counts.values.append("idle") })
            XCTAssertTrue(counts.values.isEmpty) // Returning false leaves Sparkle in charge.
            gate.setWorkInProgress(true)
            XCTAssertTrue(gate.postponeIfBusy { counts.values.append("earlier-stage") })
            XCTAssertTrue(gate.postponeIfBusy { counts.values.append("latest-stage"); installed.fulfill() })
            gate.setWorkInProgress(false)
            counts.gate = gate
        }
        await fulfillment(of: [installed], timeout: 1)
        await MainActor.run { XCTAssertEqual(counts.values, ["latest-stage"]) }
    }

    func testCombineBusyBindingUsesPublishedValuesAndWaitsForSetterBeforeRelaunch() async {
        let installed = expectation(description: "Install sees committed idle state")
        let state = await MainActor.run { PublishedWorkState() }
        await MainActor.run {
            state.bind()
            state.busy = true
            XCTAssertTrue(state.gate.workInProgress)
            XCTAssertTrue(state.gate.postponeIfBusy {
                XCTAssertFalse(state.busy) // @Published willSet must have finished.
                XCTAssertFalse(state.recording)
                installed.fulfill()
            })
            state.recording = true
            state.busy = false
            XCTAssertTrue(state.gate.workInProgress) // Ongoing recording keeps installation blocked.
            state.recording = false
            state.busy = true // New work starts before the deferred callback can run.
            XCTAssertTrue(state.gate.workInProgress)
        }
        await MainActor.run {
            XCTAssertTrue(state.busy)
            state.busy = false
        }
        await fulfillment(of: [installed], timeout: 1)
    }
}

@MainActor
private final class InstallationCalls {
    var values: [String] = []
    var gate: UpdateInstallationGate?
}

@MainActor
private final class PublishedWorkState {
    @Published var busy = false
    @Published var recording = false
    let gate = UpdateInstallationGate()
    private var binding: AnyCancellable?
    func bind() {
        binding = $recording.combineLatest($busy).sink { [weak self] recording, busy in
            self?.gate.setWorkInProgress(recording || busy)
        }
    }
}
