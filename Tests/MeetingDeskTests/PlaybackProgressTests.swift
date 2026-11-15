import Combine
import XCTest
@testable import MeetingDesk

final class PlaybackProgressTests: XCTestCase {
    @MainActor func testPausedPollingDoesNotRedrawWorkspaceAndResumeStillPublishes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("playback-progress-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let domain = "playback-progress-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: defaults)
        var emissions = 0
        let subscription = store.objectWillChange.sink { emissions += 1 }
        defer { subscription.cancel() }
        for _ in 0..<100 { store.publishPlaybackProgress(time: 0, playing: false) }
        XCTAssertEqual(emissions, 0, "Idle/paused polling must not trigger workspace redraws")
        store.publishPlaybackProgress(time: 12, playing: true)
        XCTAssertEqual(store.playbackTime, 12)
        XCTAssertTrue(store.isPlaying)
        let playingEmissions = emissions
        store.publishPlaybackProgress(time: 12.2, playing: true)
        XCTAssertGreaterThan(emissions, playingEmissions, "Active playback progress still updates")
        store.publishPlaybackProgress(time: 12.2, playing: false)
        XCTAssertFalse(store.isPlaying)
        let pausedEmissions = emissions
        for _ in 0..<100 { store.publishPlaybackProgress(time: 12.2, playing: false) }
        XCTAssertEqual(emissions, pausedEmissions)
        store.publishPlaybackProgress(time: 4, playing: false)
        XCTAssertEqual(store.playbackTime, 4, "Seeking while paused still updates")
        XCTAssertGreaterThan(emissions, pausedEmissions)
    }
}
