import Foundation
import XCTest
@testable import MeetingDesk

final class TranscriptEchoProjectionTests: XCTestCase {
    private let phrase = ["Tomorrow", "Deniz", "reviews", "payment", "details", "carefully"]
    private func segment(_ id: String, words: [String], start: Double = 0,
                         source: SpeakerAudioSource? = .microphone, step: Double = 0.55) -> TranscriptSegment {
        let timed = words.enumerated().map { index, word in
            TranscriptWord(text: word + " ", start: start + Double(index) * step, end: start + Double(index) * step + 0.4)
        }
        return TranscriptSegment(id: id, speaker: "Name does not establish echo", start: start,
            end: timed.last?.end ?? start + 0.4, text: timed.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines),
            words: timed, audioSource: source)
    }
    private func assertUnchanged(_ input: [TranscriptSegment], file: StaticString = #filePath, line: UInt = #line) {
        let result = TranscriptEchoProjection.project(input)
        XCTAssertEqual(result.segments, input, file: file, line: line)
        XCTAssertTrue(result.hiddenSegmentIDs.isEmpty, file: file, line: line)
        XCTAssertEqual(result.matchedWordCount, 0, file: file, line: line)
    }

    func testWholeMicrophoneEchoIsHiddenWithoutChangingAnyStoredValueOrSystemSegment() {
        let mic = segment("mic", words: phrase)
        var system = segment("system", words: phrase, start: 0.1, source: .system)
        system.speaker = "Different person label"
        let input = [mic, system], original = input
        let result = TranscriptEchoProjection.project(input)
        XCTAssertEqual(result.segments, [system])
        XCTAssertEqual(result.hiddenSegmentIDs, ["mic"])
        XCTAssertEqual(result.matchedWordCount, 6)
        XCTAssertEqual(input, original)
        XCTAssertEqual(result.segments.first?.words, system.words)
        XCTAssertEqual(result.segments.first?.id, "system")
    }

    func testExactRunCanCrossDifferentSegmentBoundariesAndRetainsOriginalOutputOrder() {
        let micFirst = segment("mic-first", words: Array(phrase.prefix(2)))
        let micLast = segment("mic-last", words: Array(phrase.dropFirst(2)), start: 1.1)
        let systemFirst = segment("system-first", words: Array(phrase.prefix(3)), start: 0.1, source: .system)
        let systemLast = segment("system-last", words: Array(phrase.dropFirst(3)), start: 1.75, source: .system)
        let input = [systemLast, micLast, systemFirst, micFirst]
        let result = TranscriptEchoProjection.project(input)
        XCTAssertEqual(result.hiddenSegmentIDs, ["mic-first", "mic-last"])
        XCTAssertEqual(result.matchedWordCount, 6)
        XCTAssertEqual(result.segments, [systemLast, systemFirst], "Analysis may sort, but output must retain original objects and input order")
    }

    func testPartiallyMatchingMicrophoneSegmentKeepsEveryWordIncludingItsUniqueTail() {
        let mic = segment("mic", words: phrase + ["uniquely"])
        let system = segment("system", words: phrase, start: 0.1, source: .system)
        assertUnchanged([mic, system])
    }

    func testDifferentPhrasesShortAgreementsAndDifferentWordOrderAreNeverHidden() {
        assertUnchanged([segment("mic", words: phrase), segment("system", words: ["Tomorrow", "Deniz", "rejects", "payment", "details", "carefully"], start: 0.1, source: .system)])
        let fourLongWords = ["Tomorrow", "implementations", "synchronize", "successfully"]
        assertUnchanged([segment("mic", words: fourLongWords), segment("system", words: fourLongWords, start: 0.1, source: .system)])
        let shortAgreements = ["yes", "no", "ok", "so", "we"]
        assertUnchanged([segment("mic", words: shortAgreements), segment("system", words: shortAgreements, start: 0.1, source: .system)])
        assertUnchanged([segment("mic", words: phrase), segment("system", words: phrase.reversed(), start: 0.1, source: .system)])
    }

    func testFarAwayRepetitionAndSameChannelNeverEstablishEcho() {
        assertUnchanged([segment("mic", words: phrase), segment("system", words: phrase, start: 40, source: .system)])
        assertUnchanged([segment("first", words: phrase), segment("second", words: phrase, start: 0.1)])
    }

    func testUnknownMixedMissingOrInvalidWordTimingAndJoinMismatchArePreserved() {
        let system = segment("system", words: phrase, start: 0.1, source: .system)
        assertUnchanged([segment("mixed", words: phrase, source: .mixed), system])
        assertUnchanged([segment("local-microphone-1", words: phrase, source: nil), system])
        var missing = segment("missing", words: phrase); missing.words = nil
        assertUnchanged([missing, system])
        var invalid = segment("invalid", words: phrase); invalid.words?[2].start = .nan
        assertUnchanged([invalid, system])
        var outside = segment("outside", words: phrase); outside.words?[0].start = -0.1
        assertUnchanged([outside, system])
        var zero = segment("zero", words: phrase); let zeroStart = zero.words?[2].start ?? 0; zero.words?[2].end = zeroStart
        assertUnchanged([zero, system])
        var mismatch = segment("mismatch", words: phrase); mismatch.text += " missing words"
        assertUnchanged([mismatch, system])
    }

    func testPunctuationAndCaseCanDifferButUnknownSymbolsCannotBeDiscarded() {
        let mic = segment("mic", words: ["Tomorrow,", "Deniz", "reviews", "payment", "details!", "carefully."])
        let system = segment("system", words: phrase.map { $0.lowercased() }, start: 0.1, source: .system)
        XCTAssertEqual(TranscriptEchoProjection.project([mic, system]).hiddenSegmentIDs, ["mic"])
        let symbolMic = segment("symbol", words: ["Tomorrow", "Deniz", "reviews", "payment", "details", "carefully😀"])
        assertUnchanged([symbolMic, system])
    }

    func testEveryPointAndSubstantialRunOverlapMustPass() {
        let mic = segment("mic", words: phrase)
        var badEnd = segment("system", words: phrase, start: 0.1, source: .system)
        badEnd.words?[2].end += 0.51
        assertUnchanged([mic, badEnd])
        let text = phrase.joined(separator: " ")
        let shortMic = TranscriptSegment(id: "short-mic", speaker: "A", start: 0, end: 0.1, text: text,
            words: [.init(text: text, start: 0, end: 0.1)], audioSource: .microphone)
        let shortSystem = TranscriptSegment(id: "short-system", speaker: "B", start: 0.2, end: 0.3, text: text,
            words: [.init(text: text, start: 0.2, end: 0.3)], audioSource: .system)
        assertUnchanged([shortMic, shortSystem])
    }

    func testLongSilencesDoNotJoinSeparateShortAgreementsIntoAQualifyingRun() {
        let words = ["absolutely", "certainly", "understood", "excellent", "agreed"]
        let mic = words.enumerated().map { segment("mic-\($0.offset)", words: [$0.element], start: Double($0.offset) * 10) }
        let system = words.enumerated().map { segment("system-\($0.offset)", words: [$0.element], start: Double($0.offset) * 10 + 0.1, source: .system) }
        assertUnchanged(mic + system)
    }

    func testUnvalidatedSystemTextIsABarrierRatherThanSilentlySkipped() {
        let mic = segment("mic", words: phrase)
        let first = segment("system-first", words: Array(phrase.prefix(3)), start: 0.1, source: .system)
        let unknown = TranscriptSegment(id: "system-unknown", speaker: "B", start: 1.5, end: 1.6,
            text: "Intervening unvalidated speech", words: nil, audioSource: .system)
        let last = segment("system-last", words: Array(phrase.dropFirst(3)), start: 1.75, source: .system)
        assertUnchanged([mic, first, unknown, last])
    }

    func testSeparatePartialRunsDoNotCombineToHideOneLongMicrophoneSegment() {
        var mic = segment("mic", words: phrase + phrase)
        for index in 6..<12 { mic.words?[index].start += 4; mic.words?[index].end += 4 }
        mic.end += 4
        let first = segment("system-first", words: phrase, start: 0.1, source: .system)
        let last = segment("system-last", words: phrase, start: 7.4, source: .system)
        assertUnchanged([mic, first, last])
    }

    func testDuplicateSegmentIDsRemainVisibleSoHiddenIDsCannotAffectAnotherSegment() {
        let mic = segment("same-id", words: phrase)
        let system = segment("system", words: phrase, start: 0.1, source: .system)
        let distinct = segment("same-id", words: ["Unique", "microphone", "speech"], start: 20)
        assertUnchanged([mic, system, distinct])
    }
}
