import CoreGraphics
import XCTest
@testable import MeetingDesk

#if DEBUG
final class MeetingDetectionSampleProbeTests: XCTestCase {
    @MainActor func testOptInSystemReaderTimingOnly() async throws {
        guard let output = ProcessInfo.processInfo.environment["MEETINGDESK_DETECTOR_PROBE_OUTPUT"] else {
            throw XCTSkip("Optional metadata-only system reader timing probe")
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output))
        var samples: [[String: Any]] = []
        for _ in 0..<3 {
            let result = await MeetingDetector.debugMeasureSystemSample()
            samples.append(["milliseconds": result.milliseconds, "detectedMeetingCount": result.detectedMeetingCount])
        }
        let report: [String: Any] = ["samples": samples, "existingScreenGrant": CGPreflightScreenCaptureAccess(),
            "contentLogged": false, "modelStarted": false, "archiveRead": false,
            "note": "Measures this test process; permissions and active processes can differ from the installed app."]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output), options: .atomic)
    }
}

#endif
