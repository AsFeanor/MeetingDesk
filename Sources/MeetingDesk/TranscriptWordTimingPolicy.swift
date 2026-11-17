import Foundation

/// Optional on TranscriptSegment. Absence retains legacy archive behavior.
/// All cases keep usable text/segment timing but require source-only automatic
/// assignment, rather than guessing an individual from an unsafe word list.
enum TranscriptWordTimingIssue: String, Codable, Equatable, Sendable {
    case missing, invalid, nonFiniteOrBounds, unordered, textMismatch
    var requiresConservativeSpeakerAssignment: Bool { true }
}

struct TranscriptWordTimingSummary: Codable, Equatable, Sendable {
    let segmentCount: Int
    let validWordTimedSegments: Int
    let missingWordLists: Int
    let invalidWordLists: Int
    var reviewRequiredSegments: Int { missingWordLists + invalidWordLists }

    init(segments: [TranscriptSegment]) {
        segmentCount = segments.count
        validWordTimedSegments = segments.filter { $0.wordTimingIssue == nil && $0.words?.isEmpty == false }.count
        missingWordLists = segments.filter { $0.wordTimingIssue == .missing }.count
        invalidWordLists = segments.filter { $0.wordTimingIssue != nil && $0.wordTimingIssue != .missing }.count
    }
}

enum WhisperWordTimingPolicy {
    struct Assessment {
        let words: [TranscriptWord]?
        let issue: TranscriptWordTimingIssue?
    }

    static func assess(_ segment: WhisperWorkerSegment, cleanText: String) -> Assessment {
        // Worker may already have omitted an unsafe list. Keep its conservative
        // marker; an unknown issue never authorizes individual-speaker alignment.
        if let marker = segment.wordTimingIssue {
            return Assessment(words: nil, issue: marker == "missing" ? .missing : .invalid)
        }
        guard let words = segment.words, !words.isEmpty else { return Assessment(words: nil, issue: .missing) }
        guard words.allSatisfy({ !$0.text.isEmpty && $0.start.isFinite && $0.end.isFinite
            && $0.start >= segment.start && $0.end <= segment.end && $0.end >= $0.start }) else {
            return Assessment(words: nil, issue: .nonFiniteOrBounds)
        }
        guard zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }) else {
            return Assessment(words: nil, issue: .unordered)
        }
        guard words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == cleanText else {
            return Assessment(words: nil, issue: .textMismatch)
        }
        return Assessment(words: words.map { TranscriptWord(text: $0.text, start: $0.start, end: $0.end) }, issue: nil)
    }
}
