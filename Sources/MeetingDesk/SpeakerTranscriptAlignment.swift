import Foundation

enum SpeakerTranscriptAlignment {
    static func source(for segment: TranscriptSegment) -> SpeakerAudioSource {
        if let value = segment.audioSource { return value }
        if segment.id.hasPrefix("local-microphone-") || segment.speaker == "Mikrofon" { return .microphone }
        if segment.id.hasPrefix("local-system-") || segment.speaker == "Toplantı sesi" { return .system }
        return .mixed
    }

    static func assign(_ segments: [TranscriptSegment], turns: [SpeakerTurn]) throws -> [TranscriptSegment] {
        var result: [TranscriptSegment] = []
        for original in segments {
            try Task.checkCancellation()
            let source = source(for: original)
            let candidates = turns.filter { $0.source == source && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start }
            guard let words = original.words, !words.isEmpty,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= original.start && $0.end <= original.end && $0.end >= $0.start }),
                  zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }),
                  words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == original.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                var value = original
                value.audioSource = source
                value.words = nil
                value.speaker = bestSpeaker(start: original.start, end: original.end, turns: candidates, minimumCoverage: 0.95, maximumOtherCoverage: 0.05) ?? original.speaker
                result.append(value)
                continue
            }
            var groups: [(String, [TranscriptWord])] = []
            for word in words {
                let speaker = bestSpeaker(start: word.start, end: word.end, turns: candidates, minimumCoverage: 0.6) ?? sourceLabel(source)
                if groups.last?.0 == speaker { groups[groups.count - 1].1.append(word) }
                else { groups.append((speaker, [word])) }
            }
            for (index, group) in groups.enumerated() {
                let text = group.1.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty, let first = group.1.first, let last = group.1.last else { continue }
                result.append(TranscriptSegment(id: "\(original.id)-voice-\(index + 1)", speaker: group.0,
                    start: max(original.start, first.start), end: min(original.end, last.end), text: text,
                    words: group.1, audioSource: source))
            }
        }
        return result
    }

    private static func sourceLabel(_ source: SpeakerAudioSource) -> String {
        switch source { case .microphone: return "Mikrofon"; case .system: return "Toplantı sesi"; case .mixed: return "Konuşma" }
    }

    private static func bestSpeaker(start: Double, end: Double, turns: [SpeakerTurn], minimumCoverage: Double, maximumOtherCoverage: Double = 0.25) -> String? {
        let duration = end - start
        guard duration > 0, duration.isFinite else { return nil }
        let grouped = Dictionary(grouping: turns, by: \.speakerID)
        var scores: [(String, Double)] = []
        for (id, values) in grouped {
            var intervals: [(Double, Double)] = []
            for value in values {
                let lower = max(start, value.start), upper = min(end, value.end)
                if upper > lower { intervals.append((lower, upper)) }
            }
            intervals.sort { $0.0 < $1.0 }
            var total = 0.0, previousEnd = start
            for interval in intervals {
                total += max(0, interval.1 - max(interval.0, previousEnd))
                previousEnd = max(previousEnd, interval.1)
            }
            scores.append((id, total / duration))
        }
        scores.sort { first, second in first.1 == second.1 ? first.0 < second.0 : first.1 > second.1 }
        guard let best = scores.first, best.1 >= minimumCoverage else { return nil }
        let second = scores.dropFirst().first?.1 ?? 0
        guard second <= maximumOtherCoverage, best.1 - second >= 0.2 else { return nil }
        return best.0
    }
}
