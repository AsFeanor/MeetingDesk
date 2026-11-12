import Foundation
import AVFoundation
import CoreMedia
import Speech

/// Uses only Apple's on-device transcribers. No API key, audio upload, or cloud fallback.
struct LocalTranscriptionService {
    static let privacyDescription = "Ses Mac’te işlenir; herhangi bir API’ye gönderilmez. İlk kullanımda Apple’ın dil modeli indirilebilir. Ayrı kaynaklar varsa mikrofon ve toplantı sesi birlikte korunur. Konuşmacı tanıma açıldığında sesler yalnız bu Mac’teki onaylı ses profilleriyle karşılaştırılır."

    static func localeIdentifier(for language: String) throws -> String {
        switch language {
        case "Türkçe": return "tr-TR"
        case "English": return "en-US"
        default: throw MeetingError.message("Yerel transkript için toplantı dilini Türkçe veya English olarak seçin.")
        }
    }

    static func availabilityDescription(language: String) async -> String {
        guard #available(macOS 26, *) else {
            return "Ücretsiz yerel transkript macOS 26 veya daha yeni bir sürüm gerektirir."
        }
        do {
            let requested = Locale(identifier: try localeIdentifier(for: language))
            if SpeechTranscriber.isAvailable,
               let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
                let installed = await SpeechTranscriber.installedLocales
                return availabilityMessage(language: language, installed: installed.contains(locale), engine: "Apple Konuşma")
            }
            if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
                let installed = await DictationTranscriber.installedLocales
                return availabilityMessage(language: language, installed: installed.contains(locale), engine: "Apple Dikte")
            }
            return "Bu Mac, \(language) için kullanılabilir bir yerel konuşma modeli bildirmedi. Ses buluta gönderilmez; transkripti yapıştırabilirsiniz."
        } catch { return error.localizedDescription }
    }

    private static func availabilityMessage(language: String, installed: Bool, engine: String) -> String {
        installed
            ? "\(engine): \(language) modeli hazır. Transkript Mac’te ücretsiz oluşturulur."
            : "\(engine): \(language) destekleniyor. İlk transkriptte Apple’ın dil modeli indirilir; bunun için internet gerekir."
    }

    func transcribe(audioURL: URL, language: String, allowNoSpeech: Bool = false) async throws -> [TranscriptSegment] {
        try Task.checkCancellation()
        let requested = Locale(identifier: try Self.localeIdentifier(for: language))
        guard audioURL.isFileURL else { throw MeetingError.message("Yerel transkript için Mac’te kayıtlı bir ses dosyası seçin.") }
        let file: AVAudioFile
        do { file = try AVAudioFile(forReading: audioURL) }
        catch {
            try Task.checkCancellation()
            throw MeetingError.message("Ses dosyası okunamadı: \(error.localizedDescription)")
        }
        try Task.checkCancellation()
        let duration = Double(file.length) / file.processingFormat.sampleRate
        guard duration.isFinite, duration > 0 else { throw MeetingError.message("Ses dosyası boş veya süresi okunamıyor.") }
        guard #available(macOS 26, *) else {
            throw MeetingError.message("Ücretsiz yerel transkript macOS 26 veya daha yeni bir sürüm gerektirir.")
        }
        if SpeechTranscriber.isAvailable,
           let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requested) {
            try Task.checkCancellation()
            let module = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            try await ensureAssets(for: module)
            return try await analyze(file: file, duration: duration, module: module, results: module.results, allowNoSpeech: allowNoSpeech)
        }
        try Task.checkCancellation()
        if let locale = await DictationTranscriber.supportedLocale(equivalentTo: requested) {
            try Task.checkCancellation()
            let module = DictationTranscriber(locale: locale, preset: .timeIndexedLongDictation)
            try await ensureAssets(for: module)
            return try await analyze(file: file, duration: duration, module: module, results: module.results, allowNoSpeech: allowNoSpeech)
        }
        try Task.checkCancellation()
        throw MeetingError.message("Bu Mac’te \(language) için ücretsiz yerel konuşma modeli kullanılamıyor. Ses buluta gönderilmedi. Başka bir dil seçebilir veya transkripti yapıştırabilirsiniz.")
    }

    @available(macOS 26, *)
    private func ensureAssets(for module: any SpeechModule) async throws {
        try Task.checkCancellation()
        do {
            if let installation = try await AssetInventory.assetInstallationRequest(supporting: [module]) {
                // The OS downloads language resources, never the meeting recording.
                try await withTaskCancellationHandler {
                    try await installation.downloadAndInstall()
                } onCancel: {
                    installation.progress.cancel()
                }
            }
            try Task.checkCancellation()
            let status = await AssetInventory.status(forModules: [module])
            try Task.checkCancellation()
            guard status == .installed else {
                throw MeetingError.message("Apple’ın yerel dil modeli henüz hazır değil. Model indirmesi için internet bağlantısını ve Mac’teki boş alanı kontrol edin.")
            }
        } catch is CancellationError { throw CancellationError() }
        catch {
            try Task.checkCancellation()
            throw MeetingError.message("Apple’ın yerel dil modeli hazırlanamadı. İlk kullanımda internet ve yeterli boş alan gerekir. \(error.localizedDescription)")
        }
    }

    @available(macOS 26, *)
    private func analyze<Results: AsyncSequence & Sendable>(
        file: AVAudioFile, duration: Double, module: any SpeechModule, results: Results, allowNoSpeech: Bool
    ) async throws -> [TranscriptSegment] where Results.Element: SpeechModuleResult {
        try Task.checkCancellation()
        let analyzer = SpeechAnalyzer(modules: [module])
        return try await withTaskCancellationHandler {
            async let collected = collect(results: results, duration: duration)
            do {
                let lastSample = try await analyzer.analyzeSequence(from: file)
                // Cancellation may make analyzeSequence return an early time instead of throwing.
                try Task.checkCancellation()
                guard let lastSample else { throw MeetingError.message("Ses dosyasında okunabilir ses örneği bulunamadı.") }
                try LocalTranscriptAssembler.requireEntireFileRead(lastSampleSeconds: lastSample.seconds, duration: duration)
                try await analyzer.finalizeAndFinish(through: lastSample)
                let transcript = try await collected
                try Task.checkCancellation()
                guard allowNoSpeech || !transcript.isEmpty else { throw MeetingError.message("Bu kayıtta konuşma tanınamadı. Toplantı dilini ve kaydın sesini kontrol edin.") }
                return transcript
            } catch {
                await analyzer.cancelAndFinishNow()
                throw error
            }
        } onCancel: {
            Task { await analyzer.cancelAndFinishNow() }
        }
    }

    @available(macOS 26, *)
    private func timedWords(_ text: AttributedString, start: Double, end: Double) -> [TranscriptWord]? {
        let fragments = text.runs.map { run -> TimedSpeechTextFragment in
            let range = run.audioTimeRange
            return TimedSpeechTextFragment(text: String(text[run.range].characters),
                                          start: range?.start.seconds, end: range?.end.seconds)
        }
        return TimedSpeechText.words(from: fragments, start: start, end: end)
    }

    @available(macOS 26, *)
    private func collect<Results: AsyncSequence>(results: Results, duration: Double) async throws -> [TranscriptSegment]
    where Results.Element: SpeechModuleResult {
        var assembler = LocalTranscriptAssembler(duration: duration)
        for try await result in results {
            try Task.checkCancellation()
            guard result.isFinal else { continue }
            // Both supported Apple transcribers expose text and timing in the same result shape.
            if let speech = result as? SpeechTranscriber.Result {
                try assembler.append(text: String(speech.text.characters), start: speech.range.start.seconds, end: speech.range.end.seconds, words: timedWords(speech.text, start: speech.range.start.seconds, end: speech.range.end.seconds))
            } else if let dictation = result as? DictationTranscriber.Result {
                try assembler.append(text: String(dictation.text.characters), start: dictation.range.start.seconds, end: dictation.range.end.seconds, words: timedWords(dictation.text, start: dictation.range.start.seconds, end: dictation.range.end.seconds))
            } else { throw MeetingError.message("Apple yerel transkript sonucu okunamadı.") }
        }
        try Task.checkCancellation()
        return assembler.segments
    }
}

/// A pure representation of native attributed-text runs. Missing times are
/// retained so punctuation/spacing cannot accidentally discard every word time.
struct TimedSpeechTextFragment {
    var text: String
    var start: Double? = nil
    var end: Double? = nil
}

enum TimedSpeechText {
    static func words(from fragments: [TimedSpeechTextFragment], start: Double, end: Double) -> [TranscriptWord]? {
        guard start.isFinite, end.isFinite, start >= 0, end > start else { return nil }
        let nonSpeech = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)
        var words: [TranscriptWord] = []
        var prefix = ""
        for fragment in fragments where !fragment.text.isEmpty {
            switch (fragment.start, fragment.end) {
            case let (.some(lower), .some(upper)):
                guard lower.isFinite, upper.isFinite, lower >= start, upper <= end, upper >= lower else { return nil }
                if let previous = words.last {
                    guard lower >= previous.start, upper >= previous.end else { return nil }
                }
                words.append(TranscriptWord(text: prefix + fragment.text, start: lower, end: upper))
                prefix = ""
            case (.none, .none):
                // These characters are formatting attached to a neighboring
                // timed word. Untimed lexical text must never receive guessed times.
                guard fragment.text.unicodeScalars.allSatisfy({ nonSpeech.contains($0) }) else { return nil }
                if words.isEmpty { prefix += fragment.text }
                else { words[words.count - 1].text += fragment.text }
            default:
                return nil
            }
        }
        guard !words.isEmpty, prefix.isEmpty,
              words.map(\.text).joined() == fragments.map(\.text).joined() else { return nil }
        return words
    }
}

/// Keeps finalized utterances and timestamps without inventing speaker identities.
struct LocalTranscriptAssembler {
    let duration: Double
    private(set) var segments: [TranscriptSegment] = []

    mutating func append(text: String, start: Double, end: Double, words: [TranscriptWord]? = nil) throws {
        let clean = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty else { return }
        guard start.isFinite, end.isFinite, start >= 0, end >= start,
              start <= duration + 0.1, end <= duration + 2 else {
            throw MeetingError.message("Yerel transkriptin zaman bilgileri geçersiz olduğu için sonuç kaydedilmedi.")
        }
        let boundedEnd = min(end, duration)
        let boundedStart = min(start, duration)
        guard !segments.contains(where: { $0.start == boundedStart && $0.end == boundedEnd && $0.text == clean }) else { return }
        segments.append(TranscriptSegment(id: "local-\(segments.count + 1)", speaker: "Konuşma", start: boundedStart, end: boundedEnd, text: clean, words: words))
    }

    static func requireEntireFileRead(lastSampleSeconds: Double, duration: Double) throws {
        guard lastSampleSeconds.isFinite, lastSampleSeconds >= max(0, duration - 0.1) else {
            throw MeetingError.message("Ses dosyasının tamamı işlenemedi; eksik transkript kaydedilmedi. Kaydınız korunuyor, yeniden deneyebilirsiniz.")
        }
    }
}
