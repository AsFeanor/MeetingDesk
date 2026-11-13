import Foundation

enum LocalSummaryBackend: String, CaseIterable, Identifiable {
    case qwen, apple

    static let defaultsKey = "meetingdesk.localSummaryBackend"
    var id: String { rawValue }

    static func selection(in defaults: UserDefaults) -> LocalSummaryBackend {
        defaults.string(forKey: defaultsKey).flatMap(LocalSummaryBackend.init(rawValue:)) ?? .qwen
    }

    var label: String {
        switch self {
        case .qwen: return "Qwen3.5 9B · önerilen"
        case .apple: return "Apple Intelligence · temel"
        }
    }

    var notesEngine: String {
        switch self {
        case .qwen: return OllamaSummaryService.engineIdentifier
        case .apple: return ProcessingMode.local.rawValue
        }
    }

    var meetingDescription: String {
        switch self {
        case .qwen: return "Qwen3.5 ile kısa toplantı notu · Transkript bu Mac’te değerlendirilir."
        case .apple: return "Temel yerel özet · Apple Intelligence kullanır; transkript Mac’te işlenir."
        }
    }
}
