import AVFoundation
import Foundation
import XCTest
@testable import MeetingDesk

final class MicrophoneAudioPreparationTests: XCTestCase {
    func testASRReceivesBoostedPrivateMicrophoneCopyAndUnchangedSystemTrack() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let micBytes = try Data(contentsOf: fixture.microphone)
        let systemBytes = try Data(contentsOf: fixture.system)
        let calls = PreparedAudioCalls()
        let service = ChannelTranscriptionService(temporaryRoot: fixture.scratch) { url, _, _ in
            let audio = try readPreparedAudio(url)
            await calls.append(url: url, audio: audio)
            if url != fixture.system {
                let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
                let folderPermissions = try FileManager.default.attributesOfItem(atPath: url.deletingLastPathComponent().path)[.posixPermissions] as? NSNumber
                XCTAssertEqual(permissions?.intValue, 0o600)
                XCTAssertEqual(folderPermissions?.intValue, 0o700)
            }
            return [TranscriptSegment(id: "local-1", speaker: "Konuşma", start: 2, end: 5,
                text: url == fixture.system ? "Remote speech is present." : "Microphone speech is present.")]
        }
        let result = try await service.transcribe(mixedURL: fixture.mixed, microphoneURL: fixture.microphone,
            systemURL: fixture.system, language: "Türkçe", microphoneGain: 2)
        let recorded = await calls.values()
        XCTAssertEqual(recorded.count, 2)
        let prepared = try XCTUnwrap(recorded.first)
        XCTAssertNotEqual(prepared.url, fixture.microphone)
        XCTAssertEqual(prepared.url.pathExtension, "caf")
        XCTAssertEqual(prepared.audio.sampleRate, 48_000)
        XCTAssertEqual(prepared.audio.frameCount, AudioPreparationFixture.frames)
        XCTAssertEqual(prepared.audio.samples[0], 0)
        XCTAssertEqual(prepared.audio.samples[2], RecorderMix.sample(system: 0, microphone: 0.1, microphoneGain: 2), accuracy: 0.00001)
        XCTAssertEqual(prepared.audio.samples[4], RecorderMix.sample(system: 0, microphone: 0.9, microphoneGain: 2), accuracy: 0.00001)
        XCTAssertEqual(recorded.last?.url, fixture.system)
        XCTAssertEqual(recorded.last?.audio.samples[2], Float(0.3))
        XCTAssertEqual(try Data(contentsOf: fixture.microphone), micBytes)
        XCTAssertEqual(try Data(contentsOf: fixture.system), systemBytes)
        XCTAssertFalse(FileManager.default.fileExists(atPath: prepared.url.path))
        XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
        XCTAssertTrue(result.sourceSeparated)
        XCTAssertEqual(result.segments.count, 2)
    }

    func testPreviewGainUsesCaptureClampAndSoftLimiter() throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.microphone)
        for (index, gain) in [0.0, 1, 4, 10, Double.nan].enumerated() {
            let output = fixture.root.appendingPathComponent("preview-\(index).caf")
            try MicrophoneAudioPreparation.makePreview(input: fixture.microphone, output: output, gain: gain)
            let audio = try readPreparedAudio(output)
            XCTAssertEqual(audio.frameCount, AudioPreparationFixture.frames)
            XCTAssertEqual(audio.samples[2], RecorderMix.sample(system: 0, microphone: 0.1, microphoneGain: gain), accuracy: 0.00001)
            XCTAssertEqual(audio.samples[4], RecorderMix.sample(system: 0, microphone: 0.9, microphoneGain: gain), accuracy: 0.00001)
            XCTAssertLessThanOrEqual(abs(audio.samples[4]), 1)
        }
        XCTAssertEqual(try Data(contentsOf: fixture.microphone), original)
    }

    func testDefaultAndBelowMinimumGainDoNotCreatePreparationFiles() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        for gain in [1.0, 0, -5] {
            let calls = PreparedAudioCalls()
            let service = ChannelTranscriptionService(temporaryRoot: fixture.scratch) { url, _, _ in
                await calls.append(url: url, audio: try readPreparedAudio(url))
                return [TranscriptSegment(id: "local-1", speaker: "Konuşma", start: 1, end: 2, text: "Speech.")]
            }
            _ = try await service.transcribe(mixedURL: fixture.mixed, microphoneURL: fixture.microphone,
                systemURL: fixture.system, language: "English", microphoneGain: gain)
            let recorded = await calls.values()
            XCTAssertEqual(recorded.map(\.url), [fixture.microphone, fixture.system])
            XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
        }
    }

    func testMixedFallbackDoesNotApplyMicrophoneGainToWholeRecording() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let calls = PreparedAudioCalls()
        let service = ChannelTranscriptionService(temporaryRoot: fixture.scratch) { url, _, _ in
            await calls.append(url: url, audio: try readPreparedAudio(fixture.microphone))
            return [TranscriptSegment(id: "local-1", speaker: "Konuşma", start: 1, end: 2, text: "Mixed speech.")]
        }
        let result = try await service.transcribe(mixedURL: fixture.mixed, microphoneURL: fixture.microphone,
            systemURL: nil, language: "English", microphoneGain: 4)
        let recorded = await calls.values()
        XCTAssertEqual(recorded.map(\.url), [fixture.mixed])
        XCTAssertFalse(result.sourceSeparated)
        XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
    }

    func testASRFailureRemovesTemporaryCopyAndPreservesSource() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.microphone)
        let calls = PreparedAudioCalls()
        let service = ChannelTranscriptionService(temporaryRoot: fixture.scratch) { url, _, _ in
            await calls.append(url: url, audio: try readPreparedAudio(url))
            throw MeetingError.message("Synthetic model failure")
        }
        do {
            _ = try await service.transcribe(mixedURL: fixture.mixed, microphoneURL: fixture.microphone,
                systemURL: fixture.system, language: "English", microphoneGain: 3)
            XCTFail("Model failure must propagate")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Synthetic model failure")) }
        let recorded = await calls.values()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorded.first).url.path))
        XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.microphone), original)
    }

    func testCancellationDuringASRRemovesTemporaryCopyBeforeReturning() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.microphone)
        let calls = PreparedAudioCalls()
        let service = ChannelTranscriptionService(temporaryRoot: fixture.scratch) { url, _, _ in
            await calls.append(url: url, audio: try readPreparedAudio(url))
            withUnsafeCurrentTask { $0?.cancel() }
            return [TranscriptSegment(id: "local-1", speaker: "Konuşma", start: 1, end: 2, text: "Cancelled speech.")]
        }
        let task = Task {
            try await service.transcribe(mixedURL: fixture.mixed, microphoneURL: fixture.microphone,
                systemURL: fixture.system, language: "English", microphoneGain: 2)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch { XCTAssertTrue(error is CancellationError) }
        let recorded = await calls.values()
        XCTAssertEqual(recorded.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: try XCTUnwrap(recorded.first).url.path))
        XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
        XCTAssertEqual(try Data(contentsOf: fixture.microphone), original)
    }

    func testPreparationFailureRemovesItsPrivateFolderWithoutCallingASR() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let invalid = fixture.root.appendingPathComponent("invalid.caf")
        let bytes = Data("invalid audio bytes".utf8)
        try bytes.write(to: invalid)
        let service = ChannelTranscriptionService(temporaryRoot: fixture.scratch) { _, _, _ in
            XCTFail("Unreadable audio must never reach ASR")
            return []
        }
        do {
            _ = try await service.transcribe(mixedURL: fixture.mixed, microphoneURL: invalid,
                systemURL: fixture.system, language: "English", microphoneGain: 2)
            XCTFail("Unreadable audio must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("Mikrofon")) }
        XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
        XCTAssertEqual(try Data(contentsOf: invalid), bytes)
    }

    func testCancelledPreparationNeverCreatesOutput() async throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let output = fixture.root.appendingPathComponent("cancelled.caf")
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try MicrophoneAudioPreparation.makePreview(input: fixture.microphone, output: output, gain: 2)
        }
        do { try await task.value; XCTFail("Cancelled preparation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
        XCTAssertTrue(try scratchFiles(fixture.scratch).isEmpty)
    }

    func testPreviewRefusesToOverwriteSourceOrExistingOutput() throws {
        let fixture = try AudioPreparationFixture()
        defer { try? FileManager.default.removeItem(at: fixture.root) }
        let original = try Data(contentsOf: fixture.microphone)
        let system = try Data(contentsOf: fixture.system)
        XCTAssertThrowsError(try MicrophoneAudioPreparation.makePreview(input: fixture.microphone, output: fixture.microphone, gain: 4))
        XCTAssertThrowsError(try MicrophoneAudioPreparation.makePreview(input: fixture.microphone, output: fixture.system, gain: 4))
        XCTAssertEqual(try Data(contentsOf: fixture.microphone), original)
        XCTAssertEqual(try Data(contentsOf: fixture.system), system)
    }
}

private struct AudioPreparationFixture {
    static let frames: AVAudioFrameCount = 16_384
    let root: URL
    let scratch: URL
    let mixed: URL
    let microphone: URL
    let system: URL

    init() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-MicPreparationTests-\(UUID())", isDirectory: true)
        scratch = root.appendingPathComponent("scratch", isDirectory: true)
        mixed = root.appendingPathComponent("unused-mixed.caf")
        microphone = root.appendingPathComponent("microphone.caf")
        system = root.appendingPathComponent("system.caf")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try writePreparationAudio(microphone, values: [0, 0, 0.1, 0.4, 0.9, -0.8])
        try writePreparationAudio(system, values: [0.3])
    }
}

private struct PreparedAudioSnapshot {
    let samples: [Float]
    let sampleRate: Double
    let frameCount: AVAudioFrameCount
}

private actor PreparedAudioCalls {
    struct Call {
        let url: URL
        let audio: PreparedAudioSnapshot
    }
    private var captured: [Call] = []
    func append(url: URL, audio: PreparedAudioSnapshot) { captured.append(Call(url: url, audio: audio)) }
    func values() -> [Call] { captured }
}

private func writePreparationAudio(_ url: URL, values: [Float]) throws {
    let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AudioPreparationFixture.frames))
    buffer.frameLength = AudioPreparationFixture.frames
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    for index in 0..<Int(buffer.frameLength) { samples[index] = values[index % values.count] }
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    try file.write(from: buffer)
}

private func readPreparedAudio(_ url: URL) throws -> PreparedAudioSnapshot {
    let file = try AVAudioFile(forReading: url)
    let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length)))
    try file.read(into: buffer)
    let samples = try XCTUnwrap(buffer.floatChannelData?[0])
    return PreparedAudioSnapshot(samples: Array(UnsafeBufferPointer(start: samples, count: Int(buffer.frameLength))),
                                 sampleRate: file.processingFormat.sampleRate, frameCount: buffer.frameLength)
}

private func scratchFiles(_ url: URL) throws -> [URL] {
    try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
}
