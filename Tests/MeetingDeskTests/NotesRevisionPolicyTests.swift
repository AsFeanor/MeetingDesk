import XCTest
@testable import MeetingDesk

final class NotesRevisionPolicyTests: XCTestCase {
    func testOldArchiveDecodesWithoutAnyNewOptionalFields() throws {
        let originalJSON = #"{"id":"00000000-0000-0000-0000-000000000001","title":"Eski toplantı","createdAt":0,"duration":0,"segments":[],"personalNotes":"","speakerNames":{},"completedActions":[],"outputLanguage":"Türkçe","notesNeedRefresh":false,"source":"Kayıt"}"#
        let meeting = try JSONDecoder().decode(Meeting.self, from: Data(originalJSON.utf8))
        XCTAssertNil(meeting.templateRawValue)
        XCTAssertNil(meeting.notesManualEdits)
        XCTAssertNil(meeting.reviewedAt)
        XCTAssertNil(meeting.transcriptSourceSeparated)
        XCTAssertEqual(meeting.template, .general)
        var unknownTemplate = meeting
        unknownTemplate.templateRawValue = "future-template"
        XCTAssertEqual(unknownTemplate.template, .general)
    }

    func testUserWordingOwnerAndExplicitlyClearedDueSurviveChangedModelIDs() throws {
        let meeting = sampleMeeting()
        var draft = try XCTUnwrap(meeting.notes)
        draft.summary = "Benim düzelttiğim özet."
        draft.actions[0].text = "Düğmenin eski tasarımını arşivleyerek kaldır."
        draft.actions[0].owner = "Ece"
        draft.actions[0].due = nil
        draft.decisions[0].text = "Düzeltilen karar."
        draft.questions[0].text = "Düzeltilen açık soru?"
        draft.ideas[0].text = "Düzeltilen fikir."
        draft.topics[0].title = "Düzeltilen başlık"
        draft.topics[0].text = "Düzeltilen konu açıklaması."
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        var regenerated = try XCTUnwrap(meeting.notes)
        regenerated.summary = "Modelin yeni özeti."
        regenerated.actions[0].id = "new-action"
        regenerated.decisions[0].id = "new-decision"
        regenerated.questions[0].id = "new-question"
        regenerated.ideas[0].id = "new-idea"
        regenerated.topics[0].id = "new-topic"
        let result = NotesRevisionPolicy.reconcileGenerated(regenerated, into: edited, engine: "local")
        let notes = try XCTUnwrap(result.notes)
        XCTAssertEqual(notes.summary, draft.summary)
        XCTAssertEqual(notes.actions[0].id, "new-action")
        XCTAssertEqual(notes.actions[0].text, draft.actions[0].text)
        XCTAssertEqual(notes.actions[0].owner, "Ece")
        XCTAssertNil(notes.actions[0].due)
        XCTAssertEqual(notes.decisions[0].text, draft.decisions[0].text)
        XCTAssertEqual(notes.questions[0].text, draft.questions[0].text)
        XCTAssertEqual(notes.ideas[0].text, draft.ideas[0].text)
        XCTAssertEqual(notes.topics[0].title, draft.topics[0].title)
        XCTAssertEqual(notes.topics[0].text, draft.topics[0].text)
        XCTAssertEqual(notes.actions[0].evidence, ["s1"])
        XCTAssertEqual(result.notesEngine, "local")
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(result))
        XCTAssertEqual(restored.notesManualEdits, result.notesManualEdits)
    }

    func testOnlyEditedActionFieldsOverrideFreshOutput() throws {
        let meeting = sampleMeeting()
        var draft = try XCTUnwrap(meeting.notes)
        draft.actions[0].owner = "Ece"
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        var fresh = try XCTUnwrap(meeting.notes)
        fresh.actions[0].id = "fresh"
        fresh.actions[0].due = "gelecek hafta"
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        XCTAssertEqual(result.notes?.actions[0].owner, "Ece")
        XCTAssertEqual(result.notes?.actions[0].due, "gelecek hafta")
        XCTAssertEqual(result.notes?.actions[0].text, fresh.actions[0].text)
    }

    func testCompletionMatchesExactWordingAndEvidenceWhenIDsChange() throws {
        var meeting = sampleMeeting()
        meeting.completedActions = ["a1"]
        var fresh = try XCTUnwrap(meeting.notes)
        fresh.actions[0].id = "new-a1"
        fresh.actions[0].text = "  REMOVE tenant expense button\n"
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: meeting)
        XCTAssertEqual(result.completedActions, ["new-a1"])
        XCTAssertEqual(result.notes?.actions.count, 1)
    }

    func testUnrelatedActionSharingEvidenceAndReusedIDDoesNotReceiveCompletionOrCorrection() throws {
        var meeting = sampleMeeting()
        meeting.completedActions = ["a1"]
        var draft = try XCTUnwrap(meeting.notes)
        draft.actions[0].owner = "Ece"
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        var fresh = try XCTUnwrap(meeting.notes)
        fresh.actions = [ActionItem(id: "a1", text: "Schedule customer interviews.", owner: nil, due: nil, evidence: ["s1"])]
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        let actions = try XCTUnwrap(result.notes?.actions)
        XCTAssertEqual(actions.count, 2)
        XCTAssertEqual(actions[0].text, "Schedule customer interviews.")
        XCTAssertNil(actions[0].owner)
        XCTAssertFalse(result.completedActions.contains(actions[0].id))
        XCTAssertEqual(actions[1].owner, "Ece")
        XCTAssertTrue(result.completedActions.contains(actions[1].id))
        XCTAssertNotEqual(actions[0].id, actions[1].id)
    }

    func testAmbiguousActionsAreRetainedSeparatelyInsteadOfConflatingCompletion() throws {
        var meeting = sampleMeeting()
        meeting.completedActions = ["a1"]
        var fresh = try XCTUnwrap(meeting.notes)
        let action = fresh.actions[0]
        fresh.actions = [ActionItem(id: "one", text: action.text, owner: nil, due: nil, evidence: action.evidence),
                         ActionItem(id: "two", text: action.text, owner: nil, due: nil, evidence: action.evidence)]
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: meeting)
        XCTAssertEqual(result.notes?.actions.count, 3)
        XCTAssertFalse(result.completedActions.contains("one"))
        XCTAssertFalse(result.completedActions.contains("two"))
        XCTAssertTrue(result.completedActions.contains("a1"))
    }

    func testNegationCancellationRoleOrderAndCurrencyNeverReceiveOldCompletionOrOwner() throws {
        let opposites = [
            ("Remove the tenant expense button from the landlord dashboard", "Do not remove the tenant expense button from the landlord dashboard"),
            ("Kiracı gider düğmesini mülk sahibi panelinden kaldırma işlemini tamamla", "Kiracı gider düğmesini mülk sahibi panelinden kaldırma işlemini iptal et"),
            ("Move balance from tenant account to landlord account", "Move balance from landlord account to tenant account"),
            ("Transfer £100 to the landlord account", "Transfer €100 to the landlord account")
        ]
        for (oldText, newText) in opposites {
            var meeting = sampleMeeting()
            meeting.notes?.actions = [ActionItem(id: "old", text: oldText, owner: nil, due: nil, evidence: ["s1"])]
            meeting.completedActions = ["old"]
            var draft = try XCTUnwrap(meeting.notes)
            draft.actions[0].owner = "Ece"
            let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
            var fresh = try XCTUnwrap(meeting.notes)
            fresh.actions = [ActionItem(id: "fresh", text: newText, owner: nil, due: nil, evidence: ["s1"])]
            let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
            let actions = try XCTUnwrap(result.notes?.actions)
            XCTAssertEqual(actions.count, 2, oldText)
            XCTAssertEqual(actions[0].text, newText)
            XCTAssertNil(actions[0].owner)
            XCTAssertFalse(result.completedActions.contains("fresh"))
            XCTAssertEqual(actions[1].owner, "Ece")
            XCTAssertTrue(result.completedActions.contains(actions[1].id))
        }
    }

    func testSameWordingWithDifferentEvidenceKeepsIndependentActionState() throws {
        var meeting = sampleMeeting()
        meeting.segments.append(TranscriptSegment(id: "s2", speaker: "B", start: 13, end: 15, text: "The same work in a separate context."))
        meeting.completedActions = ["a1"]
        var draft = try XCTUnwrap(meeting.notes)
        draft.actions[0].owner = "Ece"
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        var fresh = try XCTUnwrap(meeting.notes)
        fresh.actions[0].id = "different-context"
        fresh.actions[0].owner = nil
        fresh.actions[0].evidence = ["s2"]
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        XCTAssertEqual(result.notes?.actions.count, 2)
        XCTAssertNil(result.notes?.actions[0].owner)
        XCTAssertFalse(result.completedActions.contains("different-context"))
        XCTAssertEqual(result.notes?.actions[1].owner, "Ece")
        XCTAssertTrue(result.completedActions.contains(try XCTUnwrap(result.notes?.actions[1].id)))
    }

    func testAmbiguousEditedCompletedActionIsRetainedOnceAcrossRepeatedRegeneration() throws {
        var meeting = sampleMeeting()
        meeting.completedActions = ["a1"]
        var draft = try XCTUnwrap(meeting.notes)
        draft.actions[0].owner = "Ece"
        var state = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        var fresh = try XCTUnwrap(meeting.notes)
        let action = fresh.actions[0]
        fresh.actions = [ActionItem(id: "one", text: action.text, owner: nil, due: nil, evidence: action.evidence),
                         ActionItem(id: "two", text: action.text, owner: nil, due: nil, evidence: action.evidence)]
        for _ in 0..<4 {
            state = NotesRevisionPolicy.reconcileGenerated(fresh, into: state)
            let actions = try XCTUnwrap(state.notes?.actions)
            XCTAssertEqual(actions.count, 3)
            XCTAssertEqual(Set(actions.map(\.id)).count, 3)
            XCTAssertEqual(actions.filter { $0.owner == "Ece" }.count, 1)
            XCTAssertEqual(state.completedActions, ["a1"])
        }
    }

    func testNewEditOnReusedOriginalIDDoesNotReplaceEarlierCorrection() throws {
        var meeting = sampleMeeting()
        meeting.completedActions = ["a1"]
        var originalDraft = try XCTUnwrap(meeting.notes)
        originalDraft.actions[0].owner = "Ece"
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: originalDraft)
        var fresh = try XCTUnwrap(meeting.notes)
        fresh.actions = [ActionItem(id: "a1", text: "Schedule customer interviews.", owner: nil, due: nil, evidence: ["s1"])]
        let reconciled = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        var newDraft = try XCTUnwrap(reconciled.notes)
        newDraft.actions[0].owner = "Derya"
        var state = NotesRevisionPolicy.applyEdits(to: reconciled, editedNotes: newDraft)
        let retainedID = try XCTUnwrap(state.notes?.actions[1].id)
        for _ in 0..<4 {
            state = NotesRevisionPolicy.reconcileGenerated(fresh, into: state)
            let actions = try XCTUnwrap(state.notes?.actions)
            XCTAssertEqual(actions.count, 2)
            XCTAssertEqual(actions[0].owner, "Derya")
            XCTAssertEqual(actions[1].owner, "Ece")
            XCTAssertEqual(actions[1].id, retainedID)
            XCTAssertEqual(state.completedActions, [retainedID])
            XCTAssertEqual(state.notesManualEdits?.actions.count, 2)
        }
    }

    func testEvidenceCannotBeRewrittenAndNewNotesDoNotAcquireInventedSources() throws {
        let meeting = sampleMeeting()
        var draft = try XCTUnwrap(meeting.notes)
        draft.actions[0].text = "Elle düzeltildi."
        draft.actions[0].evidence = ["invented"]
        draft.actions[0].owner = "  "
        draft.actions[0].due = ""
        draft.decisions[0].evidence = ["invented"]
        draft.ideas.append(EvidenceItem(id: "manual-one", text: "Kendi fikrim.", evidence: ["invented"]))
        let result = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        XCTAssertEqual(result.notes?.actions[0].evidence, ["s1"])
        XCTAssertEqual(result.notes?.decisions[0].evidence, ["s1"])
        XCTAssertNil(result.notes?.actions[0].owner)
        XCTAssertNil(result.notes?.actions[0].due)
        XCTAssertEqual(result.notes?.ideas.last?.evidence, [])
        XCTAssertEqual(result.segments, meeting.segments)
    }

    func testDeletedItemsStayDeletedAndManualAdditionsSurviveRegeneration() throws {
        let meeting = sampleMeeting()
        var draft = try XCTUnwrap(meeting.notes)
        draft.decisions = []
        draft.actions.append(ActionItem(id: "manual-action", text: "Kendi eklediğim takip.", owner: nil, due: nil, evidence: []))
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        var fresh = try XCTUnwrap(meeting.notes)
        fresh.decisions[0].id = "new-decision"
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        XCTAssertEqual(result.notes?.decisions, [])
        XCTAssertEqual(result.notes?.actions.last?.text, "Kendi eklediğim takip.")
        XCTAssertEqual(result.notes?.actions.last?.evidence, [])
    }

    func testManualAdditionsAndDeletionsAreIdempotentAcrossChangedGeneratedIDs() throws {
        let meeting = sampleMeeting()
        var draft = try XCTUnwrap(meeting.notes)
        draft.decisions = []
        draft.questions = []
        draft.ideas = []
        draft.topics = []
        draft.actions = [ActionItem(id: "manual-action", text: "Kendi eklediğim takip.", owner: nil, due: nil, evidence: [])]
        var state = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        state.completedActions = ["manual-action"]
        for index in 0..<4 {
            var fresh = try XCTUnwrap(meeting.notes)
            fresh.actions[0].id = "a\(index)"
            fresh.decisions[0].id = "d\(index)"
            fresh.questions[0].id = "q\(index)"
            fresh.ideas[0].id = "i\(index)"
            fresh.topics[0].id = "t\(index)"
            state = NotesRevisionPolicy.reconcileGenerated(fresh, into: state)
            XCTAssertEqual(state.notes?.actions.map(\.id), ["manual-action"])
            XCTAssertEqual(state.completedActions, ["manual-action"])
            XCTAssertEqual(state.notes?.decisions, [])
            XCTAssertEqual(state.notes?.questions, [])
            XCTAssertEqual(state.notes?.ideas, [])
            XCTAssertEqual(state.notes?.topics, [])
            XCTAssertEqual(state.notesManualEdits?.actions.count, 2)
        }
        var withoutManualAction = try XCTUnwrap(state.notes)
        withoutManualAction.actions = []
        state = NotesRevisionPolicy.applyEdits(to: state, editedNotes: withoutManualAction)
        state = NotesRevisionPolicy.reconcileGenerated(try XCTUnwrap(meeting.notes), into: state)
        XCTAssertEqual(state.notes?.actions, [])
        XCTAssertEqual(state.completedActions, [])
    }

    func testReviewRequiresCurrentNotesAndIsInvalidatedByEditsOrRegeneration() throws {
        let timestamp = Date(timeIntervalSince1970: 1_000)
        let meeting = NotesRevisionPolicy.markReviewed(sampleMeeting(), at: timestamp)
        XCTAssertTrue(meeting.notesAreReviewed)
        XCTAssertEqual(meeting.reviewedAt, timestamp)
        let same = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: try XCTUnwrap(meeting.notes))
        XCTAssertEqual(same.reviewedAt, timestamp)
        var draft = try XCTUnwrap(meeting.notes)
        draft.summary = "Yeni düzeltme."
        XCTAssertNil(NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft).reviewedAt)
        XCTAssertNil(NotesRevisionPolicy.reconcileGenerated(try XCTUnwrap(meeting.notes), into: meeting).reviewedAt)
        XCTAssertNil(NotesRevisionPolicy.invalidateReview(meeting).reviewedAt)
        var stale = sampleMeeting()
        stale.notesNeedRefresh = true
        XCTAssertNil(NotesRevisionPolicy.markReviewed(stale, at: timestamp).reviewedAt)
        XCTAssertFalse(stale.notesAreReviewed)
    }

    func testPreservedCorrectionWithMissingSourcesRemainsUnreviewedAndStale() throws {
        let meeting = sampleMeeting()
        var draft = try XCTUnwrap(meeting.notes)
        draft.actions[0].owner = "Ece"
        var edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        edited.segments = [TranscriptSegment(id: "new-source", speaker: "A", start: 0, end: 10, text: "A new discussion.")]
        let fresh = MeetingNotes(summary: "Yeni döküm özeti.", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        XCTAssertEqual(result.notes?.actions[0].evidence, ["s1"])
        XCTAssertTrue(result.notesNeedRefresh)
        XCTAssertNil(NotesRevisionPolicy.markReviewed(result).reviewedAt)
    }

    func testTemplatesEmphasizeOnlyGroundedInformation() {
        XCTAssertEqual(MeetingTemplate.allCases.map(\.label), ["Genel toplantı", "Ekip toplantısı", "Ürün değerlendirmesi", "Müşteri görüşmesi"])
        for template in MeetingTemplate.allCases {
            let prompt = LocalSummaryService.instructions(language: "Turkish", template: template)
            XCTAssertTrue(prompt.contains("Meeting template: \(template.rawValue)"))
            XCTAssertTrue(prompt.contains("Never infer owners, dates, agreement, or identities"))
            XCTAssertTrue(prompt.contains("Do not turn a relative phrase into a calendar date"))
            XCTAssertTrue(prompt.contains("UNTRUSTED"))
        }
    }

    private func sampleMeeting() -> Meeting {
        Meeting(title: "Sentetik toplantı", segments: [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 12,
            text: "Remove the tenant expense button. Ali will do this tomorrow. Schedule interviews too.")],
                notes: MeetingNotes(summary: "Kaynak özeti.",
                                    decisions: [EvidenceItem(id: "d1", text: "Remove tenant expense button", evidence: ["s1"])],
                                    actions: [ActionItem(id: "a1", text: "Remove tenant expense button", owner: "Ali", due: "tomorrow", evidence: ["s1"])],
                                    questions: [EvidenceItem(id: "q1", text: "Which release includes the change?", evidence: ["s1"])],
                                    ideas: [EvidenceItem(id: "i1", text: "Explore billing alternatives", evidence: ["s1"])],
                                    topics: [TopicNote(id: "t1", title: "Billing", text: "Billing workflow discussion", evidence: ["s1"])]))
    }
}
