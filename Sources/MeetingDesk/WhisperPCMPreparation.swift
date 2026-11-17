import AVFoundation
import CryptoKit
import Darwin
import Foundation

/// Complete-track PCM conversion matching the accepted native trial: arithmetic
/// channel mean first, then mono AVAudioConverter resampling. Gain is already
/// applied by ChannelTranscriptionService and must not be applied here again.
struct WhisperPCMPreparation: WhisperPCMPreparing {
    let sessionDirectory: URL

    func prepare(audioURL: URL, requestID: UUID) async throws -> PreparedWhisperPCM {
        let folder = sessionDirectory.appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(requestID.uuidString, isDirectory: true)
        let writer = Task.detached(priority: .utility) {
            do {
                try Task.checkCancellation()
                try WhisperPrivateFiles.makeDirectory(folder, existingAllowed: false)
                return try Self.convert(inputURL: audioURL, outputURL: folder.appendingPathComponent("audio.f32"), requestID: requestID)
            } catch {
                // convert closes its writer before this cleanup is reached.
                if FileManager.default.fileExists(atPath: folder.path) { try FileManager.default.removeItem(at: folder) }
                throw error
            }
        }
        return try await withTaskCancellationHandler {
            let value = try await writer.value
            do { try Task.checkCancellation(); return value }
            catch { try await discard(value); throw error }
        } onCancel: { writer.cancel() }
    }

    func discard(_ prepared: PreparedWhisperPCM) async throws {
        let expected = sessionDirectory.appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(prepared.requestID.uuidString, isDirectory: true)
        guard prepared.file.deletingLastPathComponent() == expected else { throw WhisperAdapterFailure.invalidPCM }
        if FileManager.default.fileExists(atPath: expected.path) { try FileManager.default.removeItem(at: expected) }
    }

    static func convert(inputURL: URL, outputURL: URL, requestID: UUID) throws -> PreparedWhisperPCM {
        try Task.checkCancellation()
        let sourceAttributes = try FileManager.default.attributesOfItem(atPath: inputURL.path)
        guard inputURL.isFileURL, outputURL.isFileURL,
              sourceAttributes[.type] as? FileAttributeType == .typeRegular,
              inputURL.standardizedFileURL.resolvingSymlinksInPath() != outputURL.standardizedFileURL.resolvingSymlinksInPath() else {
            throw WhisperAdapterFailure.invalidPCM
        }
        let sourceDigest = try WhisperPrivateFiles.sha256(inputURL)
        let input = try AVAudioFile(forReading: inputURL, commonFormat: .pcmFormatFloat32, interleaved: false)
        let sourceFrames = input.length, sourceRate = input.processingFormat.sampleRate
        guard sourceFrames > 0, sourceRate.isFinite, sourceRate > 0,
              let monoFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sourceRate, channels: 1, interleaved: false),
              let targetFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: monoFormat, to: targetFormat),
              let sourceBuffer = AVAudioPCMBuffer(pcmFormat: input.processingFormat, frameCapacity: 32_768),
              let monoBuffer = AVAudioPCMBuffer(pcmFormat: monoFormat, frameCapacity: 32_768),
              let output = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: 16_384) else { throw WhisperAdapterFailure.invalidPCM }
        let descriptor = Darwin.open(outputURL.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw WhisperAdapterFailure.invalidPCM }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close() }
        var frames: Int64 = 0, stalls = 0
        var inputFailure: Error?
        while true {
            try Task.checkCancellation()
            output.frameLength = 0
            var failure: NSError?
            let status = converter.convert(to: output, error: &failure) { requested, state in
                do {
                    try Task.checkCancellation()
                    let remaining = sourceFrames - input.framePosition
                    guard remaining > 0 else { state.pointee = .endOfStream; return nil }
                    let count = AVAudioFrameCount(min(remaining, AVAudioFramePosition(min(32_768, max(1, requested)))))
                    sourceBuffer.frameLength = 0
                    try input.read(into: sourceBuffer, frameCount: count)
                    guard sourceBuffer.frameLength > 0, let channels = sourceBuffer.floatChannelData,
                          let mono = monoBuffer.floatChannelData?[0] else { throw WhisperAdapterFailure.invalidPCM }
                    let channelCount = Int(sourceBuffer.format.channelCount)
                    guard channelCount > 0 else { throw WhisperAdapterFailure.invalidPCM }
                    monoBuffer.frameLength = sourceBuffer.frameLength
                    for frame in 0..<Int(sourceBuffer.frameLength) {
                        var sum = 0.0
                        for channel in 0..<channelCount {
                            let sample = channels[channel][frame]
                            guard sample.isFinite else { throw WhisperAdapterFailure.invalidPCM }
                            sum += Double(sample)
                        }
                        mono[frame] = Float(sum / Double(channelCount))
                    }
                    state.pointee = .haveData
                    return monoBuffer
                } catch { inputFailure = error; state.pointee = .endOfStream; return nil }
            }
            if let inputFailure { throw inputFailure }
            guard failure == nil, status != .error else { throw WhisperAdapterFailure.invalidPCM }
            if output.frameLength > 0 {
                guard let samples = output.floatChannelData?[0] else { throw WhisperAdapterFailure.invalidPCM }
                for frame in 0..<Int(output.frameLength) where !samples[frame].isFinite { throw WhisperAdapterFailure.invalidPCM }
                try writer.write(contentsOf: Data(bytes: samples, count: Int(output.frameLength) * MemoryLayout<Float>.size))
                frames += Int64(output.frameLength)
                stalls = 0
            } else { stalls += 1 }
            if status == .endOfStream { break }
            guard stalls < 16 else { throw WhisperAdapterFailure.invalidPCM }
        }
        try Task.checkCancellation()
        let duration = Double(sourceFrames) / sourceRate
        guard input.framePosition == sourceFrames, frames > 0,
              abs(Double(frames) / 16_000 - duration) <= 0.05 else { throw WhisperAdapterFailure.invalidPCM }
        try writer.synchronize(); try writer.close()
        guard try WhisperPrivateFiles.sha256(inputURL) == sourceDigest else { throw WhisperAdapterFailure.invalidPCM }
        return PreparedWhisperPCM(requestID: requestID, file: outputURL, frameCount: frames,
            originalDuration: duration, sampleRate: 16_000, sha256: try WhisperPrivateFiles.sha256(outputURL))
    }
}

enum WhisperPrivateFiles {
    static func makeDirectory(_ directory: URL, existingAllowed: Bool) throws {
        // Resolving a not-yet-existing leaf may leave its parent symlinks
        // unresolved. Inspect each existing component before creating anything.
        var componentURL = URL(fileURLWithPath: "/", isDirectory: true)
        for component in directory.standardizedFileURL.pathComponents.dropFirst() {
            componentURL.appendPathComponent(component, isDirectory: true)
            var information = stat()
            if lstat(componentURL.path, &information) == 0 {
                if information.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK) {
                    // Foundation may retain macOS's root-owned /var or /tmp
                    // spelling even after resolving a temporary-directory URL.
                    let systemTarget = ["/var": "/private/var", "/tmp": "/private/tmp"][componentURL.path]
                    guard information.st_uid == 0, let systemTarget,
                          let destination = try? FileManager.default.destinationOfSymbolicLink(atPath: componentURL.path),
                          destination == systemTarget || destination == String(systemTarget.dropFirst()) else {
                        throw WhisperAdapterFailure.invalidPCM
                    }
                }
            } else if errno != ENOENT { throw WhisperAdapterFailure.invalidPCM }
        }
        // URL equality also compares directory-form metadata, which may change
        // when resolving a new or newly-created directory. Compare canonical
        // paths instead; symlink components still resolve to a different path.
        guard directory.isFileURL, directory.standardizedFileURL.path == directory.standardizedFileURL.resolvingSymlinksInPath().path,
              existingAllowed || !FileManager.default.fileExists(atPath: directory.path) else { throw WhisperAdapterFailure.invalidPCM }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              (attributes[.ownerAccountID] as? NSNumber)?.uint32Value == geteuid(),
              ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o077 == 0 else { throw WhisperAdapterFailure.invalidPCM }
    }

    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            hash.update(data: data)
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
