import XCTest
import FoundationModels
@testable import MeetingDesk

/// Pure input/grounding contracts; no model, recorder or real archive is used.
final class LocalTaskTimeInputTests: XCTestCase {
    func testTimeProjectionPreservesEveryCitedFragmentIdentityAndOrderWhileOtherInputsAndArchivesKeepRecorderData() throws {
        let sources = fixture()
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        let candidate = candidate()
        let time = try LocalSummaryService.taskTimeInput(candidate: candidate, evidenceScope: scope)
        let full = try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope)
        let otherMetadata = try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope)
        XCTAssertEqual(time.candidate, full.candidate)
        XCTAssertEqual(time.supportingSources.map(\.id), ["s1", "s3", "s1"])
        XCTAssertEqual(time.supportingSources.map(\.text), [sources[0].text, sources[2].text, sources[3].text])
        XCTAssertEqual(time.supportingSources.map(\.providedSpeakerName), ["Nora", nil, "Nora"])
        let encoded = try object(time)
        XCTAssertEqual(Set(encoded.keys), ["candidate", "supportingSources"])
        let rows = try XCTUnwrap(encoded["supportingSources"] as? [[String: Any]])
        for (index, row) in rows.enumerated() {
            var keys: Set<String> = ["id", "text"]
            if time.supportingSources[index].providedSpeakerName != nil { keys.insert("providedSpeakerName") }
            XCTAssertEqual(Set(row.keys), keys)
            for forbidden in ["start", "end", "sourcePosition", "speaker", "speakerLabel", "leadingWholeWordBoundary", "trailingWholeWordBoundary"] {
                XCTAssertNil(row[forbidden])
            }
        }
        XCTAssertEqual(full.supportingSources.map(\.sourcePosition), [0, 2, 3])
        XCTAssertEqual(full.supportingSources.map(\.start), [1.25, 4, 1.25])
        XCTAssertEqual(full.supportingSources.map(\.end), [5, 6, 5])
        XCTAssertEqual(full.otherSources.map(\.text), [sources[1].text])
        XCTAssertEqual(otherMetadata.supportingSources, full.supportingSources,
                       "Nature and owner builders retain their existing complete source metadata")
        let generalSource = try object(sources[0])
        XCTAssertEqual(generalSource["start"] as? Double, 1.25)
        XCTAssertEqual(generalSource["end"] as? Double, 5)
        let meeting = Meeting(title: "Synthetic recorder metadata", segments: [
            .init(id: "stored", speaker: "A", start: 1.25, end: 5, text: sources[0].text)
        ])
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting))
        XCTAssertEqual(restored.segments, meeting.segments)
        XCTAssertEqual(restored.segments[0].speaker, "A")
        XCTAssertEqual(restored.segments[0].start, 1.25)
        XCTAssertEqual(restored.segments[0].end, 5)
    }

    func testTimeBytesIgnoreRecorderTimesAndPositionsButNeverEraseTextOrProvidedIdentityChanges() throws {
        let candidate = candidate()
        let original = fixture()
        var changed = original
        for index in changed.indices { changed[index].start += 700; changed[index].end += 900 }
        // Same uncited alias, so aliases and cited-row order remain fixed while sourcePosition shifts.
        changed.insert(.init(id: "unrelated", speaker: "Z", start: 800, end: 900, text: "Another uncited fragment."), at: 2)
        let first = try LocalSummaryService.evidenceScope(sources: original)
        let second = try LocalSummaryService.evidenceScope(sources: changed)
        let firstTime = try LocalSummaryService.taskTimeInput(candidate: candidate, evidenceScope: first)
        let secondTime = try LocalSummaryService.taskTimeInput(candidate: candidate, evidenceScope: second)
        XCTAssertEqual(firstTime, secondTime)
        XCTAssertEqual(try LocalSummaryService.modelInputData(firstTime), try LocalSummaryService.modelInputData(secondTime),
                       "Recorder-only changes must not change either actual time-request payload")
        let fullFirst = try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: first)
        let fullSecond = try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: second)
        XCTAssertNotEqual(fullFirst, fullSecond)
        XCTAssertEqual(fullSecond.supportingSources.map(\.sourcePosition), [0, 3, 4])
        XCTAssertNotEqual(try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: first),
                          try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: second))
        var differentText = original; differentText[3].text += " New spoken detail."
        var differentName = original; differentName[0].providedSpeakerName = "Marina"
        for variant in [differentText, differentName] {
            let input = try LocalSummaryService.taskTimeInput(candidate: candidate,
                evidenceScope: LocalSummaryService.evidenceScope(sources: variant))
            XCTAssertNotEqual(try LocalSummaryService.modelInputData(input), try LocalSummaryService.modelInputData(firstTime))
        }
    }

    func testTimeFactoryRejectsUnknownOrMissingEvidenceInsteadOfSilentlyNarrowingSources() throws {
        let scope = try LocalSummaryService.evidenceScope(sources: fixture())
        for evidence in [[], ["foreign"], ["operation", "foreign"], ["s1"]] as [[String]] {
            let invalid = LocalSummaryService.ActionCandidate(id: "task", text: "A task.", evidence: evidence)
            XCTAssertThrowsError(try LocalSummaryService.taskTimeInput(candidate: invalid, evidenceScope: scope))
        }
    }

    func testSpokenNumericTimesStayVerbatimAndUnsupportedRecorderFiveStillFailsFinalGrounding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        let presence = try LocalSummaryService.parseTimePresence(generated(["hasExplicitTaskTime": true]))
        for (text, phrase) in [("We agreed to send the form at 5.", "5"),
                               ("Formu saat 5'te göndermeyi üstlendik.", "5'te"),
                               ("We will send the form at 17:30.", "17:30")] {
            let meeting = Meeting(title: "Synthetic spoken time", segments: [
                .init(id: "source", speaker: "A", start: 0, end: 5, text: text)
            ])
            let scope = try LocalSummaryService.evidenceScope(sources: [
                .init(id: "source", speaker: "A", start: 0, end: 5, text: text)
            ])
            let task = LocalSummaryService.ActionCandidate(id: "numeric-task", text: text, evidence: ["source"])
            XCTAssertEqual(try LocalSummaryService.taskTimeInput(candidate: task, evidenceScope: scope).supportingSources[0].text, text)
            let value = try LocalSummaryService.taskTimeValue(generated(["taskTimePhrase": phrase]), presence: presence)
            XCTAssertEqual(value, phrase)
            let action = ActionItem(id: task.id, text: task.text, owner: nil, due: value, evidence: task.evidence)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes(action), meeting: meeting))
        }
        let text = "We agreed to review the form; no time was set."
        let meeting = Meeting(title: "Synthetic unsupported recorder value", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 5, text: text)
        ])
        let value = try LocalSummaryService.taskTimeValue(generated(["taskTimePhrase": "5"]), presence: presence)
        XCTAssertEqual(value, "5", "No blanket number filter or invalid-to-nil repair is allowed")
        let invalid = ActionItem(id: "task", text: text, owner: nil, due: value, evidence: ["source"])
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes(invalid), meeting: meeting),
                             "Recording end=5 cannot ground a time absent from transcript text")
        let absent = try LocalSummaryService.parseTimePresence(generated(["hasExplicitTaskTime": false]))
        XCTAssertNil(try LocalSummaryService.taskTimeValue(nil, presence: absent))
        XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(generated(["taskTimePhrase": "5"]), presence: absent))
    }

    private func fixture() -> [LocalSummaryService.Source] {
        [
            .init(id: "operation", speaker: "A", start: 1.25, end: 5, text: "Nora will send ", providedSpeakerName: "Nora"),
            .init(id: "unrelated", speaker: "B", start: 8, end: 9, text: "The old plan was cancelled."),
            .init(id: "assignment", speaker: "C", start: 4, end: 6, text: "The assignment was accepted."),
            .init(id: "operation", speaker: "A", start: 1.25, end: 5, text: "the signed form at 17:30. 👩🏽‍💻", providedSpeakerName: "Nora")
        ]
    }
    private func candidate() -> LocalSummaryService.ActionCandidate {
        .init(id: "task", text: "Send the signed form.", evidence: ["assignment", "operation"])
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: LocalSummaryService.modelInputData(value)) as? [String: Any])
    }
    private func notes(_ action: ActionItem) -> MeetingNotes {
        .init(summary: "Synthetic task.", decisions: [], actions: [action], questions: [], ideas: [], topics: [])
    }
    @available(macOS 26.0, *)
    private func generated(_ value: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
}
