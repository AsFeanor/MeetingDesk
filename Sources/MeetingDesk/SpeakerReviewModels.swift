import Foundation

/// A human-confirmed person inside one meeting. Several model clusters may refer to this person.
struct SpeakerReviewPerson: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var voiceProfileID: UUID? = nil
}

struct SpeakerReviewSelection: Equatable, Sendable {
    var personID: UUID? = nil
    var voiceProfileID: UUID? = nil
    var name: String
}

enum SpeakerReviewError: LocalizedError {
    case unknownSpeaker, unknownPerson, unknownVoiceProfile, conflictingSelection, invalidReviewData
    case duplicateName(String)

    var errorDescription: String? {
        switch self {
        case .unknownSpeaker: return "Bu ses bölümü artık bulunamıyor. Konuşmacı listesini yeniden açın."
        case .unknownPerson: return "Seçilen kişi artık bu toplantıda bulunamıyor. Listeden yeniden seçin."
        case .unknownVoiceProfile: return "Seçilen ses profili artık bulunamıyor. Başka bir kişi seçin veya yeni isim yazın."
        case .conflictingSelection: return "Kişi ve ses profili seçimleri birbiriyle uyuşmuyor. Tek bir kişi seçin."
        case .invalidReviewData: return "Toplantının kişi eşleştirmeleri okunamadı. Önceki konuşmacı bilgileri korundu."
        case .duplicateName(let name): return "\(name) bu toplantının kişi listesinde zaten var. Aynı kişiyse listeden seçin; farklı bir kişiyse soyadıyla birlikte yazın."
        }
    }
}
