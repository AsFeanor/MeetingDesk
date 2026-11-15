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
        // Older archives can contain chronology errors introduced when a source
        // utterance was split. Repair display order without rewriting the archive.
        let ordered = orderedSegments(meeting.segments)
        var result: [TranscriptConversationBlock] = []
        for segment in ordered {
            if let last = result.last, canAppend(segment, to: last, meeting: meeting) {
                result[result.count - 1].segments.append(segment)
            } else {
                result.append(TranscriptConversationBlock(segments: [segment]))
            }
        }
        return result
    }

    private static func canAppend(_ segment: TranscriptSegment, to block: TranscriptConversationBlock, meeting: Meeting) -> Bool {
        guard let first = block.segments.first,
              first.start.isFinite, block.end.isFinite, first.start >= 0, block.end >= first.start,
              segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end >= segment.start,
              block.segments.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              block.source == SpeakerTranscriptAlignment.source(for: segment),
              identity(for: first.speaker, in: meeting) == identity(for: segment.speaker, in: meeting),
              segment.start - block.end <= 1.5,
              max(block.end, segment.end) - block.start <= 30 else { return false }
        return true
    }

    private static func identity(for speakerID: String, in meeting: Meeting) -> String {
        if let known = SpeakerReviewQueue.identifiedKey(for: speakerID, in: meeting) { return "known:" + known }
        return "voice:" + speakerID
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
