import Foundation

/// Tokenization, index construction and ranking stay off the main actor. Updating an unchanged
/// transcript snapshot is a no-op; playback position and note edits are not index inputs.
actor ArchiveQuestionIndex {
    static let maximumPassages = 24
    static let maximumContextBytes = 72_000
    static let maximumPassageBytes = 16_000
    static let maximumQuestionBytes = 4_000

    private struct Document {
        let source: ArchiveQuestionSource
        let tokens: Set<String>
        let titleTokens: Set<String>
    }
    private var fingerprints: [UUID: String] = [:]
    private var documents: [String: Document] = [:]
    private var postings: [String: Set<String>] = [:]
    private var invalidMeetingIDs: Set<UUID> = []
    private var oversized: [UUID: Int] = [:]
    private(set) var buildCount = 0

    @discardableResult
    func replace(meetings: [Meeting]) throws -> Bool {
        guard Set(meetings.map(\.id)).count == meetings.count else { throw ArchiveQuestionFailure.invalidSources }
        let next = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, ArchiveQuestionFingerprint.meeting($0)) })
        guard next != fingerprints else { return false }
        var nextDocuments: [String: Document] = [:]
        var nextPostings: [String: Set<String>] = [:]
        var nextInvalid: Set<UUID> = []
        var nextOversized: [UUID: Int] = [:]
        for meeting in meetings {
            let ids = meeting.segments.map(\.id)
            guard meeting.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  Set(ids).count == ids.count,
                  meeting.segments.allSatisfy({ !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }) else {
                nextInvalid.insert(meeting.id); continue
            }
            // Names are retrieval metadata only; they never establish ownership of a statement.
            let titleTokens = Self.tokens(([meeting.title] + meeting.speakerNames.values.sorted()).joined(separator: " "))
            for segment in meeting.segments {
                guard !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
                guard segment.text.utf8.count <= Self.maximumPassageBytes else {
                    nextOversized[meeting.id, default: 0] += 1; continue
                }
                let alias = ArchiveQuestionSource.alias(meetingID: meeting.id, segmentID: segment.id)
                let source = ArchiveQuestionSource(id: alias, meetingID: meeting.id, segmentID: segment.id,
                    meetingTitle: meeting.title, meetingDate: meeting.createdAt, start: segment.start, end: segment.end,
                    text: segment.text, fingerprint: ArchiveQuestionFingerprint.source(meeting: meeting, segment: segment))
                let tokens = Self.tokens(segment.text)
                nextDocuments[alias] = Document(source: source, tokens: tokens, titleTokens: titleTokens)
                for token in tokens.union(titleTokens) { nextPostings[token, default: []].insert(alias) }
            }
        }
        fingerprints = next; documents = nextDocuments; postings = nextPostings
        invalidMeetingIDs = nextInvalid; oversized = nextOversized; buildCount += 1
        return true
    }

    func retrieve(question rawQuestion: String, meetingIDs: Set<UUID>? = nil) throws -> ArchiveQuestionContext {
        let question = rawQuestion.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, question.utf8.count <= Self.maximumQuestionBytes else { throw ArchiveQuestionFailure.invalidQuestion }
        let scopedIDs = Set(fingerprints.keys).filter { meetingIDs?.contains($0) ?? true }
        guard invalidMeetingIDs.isDisjoint(with: scopedIDs) else { throw ArchiveQuestionFailure.invalidSources }
        // An explicit empty scope stays empty. It never expands into the archive.
        let snapshot = ArchiveQuestionSnapshot(meetingIDs: meetingIDs,
            fingerprints: fingerprints.filter { scopedIDs.contains($0.key) })
        let query = Self.tokens(question)
        guard query.count <= 64 else { throw ArchiveQuestionFailure.invalidQuestion }
        var candidates: Set<String> = []
        var matchingTokens: [String: Set<String>] = [:]
        for term in query {
            var matches: Set<String> = []
            for token in postings.keys where Self.matches(term, token) {
                matches.formUnion(postings[token] ?? [])
                matchingTokens[term, default: []].insert(token)
            }
            candidates.formUnion(matches)
        }
        struct Ranked { let document: Document; let score: Double; let contentMatches: Int; let metadataMatches: Int }
        var ranked: [Ranked] = candidates.compactMap { alias in
            guard let document = documents[alias], scopedIDs.contains(document.source.meetingID) else { return nil }
            var contentMatches = 0
            var metadataMatches = 0
            var score = 0.0
            for term in query {
                let variants = matchingTokens[term] ?? []
                let frequency = variants.reduce(0) { $0 + (postings[$1]?.count ?? 0) }
                let inverseFrequency = log(1 + Double(documents.count + 1) / Double(frequency + 1))
                if !document.tokens.isDisjoint(with: variants) { contentMatches += 1; score += 2 * inverseFrequency }
                if !document.titleTokens.isDisjoint(with: variants) { metadataMatches += 1; score += inverseFrequency }
            }
            // Title/person metadata can identify the meeting ("Mia ile ne konuştuk?").
            // Only its actual transcript quotes may support the eventual answer.
            guard contentMatches > 0 || metadataMatches > 0 else { return nil }
            score += Double(contentMatches) / Double(max(1, query.count)) * 4
            return Ranked(document: document, score: score, contentMatches: contentMatches, metadataMatches: metadataMatches)
        }
        let latest = Self.prefersLatest(question)
        var retrievalNote: String?
        if latest, !ranked.isEmpty {
            // Explicit recency queries use archived meeting dates. Prefer an exact meeting
            // title/person context over an incidental mention in another meeting's transcript.
            let strongestMetadata = ranked.map(\.metadataMatches).max() ?? 0
            if strongestMetadata > 0 { ranked = ranked.filter { $0.metadataMatches == strongestMetadata } }
            if let newest = ranked.map({ $0.document.source.meetingDate }).max() {
                ranked = ranked.filter { $0.document.source.meetingDate == newest }
            }
            retrievalNote = "Son toplantı isteği, eşleşen toplantıların kayıt tarihine göre daraltıldı."
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.document.source.meetingDate != $1.document.source.meetingDate { return $0.document.source.meetingDate > $1.document.source.meetingDate }
            if $0.document.source.start != $1.document.source.start { return $0.document.source.start < $1.document.source.start }
            return $0.document.source.id < $1.document.source.id
        }
        let metadataOnly = !ranked.isEmpty && ranked.allSatisfy { $0.contentMatches == 0 }
        // A broad meeting/person question has no passage keyword to rank. Spread its bounded
        // excerpts across the meeting rather than silently reading only the beginning.
        let selectionOrder = metadataOnly ? Self.spreadIndices(count: ranked.count).map { ranked[$0] } : ranked
        var selected: [ArchiveQuestionSource] = []
        var byteCount = 0
        for row in selectionOrder {
            let bytes = row.document.source.text.utf8.count
            guard selected.count < Self.maximumPassages else { break }
            // Never take a prefix of a passage. An oversized candidate is skipped whole.
            guard byteCount + bytes <= Self.maximumContextBytes else { continue }
            selected.append(row.document.source); byteCount += bytes
        }
        if metadataOnly {
            selected.sort {
                if $0.meetingDate != $1.meetingDate { return $0.meetingDate > $1.meetingDate }
                if $0.meetingID != $1.meetingID { return $0.meetingID.uuidString < $1.meetingID.uuidString }
                if $0.start != $1.start { return $0.start < $1.start }
                return $0.id < $1.id
            }
            retrievalNote = (retrievalNote.map { $0 + " " } ?? "") + "Başlık veya katılımcı eşleşmesindeki konuşma bölümlerinden sınırlı bir seçki değerlendirildi."
        }
        return ArchiveQuestionContext(question: question, sources: selected, snapshot: snapshot,
            scopedMeetingCount: scopedIDs.count, matchedPassageCount: ranked.count,
            omittedOversizedPassageCount: oversized.filter { scopedIDs.contains($0.key) }.values.reduce(0, +), retrievalNote: retrievalNote)
    }

    private static func prefersLatest(_ text: String) -> Bool {
        let words = normalized(text).split { !$0.isLetter && !$0.isNumber }.map(String.init)
        let padded = " " + words.joined(separator: " ") + " "
        if [" en son ", " enson ", " latest ", " last ", " most recent "].contains(where: { padded.contains($0) }) { return true }
        return words.indices.dropLast().contains { words[$0] == "son" && (words[$0 + 1].hasPrefix("toplanti") || words[$0 + 1].hasPrefix("gorusme")) }
    }

    private static func spreadIndices(count: Int) -> [Int] {
        guard count > 1 else { return count == 1 ? [0] : [] }
        var result = [0, count - 1]
        var intervals = [(0, count - 1)]
        var cursor = 0
        while cursor < intervals.count {
            let (lower, upper) = intervals[cursor]; cursor += 1
            guard upper - lower > 1 else { continue }
            let middle = lower + (upper - lower) / 2
            result.append(middle)
            intervals.append((lower, middle)); intervals.append((middle, upper))
        }
        return result
    }

    static func normalized(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "tr_TR"))
            .replacingOccurrences(of: "ı", with: "i").lowercased()
    }

    static func tokens(_ text: String) -> Set<String> {
        let values = normalized(text).split { !$0.isLetter && !$0.isNumber }
        return Set(values.map(String.init).filter { $0.count > 1 && !stopwords.contains($0) })
    }

    private static func matches(_ query: String, _ token: String) -> Bool {
        if query == token { return true }
        // Conservative suffix tolerance covers Turkish inflections and common plural forms.
        return min(query.count, token.count) >= 4 && (query.hasPrefix(token) || token.hasPrefix(query))
    }

    private static let stopwords: Set<String> = [
        "ne", "nedir", "neler", "hangi", "nasil", "neden", "mi", "mu", "ve", "veya", "ile", "icin", "bu", "su", "bir", "da", "de", "olarak",
        "biz", "bana", "ben", "en", "enson", "son", "sonuncu", "sonra", "once", "toplanti", "toplantida", "toplantilar", "gecmis", "soyle", "anlat", "hakkinda", "konustuk", "konusuldu", "soylendi", "dedik", "demisti",
        "the", "a", "an", "is", "are", "was", "were", "be", "been", "of", "to", "in", "on", "at", "for", "from", "and", "or", "what", "when", "which", "how", "why", "did", "do", "does", "we", "our", "me", "about", "meeting", "meetings", "latest", "last", "most", "recent", "discuss", "discussed", "talk", "talked"
    ]
}
