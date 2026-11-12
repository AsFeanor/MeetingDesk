import AVFoundation
import CryptoKit
import XCTest
@testable import MeetingDesk

/// Opt-in real model check. Ordinary tests never fetch models or read fixtures.
/// Inputs are pinned public human recordings, not user meeting archives.
final class SpeakerModelIntegrationTests: XCTestCase {
    func testRealDiarizationEnrollmentAndIndependentVoiceRecognition() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEETINGDESK_SPEAKER_MODEL_CHECK"] == "1" else {
            throw XCTSkip("Real speaker models run only with MEETINGDESK_SPEAKER_MODEL_CHECK=1")
        }
        let root = URL(fileURLWithPath: try XCTUnwrap(environment["MEETINGDESK_SPEAKER_FIXTURE_ROOT"]), isDirectory: true)
        let cache = URL(fileURLWithPath: try XCTUnwrap(environment["MEETINGDESK_SPEAKER_MODEL_CACHE"]), isDirectory: true)
        let enrollURL = try fixture("Vocabulary/quilter.wav", sha256: "799f78ed4beb4de7ceae3a809262d4ce242394342ccd1d58cef7d49dbc2def46", root: root)
        let knownURL = try fixture("Vocabulary/quilter-possessive.wav", sha256: "473b1bb573e8f7cdcd639c6e318036236190107b66bfe6892286121a92d464c1", root: root)
        let otherURL = try fixture("03-diff-explanation-16.9s.wav", sha256: "83f670fa70b12e64a1c5195d948937605c0e4786d5cefea3d3feb0b3b47cde36", root: root)
        let enrollmentAudio = try audio(enrollURL)
        let knownAudio = try audio(knownURL)
        let otherAudio = try audio(otherURL)
        let folder = try SpeakerTestAudio.makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let engine = SpeakerDiarizationEngine(cacheRoot: cache)
        try await engine.prepareModels()

        let enrollment = try await engine.sample(audioURL: enrollURL, speakerID: "system:enrollment", turns: [
            fullTurn("enrollment", duration: Double(enrollmentAudio.count) / 16_000)
        ])
        XCTAssertEqual(enrollment.embedding.count, 192)
        XCTAssertTrue(enrollment.modelID.hasPrefix("campplus-coreml-v2-192-"))
        XCTAssertGreaterThanOrEqual(enrollment.cleanDuration, 3)
        let profiles = try VoiceProfileEnrollment.remember(name: "Public fixture speaker 1272", sample: enrollment, existing: [])
        let store = VoiceProfileStore(root: folder.appendingPathComponent("profiles"))
        try store.save(profiles)
        let restored = try store.load()
        XCTAssertEqual(restored, profiles)

        // A different utterance from the same documented LibriSpeech speaker.
        let known = try await engine.sample(audioURL: knownURL, speakerID: "system:held-out", turns: [
            fullTurn("held-out", duration: Double(knownAudio.count) / 16_000)
        ])
        let knownMatch = try XCTUnwrap(VoiceProfileMatcher.match(sample: known, profiles: restored), "Held-out same-speaker speech must produce a recognition suggestion")
        XCTAssertEqual(knownMatch.profileID, profiles[0].id)
        let other = try await engine.sample(audioURL: otherURL, speakerID: "system:other", turns: [
            fullTurn("other", duration: Double(otherAudio.count) / 16_000)
        ])
        let otherMatch = VoiceProfileMatcher.match(sample: other, profiles: restored)
        XCTAssertNotEqual(otherMatch?.automatic, true, "A different real voice must not receive the enrolled identity automatically")
        let knownScore = try XCTUnwrap(VoiceVector.cosine(enrollment.embedding, known.embedding))
        let otherScore = try XCTUnwrap(VoiceVector.cosine(enrollment.embedding, other.embedding))
        XCTAssertGreaterThan(knownScore, otherScore)

        // Controlled edit of three real utterances: A, B, A. This is not a natural
        // meeting or a Turkish accuracy benchmark. No synthetic voice is used.
        let gap = [Float](repeating: 0, count: 24_000)
        let middleAudio = Array(otherAudio.prefix(16_000 * 12))
        let middleOffset = Double(enrollmentAudio.count + gap.count) / 16_000
        let finalOffset = middleOffset + Double(middleAudio.count + gap.count) / 16_000
        let combined = enrollmentAudio + gap + middleAudio + gap + knownAudio
        let combinedURL = folder.appendingPathComponent("public-two-speaker-edit.caf")
        try writeAudio(combined, to: combinedURL)
        let analysis = try await engine.analyze(audioURL: combinedURL, source: .system)
        let duration = Double(combined.count) / 16_000
        XCTAssertGreaterThanOrEqual(Set(analysis.turns.map(\.speakerID)).count, 2)
        XCTAssertTrue(analysis.turns.allSatisfy { $0.source == .system && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end <= duration && $0.end > $0.start })
        XCTAssertTrue(analysis.samples.allSatisfy { $0.embedding.count == 192 && $0.modelID == enrollment.modelID })

        // Probe times come from input energy, independently of the diarizer.
        // This exercises the production timestamp-to-transcript assignment.
        let ranges = [loudSpeechRange(enrollmentAudio, offset: 0),
                      loudSpeechRange(middleAudio, offset: middleOffset),
                      loudSpeechRange(knownAudio, offset: finalOffset)]
        let transcript = ranges.enumerated().map { index, range in
            TranscriptSegment(id: "local-system-probe-\(index)", speaker: "Toplantı sesi", start: range.lowerBound,
                              end: range.upperBound, text: "probe", words: [TranscriptWord(text: "probe", start: range.lowerBound, end: range.upperBound)], audioSource: .system)
        }
        let assigned = try SpeakerTranscriptAlignment.assign(transcript, turns: analysis.turns)
        XCTAssertEqual(assigned.count, 3)
        guard assigned.count == 3 else { return }
        XCTAssertTrue(assigned.allSatisfy { $0.speaker.hasPrefix("system:") }, "Clean known speech must receive a diarized source identity")
        XCTAssertEqual(assigned[0].speaker, assigned[2].speaker, "The same real voice should retain its cluster across the second speaker")
        XCTAssertNotEqual(assigned[0].speaker, assigned[1].speaker)
        XCTAssertEqual(assigned.map(\.text), transcript.map(\.text))
        XCTAssertEqual(assigned.map(\.start), transcript.map(\.start))
        XCTAssertEqual(assigned.map(\.end), transcript.map(\.end))

        let metrics: [String: Any] = ["modelID": enrollment.modelID, "knownSimilarity": knownScore,
            "knownAutomatic": knownMatch.automatic, "otherSimilarity": otherScore,
            "otherAutomatic": otherMatch?.automatic ?? false, "turns": analysis.turns.count,
            "speakerCount": Set(analysis.turns.map(\.speakerID)).count, "voiceSamples": analysis.samples.count,
            "duration": duration, "privateRecordingsRead": false, "naturalMeetingBenchmark": false,
            "turkishAccuracyVerified": false]
        let data = try JSONSerialization.data(withJSONObject: metrics, options: [.prettyPrinted, .sortedKeys])
        if let report = environment["MEETINGDESK_SPEAKER_REPORT_PATH"] {
            try data.write(to: URL(fileURLWithPath: report), options: .atomic)
        }
        print("Public speaker model check: " + String(decoding: data, as: UTF8.self))
    }

    private func fixture(_ path: String, sha256: String, root: URL) throws -> URL {
        let url = root.appendingPathComponent(path)
        let bytes = try Data(contentsOf: url)
        XCTAssertEqual(SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), sha256,
                       "Only pinned public fixtures may be used by this model check")
        guard SHA256.hash(data: bytes).map({ String(format: "%02x", $0) }).joined() == sha256 else {
            throw SpeakerEngineError.invalidAudio
        }
        return url
    }

    private func audio(_ url: URL) throws -> [Float] {
        let input = try SpeakerAudioInput.make(url: url)
        defer { try? input.cleanup() }
        return try input.samples(in: 0..<input.duration)
    }

    private func fullTurn(_ suffix: String, duration: Double) -> SpeakerTurn {
        SpeakerTurn(speakerID: "system:\(suffix)", source: .system, start: 0, end: duration)
    }

    private func loudSpeechRange(_ samples: [Float], offset: Double) -> Range<Double> {
        let window = 16_000
        var best = 8_000
        var energy = -Double.infinity
        for first in stride(from: 8_000, through: max(8_000, samples.count - window - 8_000), by: 4_000) {
            let value = samples[first..<min(samples.count, first + window)].reduce(0.0) { $0 + Double($1) * Double($1) }
            if value > energy { energy = value; best = first }
        }
        return (offset + Double(best) / 16_000 + 0.25)..<(offset + Double(best) / 16_000 + 0.75)
    }

    private func writeAudio(_ samples: [Float], to url: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)))
        buffer.frameLength = AVAudioFrameCount(samples.count)
        samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!, count: samples.count) }
        let file = try AVAudioFile(forWriting: url, settings: format.settings)
        try file.write(from: buffer)
    }
}
