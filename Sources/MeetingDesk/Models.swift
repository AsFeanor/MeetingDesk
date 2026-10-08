import Foundation

enum ProcessingMode: String, CaseIterable, Identifiable {
    case local, openAI
    var id: String { rawValue }
    var label: String { self == .local ? "Mac’te ücretsiz" : "OpenAI · ücretli" }
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

    func speakerName(_ id: String) -> String { speakerNames[id] ?? id }
    var speakers: [String] { Array(Set(segments.map(\.speaker))).sorted() }
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
