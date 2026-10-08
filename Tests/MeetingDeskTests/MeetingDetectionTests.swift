import XCTest
@testable import MeetingDesk

final class MeetingDetectionTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000)
    private let zoom = DetectedMeeting(id: "native:us.zoom.xos", appName: "Zoom",
                                      evidenceDescription: "Test", confidence: .nativeMicrophone)

    private func at(_ seconds: TimeInterval) -> Date { start.addingTimeInterval(seconds) }

    func testOnlyActiveInputFromSupportedAppProducesNativeSignal() {
        let processes = [
            MeetingAudioProcess(processID: 2, bundleIdentifier: "us.zoom.xos", isInputRunning: false),
            MeetingAudioProcess(processID: 3, bundleIdentifier: "com.apple.VoiceMemos", isInputRunning: true)
        ]
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: processes, browserWindows: [],
            ownProcessID: 1, ownBundleIdentifier: "com.altugegesari.meetingdesk").isEmpty)
        let active = MeetingAudioProcess(processID: 2, bundleIdentifier: "us.zoom.xos", isInputRunning: true)
        let signals = MeetingDetectionSignals.detect(processes: [active], browserWindows: [],
            ownProcessID: 1, ownBundleIdentifier: "com.altugegesari.meetingdesk")
        XCTAssertEqual(signals.map(\.appName), ["Zoom"])
        XCTAssertEqual(signals.first?.confidence, .nativeMicrophone)
    }

    func testOwnMicrophoneAndRelatedMeetingDeskHelpersCannotCauseSuggestion() {
        let processes = [
            MeetingAudioProcess(processID: 1, bundleIdentifier: "us.zoom.xos", isInputRunning: true),
            MeetingAudioProcess(processID: 3, bundleIdentifier: "com.altugegesari.meetingdesk.helper", isInputRunning: true),
            MeetingAudioProcess(processID: 4, bundleIdentifier: "com.altugegesari.meetingdesk.workflow-preview", isInputRunning: true)
        ]
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: processes, browserWindows: [],
            ownProcessID: 1, ownBundleIdentifier: "com.altugegesari.meetingdesk").isEmpty)
    }

    func testBundleMatchingUsesComponentBoundaryAndDeduplicatesHelpers() {
        let processes = [
            MeetingAudioProcess(processID: 2, bundleIdentifier: "us.zoom.xos.lookalike", isInputRunning: true),
            MeetingAudioProcess(processID: 3, bundleIdentifier: "us.zoom.xos", isInputRunning: true),
            MeetingAudioProcess(processID: 4, bundleIdentifier: "us.zoom.xosevil", isInputRunning: true)
        ]
        let signals = MeetingDetectionSignals.detect(processes: processes, browserWindows: [],
            ownProcessID: 1, ownBundleIdentifier: nil)
        XCTAssertEqual(signals.count, 1)
        XCTAssertEqual(signals.first?.id, zoom.id)
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: [processes[2]], browserWindows: [],
            ownProcessID: 1, ownBundleIdentifier: nil).isEmpty)
    }

    func testBrowserRequiresBothSameBrowserInputAndRecognizedWindow() {
        let chrome = MeetingAudioProcess(processID: 2, bundleIdentifier: "com.google.Chrome.helper", isInputRunning: true)
        let googleMeet = MeetingBrowserWindow(bundleIdentifier: "com.google.Chrome", title: "Meet - abc-defg-hij")
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: [chrome], browserWindows: [],
            ownProcessID: 1, ownBundleIdentifier: nil).isEmpty)
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: [], browserWindows: [googleMeet],
            ownProcessID: 1, ownBundleIdentifier: nil).isEmpty)
        let wrongBrowser = MeetingBrowserWindow(bundleIdentifier: "com.microsoft.edgemac", title: "Google Meet")
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: [chrome], browserWindows: [wrongBrowser],
            ownProcessID: 1, ownBundleIdentifier: nil).isEmpty)
        let signals = MeetingDetectionSignals.detect(processes: [chrome], browserWindows: [googleMeet],
            ownProcessID: 1, ownBundleIdentifier: nil)
        XCTAssertEqual(signals.map(\.appName), ["Google Meet (Chrome)"])
        XCTAssertEqual(signals.first?.confidence, .browserMeetingWindow)
        XCTAssertFalse(signals.first?.evidenceDescription.contains("abc-defg-hij") ?? true)
    }

    func testOrdinaryBrowserPageChatAndSharedWebKitMicrophoneDoNotCountAsCall() {
        let chrome = MeetingAudioProcess(processID: 2, bundleIdentifier: "com.google.Chrome", isInputRunning: true)
        for title in ["Meet our team", "Microsoft Teams | Chat", "Zoom pricing", "Webex products"] {
            let window = MeetingBrowserWindow(bundleIdentifier: "com.google.Chrome", title: title)
            XCTAssertTrue(MeetingDetectionSignals.detect(processes: [chrome], browserWindows: [window],
                ownProcessID: 1, ownBundleIdentifier: nil).isEmpty, title)
        }
        let shared = MeetingAudioProcess(processID: 3, bundleIdentifier: "com.apple.WebKit.GPU", isInputRunning: true)
        let safari = MeetingBrowserWindow(bundleIdentifier: "com.apple.Safari", title: "Google Meet")
        XCTAssertTrue(MeetingDetectionSignals.detect(processes: [shared], browserWindows: [safari],
            ownProcessID: 1, ownBundleIdentifier: nil).isEmpty)
    }

    func testTurkishMeetingWindowIsRecognizedWithoutRetainingItsTitle() {
        let chrome = MeetingAudioProcess(processID: 2, bundleIdentifier: "com.google.Chrome", isInputRunning: true)
        let window = MeetingBrowserWindow(bundleIdentifier: "com.google.Chrome",
                                          title: "Özel müşteri Toplantısı | Microsoft Teams")
        let signals = MeetingDetectionSignals.detect(processes: [chrome], browserWindows: [window],
            ownProcessID: 1, ownBundleIdentifier: nil)
        XCTAssertEqual(signals.first?.appName, "Microsoft Teams (Chrome)")
        XCTAssertFalse(signals.first?.id.contains("müşteri") ?? true)
        XCTAssertFalse(signals.first?.evidenceDescription.contains("müşteri") ?? true)
    }

    func testSuggestionRequiresStableSignalAndShortMicrophoneCheckNeverQualifies() {
        var policy = MeetingDetectionPolicy()
        XCTAssertNil(policy.observe([zoom], at: at(0)))
        XCTAssertNil(policy.observe([zoom], at: at(3)))
        XCTAssertEqual(policy.observe([zoom], at: at(6)), zoom)

        var brief = MeetingDetectionPolicy()
        XCTAssertNil(brief.observe([zoom], at: at(0)))
        XCTAssertNil(brief.observe([], at: at(3)))
        XCTAssertNil(brief.observe([], at: at(6)))
        XCTAssertNil(brief.observe([zoom], at: at(9)))
        XCTAssertNil(brief.observe([zoom], at: at(12)))
        XCTAssertEqual(brief.observe([zoom], at: at(15)), zoom)
    }

    func testShortMissingSampleDoesNotFlickerSuggestionButEndedSignalClearsIt() {
        var policy = MeetingDetectionPolicy()
        _ = policy.observe([zoom], at: at(0))
        XCTAssertEqual(policy.observe([zoom], at: at(6)), zoom)
        XCTAssertEqual(policy.observe([], at: at(9)), zoom)
        XCTAssertEqual(policy.observe([zoom], at: at(12)), zoom)
        XCTAssertNil(policy.observe([], at: at(32)))
    }

    func testDismissalSurvivesShortDropoutsAndOnlyRearmsForNewSession() {
        var policy = MeetingDetectionPolicy()
        _ = policy.observe([zoom], at: at(0))
        XCTAssertEqual(policy.observe([zoom], at: at(6)), zoom)
        policy.dismissCurrentMeeting()
        XCTAssertNil(policy.observe([zoom], at: at(9)))
        XCTAssertNil(policy.observe([], at: at(12)))
        XCTAssertNil(policy.observe([zoom], at: at(15)))
        XCTAssertNil(policy.observe([], at: at(35)))
        XCTAssertNil(policy.observe([zoom], at: at(36)))
        XCTAssertEqual(policy.observe([zoom], at: at(42)), zoom)
    }

    func testRecordingSuspensionKeepsDismissalAndAddsResumeCooldown() {
        var policy = MeetingDetectionPolicy()
        _ = policy.observe([zoom], at: at(0))
        XCTAssertEqual(policy.observe([zoom], at: at(6)), zoom)
        policy.dismissCurrentMeeting()
        policy.setSuspended(true, at: at(6))
        XCTAssertNil(policy.observe([zoom], at: at(9)))
        policy.setSuspended(false, at: at(12))
        XCTAssertNil(policy.observe([zoom], at: at(27)))

        var resumed = MeetingDetectionPolicy()
        resumed.setSuspended(true, at: at(0))
        XCTAssertNil(resumed.observe([zoom], at: at(0)))
        XCTAssertNil(resumed.observe([zoom], at: at(6)))
        resumed.setSuspended(false, at: at(9))
        XCTAssertNil(resumed.observe([zoom], at: at(12)))
        XCTAssertNil(resumed.observe([zoom], at: at(21)))
        XCTAssertEqual(resumed.observe([zoom], at: at(24)), zoom)
    }

    func testResetRemovesCandidatesAndDismissal() {
        var policy = MeetingDetectionPolicy()
        _ = policy.observe([zoom], at: at(0))
        XCTAssertEqual(policy.observe([zoom], at: at(6)), zoom)
        policy.dismissCurrentMeeting()
        policy.reset()
        XCTAssertNil(policy.observe([], at: at(9)))
        XCTAssertNil(policy.observe([zoom], at: at(12)))
        XCTAssertEqual(policy.observe([zoom], at: at(18)), zoom)
    }

    @MainActor
    func testDetectorOnlyStartsWhenRequestedAndStopResetsObservation() {
        var sampleCount = 0
        var time = at(0)
        let signal = zoom
        let detector = MeetingDetector(sample: {
            sampleCount += 1
            return [signal]
        }, now: { time })
        XCTAssertEqual(sampleCount, 0)
        detector.start()
        XCTAssertEqual(sampleCount, 1)
        XCTAssertNil(detector.candidate)
        detector.start()
        XCTAssertEqual(sampleCount, 1)
        detector.stop()
        time = at(9)
        detector.start()
        XCTAssertEqual(sampleCount, 2)
        XCTAssertNil(detector.candidate)
        detector.stop()
    }
}
