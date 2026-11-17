import AVFoundation
import Foundation
import XCTest
@testable import MeetingDesk

final class WhisperTranscriptionTests: XCTestCase {
    private let digest = String(repeating: "a", count: 64)
    private var configuration: VerifiedWhisperConfiguration {
        VerifiedWhisperConfiguration(modelDirectory: URL(fileURLWithPath: "/synthetic-model"),
            modelIdentifier: "mlx-community/whisper-large-v3-turbo",
            modelRevision: "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
            implementationVersion: "mlx-whisper-0.4.3+meetingdesk-ipc1",
            decodingStrategyID: "window-auto-20s-v1", acceptedLanguageModes: [.turkishEnglish])
    }
    private func request(_ identity: UUID = UUID()) -> WhisperWorkerRequest {
        WhisperWorkerRequest(schemaVersion: 1, requestID: identity, pcmPath: "/synthetic/audio.f32", pcmSHA256: digest,
            resultPath: "/synthetic/result.json", sampleRate: 16_000, frameCount: 160_000,
            fullTrackTimeOffset: 0, modelDirectory: configuration.modelDirectory.path,
            modelIdentifier: configuration.modelIdentifier, modelRevision: configuration.modelRevision,
            decodingStrategyID: configuration.decodingStrategyID, languageMode: .turkishEnglish, allowNoSpeech: true)
    }
    private func reply(_ request: WhisperWorkerRequest, segments: [WhisperWorkerSegment],
                       processed: Int64? = nil, sha: String? = nil, revision: String? = nil) -> WhisperWorkerReply {
        WhisperWorkerReply(schemaVersion: 1, requestID: request.requestID, backend: "mlx-whisper",
            modelIdentifier: configuration.modelIdentifier, modelRevision: revision ?? configuration.modelRevision,
            implementationVersion: configuration.implementationVersion, decodingStrategyID: configuration.decodingStrategyID,
            languageMode: .turkishEnglish, sampleRate: 16_000, sourceFrameCount: request.frameCount,
            processedFrameCount: processed ?? request.frameCount, pcmSHA256: sha ?? digest, complete: true, segments: segments)
    }
    private func map(_ segments: [WhisperWorkerSegment]) throws -> [TranscriptSegment] {
        let req = request()
        return try WhisperTranscriptionAdapter.segments(reply: reply(req, segments: segments), request: req,
            configuration: configuration, duration: 10)
    }

    func testOnlyMixedSpeechLanguageSelectsWhisper() throws {
        XCTAssertEqual(try LocalASRBackend.route(language: "Türkçe"), .apple)
        XCTAssertEqual(try LocalASRBackend.route(language: "English"), .apple)
        XCTAssertEqual(try LocalASRBackend.route(language: "Türkçe + English"), .mlxWhisper)
        XCTAssertThrowsError(try LocalASRBackend.route(language: "Klingon"))
        XCTAssertThrowsError(try WhisperLanguageMode(language: "Türkçe"))
    }

    func testGenuineWordTimesAndCodeSwitchTextArePreserved() throws {
        let result = try map([.init(text: "  Şu deadline tomorrow. ", start: 3, end: 5,
            words: [.init(text: " Şu", start: 3, end: 3.5), .init(text: " deadline", start: 3.5, end: 4),
                    .init(text: " tomorrow.", start: 4, end: 5)])])
        XCTAssertEqual(result[0].text, "Şu deadline tomorrow.")
        XCTAssertEqual(result[0].start, 3); XCTAssertEqual(result[0].end, 5)
        XCTAssertEqual(result[0].words?.map(\.start), [3, 3.5, 4])
        XCTAssertNil(result[0].wordTimingIssue)
    }

    func testMissingWordListsKeepTextTimelineAndExplicitIssue() throws {
        let result = try map([.init(text: "Türkçe and English remain.", start: 2, end: 7, words: nil)])
        XCTAssertEqual(result[0].text, "Türkçe and English remain.")
        XCTAssertEqual(result[0].start, 2); XCTAssertEqual(result[0].end, 7)
        XCTAssertNil(result[0].words); XCTAssertEqual(result[0].wordTimingIssue, .missing)
    }

    func testWordsOutsideSegmentAreOmittedWithoutExpandingSegmentOrFailingTrack() throws {
        let result = try map([.init(text: "Bir deadline.", start: 2, end: 4,
            words: [.init(text: "Bir", start: 1.98, end: 2.8), .init(text: " deadline.", start: 2.8, end: 4.02)])])
        XCTAssertEqual(result.count, 1); XCTAssertEqual(result[0].start, 2); XCTAssertEqual(result[0].end, 4)
        XCTAssertNil(result[0].words); XCTAssertEqual(result[0].wordTimingIssue, .nonFiniteOrBounds)
    }

    func testWorkerIssueIsConservativeEvenWithAnApparentlyValidWordList() throws {
        let result = try map([.init(text: "Hello.", start: 2, end: 4,
            words: [.init(text: "Hello.", start: 2, end: 4)], wordTimingIssue: "invalid")])
        XCTAssertNil(result[0].words); XCTAssertEqual(result[0].wordTimingIssue, .invalid)
    }

    func testWordJoinOrOrderMismatchOnlyDegradesAffectedSegment() throws {
        let values: [WhisperWorkerSegment] = [
            .init(text: "Source text.", start: 0, end: 2, words: [.init(text: "Different", start: 0, end: 2)]),
            .init(text: "Second phrase.", start: 3, end: 5,
                words: [.init(text: "Second", start: 4, end: 5), .init(text: " phrase.", start: 3, end: 4)])]
        let result = try map(values)
        XCTAssertEqual(result.map(\.wordTimingIssue), [.textMismatch, .unordered])
        XCTAssertEqual(result.map(\.text), values.map(\.text))
    }

    func testPartialFrameDigestAndModelMismatchAreFatal() {
        let req = request(), values = [WhisperWorkerSegment(text: "OK", start: 0, end: 1, words: nil)]
        for response in [reply(req, segments: values, processed: 159_999), reply(req, segments: values, sha: String(repeating: "b", count: 64)),
                         reply(req, segments: values, revision: "wrong")] {
            XCTAssertThrowsError(try WhisperTranscriptionAdapter.segments(reply: response, request: req,
                configuration: configuration, duration: 10))
        }
    }

    func testInvalidSegmentTimesStillRejectWholeTranscript() {
        for segment in [WhisperWorkerSegment(text: "Wrong", start: -1, end: 1, words: nil),
                        .init(text: "Wrong", start: 1, end: 11, words: nil)] { XCTAssertThrowsError(try map([segment])) }
    }

    func testFlaggedUtteranceNeverGetsIndividualFallbackEvenWithOneDominantTurn() throws {
        let input = TranscriptSegment(id: "local-system-1", speaker: "Toplantı sesi", start: 0, end: 10,
            text: "Ben tamamlayacağım, then you review.", wordTimingIssue: .invalid, audioSource: .system)
        let result = try SpeakerTranscriptAlignment.assign([input], turns: [.init(speakerID: "voice-1", source: .system, start: 0, end: 10)])
        XCTAssertEqual(result, [input])
    }

    func testLegacyWordlessUtteranceKeepsExistingFallback() throws {
        let input = TranscriptSegment(id: "local-system-1", speaker: "Toplantı sesi", start: 0, end: 10, text: "Eski toplantı.", audioSource: .system)
        let result = try SpeakerTranscriptAlignment.assign([input], turns: [.init(speakerID: "voice-1", source: .system, start: 0, end: 10)])
        XCTAssertEqual(result[0].speaker, "voice-1"); XCTAssertNil(result[0].wordTimingIssue)
    }

    func testIssueSurvivesChannelMergeAndArchiveRoundTrip() throws {
        var input = TranscriptSegment(id: "whisper-1", speaker: "Konuşma", start: 1, end: 2, text: "Karma speech.")
        input.wordTimingIssue = .missing
        let merged = try ChannelTranscriptionService.merge(microphone: [], system: [input])
        XCTAssertEqual(merged[0].wordTimingIssue, .missing)
        XCTAssertEqual(try JSONDecoder().decode([TranscriptSegment].self, from: JSONEncoder().encode(merged)), merged)
        let legacy = Data("{\"id\":\"old\",\"speaker\":\"Konuşma\",\"start\":0,\"end\":1,\"text\":\"Legacy\"}".utf8)
        XCTAssertNil(try JSONDecoder().decode(TranscriptSegment.self, from: legacy).wordTimingIssue)
    }

    func testPCMArithmeticDownmixPreservesFullTimelineAndDoesNotApplyGain() async throws {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WhisperPCMTest-\(UUID())")
        try WhisperPrivateFiles.makeDirectory(root, existingAllowed: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("synthetic.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 2, interleaved: false))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000)); buffer.frameLength = 16_000
        let channels = try XCTUnwrap(buffer.floatChannelData)
        for index in 0..<16_000 { channels[0][index] = index < 1_600 ? 0 : 0.2; channels[1][index] = index < 1_600 ? 0 : 0.6 }
        do { let file = try AVAudioFile(forWriting: source, settings: format.settings); try file.write(from: buffer) }
        let before = try WhisperPrivateFiles.sha256(source)
        let preparer = WhisperPCMPreparation(sessionDirectory: root)
        let pcm = try await preparer.prepare(audioURL: source, requestID: UUID())
        XCTAssertEqual(pcm.frameCount, 16_000); XCTAssertEqual(pcm.duration, 1)
        let data = try Data(contentsOf: pcm.file)
        let samples = data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        XCTAssertTrue(samples.prefix(1_600).allSatisfy { $0 == 0 })
        XCTAssertEqual(samples[5_000], 0.4, accuracy: 0.00001)
        XCTAssertEqual(try WhisperPrivateFiles.sha256(source), before)
        try await preparer.discard(pcm)
        XCTAssertFalse(FileManager.default.fileExists(atPath: pcm.file.path))
    }
}
