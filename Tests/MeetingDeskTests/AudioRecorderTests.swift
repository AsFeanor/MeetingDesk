import XCTest
import AVFoundation
import CoreMedia
@testable import MeetingDesk

final class AudioRecorderTests: XCTestCase {
    func testMicrophoneBoostRaisesQuietSpeechWithoutRaisingSystemOrSilence() {
        let quietMicrophone: Float = 0.015
        let original = RecorderMix.sample(system: 0, microphone: quietMicrophone, microphoneGain: 1)
        let boosted = RecorderMix.sample(system: 0, microphone: quietMicrophone, microphoneGain: 2)
        XCTAssertEqual(boosted, original * 2, accuracy: 0.000_001)
        XCTAssertEqual(20 * log10(Double(boosted / original)), 6.0206, accuracy: 0.001)
        XCTAssertEqual(RecorderMix.sample(system: 0.45, microphone: 0, microphoneGain: 1),
                       RecorderMix.sample(system: 0.45, microphone: 0, microphoneGain: 4))
        XCTAssertEqual(RecorderMix.sample(system: 0, microphone: 0, microphoneGain: 4), 0)
    }

    func testBoostLimiterIsLinearForSpeechAndBoundsOverloadWithoutHardClipping() {
        XCTAssertEqual(RecorderMix.sample(system: 0.3, microphone: 0.04, microphoneGain: 2),
                       Float((0.3 + 0.04 * 2) * 0.7071), accuracy: 0.000_001)
        let onset = RecorderMix.sample(system: 0.8, microphone: 0.25, microphoneGain: 2)
        XCTAssertGreaterThan(onset, 0.85)
        XCTAssertLessThan(onset, 1)
        for gain in [1.0, 2.0, 4.0, Double.infinity, Double.nan, 100.0] {
            for system: Float in [-1, -0.7, 0, 0.7, 1, .infinity, .nan] {
                for microphone: Float in [-1, -0.4, 0, 0.4, 1, .infinity, .nan] {
                    let mixed = RecorderMix.sample(system: system, microphone: microphone, microphoneGain: gain)
                    XCTAssertTrue(mixed.isFinite)
                    XCTAssertLessThanOrEqual(abs(mixed), 1)
                }
            }
        }
        XCTAssertEqual(RecorderMix.sample(system: 0.8, microphone: 0.25, microphoneGain: 2),
                       -RecorderMix.sample(system: -0.8, microphone: -0.25, microphoneGain: 2))
    }

    func testGainRecoveryAndLegacyManifestKeepOriginalSourceData() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.m4a")
        let session = try PCMRecordingSession(destination: destination, origin: 100, microphoneGain: 3)
        let frames: [Float] = [0.01, -0.02, 0, 0.03]
        try frames.withUnsafeBufferPointer { try session.write($0, hostStart: 100, source: .microphone) }
        try session.freeze(at: 100 + Double(frames.count) / PCMRecordingSession.sampleRate)
        try session.closePartial()
        let raw = try Data(contentsOf: session.recoveryDirectory.appendingPathComponent("microphone.f32pcm"))
        XCTAssertEqual(raw, frames.withUnsafeBytes { Data($0) })
        XCTAssertEqual(try PCMRecordingSession(recoverDestination: destination).microphoneGain, 3)
        let manifestURL = session.recoveryDirectory.appendingPathComponent("recovery.json")
        var legacyManifest = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: manifestURL)) as? [String: Any])
        legacyManifest.removeValue(forKey: "microphoneGain")
        try JSONSerialization.data(withJSONObject: legacyManifest).write(to: manifestURL)
        let recoveredLegacy = try PCMRecordingSession(recoverDestination: destination)
        XCTAssertEqual(recoveredLegacy.microphoneGain, 1)
        XCTAssertEqual(recoveredLegacy.duration(at: 1000), Double(frames.count) / PCMRecordingSession.sampleRate, accuracy: 0.0001)
    }

    func testPublicationReceiptSurvivesRestartAndRejectsUnrelatedOrModifiedFiles() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.m4a")
        let session = try PCMRecordingSession(destination: destination, origin: 100, microphoneGain: 2)
        let frames: [Float] = [0.01, -0.01]
        try frames.withUnsafeBufferPointer { try session.write($0, hostStart: 100, source: .microphone) }
        try session.freeze(at: 100 + Double(frames.count) / PCMRecordingSession.sampleRate)
        let pending = session.recoveryDirectory.appendingPathComponent("microphone.m4a")
        let microphone = directory.appendingPathComponent("meeting-microphone.m4a")
        try Data("staged source fixture".utf8).write(to: pending)
        try session.recordPublication(pending: pending, final: microphone)
        try FileManager.default.moveItem(at: pending, to: microphone)
        try session.closePartial()
        let recovered = try PCMRecordingSession(recoverDestination: destination)
        XCTAssertTrue(try recovered.ownsPublishedFile(microphone))
        let unrelated = directory.appendingPathComponent("meeting-system.m4a")
        let unrelatedData = Data("unrelated existing audio".utf8)
        try unrelatedData.write(to: unrelated)
        XCTAssertFalse(try recovered.ownsPublishedFile(unrelated))
        XCTAssertThrowsError(try recovered.finish())
        XCTAssertEqual(try Data(contentsOf: unrelated), unrelatedData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: recovered.recoveryDirectory.appendingPathComponent("microphone.f32pcm").path))
        let modified = try FileHandle(forWritingTo: microphone)
        try modified.seekToEnd()
        try modified.write(contentsOf: Data("changed".utf8))
        try modified.close()
        XCTAssertFalse(try recovered.ownsPublishedFile(microphone))
        XCTAssertThrowsError(try recovered.finish())
        XCTAssertEqual(try String(contentsOf: microphone, encoding: .utf8), "staged source fixturechanged")
    }

    func testInterruptedSourcePublicationRecoversWithoutReplacingAlreadyPublishedAudio() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let availability = try AVAssetWriter(outputURL: directory.appendingPathComponent("codec-check.m4a"), fileType: .m4a)
        let codec: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 24_000.0,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
        guard availability.canApply(outputSettings: codec, forMediaType: .audio) else {
            throw XCTSkip("AAC unavailable in shell; RecorderBalanceRecoveryQA verifies interrupted native publication.")
        }
        for publishedCount in 1...3 {
            let name = "interrupted-\(publishedCount)"
            let destination = directory.appendingPathComponent("\(name).m4a")
            let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
            let session = try PCMRecordingSession(destination: destination, origin: origin, microphoneGain: 2)
            let samples = (0..<24_000).map { Float(0.025 * sin(2 * Double.pi * 440 * Double($0) / PCMRecordingSession.sampleRate)) }
            try samples.withUnsafeBufferPointer { try session.write($0, hostStart: origin, source: .microphone) }
            try session.freeze(at: origin + 1)
            let names = ["\(name)-microphone.m4a", "\(name)-system.m4a", "\(name).m4a"]
            var originals: [URL: String] = [:]
            for index in 0..<publishedCount {
                let pending = session.recoveryDirectory.appendingPathComponent("staged-\(index).m4a")
                let writer = try AACAudioFileWriter(url: pending, sampleRate: PCMRecordingSession.sampleRate)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: writer.processingFormat, frameCapacity: 24_000))
                buffer.frameLength = 24_000
                for frame in 0..<24_000 {
                    buffer.floatChannelData![0][frame] = index == 1 ? 0 : index == 2
                        ? RecorderMix.sample(system: 0, microphone: samples[frame], microphoneGain: 2) : samples[frame]
                }
                try writer.write(from: buffer)
                try writer.close()
                let final = directory.appendingPathComponent(names[index])
                try session.recordPublication(pending: pending, final: final)
                try FileManager.default.moveItem(at: pending, to: final)
                originals[final] = try RecorderPublicationIdentity.digest(final)
            }
            // Exactly the on-disk state left if the process exits between final moves.
            try session.closePartial()
            let recovered = try PCMRecordingSession(recoverDestination: destination)
            XCTAssertEqual(try recovered.finish(), 1, accuracy: 0.001)
            XCTAssertFalse(FileManager.default.fileExists(atPath: recovered.recoveryDirectory.path))
            for name in names { XCTAssertEqual(try AVAudioFile(forReading: directory.appendingPathComponent(name)).length, 24_000) }
            for (url, digest) in originals { XCTAssertEqual(try RecorderPublicationIdentity.digest(url), digest) }
        }
    }

    func testRawInputMetricsIgnorePausedAndOverlappingCallbacks() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let session = try PCMRecordingSession(destination: directory.appendingPathComponent("meeting.m4a"), origin: 100)
        try session.pause(at: 101)
        try session.resume(at: 102)
        let crossing = [Float](repeating: 0.02, count: 12_000) + [Float](repeating: 0.9, count: 24_000)
        try crossing.withUnsafeBufferPointer { try session.write($0, hostStart: 100.5, source: .microphone) }
        XCTAssertEqual(session.lastWriteMetrics?.frames, 12_000)
        XCTAssertEqual(try XCTUnwrap(session.lastWriteMetrics?.peak), 0.02, accuracy: 0.000_001)
        let paused = [Float](repeating: 1, count: 12_000)
        try paused.withUnsafeBufferPointer { try session.write($0, hostStart: 101.1, source: .microphone) }
        XCTAssertNil(session.lastWriteMetrics)
        let overlap = [Float](repeating: 1, count: 12_000)
        try overlap.withUnsafeBufferPointer { try session.write($0, hostStart: 100.5, source: .microphone) }
        XCTAssertNil(session.lastWriteMetrics)
        try session.closePartial()
    }

    func testSourcesShareTimestampPositionsRegardlessOfCallbackOrder() {
        let timeline = RecorderTimeline(origin: 100)
        let delayedMicrophone = timeline.placements(hostStart: 102, frameCount: 4, sampleRate: 2)
        let earlierSystem = timeline.placements(hostStart: 100, frameCount: 4, sampleRate: 2)
        XCTAssertEqual(delayedMicrophone, [.init(sourceOffset: 0, count: 4, targetFrame: 4)])
        XCTAssertEqual(earlierSystem, [.init(sourceOffset: 0, count: 4, targetFrame: 0)])
    }

    func testPauseDropsCrossingSamplesAndCompactsBothTracks() {
        var timeline = RecorderTimeline(origin: 10)
        timeline.pause(at: 12)
        timeline.resume(at: 14)
        XCTAssertEqual(timeline.placements(hostStart: 11, frameCount: 10, sampleRate: 2), [
            .init(sourceOffset: 0, count: 2, targetFrame: 2),
            .init(sourceOffset: 6, count: 4, targetFrame: 4)
        ])
        XCTAssertEqual(timeline.duration(at: 16), 4)
        timeline.pause(at: 16)
        XCTAssertEqual(timeline.duration(at: 20), 4)
        XCTAssertTrue(timeline.placements(hostStart: 17, frameCount: 4, sampleRate: 2).isEmpty)
    }

    func testResamplingPreservesContinuityAndReanchorsAfterSilenceGap() throws {
        let converter = RecorderPCMConverter()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        var expectedHost = 100.0
        var totalFrames = 0
        for block in 0..<100 {
            let input = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
            input.frameLength = 1024
            for frame in 0..<1024 {
                input.floatChannelData![0][frame] = Float(0.2 * sin(2 * Double.pi * 440 * Double(block * 1024 + frame) / 48_000))
            }
            let converted = try converter.convert(input, hostStart: 100 + Double(block * 1024) / 48_000)
            XCTAssertEqual(converted.hostStart, expectedHost, accuracy: 0.000_001)
            totalFrames += Int(converted.buffer.frameLength)
            expectedHost += Double(converted.buffer.frameLength) / 24_000
        }
        XCTAssertEqual(Double(totalFrames), 51_200, accuracy: 64)
        let afterGap = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
        afterGap.frameLength = 1024
        let converted = try converter.convert(afterGap, hostStart: 110)
        XCTAssertEqual(converted.hostStart, 110, accuracy: 0.000_001)
    }

    func testAACMixKeepsIndependentSourceTimingAndSilence() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.m4a")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let availability = try AVAssetWriter(outputURL: directory.appendingPathComponent("codec-check.m4a"), fileType: .m4a)
        let codec: [String: Any] = [AVFormatIDKey: Int(kAudioFormatMPEG4AAC), AVSampleRateKey: 24_000.0,
                                   AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 48_000]
        guard availability.canApply(outputSettings: codec, forMediaType: .audio) else {
            throw XCTSkip("Bu test ortamında macOS AAC kodlayıcısı kullanılamıyor. Native RecorderNativeQA uygulaması aynı karışımı ve kurtarmayı doğrular.")
        }
        let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let session = try PCMRecordingSession(destination: destination, origin: origin)
        let rate = PCMRecordingSession.sampleRate
        let tone = (0..<24_000).map { Float(0.2 * sin(2 * Double.pi * 440 * Double($0) / rate)) }
        // Microphone arrives first; system has a later one-second gap.
        try tone.withUnsafeBufferPointer { try session.write($0, hostStart: origin, source: .microphone) }
        try tone.withUnsafeBufferPointer { try session.write($0, hostStart: origin, source: .system) }
        try tone.withUnsafeBufferPointer { try session.write($0, hostStart: origin + 2, source: .system) }
        try session.freeze(at: origin + 3)
        XCTAssertEqual(try session.finish(), 3, accuracy: 0.001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.recoveryDirectory.path))
        let systemSource = try AVAudioFile(forReading: directory.appendingPathComponent("meeting-system.m4a"))
        let microphoneSource = try AVAudioFile(forReading: directory.appendingPathComponent("meeting-microphone.m4a"))
        XCTAssertEqual(systemSource.length, audioFrames(for: 3))
        XCTAssertEqual(microphoneSource.length, audioFrames(for: 3))
        let audio = try AVAudioFile(forReading: destination)
        XCTAssertEqual(audio.fileFormat.channelCount, 1)
        XCTAssertEqual(audio.fileFormat.sampleRate, rate)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: AVAudioFrameCount(audio.length)))
        try audio.read(into: buffer)
        let values = try XCTUnwrap(buffer.floatChannelData?[0])
        func rms(_ start: Double, _ end: Double) -> Double {
            let a = Int(start * rate), b = Int(end * rate)
            return sqrt((a..<b).reduce(0.0) { $0 + Double(values[$1] * values[$1]) } / Double(b - a))
        }
        XCTAssertEqual(rms(0.2, 0.8), 0.2, accuracy: 0.025)
        XCTAssertLessThan(rms(1.2, 1.8), 0.002)
        XCTAssertEqual(rms(2.2, 2.8), 0.1, accuracy: 0.02)
        let size = try XCTUnwrap((try FileManager.default.attributesOfItem(atPath: destination.path)[.size]) as? NSNumber)
        XCTAssertLessThan(size.intValue, 40_000)
    }

    private func audioFrames(for duration: Double) -> AVAudioFramePosition {
        AVAudioFramePosition(duration * PCMRecordingSession.sampleRate)
    }

    func testStopAcceptsOnlyFlushedSamplesBeforeStopBoundary() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let session = try PCMRecordingSession(destination: directory.appendingPathComponent("meeting.m4a"), origin: origin)
        try session.freeze(at: origin + 1)
        let frames = [Float](repeating: 0.2, count: 24_000)
        try frames.withUnsafeBufferPointer { try session.write($0, hostStart: origin + 0.5, source: .system) }
        try session.closePartial()
        let data = try Data(contentsOf: session.recoveryDirectory.appendingPathComponent("system.f32pcm"))
        XCTAssertEqual(data.count, 24_000 * MemoryLayout<Float>.size)
    }

    func testFailedFinalizationPreservesRawAudioAndRecoveryManifest() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.m4a")
        let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let session = try PCMRecordingSession(destination: destination, origin: origin)
        let frames = [Float](repeating: 0.2, count: 2_400)
        try frames.withUnsafeBufferPointer { try session.write($0, hostStart: origin, source: .microphone) }
        try session.freeze(at: origin + 0.1)
        try Data("Existing recording".utf8).write(to: destination)
        XCTAssertThrowsError(try session.finish())
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.recoveryDirectory.appendingPathComponent("microphone.f32pcm").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: session.recoveryDirectory.appendingPathComponent("recovery.json").path))
        XCTAssertEqual(try String(contentsOf: destination, encoding: .utf8), "Existing recording")
    }

    func testRecoveryIncludesFramesWrittenAfterLastCheckpoint() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.m4a")
        let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let session = try PCMRecordingSession(destination: destination, origin: origin)
        let frames = [Float](repeating: 0.1, count: 24_000)
        try frames.withUnsafeBufferPointer { try session.write($0, hostStart: origin, source: .microphone) }
        try session.closePartial()
        let recovery = try PCMRecordingSession(recoverDestination: destination)
        XCTAssertEqual(recovery.duration(at: 1_000), 1, accuracy: 0.001)
    }

    func testFailedStartWithNoAudioCanRetryButRecordedAudioIsProtected() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let destination = directory.appendingPathComponent("meeting.m4a")
        let origin = CMTimeGetSeconds(CMClockGetTime(CMClockGetHostTimeClock()))
        let empty = try PCMRecordingSession(destination: destination, origin: origin)
        try empty.closePartial()
        let retry = try PCMRecordingSession(destination: destination, origin: origin)
        let frames = [Float](repeating: 0.1, count: 100)
        try frames.withUnsafeBufferPointer { try retry.write($0, hostStart: origin, source: .microphone) }
        try retry.closePartial()
        XCTAssertThrowsError(try PCMRecordingSession(destination: destination, origin: origin))
        XCTAssertEqual(try Data(contentsOf: retry.recoveryDirectory.appendingPathComponent("microphone.f32pcm")).count, 400)
    }
}
