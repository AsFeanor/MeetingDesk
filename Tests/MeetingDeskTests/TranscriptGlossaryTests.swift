import Foundation
import XCTest
@testable import MeetingDesk

final class TranscriptGlossaryTests: XCTestCase {
    private func segment(_ text: String, id: String = "s1") -> TranscriptSegment {
        TranscriptSegment(id: id, speaker: "system:A", start: 3, end: 12, text: text,
            words: [TranscriptWord(text: text, start: 3, end: 12)], audioSource: .system)
    }
    private func entry(_ canonical: String = "Lifesycle", _ variant: String = "life cycle") -> GlossaryEntry {
        GlossaryEntry(canonical: canonical, variants: [variant])
    }

    func testOnlyWholeWordsAndPhrasesMatchWithPunctuation() {
        let value = segment("(life cycle), LİFE CYCLE! alife cycle life cycles life cycle_ life cycle2")
        let matches = TranscriptGlossary.suggestions(segments: [value], entries: [entry()])
        XCTAssertEqual(matches.map(\.matchedText), ["life cycle", "LİFE CYCLE"])
        XCTAssertEqual(matches[0].afterText, "(Lifesycle), LİFE CYCLE! alife cycle life cycles life cycle_ life cycle2")
    }

    func testTurkishCaseRulesKeepDottedAndDotlessISeparate() {
        let entries = [entry("Kent", "istanbul"), entry("Şehir", "ısparta")]
        let matches = TranscriptGlossary.suggestions(segments: [segment("İSTANBUL İstanbul Istanbul ISPARTA Isparta isparta")], entries: entries)
        XCTAssertEqual(matches.map(\.matchedText), ["İSTANBUL", "İstanbul", "ISPARTA", "Isparta"])
    }

    func testCanonicalUnicodeEquivalenceWithoutRemovingTurkishAccents() {
        let matches = TranscriptGlossary.suggestions(segments: [segment("cafe\u{301}; café; surec; süreç")],
            entries: [entry("Kafe", "café"), entry("İşlem", "süreç")])
        XCTAssertEqual(matches.map(\.matchedText), ["cafe\u{301}", "café", "süreç"])
        XCTAssertEqual(matches[0].afterText, "Kafe; café; surec; süreç")
    }

    func testPunctuationInsideTermIsLiteralAndExternalLettersBlockIt() {
        let matches = TranscriptGlossary.suggestions(segments: [segment("C++ / C++Builder / XC++ / (C++)")], entries: [entry("CPP", "C++")])
        XCTAssertEqual(matches.count, 2)
    }

    func testNoFuzzyMatchesOrCanonicalAutoReplacement() {
        XCTAssertTrue(TranscriptGlossary.suggestions(segments: [segment("Lifesycle lifecyle life-cycle")], entries: [entry()]).isEmpty)
    }

    func testConflictingMappingIsSkippedWhileIndependentTermRemains() {
        let matches = TranscriptGlossary.suggestions(segments: [segment("life cycle hello")],
            entries: [entry(), entry("Başka", "life cycle"), entry("Merhaba", "hello")])
        XCTAssertEqual(matches.map(\.canonical), ["Merhaba"])
    }

    func testCanonicalTermCannotBeMappedToAnotherEntry() {
        let matches = TranscriptGlossary.suggestions(segments: [segment("Lifesycle life cycle")],
            entries: [entry(), entry("Başka", "Lifesycle")])
        XCTAssertEqual(matches.map(\.matchedText), ["life cycle"])
    }

    func testOverlappingPhrasesAreSkippedInsteadOfChoosingLongest() {
        XCTAssertTrue(TranscriptGlossary.suggestions(segments: [segment("life cycle")],
            entries: [entry(), entry("Döngü", "cycle")]).isEmpty)
        XCTAssertTrue(TranscriptGlossary.suggestions(segments: [segment("foo foo foo")],
            entries: [entry("Bar", "foo foo")]).isEmpty)
    }

    func testDuplicateSegmentOrEntryIDsCannotProduceActionableSuggestion() {
        let value = segment("life cycle")
        XCTAssertTrue(TranscriptGlossary.suggestions(segments: [value, value], entries: [entry()]).isEmpty)
        let term = entry()
        XCTAssertTrue(TranscriptGlossary.suggestions(segments: [value], entries: [term, term]).isEmpty)
    }

    func testValidationRejectsEmptyTermsSelfMappingsAndCaseFoldDuplicates() {
        for value in [entry("", "foo"), GlossaryEntry(canonical: "Foo", variants: []), entry("İsim", "İSİM"),
                      GlossaryEntry(canonical: "Foo", variants: ["bar", "BAR"]), entry("Foo", "\nbar"), entry("Foo", " ")] {
            XCTAssertThrowsError(try GlossaryValidation.entries([value]))
        }
        XCTAssertThrowsError(try GlossaryValidation.entries([entry(), entry("Başka", "LİFE CYCLE")]))
        XCTAssertThrowsError(try GlossaryValidation.entries([entry(), entry("Başka", "Lifesycle")]))
        let value = entry()
        XCTAssertThrowsError(try GlossaryValidation.entries([value, value]))
    }

    func testApplyingOneOccurrencePreservesOtherTextTimingIdentityAndAudio() throws {
        let term = entry()
        var original = Meeting(title: "Synthetic", duration: 20, audioFileName: "synthetic.m4a",
            segments: [segment("life cycle ve life cycle"), segment("life cycle", id: "s2")])
        original.speakerNames = ["system:A": "Örnek"]
        original.speakerTurns = [SpeakerTurn(speakerID: "system:A", source: .system, start: 3, end: 12)]
        original.speakerReviewPeople = [SpeakerReviewPerson(name: "Örnek")]
        original.speakerReviewAssignments = ["system:A": original.speakerReviewPeople![0].id]
        original.notes = MeetingNotes(summary: "Original", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        original.reviewedAt = Date()
        let suggestion = try XCTUnwrap(TranscriptGlossary.suggestions(segments: original.segments, entries: [term]).first)
        let updated = try TranscriptGlossary.applying(suggestion, to: original, entries: [term])
        var expected = original
        expected.segments[0].text = "Lifesycle ve life cycle"; expected.segments[0].words = nil
        expected.notesNeedRefresh = true; expected.reviewedAt = nil
        XCTAssertEqual(updated, expected)
        XCTAssertEqual(original.segments[0].text, "life cycle ve life cycle")
        XCTAssertNotNil(updated.segments[1].words)
    }

    func testStaleTextDictionaryOrSpeakerSnapshotIsRejected() throws {
        let term = entry(), value = segment("life cycle")
        let suggestion = try XCTUnwrap(TranscriptGlossary.suggestions(segments: [value], entries: [term]).first)
        var original = Meeting(title: "Synthetic", segments: [value])
        original.segments[0].text = "life cycle changed"
        XCTAssertThrowsError(try TranscriptGlossary.applying(suggestion, to: original, entries: [term]))
        original.segments = [value]
        XCTAssertThrowsError(try TranscriptGlossary.applying(suggestion, to: original, entries: []))
        original.segments[0].speaker = "system:B"
        XCTAssertThrowsError(try TranscriptGlossary.applying(suggestion, to: original, entries: [term]))
    }

    func testForgedAfterTextAndDuplicateSourceIDAreRejected() throws {
        let term = entry(), value = segment("life cycle")
        var suggestion = try XCTUnwrap(TranscriptGlossary.suggestions(segments: [value], entries: [term]).first)
        let original = Meeting(title: "Synthetic", segments: [value])
        suggestion.afterText = "Unapproved whole transcript replacement"
        XCTAssertThrowsError(try TranscriptGlossary.applying(suggestion, to: original, entries: [term]))
        suggestion = try XCTUnwrap(TranscriptGlossary.suggestions(segments: [value], entries: [term]).first)
        var duplicates = original; duplicates.segments.append(value)
        XCTAssertThrowsError(try TranscriptGlossary.applying(suggestion, to: duplicates, entries: [term]))
    }
}
