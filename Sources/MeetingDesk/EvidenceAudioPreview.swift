import Foundation

struct EvidenceAudioExcerpt: Identifiable, Equatable {
    var id: String
    var segmentID: String
    var source: SpeakerAudioSource
    var start: Double
    var end: Double
    var duration: Double { end - start }
    var playbackSource: PlaybackSource {
        switch source { case .microphone: return .microphone; case .system: return .system; case .mixed: return .mixed }
    }
}

/// Bounded listening windows reference the original channel and source ID.
/// Missing/stale evidence never falls back to an unrelated timestamp or channel.
enum EvidenceAudioPreview {
    static func excerpts(in meeting: Meeting, evidence: [String]) -> [EvidenceAudioExcerpt] {
        guard meeting.duration.isFinite, meeting.duration > 0 else { return [] }
        let byID = Dictionary(grouping: meeting.segments, by: \.id)
        var seen = Set<String>()
        return evidence.compactMap { id -> EvidenceAudioExcerpt? in
            guard seen.insert(id).inserted, let values = byID[id], values.count == 1, let segment = values.first,
                  segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start,
                  segment.start < meeting.duration, segment.end <= meeting.duration + 0.25,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let start = max(0, segment.start - 0.35)
            let end = min(meeting.duration, start + 12, max(segment.end + 0.35, start + 3))
            guard end > start else { return nil }
            return EvidenceAudioExcerpt(id: "evidence:\(meeting.id.uuidString):\(id)", segmentID: id,
                source: SpeakerTranscriptAlignment.source(for: segment), start: start, end: end)
        }.sorted { $0.start == $1.start ? $0.segmentID < $1.segmentID : $0.start < $1.start }
    }
}
