import Foundation

/// A local spelling preference. It never becomes an ASR prompt or a speaker identity.
struct GlossaryEntry: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var canonical: String
    var variants: [String]
}

enum GlossaryError: LocalizedError {
    case invalidEntry, duplicateID, ambiguousTerm(String), invalidArchive, invalidStorage, staleSuggestion

    var errorDescription: String? {
        switch self {
        case .invalidEntry: return "Doğru yazımı ve en az bir farklı duyulan yazımı girin. Her yazım tek satırda, en fazla 200 karakter olmalı."
        case .duplicateID: return "Sözlükte yinelenen bir kayıt kimliği var. Önceki kayıtlar korundu."
        case .ambiguousTerm(let term): return "“\(term)” birden fazla kayda veya aynı doğru yazıma bağlanıyor. Her yazımı yalnız bir kez kullanın."
        case .invalidArchive: return "Kişisel sözlük okunamadı. Mevcut dosya korunuyor; sözlük değiştirilmedi."
        case .invalidStorage: return "Kişisel sözlük kaydedilemedi. Önceki kayıtlar korundu."
        case .staleSuggestion: return "Transkript veya sözlük değişti. Bu öneri uygulanmadı; güncel öneriyi yeniden seçin."
        }
    }
}

enum GlossaryValidation {
    static let locale = Locale(identifier: "tr_TR")

    static func key(_ text: String) -> String {
        text.precomposedStringWithCanonicalMapping
            .folding(options: [.caseInsensitive], locale: locale)
            .precomposedStringWithCanonicalMapping
    }

    static func validTerm(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 200 &&
        value == value.trimmingCharacters(in: .whitespacesAndNewlines) &&
        value.rangeOfCharacter(from: .newlines.union(.controlCharacters)) == nil &&
        value.unicodeScalars.contains { CharacterSet.letters.union(.decimalDigits).contains($0) }
    }

    static func entries(_ entries: [GlossaryEntry]) throws {
        guard entries.count <= 5_000 else { throw GlossaryError.invalidEntry }
        guard Set(entries.map(\.id)).count == entries.count else { throw GlossaryError.duplicateID }
        var owners: [String: UUID] = [:]
        for entry in entries {
            guard validTerm(entry.canonical), !entry.variants.isEmpty, entry.variants.count <= 100,
                  entry.variants.allSatisfy(validTerm) else { throw GlossaryError.invalidEntry }
            for term in [entry.canonical] + entry.variants {
                let key = key(term)
                // Duplicate terms within one entry are rejected as well as conflicting mappings.
                guard owners[key] == nil else { throw GlossaryError.ambiguousTerm(term) }
                owners[key] = entry.id
            }
        }
    }
}

struct GlossarySuggestion: Identifiable, Equatable {
    var entryID: UUID
    var segment: TranscriptSegment
    var location: Int
    var length: Int
    var matchedText: String
    var canonical: String
    var afterText: String

    var id: String { "\(segment.id.utf8.count):\(segment.id):\(entryID.uuidString):\(location):\(length)" }
    var beforeText: String { segment.text }
}

enum TranscriptGlossary {
    private struct Term {
        var entryID: UUID
        var variant: String
        var canonical: String
    }

    /// Exact, locale-aware occurrences only. Ambiguous mappings and overlapping
    /// phrases are omitted rather than choosing a replacement on the user's behalf.
    static func suggestions(segments: [TranscriptSegment], entries: [GlossaryEntry]) -> [GlossarySuggestion] {
        guard entries.count <= 5_000 else { return [] }
        let duplicateEntryIDs = Set(Dictionary(grouping: entries, by: \.id).filter { $0.value.count != 1 }.keys)
        let validEntries = entries.filter {
            !duplicateEntryIDs.contains($0.id) && GlossaryValidation.validTerm($0.canonical) &&
            !$0.variants.isEmpty && $0.variants.count <= 100 && $0.variants.allSatisfy(GlossaryValidation.validTerm)
        }
        let canonicalOwners = Dictionary(grouping: validEntries, by: { GlossaryValidation.key($0.canonical) })
        var groups: [String: [Term]] = [:]
        for entry in validEntries {
            guard canonicalOwners[GlossaryValidation.key(entry.canonical)]?.count == 1 else { continue }
            for variant in entry.variants {
                let key = GlossaryValidation.key(variant)
                guard key != GlossaryValidation.key(entry.canonical) else { continue }
                groups[key, default: []].append(Term(entryID: entry.id, variant: variant, canonical: entry.canonical))
            }
        }
        let terms: [Term] = groups.compactMap { key, values in
            guard values.count == 1, canonicalOwners[key] == nil else { return nil }
            return values.first
        }.sorted {
            if $0.variant.count != $1.variant.count { return $0.variant.count > $1.variant.count }
            return $0.entryID.uuidString < $1.entryID.uuidString
        }
        let duplicateSegmentIDs = Set(Dictionary(grouping: segments, by: \.id).filter { $0.value.count != 1 }.keys)
        var result: [GlossarySuggestion] = []
        for segment in segments where !duplicateSegmentIDs.contains(segment.id) {
            if Task.isCancelled { return [] }
            var candidates: [GlossarySuggestion] = []
            for term in terms {
                var cursor = segment.text.startIndex
                while cursor < segment.text.endIndex,
                      let range = segment.text.range(of: term.variant, options: [.caseInsensitive],
                          range: cursor..<segment.text.endIndex, locale: GlossaryValidation.locale) {
                    cursor = segment.text.index(after: range.lowerBound)
                    guard isWholeTerm(range, in: segment.text) else { continue }
                    let nsRange = NSRange(range, in: segment.text)
                    var replacement = segment.text
                    replacement.replaceSubrange(range, with: term.canonical)
                    guard replacement != segment.text else { continue }
                    candidates.append(GlossarySuggestion(entryID: term.entryID, segment: segment,
                        location: nsRange.location, length: nsRange.length,
                        matchedText: String(segment.text[range]), canonical: term.canonical, afterText: replacement))
                }
            }
            let unambiguous = candidates.filter { candidate in
                !candidates.contains { other in
                    other.id != candidate.id && NSIntersectionRange(
                        NSRange(location: candidate.location, length: candidate.length),
                        NSRange(location: other.location, length: other.length)).length > 0
                }
            }
            result.append(contentsOf: unambiguous.sorted {
                if $0.location != $1.location { return $0.location < $1.location }
                return $0.id < $1.id
            })
        }
        return result
    }

    /// Recompute membership against the current source and current dictionary.
    /// Only the chosen occurrence loses word timings; identities and audio stay intact.
    static func applying(_ suggestion: GlossarySuggestion, to meeting: Meeting, entries: [GlossaryEntry]) throws -> Meeting {
        guard meeting.segments.filter({ $0.id == suggestion.segment.id }).count == 1,
              let index = meeting.segments.firstIndex(where: { $0.id == suggestion.segment.id }),
              meeting.segments[index] == suggestion.segment,
              suggestions(segments: [meeting.segments[index]], entries: entries).contains(suggestion) else {
            throw GlossaryError.staleSuggestion
        }
        var updated = meeting
        updated.segments[index].text = suggestion.afterText
        updated.segments[index].words = nil
        updated.notesNeedRefresh = updated.notes != nil || updated.notesNeedRefresh
        updated.reviewedAt = nil
        return updated
    }

    private static func isWholeTerm(_ range: Range<String.Index>, in text: String) -> Bool {
        if range.lowerBound > text.startIndex, isWord(text[text.index(before: range.lowerBound)]) { return false }
        if range.upperBound < text.endIndex, isWord(text[range.upperBound]) { return false }
        return true
    }

    private static func isWord(_ character: Character) -> Bool {
        character.unicodeScalars.contains {
            CharacterSet.letters.union(.decimalDigits).union(.nonBaseCharacters).contains($0) || $0 == "_"
        }
    }
}
