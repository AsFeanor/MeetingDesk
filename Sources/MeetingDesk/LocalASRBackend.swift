import Foundation

/// The existing speech-language setting selects the local transcriber.
enum LocalASRBackend: String, CaseIterable, Codable, Identifiable, Sendable {
    case apple, mlxWhisper = "mlx-whisper"
    var id: String { rawValue }
    var label: String { self == .apple ? "Apple" : "Whisper · bu Mac’te" }

    /// First-release routing uses only the existing speech-language setting.
    /// No backend picker/preference or per-meeting backend field is introduced.
    static func route(language: String) throws -> Self {
        if language == "Türkçe + English" { return .mlxWhisper }
        _ = try LocalTranscriptionService.localeIdentifier(for: language)
        return .apple
    }

    func validate(language: String) throws {
        switch self {
        case .apple: _ = try LocalTranscriptionService.localeIdentifier(for: language)
        case .mlxWhisper: _ = try WhisperLanguageMode(language: language)
        }
    }
}

enum WhisperLanguageMode: String, Codable, Hashable, Sendable {
    case turkishEnglish = "tr-en-mixed"
    init(language: String) throws {
        switch language {
        case "Türkçe + English": self = .turkishEnglish
        default: throw WhisperAdapterFailure.unsupportedLanguage
        }
    }
}

/// Optional addition to Meeting: legacy archives continue to decode as before.
/// This records the successful transcript, not the current settings selection.
struct TranscriptASRProvenance: Codable, Equatable, Sendable {
    var schemaVersion = 1
    let backend: LocalASRBackend
    let implementationVersion: String?
    let modelIdentifier: String?
    let modelRevision: String?
    let decodingStrategyID: String?
    let languageMode: String
    let wordTimings: String?
    var wordTimingSummary: TranscriptWordTimingSummary? = nil
}

enum WhisperAdapterFailure: LocalizedError {
    case unsupportedLanguage, unacceptedLanguageStrategy, closedSession, concurrentRequest
    case invalidPCM, invalidEnvelope, incompleteTrack, invalidSegment, invalidWords, noSpeech, cleanupFailed
    case runtimeUnavailable, workerFailed, workerDeadline
    var errorDescription: String? {
        switch self {
        case .unsupportedLanguage: return "Bu Whisper ayarı için Türkçe + English seç. Tek dilli seçenekler Apple ile işlenir."
        case .unacceptedLanguageStrategy: return "Bu dil seçimi için doğrulanmış transkript ayarı hazır değil."
        case .closedSession, .concurrentRequest: return "Transkript oturumu hazır değil. Önceki kayıt korunuyor; yeniden deneyebilirsin."
        case .invalidPCM: return "Sesin tamamı transkript için hazırlanamadı. Özgün kayıt korunuyor."
        case .invalidEnvelope, .incompleteTrack: return "Yerel transkript sonucu tamamlanamadı veya doğrulanamadı. Önceki döküm korunuyor."
        case .invalidSegment, .invalidWords: return "Yerel transkriptin zaman bilgileri doğrulanamadı. Eksik döküm kaydedilmedi."
        case .noSpeech: return "Bu kayıtta konuşma tanınamadı. Özgün kayıt korunuyor."
        case .cleanupFailed: return "Geçici transkript dosyaları temizlenemedi. İşlem tamamlanmadı; önceki döküm korunuyor."
        case .runtimeUnavailable: return "Yerel karma dil transkript bileşeni hazır değil. Uygulamayı ve model kurulumunu kontrol et."
        case .workerFailed: return "Yerel transkript tamamlanamadı. Önceki döküm ve özgün kayıt korunuyor."
        case .workerDeadline: return "Yerel transkript süresi aşıldı. Önceki döküm ve özgün kayıt korunuyor."
        }
    }
}
