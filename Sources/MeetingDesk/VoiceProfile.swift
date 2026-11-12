import Foundation

/// Only explicitly approved voice examples are kept here; no audio is stored.
struct VoiceProfile: Codable, Identifiable, Equatable, Sendable {
    var id: UUID = UUID()
    var name: String
    var modelID: String
    var samples: [[Float]]
    var createdAt: Date = Date()
    var updatedAt: Date = Date()
}

enum VoiceProfileError: LocalizedError {
    case invalidName, invalidSample, insufficientSpeech, unknownProfile, modelMismatch, invalidArchive, invalidStorage

    var errorDescription: String? {
        switch self {
        case .invalidName: return "Ses profili için en fazla 100 karakterlik bir isim yazın."
        case .invalidSample: return "Bu konuşmanın ses profili okunamadı. Temiz bir konuşma bölümüyle yeniden deneyin."
        case .insufficientSpeech: return "Sesi hatırlamak için en az 3 saniyelik temiz, tek kişilik konuşma gerekir."
        case .unknownProfile: return "Seçilen ses profili artık bulunamıyor."
        case .modelMismatch: return "Bu ses örneği profilin modeliyle uyumlu değil. Yeni bir ses profili oluşturun."
        case .invalidArchive: return "Ses profilleri dosyası okunamadı. Mevcut dosya korunuyor; üzerine yazılmadı."
        case .invalidStorage: return "Ses profilleri güvenli biçimde kaydedilemedi."
        }
    }
}

enum VoiceVector {
    static func normalized(_ values: [Float]) -> [Float]? {
        guard (2...4_096).contains(values.count), values.allSatisfy(\.isFinite) else { return nil }
        let squareSum = values.reduce(0.0) { $0 + Double($1) * Double($1) }
        guard squareSum.isFinite, squareSum > 0 else { return nil }
        let magnitude = sqrt(squareSum)
        return values.map { Float(Double($0) / magnitude) }
    }

    static func cosine(_ first: [Float], _ second: [Float]) -> Float? {
        guard first.count == second.count,
              let a = normalized(first), let b = normalized(second) else { return nil }
        let value = zip(a, b).reduce(0.0) { $0 + Double($1.0) * Double($1.1) }
        return Float(max(-1, min(1, value)))
    }
}

enum VoiceProfileValidation {
    static func name(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 100,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw VoiceProfileError.invalidName
        }
        return clean
    }

    static func sample(_ sample: SpeakerVoiceSample) throws -> [Float] {
        guard sample.cleanDuration.isFinite, sample.cleanDuration >= 3 else { throw VoiceProfileError.insufficientSpeech }
        guard validModelID(sample.modelID), let vector = VoiceVector.normalized(sample.embedding) else {
            throw VoiceProfileError.invalidSample
        }
        return vector
    }

    static func validModelID(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 256 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
            && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
    }

    static func profiles(_ profiles: [VoiceProfile]) throws {
        guard profiles.count <= 1_000, Set(profiles.map(\.id)).count == profiles.count else { throw VoiceProfileError.invalidArchive }
        var dimensions: [String: Int] = [:]
        for profile in profiles {
            guard (try? name(profile.name)) == profile.name, validModelID(profile.modelID),
                  (1...12).contains(profile.samples.count),
                  profile.createdAt.timeIntervalSinceReferenceDate.isFinite,
                  profile.updatedAt.timeIntervalSinceReferenceDate.isFinite,
                  let dimension = profile.samples.first?.count else { throw VoiceProfileError.invalidArchive }
            if let existing = dimensions[profile.modelID], existing != dimension { throw VoiceProfileError.invalidArchive }
            dimensions[profile.modelID] = dimension
            guard profile.samples.allSatisfy({ $0.count == dimension && VoiceVector.normalized($0) != nil }) else {
                throw VoiceProfileError.invalidArchive
            }
        }
    }
}

/// Enrollment is an explicit operation. Recognition never calls this method.
enum VoiceProfileEnrollment {
    static func remember(name: String, sample: SpeakerVoiceSample, existing: [VoiceProfile], profileID: UUID? = nil) throws -> [VoiceProfile] {
        let cleanName = try VoiceProfileValidation.name(name)
        let vector = try VoiceProfileValidation.sample(sample)
        try VoiceProfileValidation.profiles(existing)
        var profiles = existing
        if let profileID {
            guard let index = profiles.firstIndex(where: { $0.id == profileID }) else { throw VoiceProfileError.unknownProfile }
            guard profiles[index].modelID == sample.modelID,
                  profiles[index].samples.first?.count == vector.count else { throw VoiceProfileError.modelMismatch }
            profiles[index].name = cleanName
            profiles[index].samples.append(vector)
            profiles[index].samples = Array(profiles[index].samples.suffix(12))
            profiles[index].updatedAt = Date()
        } else {
            // Matching names do not imply matching identities or model versions.
            profiles.append(VoiceProfile(name: cleanName, modelID: sample.modelID, samples: [vector]))
        }
        try VoiceProfileValidation.profiles(profiles)
        return profiles
    }
}

enum VoiceProfileMatcher {
    static let automaticSimilarity: Float = 0.8
    static let automaticMargin: Float = 0.15
    static let suggestionSimilarity: Float = 0.65

    static func match(sample: SpeakerVoiceSample, profiles: [VoiceProfile]) -> SpeakerIdentitySuggestion? {
        guard let query = try? VoiceProfileValidation.sample(sample),
              Set(profiles.map(\.id)).count == profiles.count else { return nil }
        let scores: [(profile: VoiceProfile, score: Float)] = profiles.compactMap { profile in
            guard profile.modelID == sample.modelID,
                  (try? VoiceProfileValidation.name(profile.name)) == profile.name,
                  (1...12).contains(profile.samples.count),
                  profile.samples.allSatisfy({ $0.count == query.count && VoiceVector.normalized($0) != nil }) else { return nil }
            guard let score = profile.samples.compactMap({ VoiceVector.cosine(query, $0) }).max() else { return nil }
            return (profile, score)
        }.sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            return $0.profile.id.uuidString < $1.profile.id.uuidString
        }
        guard let best = scores.first, best.score >= suggestionSimilarity else { return nil }
        let runnerUp = scores.dropFirst().first?.score ?? -1
        let automatic = best.score >= automaticSimilarity && best.score - runnerUp >= automaticMargin
        return SpeakerIdentitySuggestion(profileID: best.profile.id, name: best.profile.name,
                                         similarity: best.score, automatic: automatic)
    }
}
