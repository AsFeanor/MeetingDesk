import AVFoundation
import XCTest
@testable import MeetingDesk

final class SpeakerDiarizationEngineTests: XCTestCase {
    func testEnrollmentRemovesOverlapAndBoundaryContamination() throws {
        let windows = try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: [
            turn("A", 0, 12), turn("B", 4, 8)
        ], duration: 12)
        XCTAssertEqual(windows.count, 2)
        XCTAssertEqual(windows[0].lowerBound, 0.15, accuracy: 1e-8)
        XCTAssertEqual(windows[0].upperBound, 3.85, accuracy: 1e-8)
        XCTAssertEqual(windows[1].lowerBound, 8.15, accuracy: 1e-8)
        XCTAssertEqual(windows[1].upperBound, 11.85, accuracy: 1e-8)
    }

    func testFullyOverlappingOrTooShortSpeechCannotBeEnrolled() {
        for turns in [[turn("A", 0, 10), turn("B", 0, 10)], [turn("A", 0, 3)]] {
            XCTAssertThrowsError(try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: turns, duration: 10))
        }
    }

    func testDuplicateTurnsCannotInflateAvailableSpeech() throws {
        XCTAssertThrowsError(try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: [
            turn("A", 0, 2.5), turn("A", 0, 2.5)
        ], duration: 10))
        let windows = try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: [
            turn("A", 0, 10), turn("A", 5, 20)
        ], duration: 20)
        XCTAssertEqual(windows.reduce(0, { $0 + $1.countSeconds }), 19.7, accuracy: 1e-8)
    }

    func testDifferentAudioSourceDoesNotContaminateCleanSpeech() throws {
        let turns = [turn("A", 0, 10), SpeakerTurn(speakerID: "microphone:B", source: .microphone, start: 0, end: 10)]
        let windows = try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: turns, duration: 10)
        XCTAssertEqual(windows.reduce(0, { $0 + $1.countSeconds }), 9.7, accuracy: 1e-8)
    }

    func testLongSpeechUsesBoundedAudioAndChunkCount() throws {
        let windows = try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: [turn("A", 0, 3600)], duration: 3600)
        XCTAssertLessThanOrEqual(windows.count, 12)
        XCTAssertEqual(windows.reduce(0, { $0 + $1.countSeconds }), 20, accuracy: 1e-8)
        XCTAssertTrue(windows.allSatisfy { $0.countSeconds <= 6 })
    }

    func testInvalidAndPastEndTurnsAreHandledWithoutTraps() throws {
        for invalid in [turn("A", -.infinity, 5), turn("A", 0, .nan), turn("A", 5, 4), turn("A", 0, 20)] {
            XCTAssertThrowsError(try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: [invalid], duration: 10))
        }
        let windows = try SpeakerDiarizationEngine.cleanWindows(speakerID: "system:A", turns: [
            turn("A", 0, 10), turn("B", 10.20, 10.24)
        ], duration: 10)
        XCTAssertFalse(windows.isEmpty)
        XCTAssertTrue(windows.allSatisfy { $0.upperBound <= 10 })
    }

    func testConversionPreservesDurationLeadingSilenceAndPrivateCleanup() throws {
        let folder = try SpeakerTestAudio.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("stereo.caf")
        try SpeakerTestAudio.write(url: url, sampleRate: 48_000, channels: 2, duration: 1.25, leadingSilence: 0.25)
        let input = try SpeakerAudioInput.make(url: url)
        defer { try? input.cleanup() }
        XCTAssertEqual(input.duration, 1.25, accuracy: 0.002)
        let silence = try input.samples(in: 0..<0.20)
        XCTAssertLessThan(silence.map(abs).max() ?? 1, 1e-6)
        let speech = try input.samples(in: 0.4..<0.8)
        XCTAssertGreaterThan(speech.map(abs).max() ?? 0, 0.05)
        let mode = try FileManager.default.attributesOfItem(atPath: input.folder.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(mode?.intValue, 0o700)
        let rawMode = try FileManager.default.attributesOfItem(atPath: input.folder.appendingPathComponent("audio.f32").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(rawMode?.intValue, 0o600)
        try input.cleanup()
        XCTAssertFalse(FileManager.default.fileExists(atPath: input.folder.path))
    }

    func testCancellationStopsBeforeAudioConversionOrModelPreparation() async throws {
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try SpeakerAudioInput.make(url: URL(fileURLWithPath: "/not-a-recording.wav"))
        }
        do { _ = try await task.value; XCTFail("Canceled audio conversion must throw") }
        catch is CancellationError { }
        let engine = SpeakerDiarizationEngine()
        let preparation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await engine.prepareModels()
        }
        do { try await preparation.value; XCTFail("Canceled preparation must not download") }
        catch is CancellationError { }
    }

    func testFixedEmbeddingWindowAtEOFCopiesRealTailAndPadsOnlyMissingSamples() throws {
        let folder = try SpeakerTestAudio.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("short-tail.caf")
        try SpeakerTestAudio.write(url: url, sampleRate: 16_000, duration: 1.25)
        let input = try SpeakerAudioInput.make(url: url)
        defer { try? input.cleanup() }
        let originalCount = input.sampleCount
        let tailCount = 128
        let realTail = Array(try input.samples(in: 0..<input.duration).suffix(tailCount))
        var window = [Float](repeating: .nan, count: 160_000)
        try window.withUnsafeMutableBufferPointer { pointer in
            try input.copySamples(into: pointer.baseAddress!, offset: originalCount - tailCount, count: pointer.count)
        }
        XCTAssertEqual(Array(window.prefix(realTail.count)), realTail)
        XCTAssertTrue(window.dropFirst(tailCount).allSatisfy { $0 == 0 })
        XCTAssertEqual(input.sampleCount, originalCount)
        XCTAssertEqual(input.duration, 1.25, accuracy: 0.002)
        var afterEOF = [Float](repeating: .nan, count: 16)
        try afterEOF.withUnsafeMutableBufferPointer { pointer in
            try input.copySamples(into: pointer.baseAddress!, offset: originalCount + 1, count: pointer.count)
        }
        XCTAssertEqual(afterEOF, [Float](repeating: 0, count: 16))
    }

    func testModelFingerprintTracksBothActualArtifactsAndIgnoresLegacyModels() throws {
        let folder = try SpeakerTestAudio.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        for name in ["CamPlusPreprocessor_v2.mlmodelc", "CamPlusPlus_v2.mlmodelc"] {
            let artifact = folder.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: artifact, withIntermediateDirectories: false)
            try Data(name.utf8).write(to: artifact.appendingPathComponent("weights.bin"))
        }
        let original = try SpeakerDiarizationEngine.modelFingerprint(in: folder)
        try Data("unused v1".utf8).write(to: folder.appendingPathComponent("CamPlusPlus.mlmodelc"))
        XCTAssertEqual(try SpeakerDiarizationEngine.modelFingerprint(in: folder), original)
        try Data("changed weights".utf8).write(to: folder.appendingPathComponent("CamPlusPreprocessor_v2.mlmodelc/weights.bin"))
        XCTAssertNotEqual(try SpeakerDiarizationEngine.modelFingerprint(in: folder), original)
    }

    private func turn(_ speaker: String, _ start: Double, _ end: Double) -> SpeakerTurn {
        SpeakerTurn(speakerID: "system:\(speaker)", source: .system, start: start, end: end)
    }
}

private extension Range where Bound == Double {
    var countSeconds: Double { upperBound - lowerBound }
}

enum SpeakerTestAudio {
    static func makeFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-SpeakerTest-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        return folder
    }

    static func write(url: URL, sampleRate: Double, channels: AVAudioChannelCount = 1, duration: Double, leadingSilence: Double = 0) throws {
        let count = Int(sampleRate * duration)
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count)))
        buffer.frameLength = AVAudioFrameCount(count)
        for channel in 0..<Int(channels) {
            for index in 0..<count {
                let time = Double(index) / sampleRate
                buffer.floatChannelData![channel][index] = time < leadingSilence ? 0 : Float(sin(time * 2 * .pi * 230) * 0.2)
            }
        }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
