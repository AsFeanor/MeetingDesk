import Foundation

enum SpeakerAudioSource: String, Codable, Sendable {
    case microphone, system, mixed
}

struct SpeakerTurn: Codable, Equatable, Sendable {
    var speakerID: String
    var source: SpeakerAudioSource
    var start: Double
    var end: Double
}

struct SpeakerVoiceSample: Sendable {
    var speakerID: String
    var embedding: [Float]
    var cleanDuration: Double
    var modelID: String
}

struct SpeakerAnalysis: Sendable {
    var turns: [SpeakerTurn]
    var samples: [SpeakerVoiceSample]
}

struct TranscriptWord: Codable, Equatable, Sendable {
    var text: String
    var start: Double
    var end: Double
}

struct SpeakerIdentitySuggestion: Codable, Equatable, Sendable {
    var profileID: UUID
    var name: String
    var similarity: Float
    var automatic: Bool
}
