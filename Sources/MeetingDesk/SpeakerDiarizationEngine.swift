import AVFoundation
import CoreML
import CryptoKit
import FluidAudio
import Foundation

/// Offline diarization and voice comparison share no state with the profile store.
/// Only explicitly enrolled profiles are persisted by the caller.
actor SpeakerDiarizationEngine {
    nonisolated static let modelID = "campplus-coreml-v2-192"
    typealias Progress = @Sendable (_ message: String, _ fraction: Double?) -> Void

    private let cacheRoot: URL
    private let progress: Progress?
    private var diarizer: OfflineDiarizerManager?
    private var encoder: CampPlusEmbedder?
    private var embeddingModelID: String?
    // Actors can reenter at await. Reject a second pipeline instead of sharing
    // SDK models between analysis, enrollment, and model preparation.
    private var operationInProgress = false

    init(cacheRoot: URL? = nil, progress: Progress? = nil) {
        self.cacheRoot = cacheRoot ?? MLModelConfigurationUtils.defaultModelsDirectory()
        self.progress = progress
    }

    func prepareModels() async throws {
        try beginOperation()
        defer { operationInProgress = false }
        try await ensureModels()
    }

    func analyze(audioURL: URL, source: SpeakerAudioSource) async throws -> SpeakerAnalysis {
        try beginOperation()
        defer { operationInProgress = false }
        try await ensureModels()
        guard let diarizer else { throw SpeakerEngineError.modelsUnavailable }
        return try await withAudio(audioURL) { input in
            let callback = self.progress
            let result = try await diarizer.process(audioSource: input, audioLoadingSeconds: 0) { done, total in
                callback?("Konuşmacılar ayrılıyor…", total > 0 ? Double(done) / Double(total) : nil)
            }
            try Task.checkCancellation()
            let turns = try Self.validatedTurns(result.segments, source: source, duration: input.duration)
            var samples: [SpeakerVoiceSample] = []
            for speakerID in Set(turns.map(\.speakerID)).sorted() {
                try Task.checkCancellation()
                do {
                    samples.append(try await self.makeSample(input: input, speakerID: speakerID, turns: turns))
                } catch SpeakerEngineError.insufficientCleanSpeech {
                    // The turn remains visible; short/overlapping speech receives no voice identity.
                    continue
                }
            }
            return SpeakerAnalysis(turns: turns, samples: samples)
        }
    }

    func sample(audioURL: URL, speakerID: String, turns: [SpeakerTurn]) async throws -> SpeakerVoiceSample {
        try beginOperation()
        defer { operationInProgress = false }
        try await ensureModels()
        return try await withAudio(audioURL) { input in
            try await self.makeSample(input: input, speakerID: speakerID, turns: turns)
        }
    }

    /// Enroll only the short excerpt that was played and confirmed in review.
    /// The caller verifies it is still one of the current overlap-free choices.
    func sampleExcerpt(audioURL: URL, sample: SpeakerReviewSample) async throws -> SpeakerVoiceSample {
        try Task.checkCancellation()
        guard audioURL.isFileURL else { throw SpeakerEngineError.invalidAudio }
        guard sample.start.isFinite, sample.end.isFinite, sample.start >= 0,
              sample.duration.isFinite, sample.duration >= 3.4, sample.duration <= 8.000_001,
              !sample.id.isEmpty, sample.id.count <= 512,
              !sample.speakerID.isEmpty, sample.speakerID.count <= 256,
              sample.id == sample.id.trimmingCharacters(in: .whitespacesAndNewlines),
              sample.speakerID == sample.speakerID.trimmingCharacters(in: .whitespacesAndNewlines),
              sample.speakerID.hasPrefix(sample.source.rawValue + ":"),
              sample.speakerID.count > sample.source.rawValue.count + 1,
              !sample.id.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !sample.speakerID.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw SpeakerEngineError.invalidTimeline
        }
        try beginOperation()
        defer { operationInProgress = false }
        try await ensureModels()
        return try await withAudio(audioURL, range: sample.start..<sample.end) { input in
            // Input time zero is the beginning of the heard excerpt. Existing
            // boundary trimming keeps every enrolled sample inside that excerpt.
            let turn = SpeakerTurn(speakerID: sample.speakerID, source: sample.source, start: 0, end: input.duration)
            return try await self.makeSample(input: input, speakerID: sample.speakerID, turns: [turn])
        }
    }

    private func beginOperation() throws {
        try Task.checkCancellation()
        guard !operationInProgress else { throw SpeakerEngineError.alreadyProcessing }
        operationInProgress = true
    }

    private func ensureModels() async throws {
        try Task.checkCancellation()
        let callback = progress
        if diarizer == nil {
            callback?("Konuşmacı modeli hazırlanıyor…", nil)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = .all
            let models = try await OfflineDiarizerModels.load(from: cacheRoot, configuration: configuration) { status in
                callback?("Konuşmacı modeli hazırlanıyor…", status.fractionCompleted)
            }
            try Task.checkCancellation()
            var config = OfflineDiarizerConfig()
            config.segmentation.batchSize = 8
            config.embedding.batchSize = 8
            // Keep concurrent speakers visible rather than trimming one away.
            config.postProcessing.exclusiveSegments = false
            let manager = OfflineDiarizerManager(config: config)
            manager.initialize(models: models)
            diarizer = manager
        }
        if encoder == nil {
            callback?("Ses tanıma modeli hazırlanıyor…", nil)
            try await ModelHub.download(.campPlus, to: cacheRoot) { status in
                callback?("Ses tanıma modeli hazırlanıyor…", status.fractionCompleted)
            }
            try Task.checkCancellation()
            let directory = cacheRoot.appendingPathComponent(Repo.campPlus.folderName, isDirectory: true)
            let fingerprint = try Self.modelFingerprint(in: directory)
            let models = try CampPlusModels.load(from: directory)
            try Task.checkCancellation()
            encoder = CampPlusEmbedder(models: models)
            embeddingModelID = Self.modelID + "-" + fingerprint
        }
        try Task.checkCancellation()
    }

    private func withAudio<Value>(_ url: URL, range: Range<Double>? = nil, operation: (SpeakerAudioInput) async throws -> Value) async throws -> Value {
        progress?("Konuşmacı analizi için ses hazırlanıyor…", nil)
        let input = try SpeakerAudioInput.make(url: url, range: range)
        do {
            let result = try await operation(input)
            try Task.checkCancellation()
            try input.cleanup()
            return result
        } catch {
            let failure = error
            do { try input.cleanup() }
            catch { throw SpeakerEngineError.temporaryCleanupFailed }
            throw failure
        }
    }

    private static func validatedTurns(_ segments: [TimedSpeakerSegment], source: SpeakerAudioSource, duration: Double) throws -> [SpeakerTurn] {
        var turns: [SpeakerTurn] = []
        for segment in segments {
            try Task.checkCancellation()
            let start = Double(segment.startTimeSeconds)
            let end = Double(segment.endTimeSeconds)
            let identifier = segment.speakerId.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, identifier.count <= 128,
                  start.isFinite, end.isFinite, start >= 0, end >= start,
                  start <= duration + 0.25, end <= duration + 0.25 else {
                throw SpeakerEngineError.invalidTimeline
            }
            let boundedStart = min(start, duration)
            let boundedEnd = min(end, duration)
            guard boundedEnd > boundedStart else { continue }
            turns.append(SpeakerTurn(speakerID: "\(source.rawValue):\(identifier)", source: source,
                                     start: boundedStart, end: boundedEnd))
        }
        return turns.sorted {
            if $0.start != $1.start { return $0.start < $1.start }
            if $0.end != $1.end { return $0.end < $1.end }
            return $0.speakerID < $1.speakerID
        }
    }

    private func makeSample(input: SpeakerAudioInput, speakerID: String, turns: [SpeakerTurn]) async throws -> SpeakerVoiceSample {
        guard let encoder, let embeddingModelID else { throw SpeakerEngineError.modelsUnavailable }
        let windows = try Self.cleanWindows(speakerID: speakerID, turns: turns, duration: input.duration)
        var centroid = [Double](repeating: 0, count: 192)
        var cleanDuration = 0.0
        for window in windows {
            try Task.checkCancellation()
            let audio = try input.samples(in: window)
            guard !audio.isEmpty else { continue }
            let squareSum = audio.reduce(0.0) { $0 + Double($1) * Double($1) }
            // Silent/invalid spans provide no identity evidence.
            guard squareSum.isFinite, squareSum / Double(audio.count) > 1e-8 else { continue }
            let embedding = try await encoder.embed(audio: audio)
            try Task.checkCancellation()
            let unit = try Self.normalized(embedding)
            let weight = Double(audio.count) / Double(SpeakerAudioInput.sampleRate)
            for index in centroid.indices { centroid[index] += Double(unit[index]) * weight }
            cleanDuration += weight
        }
        guard cleanDuration >= 3 else { throw SpeakerEngineError.insufficientCleanSpeech }
        let embedding = try Self.normalized(centroid.map(Float.init))
        return SpeakerVoiceSample(speakerID: speakerID, embedding: embedding,
                                  cleanDuration: cleanDuration, modelID: embeddingModelID)
    }

    /// The hub's `main` revision can change independently of the SDK. Profiles
    /// compare only when both loaded CAM++ artifacts have identical bytes.
    static func modelFingerprint(in directory: URL) throws -> String {
        var hasher = SHA256()
        for name in [ModelNames.CampPlus.preprocessorFile, ModelNames.CampPlus.modelFile].sorted() {
            let artifact = directory.appendingPathComponent(name, isDirectory: true)
            let rootValues = try artifact.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
                  let enumerator = FileManager.default.enumerator(at: artifact,
                    includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey], options: [.skipsHiddenFiles]) else {
                throw SpeakerEngineError.modelsUnavailable
            }
            var files: [URL] = []
            for case let file as URL in enumerator {
                let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                guard values.isSymbolicLink != true else { throw SpeakerEngineError.modelsUnavailable }
                if values.isRegularFile == true { files.append(file) }
            }
            guard !files.isEmpty else { throw SpeakerEngineError.modelsUnavailable }
            for file in files.sorted(by: { $0.path < $1.path }) {
                try Task.checkCancellation()
                let relative = String(file.path.dropFirst(directory.path.count + 1))
                let nameBytes = Data(relative.utf8)
                var nameCount = UInt64(nameBytes.count).bigEndian
                withUnsafeBytes(of: &nameCount) { hasher.update(bufferPointer: $0) }
                hasher.update(data: nameBytes)
                let handle = try FileHandle(forReadingFrom: file)
                defer { try? handle.close() }
                var size = try handle.seekToEnd().bigEndian
                withUnsafeBytes(of: &size) { hasher.update(bufferPointer: $0) }
                try handle.seek(toOffset: 0)
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty {
                    try Task.checkCancellation()
                    hasher.update(data: bytes)
                }
            }
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Select only the requested source and remove every other speaker's overlapping
    /// interval, with a boundary margin. Bounds also apply to manually supplied turns.
    static func cleanWindows(speakerID: String, turns: [SpeakerTurn], duration: Double) throws -> [Range<Double>] {
        guard duration.isFinite, duration > 0, !speakerID.isEmpty else { throw SpeakerEngineError.invalidTimeline }
        let targetSources = Set(turns.filter { $0.speakerID == speakerID }.map(\.source))
        guard targetSources.count == 1, let source = targetSources.first else {
            throw SpeakerEngineError.insufficientCleanSpeech
        }
        let relevant = turns.filter { $0.source == source }
        guard relevant.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 0.25 }) else {
            throw SpeakerEngineError.invalidTimeline
        }
        let margin = 0.15
        let targets = merged(relevant.filter { $0.speakerID == speakerID }.compactMap { turn -> Range<Double>? in
            let start = min(duration, turn.start + margin)
            let end = max(0, min(duration, turn.end) - margin)
            return end > start ? start..<end : nil
        })
        let blockers = merged(relevant.filter { $0.speakerID != speakerID }.compactMap { turn -> Range<Double>? in
            let start = min(duration, max(0, turn.start - margin))
            let end = min(duration, turn.end + margin)
            return end > start ? start..<end : nil
        })
        var clean: [Range<Double>] = []
        for target in targets {
            try Task.checkCancellation()
            var cursor = target.lowerBound
            for blocked in blockers where blocked.upperBound > cursor && blocked.lowerBound < target.upperBound {
                if blocked.lowerBound > cursor { clean.append(cursor..<min(blocked.lowerBound, target.upperBound)) }
                cursor = max(cursor, blocked.upperBound)
                if cursor >= target.upperBound { break }
            }
            if cursor < target.upperBound { clean.append(cursor..<target.upperBound) }
        }
        clean = clean.filter { $0.upperBound - $0.lowerBound >= 1.5 }.sorted {
            let first = $0.upperBound - $0.lowerBound
            let second = $1.upperBound - $1.lowerBound
            return first == second ? $0.lowerBound < $1.lowerBound : first > second
        }
        var selected: [Range<Double>] = []
        var remaining = 20.0
        for interval in clean {
            var cursor = interval.lowerBound
            while cursor + 1.5 <= interval.upperBound, remaining >= 1.5, selected.count < 12 {
                let count = min(6, min(remaining, interval.upperBound - cursor))
                selected.append(cursor..<(cursor + count))
                cursor += count
                remaining -= count
            }
            if remaining < 1.5 || selected.count == 12 { break }
        }
        guard selected.reduce(0, { $0 + $1.upperBound - $1.lowerBound }) >= 3 else {
            throw SpeakerEngineError.insufficientCleanSpeech
        }
        return selected
    }

    private static func merged(_ intervals: [Range<Double>]) -> [Range<Double>] {
        let sorted = intervals.sorted { $0.lowerBound < $1.lowerBound }
        var result: [Range<Double>] = []
        for interval in sorted {
            if let previous = result.last, interval.lowerBound <= previous.upperBound {
                result[result.count - 1] = previous.lowerBound..<max(previous.upperBound, interval.upperBound)
            } else { result.append(interval) }
        }
        return result
    }

    private static func normalized(_ values: [Float]) throws -> [Float] {
        guard values.count == 192, values.allSatisfy(\.isFinite) else { throw SpeakerEngineError.invalidEmbedding }
        let norm = sqrt(values.reduce(0.0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { throw SpeakerEngineError.invalidEmbedding }
        return values.map { Float(Double($0) / norm) }
    }
}

enum SpeakerEngineError: LocalizedError {
    case alreadyProcessing, modelsUnavailable, invalidTimeline, invalidEmbedding
    case insufficientCleanSpeech, invalidAudio, temporaryCleanupFailed

    var errorDescription: String? {
        switch self {
        case .alreadyProcessing: return "Başka bir konuşmacı analizi sürüyor. İşlem tamamlandıktan sonra yeniden deneyin."
        case .modelsUnavailable: return "Konuşmacı modelleri henüz hazır değil."
        case .invalidTimeline: return "Konuşmacı zamanları doğrulanamadı. Önceki konuşmacı bilgileri korundu."
        case .invalidEmbedding: return "Ses örneği doğrulanamadı; kişi tanıma için kullanılmadı."
        case .insufficientCleanSpeech: return "Bu sesi hatırlamak için en az 3 saniye net, başka konuşmacıyla çakışmayan konuşma gerekiyor."
        case .invalidAudio: return "Konuşmacı analizi için sesin tamamı okunamadı veya ses biçimi geçersiz."
        case .temporaryCleanupFailed: return "Konuşmacı analizi için hazırlanan geçici ses dosyası temizlenemedi."
        }
    }
}

/// Cancellable conversion into a private, short-lived 16 kHz mono mapping keeps
/// long meetings off the heap. No audio or embedding is written to the model cache.
struct SpeakerAudioInput: AudioSampleSource {
    static let sampleRate = 16_000
    let bytes: Data
    let folder: URL
    var sampleCount: Int { bytes.count / MemoryLayout<Float>.stride }
    var duration: Double { Double(sampleCount) / Double(Self.sampleRate) }

    static func make(url: URL, range: Range<Double>? = nil) throws -> SpeakerAudioInput {
        try Task.checkCancellation()
        guard url.isFileURL else { throw SpeakerEngineError.invalidAudio }
        let input = try AVAudioFile(forReading: url)
        let format = input.processingFormat
        guard input.length > 0, format.sampleRate.isFinite, format.sampleRate > 0,
              format.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Double(sampleRate), channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: format, to: target),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_384),
              let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 8192) else {
            throw SpeakerEngineError.invalidAudio
        }
        let firstFrame: AVAudioFramePosition
        let lastFrame: AVAudioFramePosition
        if let range {
            let fileDuration = Double(input.length) / format.sampleRate
            guard range.lowerBound.isFinite, range.upperBound.isFinite,
                  range.lowerBound >= 0, range.upperBound > range.lowerBound,
                  range.upperBound <= fileDuration else { throw SpeakerEngineError.invalidTimeline }
            let first = (range.lowerBound * format.sampleRate).rounded(.up)
            let last = (range.upperBound * format.sampleRate).rounded(.down)
            guard first.isFinite, last.isFinite, first >= 0, last > first,
                  first < Double(Int64.max), last < Double(Int64.max) else { throw SpeakerEngineError.invalidTimeline }
            firstFrame = AVAudioFramePosition(first)
            lastFrame = min(input.length, AVAudioFramePosition(last))
            guard lastFrame > firstFrame else { throw SpeakerEngineError.invalidTimeline }
        } else {
            firstFrame = 0
            lastFrame = input.length
        }
        // Seeking a compressed file may decode a containing packet internally;
        // it does not read/convert the preceding meeting into an intermediate.
        input.framePosition = firstFrame
        let expectedDuration = Double(lastFrame - firstFrame) / format.sampleRate
        let outputLimit: Int64?
        if range != nil {
            let count = (expectedDuration * Double(sampleRate)).rounded(.down)
            guard count.isFinite, count > 0, count < Double(Int64.max) else { throw SpeakerEngineError.invalidTimeline }
            outputLimit = Int64(count)
        } else { outputLimit = nil }
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-SpeakerAudio-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let rawURL = folder.appendingPathComponent("audio.f32")
        var succeeded = false
        defer { if !succeeded { try? FileManager.default.removeItem(at: folder) } }
        guard FileManager.default.createFile(atPath: rawURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw SpeakerEngineError.invalidAudio
        }
        let handle = try FileHandle(forWritingTo: rawURL)
        defer { try? handle.close() }
        var readError: Error?
        var frames: Int64 = 0
        var stalled = 0
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var conversionError: NSError?
            let status = converter.convert(to: output, error: &conversionError) { packets, state in
                do {
                    try Task.checkCancellation()
                    let remaining = lastFrame - input.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    let count = AVAudioFrameCount(min(Int64(min(packets, inputBuffer.frameCapacity)), remaining))
                    guard count > 0 else { state.pointee = .endOfStream; return nil }
                    try input.read(into: inputBuffer, frameCount: count)
                    guard inputBuffer.frameLength > 0 else { state.pointee = .endOfStream; return nil }
                    state.pointee = .haveData
                    return inputBuffer
                } catch {
                    readError = error
                    state.pointee = .endOfStream
                    return nil
                }
            }
            if let readError { throw readError }
            if let conversionError { throw conversionError }
            let available = outputLimit.map { max(0, $0 - frames) } ?? Int64(output.frameLength)
            let count = Int(min(Int64(output.frameLength), available))
            if count > 0 {
                guard let pointer = output.floatChannelData?[0] else { throw SpeakerEngineError.invalidAudio }
                for index in 0..<count {
                    guard pointer[index].isFinite else { throw SpeakerEngineError.invalidAudio }
                    pointer[index] = max(-1, min(1, pointer[index]))
                }
                try handle.write(contentsOf: Data(bytes: pointer, count: count * MemoryLayout<Float>.stride))
                frames += Int64(count)
                stalled = 0
            } else { stalled += 1 }
            if status == .endOfStream { break }
            guard status != .error, stalled < 16 else { throw SpeakerEngineError.invalidAudio }
        }
        try Task.checkCancellation()
        if range != nil, input.framePosition < lastFrame { throw SpeakerEngineError.invalidAudio }
        guard frames > 0, Double(frames) / Double(sampleRate) >= expectedDuration - 0.25 else {
            throw SpeakerEngineError.invalidAudio
        }
        try handle.synchronize()
        try handle.close()
        let data = try Data(contentsOf: rawURL, options: [.mappedIfSafe])
        guard data.count % MemoryLayout<Float>.stride == 0, Int64(data.count / MemoryLayout<Float>.stride) == frames else {
            throw SpeakerEngineError.invalidAudio
        }
        succeeded = true
        return SpeakerAudioInput(bytes: data, folder: folder)
    }

    func copySamples(into destination: UnsafeMutablePointer<Float>, offset: Int, count: Int) throws {
        try Task.checkCancellation()
        guard offset >= 0, count >= 0, count <= Int.max / MemoryLayout<Float>.stride else {
            throw SpeakerEngineError.invalidAudio
        }
        guard count > 0 else { return }
        // FluidAudio's embedding stage requests an entire fixed-size model
        // window even at EOF. Its built-in sources copy only available samples
        // into a zeroed caller buffer. Preserve that tail-window contract while
        // keeping sampleCount/duration equal to the complete original source.
        memset(destination, 0, count * MemoryLayout<Float>.stride)
        guard offset < sampleCount else { return }
        let available = min(count, sampleCount - offset)
        bytes.withUnsafeBytes { buffer in
            if let base = buffer.baseAddress {
                memcpy(destination, base.advanced(by: offset * MemoryLayout<Float>.stride), available * MemoryLayout<Float>.stride)
            }
        }
    }

    func samples(in interval: Range<Double>) throws -> [Float] {
        guard interval.lowerBound.isFinite, interval.upperBound.isFinite,
              interval.lowerBound >= 0, interval.upperBound > interval.lowerBound,
              interval.upperBound <= duration else { throw SpeakerEngineError.invalidTimeline }
        let first = min(sampleCount, Int((interval.lowerBound * Double(Self.sampleRate)).rounded(.up)))
        let last = min(sampleCount, Int((interval.upperBound * Double(Self.sampleRate)).rounded(.down)))
        guard last > first else { return [] }
        var result = [Float](repeating: 0, count: last - first)
        try result.withUnsafeMutableBufferPointer { pointer in
            if let base = pointer.baseAddress { try copySamples(into: base, offset: first, count: last - first) }
        }
        return result
    }

    func cleanup() throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
