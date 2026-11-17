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
            // A new ASR issue marker deliberately bypasses even dominant-voice
            // fallback. The segment may span a speaker change without word times.
            // Keep its exact text/times and channel identity for manual review.
            if original.wordTimingIssue?.requiresConservativeSpeakerAssignment == true {
                var value = original
                value.audioSource = source
                value.words = nil
                value.speaker = sourceLabel(source)
                result.append(value)
                continue
            }
            guard let words = original.words, !words.isEmpty,
                  words.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= original.start && $0.end <= original.end && $0.end >= $0.start }),
                  zip(words, words.dropFirst()).allSatisfy({ $0.start <= $1.start && $0.end <= $1.end }),
                  words.map(\.text).joined().trimmingCharacters(in: .whitespacesAndNewlines) == original.text.trimmingCharacters(in: .whitespacesAndNewlines) else {
                var value = original
                value.audioSource = source
                value.words = nil
                value.speaker = legacySpeaker(start: original.start, end: original.end, turns: candidates) ?? original.speaker
                result.append(value)
                continue
            }
            let speakers = formattingAwareSpeakers(words: words, turns: candidates, source: source)
            var groups: [(String, [TranscriptWord])] = []
            for (word, speaker) in zip(words, speakers) {
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
        // A single source utterance can become several speaker fragments. Its
        // later fragments must not precede another track's earlier utterance.
        // Preserve the original merge order for genuinely simultaneous starts.
        try Task.checkCancellation()
        let chronological = result.enumerated().sorted { first, second in
            if first.element.start != second.element.start { return first.element.start < second.element.start }
            return first.offset < second.offset
        }.map(\.element)
        try Task.checkCancellation()
        return chronological
    }

    /// Zero-duration punctuation has no acoustic identity. Keep its original
    /// word/timing attached to an unambiguous neighboring voice instead of
    /// generating an isolated source-label card. Lexical words and positive
    /// duration formatting still use the normal coverage/overlap rules.
    private static func formattingAwareSpeakers(words: [TranscriptWord], turns: [SpeakerTurn], source: SpeakerAudioSource) -> [String] {
        let fallback = sourceLabel(source)
        var speakers = words.map { bestSpeaker(start: $0.start, end: $0.end, turns: turns, minimumCoverage: 0.6) ?? fallback }
        let formatting = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        let zeroFormatting = words.map { word in
            word.start == word.end && !word.text.isEmpty && word.text.unicodeScalars.allSatisfy { formatting.contains($0) }
        }
        var preceding = [String?](repeating: nil, count: words.count)
        var following = [String?](repeating: nil, count: words.count)
        var neighbor: String?
        for index in words.indices {
            preceding[index] = neighbor
            if !zeroFormatting[index] { neighbor = speakers[index] }
        }
        neighbor = nil
        for index in words.indices.reversed() {
            following[index] = neighbor
            if !zeroFormatting[index] { neighbor = speakers[index] }
        }
        for index in words.indices where zeroFormatting[index] {
            let neighbors = [preceding[index], following[index]].compactMap { $0 }
            guard let voice = neighbors.first, voice != fallback,
                  neighbors.allSatisfy({ $0 == voice }) else { continue }
            speakers[index] = voice
        }
        return speakers
    }

    private static func sourceLabel(_ source: SpeakerAudioSource) -> String {
        switch source { case .microphone: return "Mikrofon"; case .system: return "Toplantı sesi"; case .mixed: return "Konuşma" }
    }

    /// Pauses outside detected speech are not evidence of another person. A
    /// wordless utterance can still be attributed when its detected speech has
    /// one clear voice; a meaningful second voice prevents whole-utterance naming.
    private static func legacySpeaker(start: Double, end: Double, turns: [SpeakerTurn]) -> String? {
        let duration = end - start
        guard start.isFinite, end.isFinite, start >= 0, duration.isFinite, duration > 0 else { return nil }
        let grouped = Dictionary(grouping: turns, by: \.speakerID)
        var seconds: [(String, Double)] = []
        for (speaker, values) in grouped where !speaker.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let intervals = values.map { (max(start, $0.start), min(end, $0.end)) }
                .filter { $0.1 > $0.0 }.sorted { $0.0 < $1.0 }
            var covered = 0.0
            var previousEnd = start
            for interval in intervals {
                covered += max(0, interval.1 - max(interval.0, previousEnd))
                previousEnd = max(previousEnd, interval.1)
            }
            if covered > 0 { seconds.append((speaker, covered)) }
        }
        seconds.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard let best = seconds.first, best.1 >= min(0.3, duration * 0.6) else { return nil }
        let other = seconds.dropFirst().reduce(0.0) { $0 + $1.1 }
        let detected = best.1 + other
        // Count overlapping secondary evidence too; a long majority turn cannot
        // erase another person's short commitment. Only <=50 ms of SDK jitter
        // is tolerated, and only below 2% of all detected speaker-seconds.
        guard other <= 0.05, detected.isFinite, best.1 / detected >= 0.98 else { return nil }
        return best.0
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
