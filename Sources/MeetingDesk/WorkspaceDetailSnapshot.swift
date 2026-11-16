import Foundation

/// Meeting-derived display data does not depend on the playback clock.
/// Files may disappear after this snapshot; playback revalidates the live meeting,
/// source and exact excerpt at the moment the user presses a listening button.
struct WorkspaceDetailSnapshot {
    let meetingID: UUID?
    let participants: [WorkspaceParticipant]
    let identifiedParticipantCount: Int
    let segmentsByID: [String: TranscriptSegment]
    let uniqueSegmentIDs: Set<String>
    let availableAudioSources: Set<PlaybackSource>
    let duration: Double
    private let excerptsBySegmentID: [String: EvidenceAudioExcerpt]

    static let empty = WorkspaceDetailSnapshot(meetingID: nil, participants: [],
        identifiedParticipantCount: 0, segmentsByID: [:], uniqueSegmentIDs: [], availableAudioSources: [], duration: 0, excerptsBySegmentID: [:])

    static func build(meeting: Meeting, audioAvailable: (PlaybackSource) -> Bool) -> WorkspaceDetailSnapshot {
        let participants = WorkspaceParticipants.entries(in: meeting)
        // Text source links previously used first(where:), including legacy
        // duplicate IDs. Audio keeps its stricter unique-ID evidence policy.
        var segmentsByID: [String: TranscriptSegment] = [:]
        for segment in meeting.segments where segmentsByID[segment.id] == nil {
            segmentsByID[segment.id] = segment
        }
        var evidence: [String] = []
        if let notes = meeting.notes {
            evidence += (notes.decisions + notes.questions + notes.ideas).flatMap(\.evidence)
            evidence += notes.actions.flatMap(\.evidence)
            evidence += notes.topics.flatMap(\.evidence)
        }
        let candidates = EvidenceAudioPreview.excerpts(in: meeting, evidence: evidence)
        let availableSources = Set(PlaybackSource.allCases.filter(audioAvailable))
        let counts = Dictionary(grouping: meeting.segments, by: \.id).mapValues(\.count)
        var excerptsBySegmentID: [String: EvidenceAudioExcerpt] = [:]
        for excerpt in candidates {
            let source = excerpt.playbackSource
            if availableSources.contains(source) { excerptsBySegmentID[excerpt.segmentID] = excerpt }
        }
        return WorkspaceDetailSnapshot(meetingID: meeting.id, participants: participants,
            identifiedParticipantCount: participants.filter(\.isIdentified).count,
            segmentsByID: segmentsByID, uniqueSegmentIDs: Set(counts.compactMap { $0.value == 1 ? $0.key : nil }),
            availableAudioSources: availableSources, duration: meeting.duration, excerptsBySegmentID: excerptsBySegmentID)
    }

    func canPreview(_ segment: TranscriptSegment) -> Bool {
        guard uniqueSegmentIDs.contains(segment.id), segmentsByID[segment.id] == segment,
              duration.isFinite, duration > 0, segment.start.isFinite, segment.end.isFinite,
              segment.start >= 0, segment.end > segment.start, segment.start < duration,
              segment.end <= duration + 0.25,
              !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        let source: PlaybackSource
        switch SpeakerTranscriptAlignment.source(for: segment) {
        case .microphone: source = .microphone
        case .system: source = .system
        case .mixed: source = .mixed
        }
        return availableAudioSources.contains(source)
    }

    func excerpts(for ids: [String]) -> [EvidenceAudioExcerpt] {
        var seen = Set<String>()
        return ids.compactMap { id -> EvidenceAudioExcerpt? in
            guard seen.insert(id).inserted else { return nil }
            return excerptsBySegmentID[id]
        }.sorted { $0.start == $1.start ? $0.segmentID < $1.segmentID : $0.start < $1.start }
    }
}
