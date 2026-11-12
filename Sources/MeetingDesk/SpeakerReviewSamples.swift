import Foundation

struct SpeakerReviewSample: Identifiable, Equatable, Sendable {
    var id: String
    var speakerID: String
    var source: SpeakerAudioSource
    var start: Double
    var end: Double
    var duration: Double { end - start }
    var canRemember: Bool { duration >= 3.4 }
}

enum SpeakerReviewSamples {
    /// Excerpts point into the original track. No new audio file is created.
    static func samples(in meeting: Meeting, speakerID: String) -> [SpeakerReviewSample] {
        guard meeting.duration.isFinite, meeting.duration > 0 else { return [] }
        let all = (meeting.speakerTurns ?? []).filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.start < meeting.duration && $0.end > $0.start && $0.end <= meeting.duration + 0.25
        }
        let sources = Set(all.filter { $0.speakerID == speakerID }.map(\.source))
        guard sources.count == 1, let source = sources.first else { return [] }
        let target = union(all.filter { $0.source == source && $0.speakerID == speakerID }.compactMap { turn in
            let start = turn.start + 0.15, end = min(turn.end, meeting.duration) - 0.15
            return end > start ? start..<end : nil
        })
        let others = union(all.filter { $0.source == source && $0.speakerID != speakerID }.compactMap { turn -> Range<Double>? in
            let lower = max(0, turn.start - 0.15), upper = min(meeting.duration, turn.end + 0.15)
            return upper > lower ? lower..<upper : nil
        })
        var clean: [Range<Double>] = []
        for range in target {
            var cursor = range.lowerBound
            for blocked in others where blocked.upperBound > cursor && blocked.lowerBound < range.upperBound {
                if blocked.lowerBound > cursor { clean.append(cursor..<min(blocked.lowerBound, range.upperBound)) }
                cursor = max(cursor, blocked.upperBound)
                if cursor >= range.upperBound { break }
            }
            if cursor < range.upperBound { clean.append(cursor..<range.upperBound) }
        }
        let ranked = clean.filter { $0.countSeconds >= 1.5 }.sorted {
            $0.countSeconds == $1.countSeconds ? $0.lowerBound < $1.lowerBound : $0.countSeconds > $1.countSeconds
        }
        var selected: [Range<Double>] = []
        for range in ranked.prefix(3) {
            let length = min(8, range.countSeconds)
            let start = range.lowerBound + (range.countSeconds - length) / 2
            selected.append(start..<(start + length))
        }
        // Offer different words even when one uninterrupted turn is the only candidate.
        if selected.count < 3, let longest = ranked.first, longest.countSeconds >= 16 {
            for range in [longest.lowerBound..<(longest.lowerBound + 8), (longest.upperBound - 8)..<longest.upperBound] {
                guard selected.count < 3 else { break }
                if !selected.contains(where: { overlap($0, range) > 0.5 }) { selected.append(range) }
            }
        }
        return selected.enumerated().map { index, range in
            SpeakerReviewSample(id: "\(speakerID)-excerpt-\(index)-\(range.lowerBound)", speakerID: speakerID,
                                source: source, start: range.lowerBound, end: range.upperBound)
        }
    }

    private static func overlap(_ first: Range<Double>, _ second: Range<Double>) -> Double {
        max(0, min(first.upperBound, second.upperBound) - max(first.lowerBound, second.lowerBound))
    }

    private static func union(_ values: [Range<Double>]) -> [Range<Double>] {
        var result: [Range<Double>] = []
        for value in values.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = result.last, value.lowerBound <= last.upperBound {
                result[result.count - 1] = last.lowerBound..<max(last.upperBound, value.upperBound)
            } else { result.append(value) }
        }
        return result
    }
}

private extension Range where Bound == Double {
    var countSeconds: Double { upperBound - lowerBound }
}
