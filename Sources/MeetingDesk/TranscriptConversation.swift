import Foundation

/// A read-only presentation block. Saved segments, words and source anchor IDs
/// remain intact even when several short recognition fragments share one card.
struct TranscriptConversationBlock: Identifiable, Equatable {
    var segments: [TranscriptSegment]
    var id: String { segments.first?.id ?? "" }
    var speaker: String { segments.first?.speaker ?? "" }
    var source: SpeakerAudioSource { segments.first.map(SpeakerTranscriptAlignment.source(for:)) ?? .mixed }
    var sourceSegmentIDs: [String] { segments.map(\.id) }
    var start: Double { segments.first?.start ?? 0 }
    var end: Double { segments.map(\.end).max() ?? start }
    var text: String { TranscriptConversation.joinedText(segments.map(\.text)) }
    func containsID(_ id: String) -> Bool { segments.contains { $0.id == id } }
}

enum TranscriptConversation {
    /// Chronological projection shared by presentation, export and new summary
    /// requests. Every original segment is retained; equal starts keep archive
    /// order and malformed legacy times remain present at the end.
    static func orderedSegments(_ segments: [TranscriptSegment]) -> [TranscriptSegment] {
        segments.enumerated().sorted { first, second in
            let left = first.element.start.isFinite ? first.element.start : Double.infinity
            let right = second.element.start.isFinite ? second.element.start : Double.infinity
            if left != right { return left < right }
            return first.offset < second.offset
        }.map(\.element)
    }

    static func blocks(in meeting: Meeting) -> [TranscriptConversationBlock] {
        let speakers = Set(meeting.segments.map(\.speaker))
        let identities = Dictionary(uniqueKeysWithValues: speakers.map { id in
            (id, SpeakerReviewQueue.identifiedKey(for: id, in: meeting).map { "known:" + $0 } ?? "voice:" + id)
        })
        return blocks(orderedSegments: orderedSegments(meeting.segments), identities: identities)
    }

    /// The presentation cache supplies already sorted segments and indexed
    /// identities. End/validity are accumulated once, not rescanned per word.
    static func blocks(orderedSegments: [TranscriptSegment], identities: [String: String]) -> [TranscriptConversationBlock] {
        var result: [TranscriptConversationBlock] = []
        var currentEnd = 0.0
        var currentValid = false
        var currentSource: SpeakerAudioSource = .mixed
        var currentIdentity = ""
        for segment in orderedSegments {
            let valid = segment.start.isFinite && segment.end.isFinite && segment.start >= 0 && segment.end >= segment.start
            let source = SpeakerTranscriptAlignment.source(for: segment)
            let identity = identities[segment.speaker] ?? "voice:" + segment.speaker
            if let first = result.last?.segments.first,
               currentValid && valid, currentSource == source, currentIdentity == identity,
               segment.start - currentEnd <= 1.5, max(currentEnd, segment.end) - first.start <= 30 {
                result[result.count - 1].segments.append(segment)
                currentEnd = max(currentEnd, segment.end)
            } else {
                result.append(TranscriptConversationBlock(segments: [segment]))
                currentEnd = segment.end
                currentValid = valid
                currentSource = source
                currentIdentity = identity
            }
        }
        return result
    }

    /// Only inserts a separator. No saved character is trimmed or replaced.
    /// Punctuation-only fragments from older archives can thus sit naturally
    /// beside their neighboring words without changing the source transcript.
    static func joinedText(_ texts: [String]) -> String {
        var result = ""
        for text in texts {
            if let previous = result.last, let next = text.first,
               !previous.isWhitespace, !next.isWhitespace,
               !",.;:!?%)]}…»”’'".contains(next), !"([{«“‘".contains(previous) {
                result += " "
            }
            result += text
        }
        return result
    }
}
