import AVFoundation
import Foundation

/// Creates disposable microphone-only ASR/listening input without changing a saved track.
enum MicrophoneAudioPreparation {
    static func withPreparedAudio<Value>(
        input: URL, gain: Double, temporaryRoot: URL = FileManager.default.temporaryDirectory,
        operation: @Sendable (URL) async throws -> Value
    ) async throws -> Value {
        try Task.checkCancellation()
        let boundedGain = RecorderMix.microphoneGain(gain)
        guard boundedGain > 1 else {
            let value = try await operation(input)
            try Task.checkCancellation()
            return value
        }
        let folder = temporaryRoot.appendingPathComponent("Toplanti-MikrofonIsleme-\(UUID())", isDirectory: true)
        let output = folder.appendingPathComponent("microphone.caf")
        // Conversion may cover hours of audio; it must not occupy the UI actor.
        let preparation = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try makePreview(input: input, output: output, gain: boundedGain)
            try Task.checkCancellation()
        }
        return try await withTaskCancellationHandler {
            do {
                // Always await preparation's exit before cleanup, so its writer can
                // never recreate a temporary file after cancellation removes it.
                try await preparation.value
                try Task.checkCancellation()
                let value = try await operation(output)
                try Task.checkCancellation()
                try removeTemporaryFolder(folder)
                return value
            } catch {
                let operationError = error
                do { try removeTemporaryFolder(folder) }
                catch {
                    throw MeetingError.message("Geçici mikrofon dosyası silinemedi: \(folder.path). \(error.localizedDescription) Önceki işlem: \(operationError.localizedDescription)")
                }
                throw operationError
            }
        } onCancel: {
            preparation.cancel()
        }
    }

    /// Float32 chunks preserve leading silence, sample rate, and total frame count.
    /// Existing output paths are rejected so no source or other file is overwritten.
    static func makePreview(input: URL, output: URL, gain: Double) throws {
        try Task.checkCancellation()
        guard input.isFileURL, output.isFileURL,
              input.standardizedFileURL.resolvingSymlinksInPath() != output.standardizedFileURL.resolvingSymlinksInPath(),
              !FileManager.default.fileExists(atPath: output.path) else {
            throw MeetingError.message("Geçici mikrofon dosyası için boş ve farklı bir dosya yolu gerekiyor. Özgün kayıt değiştirilmedi.")
        }
        var completed = false
        defer { if !completed { try? FileManager.default.removeItem(at: output) } }
        let inputFile = try AVAudioFile(forReading: input, commonFormat: .pcmFormatFloat32, interleaved: false)
        let format = inputFile.processingFormat
        let expectedFrames = inputFile.length
        guard expectedFrames > 0, format.sampleRate.isFinite, format.sampleRate > 0 else {
            throw MeetingError.message("Mikrofon kaydı boş veya ses süresi okunamıyor.")
        }
        try Task.checkCancellation()
        // Keep the writer in this scope so it closes before ASR opens the CAF.
        do {
            let outputFile = try AVAudioFile(forWriting: output, settings: format.settings, commonFormat: .pcmFormatFloat32, interleaved: false)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096) else {
                throw MeetingError.message("Mikrofon sesi hazırlanamadı.")
            }
            var writtenFrames: AVAudioFramePosition = 0
            let boundedGain = RecorderMix.microphoneGain(gain)
            while inputFile.framePosition < expectedFrames {
                try Task.checkCancellation()
                try inputFile.read(into: buffer)
                guard buffer.frameLength > 0, let channels = buffer.floatChannelData else {
                    throw MeetingError.message("Mikrofon kaydının tamamı okunamadı. Eksik ses transkript için kullanılmadı.")
                }
                for channel in 0..<Int(format.channelCount) {
                    try Task.checkCancellation()
                    for frame in 0..<Int(buffer.frameLength) {
                        channels[channel][frame] = RecorderMix.sample(system: 0, microphone: channels[channel][frame], microphoneGain: boundedGain)
                    }
                }
                try Task.checkCancellation()
                try outputFile.write(from: buffer)
                writtenFrames += AVAudioFramePosition(buffer.frameLength)
            }
            guard writtenFrames == expectedFrames else {
                throw MeetingError.message("Mikrofon kaydının tamamı hazırlanamadı. Eksik ses transkript için kullanılmadı.")
            }
        }
        try Task.checkCancellation()
        completed = true
    }

    private static func removeTemporaryFolder(_ folder: URL) throws {
        if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
    }
}
