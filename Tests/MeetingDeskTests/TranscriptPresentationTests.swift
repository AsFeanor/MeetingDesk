import Foundation
import XCTest
@testable import MeetingDesk

final class TranscriptPresentationTests: XCTestCase {
    private func fixture(count: Int = 240) -> Meeting {
        var meeting = Meeting(title: "Synthetic performance fixture")
        meeting.segments = (0..<count).reversed().map { index in
            let start = Double(index) / 10
            return TranscriptSegment(id: "segment-\(index)", speaker: "voice-\((index / 12) % 8)",
                start: start, end: start + 0.09, text: "Sample \(index).",
                audioSource: index % 37 == 0 ? .microphone : .system)
        }
        meeting.speakerTurns = (0..<8).map { SpeakerTurn(speakerID: "voice-\($0)", source: .system, start: Double($0), end: Double($0) + 1) }
        let person = SpeakerReviewPerson(name: "Deniz")
        meeting.speakerReviewPeople = [person]
        meeting.speakerReviewAssignments = ["voice-0": person.id, "voice-1": person.id]
        meeting.speakerNames = ["voice-2": "  Ece  ", "voice-3": "Ses 39", "voice-4": "Mikrofon"]
        meeting.speakerSuggestions = ["voice-5": .init(profileID: UUID(), name: "Ali", similarity: 0.9, automatic: true)]
        return meeting
    }
    private func request(_ meeting: Meeting, query: String = "", source: SpeakerAudioSource? = nil,
                         flowing: Bool = true, hideEchoes: Bool = true) -> TranscriptPresentationRequest {
        .init(input: .init(meeting: meeting), grouping: .init(source: source, flowing: flowing, hideEchoes: hideEchoes), query: query)
    }
    func testIndexedPresentationMatchesPreviousGroupingNamesSearchAndAllSavedAnchors() throws {
        let meeting = fixture()
        let snapshot = try TranscriptPresentationSnapshot.prepare(.init(meeting: meeting))
        for source: SpeakerAudioSource? in [nil, .microphone, .system, .mixed] {
            for flowing in [false, true] {
                for hideEchoes in [false, true] {
                    let options = TranscriptGroupingOptions(source: source, flowing: flowing, hideEchoes: hideEchoes)
                    let rows = try snapshot.rows(for: options)
                    let old = PreviousTranscriptPresentation.blocks(meeting, options: options)
                    XCTAssertEqual(rows.map(\.block), old)
                    XCTAssertEqual(rows.map(\.name), old.map { SpeakerPresentation.name(for: $0.speaker, in: meeting) })
                    XCTAssertEqual(rows.map(\.text), old.map(\.text))
                    XCTAssertEqual(rows.map(\.sourceIDs), old.map { Set($0.sourceSegmentIDs) })
                    XCTAssertEqual(rows.map(\.canReview), old.map { block in (meeting.speakerTurns ?? []).contains { $0.speakerID == block.speaker } })
                    for query in ["", " sample 12 ", "Deniz", "ses", "not present"] {
                        let actual = try TranscriptPresentationSnapshot.filtered(rows, query: query)
                        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
                        let expected = old.filter { clean.isEmpty || $0.text.localizedStandardContains(clean) || $0.segments.contains { SpeakerPresentation.name(for: $0.speaker, in: meeting).localizedStandardContains(clean) } }
                        XCTAssertEqual(actual.map(\.block), expected)
                    }
                }
            }
        }
    }
    func testPreparedNamesMatchFallbackAndAmbiguousLegacyPersonPrecedence() throws {
        var meeting = fixture(count: 48)
        let id = UUID()
        meeting.speakerReviewPeople = [.init(id: id, name: "First"), .init(id: id, name: "Second")]
        meeting.speakerReviewAssignments = ["voice-0": id, "voice-1": id]
        meeting.segments += [TranscriptSegment(id: "empty", speaker: "unknown", start: -1, end: -2, text: ""),
            TranscriptSegment(id: "legacy-source", speaker: "Toplantı sesi", start: 100, end: 101, text: "Source")]
        let rows = try TranscriptPresentationSnapshot.prepare(.init(meeting: meeting)).rows(for: .init(source: nil, flowing: false, hideEchoes: false))
        XCTAssertEqual(rows.map(\.name), rows.map { SpeakerPresentation.name(for: $0.block.speaker, in: meeting) })
        XCTAssertEqual(rows.flatMap { $0.block.segments }, TranscriptConversation.orderedSegments(meeting.segments))
    }
    @MainActor func testEchoSuppressionAndSourceFocusNeverLoseOriginalAnchors() async throws {
        let texts = ["Here", " are", " five", " words", " repeated", " today."]
        let words = texts.enumerated().map { TranscriptWord(text: $0.element, start: Double($0.offset) / 2, end: Double($0.offset + 1) / 2) }
        let microphone = TranscriptSegment(id: "microphone", speaker: "mic-voice", start: 0, end: 3,
            text: texts.joined(), words: words, audioSource: .microphone)
        let system = TranscriptSegment(id: "system", speaker: "system-voice", start: 0, end: 3,
            text: texts.joined(), words: words, audioSource: .system)
        let meeting = Meeting(title: "Synthetic echo", segments: [microphone, system])
        let model = TranscriptPresentationModel()
        await model.update(request(meeting))
        XCTAssertEqual(model.snapshot?.hiddenSegmentIDs, ["microphone"])
        XCTAssertEqual(model.rows.flatMap { $0.block.sourceSegmentIDs }, ["system"])
        XCTAssertNil(model.blockID(containing: "microphone", input: .init(meeting: meeting)))
        await model.update(request(meeting, hideEchoes: false))
        XCTAssertEqual(model.blockID(containing: "microphone", input: .init(meeting: meeting)), "microphone")
        XCTAssertEqual(model.rows.flatMap { $0.block.segments }, [microphone, system])
        await model.update(request(meeting, source: .microphone))
        XCTAssertEqual(model.rows.flatMap { $0.block.sourceSegmentIDs }, ["microphone"], "A source-specific view always exposes its original text")
        XCTAssertEqual(model.preparationCount, 1)
    }
    func testRelevantInputExcludesNotesAndIncludesTranscriptAndIdentityChanges() {
        let original = fixture()
        var edited = original
        edited.personalNotes = "Edited notes"; edited.title = "Renamed"; edited.completedActions = ["done"]
        edited.notesNeedRefresh = true; edited.notesEngine = "changed"; edited.duration += 10
        XCTAssertEqual(TranscriptPresentationInput(meeting: original), .init(meeting: edited))
        edited.speakerNames["voice-2"] = "New name"
        XCTAssertNotEqual(TranscriptPresentationInput(meeting: original), .init(meeting: edited))
        edited = original; edited.segments[0].text += " changed"
        XCTAssertNotEqual(TranscriptPresentationInput(meeting: original), .init(meeting: edited))
    }
    @MainActor func testPlaybackLikeUpdatesDoNoRepeatedPreparationGroupingOrFiltering() async {
        let meeting = fixture(count: 2_400), model = TranscriptPresentationModel()
        let initial = request(meeting)
        await model.update(initial)
        let originalRows = model.rows
        for _ in 0..<100 { await model.update(initial) }
        XCTAssertEqual(model.preparationCount, 1)
        XCTAssertEqual(model.groupingCount, 1)
        XCTAssertEqual(model.filteringCount, 1)
        XCTAssertEqual(model.rows, originalRows)
        await model.update(request(meeting, query: "Sample"))
        XCTAssertEqual(model.preparationCount, 1)
        XCTAssertEqual(model.groupingCount, 1)
        XCTAssertEqual(model.filteringCount, 2)
        await model.update(request(meeting, source: .system))
        XCTAssertEqual(model.preparationCount, 1)
        XCTAssertEqual(model.groupingCount, 2)
        await model.update(initial)
        XCTAssertEqual(model.groupingCount, 2, "Returning to a prior view reuses its prepared rows")
        XCTAssertEqual(model.rows, originalRows)
    }
    @MainActor func testReturningToRenderedRequestInvalidatesPendingWorkAndCancelCannotPublish() async {
        let meeting = fixture(), model = TranscriptPresentationModel(), initial = request(fixture())
        // Keep a single stable meeting ID across requests.
        let first = request(meeting)
        await model.update(first)
        let revision = model.revision, rows = model.rows
        let pending = Task { await model.update(request(meeting, query: "not present")) }
        await Task.yield()
        await model.update(first)
        await pending.value
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.rows, rows)
        let cancelled = Task { await model.update(request(meeting, query: "Sample")) }
        await Task.yield(); model.cancel(); await cancelled.value
        XCTAssertEqual(model.revision, revision)
        XCTAssertEqual(model.rows, rows)
        XCTAssertFalse(model.matches(initial.input), "Another meeting cannot interact with these rows")
    }
    @MainActor func testIdentityEditRebuildsAndFocusUsesOriginalSegmentIDsOnlyForMatchingInput() async {
        var meeting = fixture(), model = TranscriptPresentationModel()
        await model.update(request(meeting, hideEchoes: false))
        XCTAssertTrue(model.matches(request(meeting, hideEchoes: false)))
        XCTAssertFalse(model.matches(request(meeting, source: .system, hideEchoes: false)), "Focus waits for the requested source view")
        XCTAssertFalse(model.matches(request(meeting, query: "Sample", hideEchoes: false)), "Focus waits for the requested search view")
        for row in model.rows { for id in row.sourceIDs {
            XCTAssertEqual(model.blockID(containing: id, input: .init(meeting: meeting)), row.id)
        } }
        var unrelated = meeting; unrelated.id = UUID()
        XCTAssertNil(model.blockID(containing: meeting.segments[0].id, input: .init(meeting: unrelated)))
        meeting.speakerNames["voice-2"] = "Updated"
        XCTAssertFalse(model.matches(.init(meeting: meeting)))
        await model.update(request(meeting, hideEchoes: false))
        XCTAssertEqual(model.preparationCount, 2)
        XCTAssertTrue(model.matches(.init(meeting: meeting)))
        XCTAssertTrue(model.rows.contains { $0.name == "Updated" })
    }
    /// Explicit opt-in read-only replay. Reports counts/times only, never titles,
    /// transcript, people, source paths or model inference output.
    @MainActor func testReadOnlyPerformanceOnExplicitLocalArchives() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let json = env["MEETINGDESK_PERF_INPUTS"], let output = env["MEETINGDESK_PERF_OUTPUT"] else {
            throw XCTSkip("Optional local performance replay; no archives accessed by default")
        }
        let paths = try JSONDecoder().decode([String].self, from: Data(json.utf8))
        var reports: [[String: Any]] = []
        for (index, path) in paths.enumerated() {
            let data = try Data(contentsOf: URL(fileURLWithPath: path))
            let meeting = try JSONDecoder().decode(Meeting.self, from: data)
            let options = TranscriptGroupingOptions(source: nil, flowing: true, hideEchoes: true)
            let before = Date()
            let blocks = PreviousTranscriptPresentation.blocks(meeting, options: options)
            let names = blocks.map { SpeakerPresentation.name(for: $0.speaker, in: meeting) }
            let texts = blocks.map(\.text)
            let oldTime = Date().timeIntervalSince(before)
            let model = TranscriptPresentationModel()
            let start = Date(); await model.update(request(meeting))
            let newTime = Date().timeIntervalSince(start)
            XCTAssertEqual(model.rows.map(\.block), blocks)
            XCTAssertEqual(model.rows.map(\.name), names)
            XCTAssertEqual(model.rows.map(\.text), texts)
            let redrawStart = Date()
            for _ in 0..<100 { await model.update(request(meeting)) }
            let redrawTime = Date().timeIntervalSince(redrawStart)
            XCTAssertEqual(model.preparationCount, 1); XCTAssertEqual(model.groupingCount, 1); XCTAssertEqual(model.filteringCount, 1)
            XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), data)
            reports.append(["archiveIndex": index, "segments": meeting.segments.count, "cards": model.rows.count,
                "oldPreparationSeconds": oldTime, "newPreparationSeconds": newTime, "cached100UpdatesSeconds": redrawTime,
                "preparations": model.preparationCount, "groupings": model.groupingCount, "filters": model.filteringCount,
                "matchingOutput": true, "archiveUnchanged": true])
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: output))
    }
}

/// Preserved v0.9 projection used only as an independent equivalence/benchmark
/// reference. The production implementation does not carry two algorithms.
private enum PreviousTranscriptPresentation {
    static func blocks(_ meeting: Meeting, options: TranscriptGroupingOptions) -> [TranscriptConversationBlock] {
        var value = meeting
        let input = options.source == nil && options.hideEchoes ? TranscriptEchoProjection.project(meeting.segments).segments : meeting.segments
        value.segments = input.filter { options.source == nil || SpeakerTranscriptAlignment.source(for: $0) == options.source }
        let ordered = TranscriptConversation.orderedSegments(value.segments)
        guard options.flowing else { return ordered.map { TranscriptConversationBlock(segments: [$0]) } }
        var result: [TranscriptConversationBlock] = []
        for segment in ordered {
            if let last = result.last, canAppend(segment, to: last, meeting: value) { result[result.count - 1].segments.append(segment) }
            else { result.append(.init(segments: [segment])) }
        }
        return result
    }
    private static func canAppend(_ segment: TranscriptSegment, to block: TranscriptConversationBlock, meeting: Meeting) -> Bool {
        guard let first = block.segments.first,
              first.start.isFinite, block.end.isFinite, first.start >= 0, block.end >= first.start,
              segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
              block.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              block.source == SpeakerTranscriptAlignment.source(for: segment),
              identity(first.speaker, meeting) == identity(segment.speaker, meeting),
              segment.start - block.end <= 1.5, max(block.end, segment.end) - block.start <= 30 else { return false }
        return true
    }
    private static func identity(_ id: String, _ meeting: Meeting) -> String {
        SpeakerReviewQueue.identifiedKey(for: id, in: meeting).map { "known:" + $0 } ?? "voice:" + id
    }
}
