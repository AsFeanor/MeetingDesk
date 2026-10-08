import XCTest
@testable import MeetingDesk

final class RecordingPanelVisibilityTests: XCTestCase {
    func testHiddenRecordingStaysHiddenWhilePausedAndSavingThenResetsForNextSession() {
        var policy = RecordingPanelVisibilityPolicy()
        XCTAssertEqual(policy.resolve(recording: true, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .recording)
        policy.hideRecordingSession()
        XCTAssertEqual(policy.resolve(recording: true, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .hidden)
        XCTAssertEqual(policy.resolve(recording: false, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .hidden)
        XCTAssertEqual(policy.resolve(recording: false, starting: false, workInProgress: false,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .hidden)
        XCTAssertFalse(policy.recordingSessionHidden)
        XCTAssertEqual(policy.resolve(recording: true, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .recording)
    }

    func testRecordingTakesPriorityOverDetectedMeetingAndStaysVisibleDuringFinalization() {
        var policy = RecordingPanelVisibilityPolicy()
        XCTAssertEqual(policy.resolve(recording: true, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: true), .recording)
        XCTAssertEqual(policy.resolve(recording: false, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: true), .saving)
        XCTAssertEqual(policy.resolve(recording: false, starting: false, workInProgress: false,
                                      recordingPanelEnabled: true, hasMeetingCandidate: true), .prompt)
    }

    func testBusyWorkWithoutRecordingNeverShowsAFalseSavingCardOrMeetingPrompt() {
        var policy = RecordingPanelVisibilityPolicy()
        XCTAssertEqual(policy.resolve(recording: false, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: true), .hidden)
        XCTAssertFalse(policy.hasObservedRecordingSession)
    }

    func testMenuBarCanRevealCurrentSessionWithoutWaitingForAnotherRecording() {
        var policy = RecordingPanelVisibilityPolicy()
        _ = policy.resolve(recording: true, starting: false, workInProgress: true,
                           recordingPanelEnabled: true, hasMeetingCandidate: false)
        policy.hideRecordingSession()
        policy.revealRecordingSession()
        XCTAssertEqual(policy.resolve(recording: true, starting: false, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .recording)
    }

    func testFailedStartDoesNotLeaveAnOrphanProgressCard() {
        var policy = RecordingPanelVisibilityPolicy()
        XCTAssertEqual(policy.resolve(recording: false, starting: true, workInProgress: true,
                                      recordingPanelEnabled: true, hasMeetingCandidate: true), .starting)
        XCTAssertEqual(policy.resolve(recording: false, starting: false, workInProgress: false,
                                      recordingPanelEnabled: true, hasMeetingCandidate: false), .hidden)
        XCTAssertFalse(policy.hasObservedRecordingSession)
    }
}
