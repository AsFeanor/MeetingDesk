import CryptoKit
import Foundation
import Speech
import XCTest
@testable import MeetingDesk

final class TimedSpeechTextTests: XCTestCase {
    /// Explicit public-file check. It does not record audio or install speech assets.
    func testInstalledNativeSpeechPreservesPublicFixtureWordTiming() async throws {
        let environment = ProcessInfo.processInfo.environment
        guard environment["MEETINGDESK_SPEECH_TIMING_CHECK"] == "1" else {
            throw XCTSkip("Native speech timing runs only with MEETINGDESK_SPEECH_TIMING_CHECK=1")
        }
        guard #available(macOS 26, *) else { throw XCTSkip("Native speech timing requires macOS 26") }
        let requested = Locale(identifier: "en-US")
        let module: any SpeechModule
        let engine: String
        // Match LocalTranscriptionService's preferred engine. Do not select a
        // downloaded fallback if production would attempt to install the preferred one.
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            guard await SpeechTranscriber.installedLocales.contains(locale) else {
                throw XCTSkip("The preferred English SpeechTranscriber model is not installed; no download allowed")
            }
            module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            engine = "SpeechTranscriber"
        } else if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            guard await DictationTranscriber.installedLocales.contains(locale) else {
                throw XCTSkip("The English DictationTranscriber model is not installed; no download allowed")
            }
            module = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
            engine = "DictationTranscriber"
        } else { throw XCTSkip("No supported native English transcriber is available") }
        guard await AssetInventory.status(forModules: [module]) == .installed else {
            throw XCTSkip("English speech assets are not installed; no download allowed")
        }
        let path = try XCTUnwrap(environment["MEETINGDESK_SPEECH_TIMING_FIXTURE"], "Provide the pinned public quilter.wav fixture path")
        let url = URL(fileURLWithPath: path)
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        guard let bytes = attributes[.size] as? NSNumber, bytes.intValue > 0, bytes.intValue <= 1_048_576 else {
            XCTFail("Public fixture exceeds its expected bound")
            return
        }
        let data = try Data(contentsOf: url)
        let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard hash == "799f78ed4beb4de7ceae3a809262d4ce242394342ccd1d58cef7d49dbc2def46" else {
            XCTFail("Only the pinned FluidAudio LibriSpeech quilter.wav public fixture may be transcribed")
            return
        }
        let segments = try await LocalTranscriptionService().transcribe(audioURL: url, language: "English")
        XCTAssertFalse(segments.isEmpty, "The public fixture must produce speech")
        var timedUnits = 0
        var exactTextPreserved = true
        for segment in segments {
            let words = try XCTUnwrap(segment.words, "The public fixture must preserve native word times")
            XCTAssertFalse(words.isEmpty)
            let reconstructed = words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
            let original = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let textMatches = Array(reconstructed.utf8) == Array(original.utf8)
            exactTextPreserved = exactTextPreserved && textMatches
            XCTAssertTrue(textMatches, "Timed text must reconstruct every original byte")
            XCTAssertTrue(words.allSatisfy { $0.start.isFinite && $0.end.isFinite && $0.start >= segment.start && $0.end <= segment.end && $0.end >= $0.start })
            XCTAssertTrue(zip(words, words.dropFirst()).allSatisfy { $0.start <= $1.start && $0.end <= $1.end })
            timedUnits += words.count
        }
        XCTAssertGreaterThan(timedUnits, 1, "The recording must retain more than a single utterance-level timing range")
        print("Public native speech timing check: engine=\(engine), segments=\(segments.count), timedUnits=\(timedUnits), exactTextPreserved=\(exactTextPreserved)")
    }

    func testUntimedWhitespaceAndPunctuationPreserveNativeTimesAndExactUnicodeText() throws {
        let fragments = [
            fragment("\n“"), fragment("İyi", 1, 1.5), fragment("\u{00a0}"),
            fragment("günler", 1.6, 2.1), fragment(",\t"),
            fragment("çağrı", 2.2, 2.6), fragment(" — "),
            fragment("e\u{301}quipe", 2.7, 3.2), fragment("!”\n")
        ]
        let words = try XCTUnwrap(TimedSpeechText.words(from: fragments, start: 1, end: 4))
        XCTAssertEqual(words.map(\.text).joined(), fragments.map(\.text).joined())
        XCTAssertEqual(Array(words.map(\.text).joined().utf8), Array(fragments.map(\.text).joined().utf8))
        XCTAssertEqual(words.map(\.start), [1, 1.6, 2.2, 2.7])
        XCTAssertEqual(words.map(\.end), [1.5, 2.1, 2.6, 3.2])
        XCTAssertEqual(words.map(\.text), ["\n“İyi\u{00a0}", "günler,\t", "çağrı — ", "e\u{301}quipe!”\n"])
    }

    func testUntimedRealWordsCannotBeGivenNeighboringWordTimes() {
        for missing in ["untimed", " aksiyon ", "👩🏽‍💻"] {
            XCTAssertNil(TimedSpeechText.words(from: [fragment("Merhaba", 0, 1), fragment(missing), fragment("son", 2, 3)], start: 0, end: 3))
        }
    }

    func testUntimedFormattingAloneDoesNotInventATimedWord() {
        XCTAssertNil(TimedSpeechText.words(from: [fragment("\t…\n")], start: 0, end: 1))
        XCTAssertNil(TimedSpeechText.words(from: [], start: 0, end: 1))
    }

    func testMalformedPartialNonFiniteOutOfBoundsOrReversedTimesFallBack() {
        let invalid = [fragment("A", Double.nan, 1), fragment("A", 0, Double.infinity),
                       fragment("A", -0.1, 1), fragment("A", 0, 3.1),
                       fragment("A", 2, 1), fragment("A", 1, nil)]
        for value in invalid {
            XCTAssertNil(TimedSpeechText.words(from: [value], start: 0, end: 3))
        }
        XCTAssertNil(TimedSpeechText.words(from: [fragment("A", 2, 3), fragment(" B", 1, 2)], start: 0, end: 3))
        XCTAssertNil(TimedSpeechText.words(from: [fragment("A", 0, 2), fragment(" B", 1, 1.5)], start: 0, end: 3))
        XCTAssertNil(TimedSpeechText.words(from: [fragment("A", 0, 1)], start: .nan, end: 3))
    }

    func testAdjacentNativeRunsAndEmptyFragmentsRemainLossless() throws {
        let fragments = [fragment(""), fragment("  "), fragment("Türk", 0, 1), fragment("çe", 0, 1), fragment("…"), fragment(" ")]
        let words = try XCTUnwrap(TimedSpeechText.words(from: fragments, start: 0, end: 1))
        XCTAssertEqual(words.map(\.text).joined(), "  Türkçe… ")
        XCTAssertEqual(words.map(\.start), [0, 0])
        XCTAssertEqual(words.map(\.end), [1, 1])
    }

    private func fragment(_ text: String, _ start: Double? = nil, _ end: Double? = nil) -> TimedSpeechTextFragment {
        TimedSpeechTextFragment(text: text, start: start, end: end)
    }
}
