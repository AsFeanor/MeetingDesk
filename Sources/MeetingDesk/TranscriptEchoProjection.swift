import Foundation

struct TranscriptEchoProjectionResult: Equatable {
    let segments: [TranscriptSegment]
    let hiddenSegmentIDs: Set<String>
    /// Lexical microphone words in segments actually hidden, never partial matches.
    let matchedWordCount: Int
}

/// An optional reading projection, never a transcription or archive mutation.
/// Only fully covered microphone segments are omitted. Every returned segment is
/// the original value in the original input order; system/mixed text is retained.
enum TranscriptEchoProjection {
    private static let pointTolerance = 0.5
    private static let minimumRunWords = 5
    private static let minimumRunCharacters = 20
    private static let minimumRunOverlap = 0.75
    private static let maximumPause = 1.25
    private static let lexicalCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
    private static let formattingCharacters = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

    static func project(_ segments: [TranscriptSegment]) -> TranscriptEchoProjectionResult {
        let duplicateIDs = Set(Dictionary(grouping: segments, by: \.id).filter { $0.value.count != 1 }.keys)
        let microphone = stream(segments, source: .microphone, duplicateIDs: duplicateIDs)
        let system = stream(segments, source: .system, duplicateIDs: duplicateIDs)
        guard !microphone.ranges.isEmpty, !system.ranges.isEmpty else { return unchanged(segments) }
        var anchors: [String: [Int]] = [:]
        for (index, token) in system.tokens.enumerated() {
            guard let token else { continue }
            anchors[token.text, default: []].append(index)
        }
        // Sorting anchor lists by time keeps lookup bounded even when another
        // same-channel segment overlaps the chronological segment stream.
        for key in Array(anchors.keys) {
            anchors[key]?.sort {
                let a = system.tokens[$0]!, b = system.tokens[$1]!
                return a.start == b.start ? $0 < $1 : a.start < b.start
            }
        }
        var hiddenIndices = Set<Int>()
        for (micIndex, optionalMic) in microphone.tokens.enumerated() {
            guard let mic = optionalMic, let candidates = anchors[mic.text] else { continue }
            var position = lowerBound(candidates, tokens: system.tokens, start: mic.start - pointTolerance)
            while position < candidates.count {
                let systemIndex = candidates[position]
                position += 1
                guard let firstSystem = system.tokens[systemIndex] else { continue }
                if firstSystem.start > mic.start + pointTolerance { break }
                guard match(mic, firstSystem) else { continue }
                // A maximal run is examined once per alignment, not once per word.
                if micIndex > 0, systemIndex > 0,
                   let previousMic = microphone.tokens[micIndex - 1], let previousSystem = system.tokens[systemIndex - 1],
                   match(previousMic, previousSystem),
                   adjacent(previousMic, mic, allowCrossSegment: microphone.allowCrossSegment),
                   adjacent(previousSystem, firstSystem, allowCrossSegment: system.allowCrossSegment) { continue }
                var length = 1
                var characters = mic.alphanumericCount
                while micIndex + length < microphone.tokens.count, systemIndex + length < system.tokens.count,
                      let nextMic = microphone.tokens[micIndex + length], let nextSystem = system.tokens[systemIndex + length],
                      let priorMic = microphone.tokens[micIndex + length - 1], let priorSystem = system.tokens[systemIndex + length - 1],
                      match(nextMic, nextSystem),
                      adjacent(priorMic, nextMic, allowCrossSegment: microphone.allowCrossSegment),
                      adjacent(priorSystem, nextSystem, allowCrossSegment: system.allowCrossSegment) {
                    characters += nextMic.alphanumericCount
                    length += 1
                }
                guard length >= minimumRunWords, characters >= minimumRunCharacters,
                      let lastMic = microphone.tokens[micIndex + length - 1], let lastSystem = system.tokens[systemIndex + length - 1],
                      overlap(mic.start, lastMic.end, firstSystem.start, lastSystem.end) >= minimumRunOverlap else { continue }
                let matched = micIndex..<(micIndex + length)
                var visitedSegments = Set<Int>()
                for tokenIndex in matched {
                    guard let token = microphone.tokens[tokenIndex], visitedSegments.insert(token.segmentIndex).inserted,
                          let range = microphone.ranges[token.segmentIndex],
                          range.lowerBound >= matched.lowerBound, range.upperBound <= matched.upperBound else { continue }
                    // One qualifying contiguous run must cover this entire segment.
                    // Separate partial runs are not combined into guessed coverage.
                    hiddenIndices.insert(token.segmentIndex)
                }
            }
        }
        guard !hiddenIndices.isEmpty else { return unchanged(segments) }
        let hiddenIDs = Set(hiddenIndices.map { segments[$0].id })
        let wordCount = hiddenIndices.reduce(0) { $0 + (microphone.ranges[$1]?.count ?? 0) }
        return TranscriptEchoProjectionResult(segments: segments.enumerated().compactMap {
            hiddenIndices.contains($0.offset) ? nil : $0.element
        }, hiddenSegmentIDs: hiddenIDs, matchedWordCount: wordCount)
    }

    private struct Token {
        let text: String
        let start: Double
        let end: Double
        let segmentIndex: Int
        var alphanumericCount: Int { text.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.count }
    }
    private struct Stream {
        var tokens: [Token?] = [] // nil is an unvalidated-text barrier, never skipped.
        var ranges: [Int: Range<Int>] = [:]
        var allowCrossSegment = true
    }

    private static func stream(_ segments: [TranscriptSegment], source: SpeakerAudioSource, duplicateIDs: Set<String>) -> Stream {
        let indices = segments.indices.filter { segments[$0].audioSource == source }.sorted {
            let a = segments[$0], b = segments[$1]
            let startA = a.start.isFinite ? a.start : .infinity
            let startB = b.start.isFinite ? b.start : .infinity
            if startA != startB { return startA < startB }
            let endA = a.end.isFinite ? a.end : .infinity
            let endB = b.end.isFinite ? b.end : .infinity
            return endA == endB ? $0 < $1 : endA < endB
        }
        var result = Stream()
        // An untimed source segment has an unknown position. Valid segments can
        // still match within themselves, but must not be joined across that unknown.
        result.allowCrossSegment = !indices.contains {
            !segments[$0].start.isFinite || !segments[$0].end.isFinite || segments[$0].start < 0 || segments[$0].end <= segments[$0].start
        }
        for index in indices {
            let segment = segments[index]
            guard !segment.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, !duplicateIDs.contains(segment.id),
                  let words = validatedTokens(segment, index: index) else {
                result.tokens.append(nil)
                continue
            }
            guard !words.isEmpty else { continue } // Valid punctuation is nonlexical.
            let lower = result.tokens.count
            result.tokens.append(contentsOf: words.map(Optional.some))
            result.ranges[index] = lower..<result.tokens.count
        }
        return result
    }

    private static func validatedTokens(_ segment: TranscriptSegment, index: Int) -> [Token]? {
        guard segment.start.isFinite, segment.end.isFinite, segment.start >= 0, segment.end > segment.start,
              let words = segment.words, !words.isEmpty,
              words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == segment.text.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        var tokens: [Token] = []
        var previous: TranscriptWord?
        for word in words {
            guard word.start.isFinite, word.end.isFinite, word.start >= segment.start, word.end <= segment.end,
                  word.end >= word.start,
                  previous.map({ word.start >= $0.start && word.end >= $0.end }) ?? true,
                  word.text.unicodeScalars.allSatisfy({ lexicalCharacters.contains($0) || formattingCharacters.contains($0) }) else { return nil }
            previous = word
            let normalized = word.text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
            let values = normalized.unicodeScalars.split { !lexicalCharacters.contains($0) }.map(String.init)
            if !values.isEmpty && word.end <= word.start { return nil }
            for value in values {
                // Isolated combining marks do not establish a spoken lexical word.
                guard value.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) else { return nil }
                tokens.append(Token(text: value, start: word.start, end: word.end, segmentIndex: index))
            }
        }
        return tokens
    }

    private static func adjacent(_ first: Token, _ second: Token, allowCrossSegment: Bool) -> Bool {
        (allowCrossSegment || first.segmentIndex == second.segmentIndex) &&
            second.start >= first.start && second.end >= first.end && second.start - first.end <= maximumPause
    }
    private static func match(_ first: Token, _ second: Token) -> Bool {
        first.text == second.text && abs(first.start - second.start) <= pointTolerance && abs(first.end - second.end) <= pointTolerance
    }
    private static func overlap(_ firstStart: Double, _ firstEnd: Double, _ secondStart: Double, _ secondEnd: Double) -> Double {
        let duration = max(firstEnd - firstStart, secondEnd - secondStart)
        guard duration.isFinite, duration > 0 else { return 0 }
        return max(0, min(firstEnd, secondEnd) - max(firstStart, secondStart)) / duration
    }
    private static func lowerBound(_ values: [Int], tokens: [Token?], start: Double) -> Int {
        var lower = 0, upper = values.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            if tokens[values[middle]]!.start < start { lower = middle + 1 } else { upper = middle }
        }
        return lower
    }
    private static func unchanged(_ segments: [TranscriptSegment]) -> TranscriptEchoProjectionResult {
        TranscriptEchoProjectionResult(segments: segments, hiddenSegmentIDs: [], matchedWordCount: 0)
    }
}
