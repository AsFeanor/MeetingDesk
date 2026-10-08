import Foundation

struct ChannelTranscriptionResult {
    let segments: [TranscriptSegment]
    /// Identifies recording sources, never individual meeting participants.
    let sourceSeparated: Bool
    let notice: String?
}

/// Uses synchronized saved source tracks when both are explicitly available.
/// Source failures are never replaced by a successful mixed-file transcription.
struct ChannelTranscriptionService {
    typealias Transcriber = @Sendable (URL, String, Bool) async throws -> [TranscriptSegment]
    private let transcribeAudio: Transcriber
    private let temporaryRoot: URL

    init(temporaryRoot: URL = FileManager.default.temporaryDirectory, transcribeAudio: @escaping Transcriber = { url, language, allowNoSpeech in
        try await LocalTranscriptionService().transcribe(audioURL: url, language: language, allowNoSpeech: allowNoSpeech)
    }) {
        self.transcribeAudio = transcribeAudio
        self.temporaryRoot = temporaryRoot
    }

    func transcribe(
        mixedURL: URL, microphoneURL: URL? = nil, systemURL: URL? = nil, language: String, microphoneGain: Double = 1
    ) async throws -> ChannelTranscriptionResult {
        try Task.checkCancellation()
        _ = try LocalTranscriptionService.localeIdentifier(for: language)
        guard let microphoneURL, let systemURL else {
            // Legacy/imported recordings, or an explicitly missing source, need the
            // full mix so available microphone/remote speech is not silently lost.
            let segments = try await transcribeTrack(mixedURL, language: language, source: .mixed, allowNoSpeech: false)
            try Task.checkCancellation()
            let tagged = try Self.tag(segments, source: .mixed)
            guard !tagged.isEmpty else { throw Self.noSpeechError }
            return ChannelTranscriptionResult(
                segments: try Self.ordered(tagged), sourceSeparated: false,
                notice: "Ayrı mikrofon ve toplantı sesi kayıtları birlikte bulunmadığı için birleşik kayıt işlendi. Bu kayıtta kaynaklar veya kişiler otomatik ayrılamaz."
            )
        }
        guard microphoneURL.standardizedFileURL != systemURL.standardizedFileURL else {
            throw MeetingError.message("Mikrofon ve toplantı sesi için aynı dosya seçildi. Kaynaklar ayrı dosyalarda olmalıdır.")
        }

        // Sequential analysis avoids reserving two Apple speech models at once.
        // Both files retain their original timeline, including leading silence.
        let microphone: [TranscriptSegment]
        do {
            microphone = try await MicrophoneAudioPreparation.withPreparedAudio(input: microphoneURL, gain: microphoneGain, temporaryRoot: temporaryRoot) { preparedURL in
                try await transcribeTrack(preparedURL, language: language, source: .microphone, allowNoSpeech: true)
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            if error is SourceTranscriptionError { throw error }
            throw SourceTranscriptionError(source: Source.microphone.label, underlyingError: error)
        }
        try Task.checkCancellation()
        let system = try await transcribeTrack(systemURL, language: language, source: .system, allowNoSpeech: true)
        try Task.checkCancellation()
        let segments = try Self.merge(microphone: microphone, system: system)
        guard !segments.isEmpty else { throw Self.noSpeechError }
        var notice = "Mikrofon ve Toplantı sesi kayıtları ayrı işlendi. Etiketler kayıt kaynağını gösterir; Toplantı sesi içindeki kişiler otomatik ayrılmaz."
        if microphone.isEmpty { notice += " Mikrofon kaynağında konuşma tanınmadı." }
        if system.isEmpty { notice += " Toplantı sesi kaynağında konuşma tanınmadı." }
        return ChannelTranscriptionResult(segments: segments, sourceSeparated: true, notice: notice)
    }

    private func transcribeTrack(_ url: URL, language: String, source: Source, allowNoSpeech: Bool) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        guard url.isFileURL else { throw MeetingError.message("\(source.label) için Mac’te kayıtlı bir ses dosyası seçin.") }
        do {
            let segments = try await transcribeAudio(url, language, allowNoSpeech)
            try Task.checkCancellation()
            return segments
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw SourceTranscriptionError(source: source.label, underlyingError: error)
        }
    }

    /// An identical phrase with substantially overlapping timing may be remote
    /// audio leaking into the microphone. Keep the system copy, conservatively.
    static func merge(microphone: [TranscriptSegment], system: [TranscriptSegment]) throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let micSegments = try tag(microphone, source: .microphone)
        let systemSegments = try tag(system, source: .system)
        var systemByPhrase: [String: [TranscriptSegment]] = [:]
        for value in systemSegments {
            try Task.checkCancellation()
            if let phrase = echoPhrase(value.segment.text) {
                systemByPhrase[phrase, default: []].append(value.segment)
            }
        }
        var retained = systemSegments
        for value in micSegments {
            try Task.checkCancellation()
            let echo: Bool
            if let phrase = echoPhrase(value.segment.text), let candidates = systemByPhrase[phrase] {
                echo = candidates.contains { substantialOverlap(value.segment, $0) }
            } else { echo = false }
            if !echo { retained.append(value) }
        }
        try Task.checkCancellation()
        return try ordered(retained)
    }

    private enum Source {
        case microphone, system, mixed
        var label: String {
            switch self {
            case .microphone: return "Mikrofon"
            case .system: return "Toplantı sesi"
            case .mixed: return "Konuşma"
            }
        }
        var prefix: String {
            switch self {
            case .microphone: return "local-microphone"
            case .system: return "local-system"
            case .mixed: return "local-mixed"
            }
        }
        var order: Int {
            switch self {
            case .microphone: return 0
            case .system: return 1
            case .mixed: return 2
            }
        }
    }

    private struct TaggedSegment {
        var segment: TranscriptSegment
        let sourceOrder: Int
        let index: Int
    }

    private static func tag(_ segments: [TranscriptSegment], source: Source) throws -> [TaggedSegment] {
        var tagged: [TaggedSegment] = []
        for (index, original) in segments.enumerated() {
            try Task.checkCancellation()
            let clean = original.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !clean.isEmpty else { continue }
            guard original.start.isFinite, original.end.isFinite, original.start >= 0, original.end >= original.start else {
                throw MeetingError.message("\(source.label) transkriptinin zaman bilgileri geçersiz olduğu için sonuç kaydedilmedi.")
            }
            let segment = TranscriptSegment(id: "\(source.prefix)-\(index + 1)", speaker: source.label,
                                            start: original.start, end: original.end, text: clean)
            tagged.append(TaggedSegment(segment: segment, sourceOrder: source.order, index: index))
        }
        return tagged
    }

    private static func ordered(_ values: [TaggedSegment]) throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let sorted = values.sorted {
            if $0.segment.start != $1.segment.start { return $0.segment.start < $1.segment.start }
            if $0.segment.end != $1.segment.end { return $0.segment.end < $1.segment.end }
            if $0.sourceOrder != $1.sourceOrder { return $0.sourceOrder < $1.sourceOrder }
            return $0.index < $1.index
        }.map(\.segment)
        try Task.checkCancellation()
        return sorted
    }

    private static func echoPhrase(_ text: String) -> String? {
        let folded = text.folding(options: [.caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
        let wordCharacters = CharacterSet.alphanumerics.union(.nonBaseCharacters)
        let words = folded.unicodeScalars.split { !wordCharacters.contains($0) }.map(String.init)
        // Short agreements may legitimately be spoken by both sides at once.
        guard words.count >= 3, words.reduce(0, { $0 + $1.count }) >= 12 else { return nil }
        return words.joined(separator: " ")
    }

    private static func substantialOverlap(_ first: TranscriptSegment, _ second: TranscriptSegment) -> Bool {
        let firstDuration = first.end - first.start
        let secondDuration = second.end - second.start
        guard firstDuration > 0.1, secondDuration > 0.1 else { return false }
        let overlap = max(0, min(first.end, second.end) - max(first.start, second.start))
        return overlap / min(firstDuration, secondDuration) >= 0.8 && overlap / max(firstDuration, secondDuration) >= 0.6
    }

    private static var noSpeechError: MeetingError {
        .message("Bu kayıtta konuşma tanınamadı. Toplantı dilini ve kaydın sesini kontrol edin.")
    }

    private struct SourceTranscriptionError: LocalizedError {
        let source: String
        let underlyingError: Error
        var errorDescription: String? {
            "\(source) kaynağı işlenemedi; eksik transkript kaydedilmedi. \(underlyingError.localizedDescription)"
        }
    }
}
