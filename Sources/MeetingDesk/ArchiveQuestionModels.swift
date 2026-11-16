import Foundation
import CryptoKit

struct ArchiveQuestionScope: Identifiable, Equatable, Sendable {
    let id: String
    let title: String
    /// nil means the complete archive is eligible for retrieval, not that every passage is read by the model.
    let meetingIDs: Set<UUID>?

    static let all = ArchiveQuestionScope(id: "all", title: "Tüm toplantılar", meetingIDs: nil)
}

struct ArchiveQuestionSource: Identifiable, Equatable, Sendable {
    let id: String
    let meetingID: UUID
    let segmentID: String
    let meetingTitle: String
    let meetingDate: Date
    let start: Double
    let end: Double
    let text: String
    let fingerprint: String

    static func alias(meetingID: UUID, segmentID: String) -> String {
        "m_" + meetingID.uuidString.lowercased() + "_s_" + ArchiveQuestionFingerprint.digest(Data(segmentID.utf8))
    }
}

struct ArchiveQuestionSnapshot: Equatable, Sendable {
    let meetingIDs: Set<UUID>?
    let fingerprints: [UUID: String]

    func isCurrent(in meetings: [Meeting]) -> Bool {
        let scoped = meetings.filter { meetingIDs?.contains($0.id) ?? true }
        guard Set(scoped.map(\.id)).count == scoped.count,
              scoped.count == fingerprints.count else { return false }
        return scoped.allSatisfy { fingerprints[$0.id] == ArchiveQuestionFingerprint.meeting($0) }
    }
}

struct ArchiveQuestionContext: Equatable, Sendable {
    let question: String
    let sources: [ArchiveQuestionSource]
    let snapshot: ArchiveQuestionSnapshot
    let scopedMeetingCount: Int
    let matchedPassageCount: Int
    let omittedOversizedPassageCount: Int
    var retrievalNote: String? = nil

    var disclosure: String {
        "Seçili kaynaklarda arandı: \(scopedMeetingCount) toplantıdan soruyla eşleşen \(sources.count) konuşma bölümü yerel modele sunuldu. Bu yanıt arşivin tamamını kapsamaz." + (retrievalNote.map { " " + $0 } ?? "")
    }
}

struct ArchiveAnswerParagraph: Identifiable, Equatable, Sendable {
    let id: String
    /// A concise model interpretation. `quote` is the separately verified supporting excerpt.
    let text: String
    let quote: String
    let source: ArchiveQuestionSource
}

struct ArchiveAnswer: Identifiable, Equatable, Sendable {
    let id: UUID
    let question: String
    let paragraphs: [ArchiveAnswerParagraph]
    let context: ArchiveQuestionContext

    var abstained: Bool { paragraphs.isEmpty }
    var disclosure: String { context.disclosure }
    var abstentionMessage: String { "Seçili kaynaklarda bu soruyu yanıtlayacak yeterli kanıt bulamadım. Soruyu farklı kelimelerle sormayı veya kapsamı değiştirmeyi deneyebilirsin." }
    func isCurrent(in meetings: [Meeting]) -> Bool { context.snapshot.isCurrent(in: meetings) }

    static func abstention(context: ArchiveQuestionContext) -> ArchiveAnswer {
        ArchiveAnswer(id: UUID(), question: context.question, paragraphs: [], context: context)
    }
}

enum ArchiveQuestionFailure: LocalizedError {
    case invalidQuestion, invalidSources, invalidResponse, incompleteResponse, staleSources, contextLimit
    var errorDescription: String? {
        switch self {
        case .invalidQuestion: return "Bir soru yaz. Çok uzun soruları kısaltıp yeniden deneyebilirsin."
        case .invalidSources: return "Seçili toplantıların kaynakları doğrulanamadı. Transkriptler korunuyor."
        case .invalidResponse: return "Yanıtın kaynak alıntıları doğrulanamadı. Yeniden sorabilirsin."
        case .incompleteResponse: return "Yerel model yanıtı tamamlayamadı. Eksik yanıt gösterilmedi."
        case .staleSources: return "Toplantı kaynakları değişti. Güncel kaynaklarla yeniden sor."
        case .contextLimit: return "Seçili kaynaklar yerel model isteğine sığmadı. Daha dar bir kapsam seçebilirsin."
        }
    }
}

enum ArchiveQuestionFingerprint {
    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func meeting(_ meeting: Meeting) -> String {
        var fields = [meeting.id.uuidString, meeting.title, String(meeting.createdAt.timeIntervalSinceReferenceDate)]
        // Array order and speaker metadata are included: an edit during a request invalidates its snapshot.
        for segment in meeting.segments {
            fields += [segment.id, segment.speaker, String(segment.start), String(segment.end), segment.text]
        }
        for key in meeting.speakerNames.keys.sorted() { fields += [key, meeting.speakerNames[key] ?? ""] }
        return digest(fields.reduce(into: Data()) { data, field in
            let bytes = Data(field.utf8)
            data.append(Data("\(bytes.count):".utf8)); data.append(bytes)
        })
    }

    static func source(meeting: Meeting, segment: TranscriptSegment) -> String {
        digest(Data([meeting.id.uuidString, segment.id, String(segment.start), String(segment.end), segment.text].joined(separator: "\u{001F}").utf8))
    }
}
