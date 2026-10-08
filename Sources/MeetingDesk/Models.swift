import Foundation

enum ProcessingMode: String, CaseIterable, Identifiable {
    case local, openAI
    var id: String { rawValue }
    var label: String { self == .local ? "Mac’te ücretsiz" : "OpenAI · ücretli" }
}

enum MeetingTemplate: String, CaseIterable, Identifiable, Codable {
    case general, team, product, customer

    var id: String { rawValue }
    var label: String {
        switch self {
        case .general: return "Genel toplantı"
        case .team: return "Ekip toplantısı"
        case .product: return "Ürün değerlendirmesi"
        case .customer: return "Müşteri görüşmesi"
        }
    }

    var description: String {
        switch self {
        case .general: return "Kararlar, aksiyonlar ve açık konular."
        case .team: return "İlerleme, engeller ve ekipçe kabul edilen sonraki adımlar."
        case .product: return "İhtiyaçlar, geri bildirimler, seçenekler ve kabul edilen ürün kararları."
        case .customer: return "Müşterinin ihtiyaçları, soruları ve açıkça verilen sözler."
        }
    }

    /// Templates change emphasis, never the standard of evidence or certainty.
    var promptGuidance: String {
        let emphasis: String
        switch self {
        case .general:
            emphasis = "Focus on accepted outcomes, concrete next steps, and unresolved issues."
        case .team:
            emphasis = "Emphasize stated progress, blockers, dependencies, and agreed team follow-up. A status update alone is not an action or decision."
        case .product:
            emphasis = "Emphasize stated user needs, product feedback, alternatives, trade-offs, and explicitly accepted product decisions. Do not invent priorities, acceptance criteria, estimates, or a roadmap."
        case .customer:
            emphasis = "Emphasize the customer's stated needs, concerns, questions, and explicit commitments. Separate requests and suggestions from promises; do not invent commercial terms or commitments."
        }
        return "Meeting template: \(rawValue). \(emphasis) Include only topics present in the sources; an empty category is valid. Never infer owners, dates, agreement, or identities from this template."
    }
}

struct TranscriptSegment: Codable, Identifiable, Equatable {
    var id: String
    var speaker: String
    var start: Double
    var end: Double
    var text: String
}

struct EvidenceItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var evidence: [String]
}

struct ActionItem: Codable, Identifiable, Equatable {
    var id: String
    var text: String
    var owner: String?
    var due: String?
    var evidence: [String]
}

struct TopicNote: Codable, Identifiable, Equatable {
    var id: String
    var title: String
    var text: String
    var evidence: [String]
}

struct MeetingNotes: Codable, Equatable {
    var summary: String
    var decisions: [EvidenceItem]
    var actions: [ActionItem]
    var questions: [EvidenceItem]
    var ideas: [EvidenceItem]
    var topics: [TopicNote]
}

struct Meeting: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var title: String
    var createdAt: Date = Date()
    var duration: Double = 0
    var audioFileName: String?
    var segments: [TranscriptSegment] = []
    var notes: MeetingNotes?
    var personalNotes: String = ""
    var speakerNames: [String: String] = [:]
    var completedActions: Set<String> = []
    var outputLanguage: String = "Türkçe"
    var notesNeedRefresh: Bool = false
    var source: String = "Kayıt"
    var transcriptionEngine: String?
    var notesEngine: String?
    var speechLanguage: String?
    var transcribedLanguage: String?
    var microphoneDeviceID: String?
    var microphoneDeviceName: String?
    var microphoneGain: Double?
    // Optional additions let older archives continue to decode with synthesized Codable.
    var templateRawValue: String?
    var notesManualEdits: NotesManualEdits?
    var reviewedAt: Date?
    var transcriptSourceSeparated: Bool?

    func speakerName(_ id: String) -> String { speakerNames[id] ?? id }
    var speakers: [String] { Array(Set(segments.map(\.speaker))).sorted() }
    var template: MeetingTemplate { MeetingTemplate(rawValue: templateRawValue ?? "") ?? .general }
    var notesAreReviewed: Bool { notes != nil && !notesNeedRefresh && reviewedAt != nil }
}

enum MeetingError: LocalizedError {
    case message(String)
    var errorDescription: String? {
        switch self { case .message(let value): return value }
    }
}

func timeLabel(_ seconds: Double) -> String {
    let s = max(0, Int(seconds.isFinite ? seconds : 0))
    return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s / 60 % 60, s % 60) : String(format: "%02d:%02d", s / 60, s % 60)
}
