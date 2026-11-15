import Combine
import Foundation

/// Only source/identity changes invalidate preparation. Playback position, notes,
/// busy flags and other AppStore publications are deliberately absent.
struct TranscriptPresentationInput: Equatable {
    let id: UUID
    let segments: [TranscriptSegment]
    let turns: [SpeakerTurn]?
    let names: [String: String]
    let people: [SpeakerReviewPerson]?
    let assignments: [String: UUID]?
    let suggestions: [String: SpeakerIdentitySuggestion]?

    init(meeting: Meeting) {
        id = meeting.id; segments = meeting.segments; turns = meeting.speakerTurns
        names = meeting.speakerNames; people = meeting.speakerReviewPeople
        assignments = meeting.speakerReviewAssignments; suggestions = meeting.speakerSuggestions
    }
    var meeting: Meeting {
        var value = Meeting(id: id, title: "", segments: segments, speakerNames: names)
        value.speakerTurns = turns; value.speakerReviewPeople = people
        value.speakerReviewAssignments = assignments; value.speakerSuggestions = suggestions
        return value
    }
}

struct TranscriptGroupingOptions: Hashable {
    var source: SpeakerAudioSource?
    var flowing: Bool
    var hideEchoes: Bool
}

struct TranscriptPresentationRequest: Equatable {
    let input: TranscriptPresentationInput
    let grouping: TranscriptGroupingOptions
    let query: String
}

struct TranscriptPresentationRow: Identifiable, Equatable {
    let block: TranscriptConversationBlock
    let name: String
    let text: String
    let sourceIDs: Set<String>
    let searchNames: [String]
    let canReview: Bool
    var id: String { block.id }
}

/// Immutable values prepared away from SwiftUI's body. Each name/rank/identity
/// and each block's joined text are resolved once per relevant input/options.
struct TranscriptPresentationSnapshot {
    let sources: Set<SpeakerAudioSource>
    let hiddenSegmentIDs: Set<String>
    private let ordered: [TranscriptSegment]
    private let echoOrdered: [TranscriptSegment]
    private let names: [String: String]
    private let identities: [String: String]
    private let reviewIDs: Set<String>

    static func prepare(_ input: TranscriptPresentationInput) throws -> Self {
        try Task.checkCancellation()
        let meeting = input.meeting
        let speakerOrder = SpeakerReviewPolicy.speakerIDs(in: meeting)
        let names = SpeakerPresentation.names(in: meeting, orderedSpeakerIDs: speakerOrder)
        let ids = Set(speakerOrder).union(input.segments.map(\.speaker))
        var identities: [String: String] = [:]
        for id in ids {
            try Task.checkCancellation()
            identities[id] = SpeakerReviewQueue.identifiedKey(for: id, in: meeting).map { "known:" + $0 } ?? "voice:" + id
        }
        let ordered = TranscriptConversation.orderedSegments(input.segments)
        try Task.checkCancellation()
        let echo = TranscriptEchoProjection.project(input.segments)
        try Task.checkCancellation()
        return Self(sources: Set(input.segments.map(SpeakerTranscriptAlignment.source(for:))),
            hiddenSegmentIDs: echo.hiddenSegmentIDs, ordered: ordered,
            echoOrdered: ordered.filter { !echo.hiddenSegmentIDs.contains($0.id) },
            names: names, identities: identities, reviewIDs: Set((input.turns ?? []).map(\.speakerID)))
    }

    func rows(for options: TranscriptGroupingOptions) throws -> [TranscriptPresentationRow] {
        try Task.checkCancellation()
        let source = options.source
        let base = source == nil && options.hideEchoes ? echoOrdered : ordered
        let selected = base.filter { source == nil || SpeakerTranscriptAlignment.source(for: $0) == source }
        let blocks = options.flowing
            ? TranscriptConversation.blocks(orderedSegments: selected, identities: identities)
            : selected.map { TranscriptConversationBlock(segments: [$0]) }
        var result: [TranscriptPresentationRow] = []
        result.reserveCapacity(blocks.count)
        for block in blocks {
            try Task.checkCancellation()
            let blockSpeakers = Set(block.segments.map(\.speaker))
            result.append(.init(block: block, name: names[block.speaker] ?? block.speaker,
                text: block.text, sourceIDs: Set(block.sourceSegmentIDs),
                searchNames: blockSpeakers.map { names[$0] ?? $0 }, canReview: reviewIDs.contains(block.speaker)))
        }
        return result
    }
    static func filtered(_ rows: [TranscriptPresentationRow], query: String) throws -> [TranscriptPresentationRow] {
        let clean = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return rows }
        return try rows.filter { row in
            try Task.checkCancellation()
            return row.text.localizedStandardContains(clean) || row.searchNames.contains { $0.localizedStandardContains(clean) }
        }
    }

}

@MainActor
final class TranscriptPresentationModel: ObservableObject {
    @Published private(set) var snapshot: TranscriptPresentationSnapshot?
    @Published private(set) var rows: [TranscriptPresentationRow] = []
    @Published private(set) var revision = 0
    private var blockIDBySegment: [String: String] = [:]
    private var preparedInput: TranscriptPresentationInput?
    private var preparedSnapshot: TranscriptPresentationSnapshot?
    private var pendingInput: TranscriptPresentationInput?
    private var preparation: Task<TranscriptPresentationSnapshot?, Never>?
    private var rowWork: Task<([TranscriptPresentationRow], [TranscriptPresentationRow])?, Never>?
    private var rowCache: [TranscriptGroupingOptions: [TranscriptPresentationRow]] = [:]
    private var renderedRequest: TranscriptPresentationRequest?
    private var latestRequest = UUID()
    // Deterministic work counters for regression tests; not published/render state.
    private(set) var preparationCount = 0
    private(set) var groupingCount = 0
    private(set) var filteringCount = 0

    func update(_ request: TranscriptPresentationRequest) async {
        // Returning to an already rendered request must also invalidate any
        // different request still preparing; otherwise stale work could win.
        let token = UUID(); latestRequest = token
        rowWork?.cancel()
        guard renderedRequest != request else { return }
        if !request.query.isEmpty {
            do { try await Task.sleep(for: .milliseconds(180)) } catch { return }
        }
        guard !Task.isCancelled, latestRequest == token else { return }
        let prepared: TranscriptPresentationSnapshot
        if preparedInput == request.input, let cached = preparedSnapshot { prepared = cached }
        else {
            if pendingInput != request.input || preparation == nil {
                preparation?.cancel()
                pendingInput = request.input
                let input = request.input
                preparationCount += 1
                preparation = Task.detached(priority: .userInitiated) {
                    try? TranscriptPresentationSnapshot.prepare(input)
                }
            }
            guard let result = await preparation?.value, !Task.isCancelled, latestRequest == token else { return }
            prepared = result
            if preparedInput != request.input { rowCache.removeAll() }
            preparedInput = request.input; preparedSnapshot = result
        }
        let cachedRows = rowCache[request.grouping]
        if cachedRows == nil { groupingCount += 1 }
        filteringCount += 1
        let grouping = request.grouping, query = request.query
        let worker = Task.detached(priority: .userInitiated) { () -> ([TranscriptPresentationRow], [TranscriptPresentationRow])? in
            do {
                let all = try cachedRows ?? prepared.rows(for: grouping)
                return (all, try TranscriptPresentationSnapshot.filtered(all, query: query))
            } catch { return nil }
        }
        rowWork = worker
        let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
        guard let result, !Task.isCancelled, latestRequest == token else { return }
        rowCache[grouping] = result.0
        var anchors: [String: String] = [:]
        for row in result.1 {
            for id in row.sourceIDs where anchors[id] == nil { anchors[id] = row.id }
        }
        blockIDBySegment = anchors
        renderedRequest = request
        snapshot = prepared; rows = result.1; revision += 1
    }
    func matches(_ input: TranscriptPresentationInput) -> Bool { renderedRequest?.input == input }
    func matches(_ request: TranscriptPresentationRequest) -> Bool { renderedRequest == request }
    func blockID(containing sourceID: String, input: TranscriptPresentationInput) -> String? {
        guard matches(input) else { return nil }
        return blockIDBySegment[sourceID]
    }
    func cancel() {
        latestRequest = UUID(); preparation?.cancel(); rowWork?.cancel()
        preparation = nil; pendingInput = nil; rowWork = nil
    }
}
