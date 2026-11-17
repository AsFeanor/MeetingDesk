import Foundation

// IPC1 contract shared with the bundled offline worker.
struct VerifiedWhisperConfiguration: Sendable {
    let modelDirectory: URL
    let modelIdentifier: String
    let modelRevision: String
    let implementationVersion: String
    let decodingStrategyID: String
    let acceptedLanguageModes: Set<WhisperLanguageMode>
}

struct PreparedWhisperPCM: Sendable {
    let requestID: UUID
    let file: URL
    let frameCount: Int64
    let originalDuration: Double
    let sampleRate: Int
    let sha256: String
    var duration: Double { Double(frameCount) / Double(sampleRate) }
}

protocol WhisperPCMPreparing: Sendable {
    /// Decode/resample the complete supplied track to raw little-endian float32
    /// 16kHz mono in a private operation folder. No gain, VAD trim or time shift.
    /// Must propagate cancellation, clean its own partial output on throw, and
    /// wait for its writer to exit before either return or error propagation.
    func prepare(audioURL: URL, requestID: UUID) async throws -> PreparedWhisperPCM
    /// Idempotent cleanup of this owned operation's PCM/result files only.
    func discard(_ prepared: PreparedWhisperPCM) async throws
}

struct WhisperWorkerRequest: Codable, Sendable {
    let schemaVersion: Int
    let requestID: UUID
    let pcmPath: String
    let pcmSHA256: String
    let resultPath: String
    let sampleRate: Int
    let frameCount: Int64
    let fullTrackTimeOffset: Double
    let modelDirectory: String
    let modelIdentifier: String
    let modelRevision: String
    let decodingStrategyID: String
    let languageMode: WhisperLanguageMode
    let allowNoSpeech: Bool
}

struct WhisperWorkerWord: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
}

struct WhisperWorkerSegment: Codable, Sendable {
    let text: String
    let start: Double
    let end: Double
    let words: [WhisperWorkerWord]?
    var wordTimingIssue: String? = nil
}

struct WhisperWorkerReply: Codable, Sendable {
    let schemaVersion: Int
    let requestID: UUID
    let backend: String
    let modelIdentifier: String
    let modelRevision: String
    let implementationVersion: String
    let decodingStrategyID: String
    let languageMode: WhisperLanguageMode
    let sampleRate: Int
    let sourceFrameCount: Int64
    let processedFrameCount: Int64
    let pcmSHA256: String
    let complete: Bool
    let segments: [WhisperWorkerSegment]
}

protocol WhisperWorkerSession: Sendable {
    /// One app-owned bundled child/model session; serialize both meeting tracks.
    /// Implement private atomic result-file IPC, bounded/drained pipes, request
    /// identity checks and offline-only local model loading. Never use PATH Python.
    func transcribe(_ request: WhisperWorkerRequest) async throws -> WhisperWorkerReply
    /// Idempotent. Return only after the owned child/reader/writer have exited;
    /// bounded escalation may target only this owned child. No killall/process scan.
    func cancelAndClose() async
    func finishAndClose() async throws
}

actor WhisperTranscriptionAdapter {
    private let configuration: VerifiedWhisperConfiguration
    private let preparation: any WhisperPCMPreparing
    private let worker: any WhisperWorkerSession
    private var closed = false
    private var transcribing = false
    private let ownedDirectory: URL?

    init(configuration: VerifiedWhisperConfiguration, preparation: any WhisperPCMPreparing,
         worker: any WhisperWorkerSession, ownedDirectory: URL? = nil) {
        self.configuration = configuration; self.preparation = preparation; self.worker = worker
        self.ownedDirectory = ownedDirectory
    }

    static func ownedSession(configuration: VerifiedWhisperConfiguration, launch: WhisperWorkerLaunch,
                             temporaryRoot: URL = FileManager.default.temporaryDirectory) throws -> WhisperTranscriptionAdapter {
        let root = temporaryRoot.standardizedFileURL.resolvingSymlinksInPath()
            .appendingPathComponent("Toplanti-Whisper-\(UUID())", isDirectory: true)
        try WhisperPrivateFiles.makeDirectory(root, existingAllowed: false)
        do {
            try WhisperPrivateFiles.makeDirectory(root.appendingPathComponent("jobs", isDirectory: true), existingAllowed: false)
            let worker = WhisperOwnedWorkerSession(launch: launch, sessionDirectory: root, modelDirectory: configuration.modelDirectory)
            return WhisperTranscriptionAdapter(configuration: configuration,
                preparation: WhisperPCMPreparation(sessionDirectory: root), worker: worker, ownedDirectory: root)
        } catch { try? FileManager.default.removeItem(at: root); throw error }
    }

    func transcribe(audioURL: URL, language: String, allowNoSpeech: Bool) async throws -> [TranscriptSegment] {
        guard !closed else { throw WhisperAdapterFailure.closedSession }
        guard !transcribing else { throw WhisperAdapterFailure.concurrentRequest }
        let languageMode = try WhisperLanguageMode(language: language)
        guard configuration.acceptedLanguageModes.contains(languageMode) else { throw WhisperAdapterFailure.unacceptedLanguageStrategy }
        try Task.checkCancellation()
        transcribing = true
        defer { transcribing = false }
        let requestID = UUID()
        var prepared: PreparedWhisperPCM?
        var discarded = false
        do {
            let pcm = try await preparation.prepare(audioURL: audioURL, requestID: requestID)
            prepared = pcm
            try Task.checkCancellation()
            try Self.validate(prepared: pcm, requestID: requestID)
            let request = WhisperWorkerRequest(schemaVersion: 1, requestID: requestID,
                pcmPath: pcm.file.path, pcmSHA256: pcm.sha256,
                resultPath: pcm.file.deletingLastPathComponent().appendingPathComponent("result.json").path,
                sampleRate: pcm.sampleRate, frameCount: pcm.frameCount,
                fullTrackTimeOffset: 0, modelDirectory: configuration.modelDirectory.path,
                modelIdentifier: configuration.modelIdentifier, modelRevision: configuration.modelRevision,
                decodingStrategyID: configuration.decodingStrategyID, languageMode: languageMode, allowNoSpeech: allowNoSpeech)
            let reply = try await withTaskCancellationHandler {
                try await worker.transcribe(request)
            } onCancel: {
                Task { await self.worker.cancelAndClose() }
            }
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            let result = try Self.segments(reply: reply, request: request, configuration: configuration, duration: pcm.duration)
            guard allowNoSpeech || !result.isEmpty else { throw WhisperAdapterFailure.noSpeech }
            try await preparation.discard(pcm)
            discarded = true
            try Task.checkCancellation()
            return result
        } catch {
            // Never remove PCM while an owned child may still be reading it.
            await worker.cancelAndClose(); closed = true
            if let prepared, !discarded {
                do { try await preparation.discard(prepared) }
                catch { throw WhisperAdapterFailure.cleanupFailed }
            }
            try cleanupOwnedDirectory()
            throw error
        }
    }

    func finishAndClose() async throws {
        guard !closed else { return }
        guard !transcribing else { throw WhisperAdapterFailure.concurrentRequest }
        do { try await worker.finishAndClose(); closed = true; try cleanupOwnedDirectory() }
        catch { await worker.cancelAndClose(); closed = true; try cleanupOwnedDirectory(); throw error }
    }

    func cancelAndClose() async {
        closed = true
        await worker.cancelAndClose()
        // Active preparation must await its writer and perform cleanup itself.
        if !transcribing { try? cleanupOwnedDirectory() }
    }

    private func cleanupOwnedDirectory() throws {
        guard let ownedDirectory, FileManager.default.fileExists(atPath: ownedDirectory.path) else { return }
        do { try FileManager.default.removeItem(at: ownedDirectory) }
        catch { throw WhisperAdapterFailure.cleanupFailed }
    }

    func provenance(language: String, mergedSegments: [TranscriptSegment]) throws -> TranscriptASRProvenance {
        let languageMode = try WhisperLanguageMode(language: language)
        return TranscriptASRProvenance(backend: .mlxWhisper, implementationVersion: configuration.implementationVersion,
            modelIdentifier: configuration.modelIdentifier, modelRevision: configuration.modelRevision,
            decodingStrategyID: configuration.decodingStrategyID, languageMode: languageMode.rawValue,
            wordTimings: "validated-per-segment-with-explicit-untimed-fallback",
            wordTimingSummary: TranscriptWordTimingSummary(segments: mergedSegments))
    }

    private static func validate(prepared: PreparedWhisperPCM, requestID: UUID) throws {
        guard prepared.requestID == requestID, prepared.file.isFileURL, prepared.sampleRate == 16_000,
              prepared.frameCount > 0, prepared.frameCount <= Int64.max / 4,
              prepared.originalDuration.isFinite, prepared.originalDuration > 0,
              prepared.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil,
              abs(prepared.duration - prepared.originalDuration) <= 0.1 else { throw WhisperAdapterFailure.invalidPCM }
        let attributes = try FileManager.default.attributesOfItem(atPath: prepared.file.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == prepared.frameCount * 4 else { throw WhisperAdapterFailure.invalidPCM }
    }

    static func segments(reply: WhisperWorkerReply, request: WhisperWorkerRequest,
                         configuration: VerifiedWhisperConfiguration, duration: Double) throws -> [TranscriptSegment] {
        guard duration.isFinite, duration > 0, request.sampleRate == 16_000, request.frameCount > 0,
              reply.schemaVersion == 1, reply.requestID == request.requestID, reply.backend == "mlx-whisper",
              reply.modelIdentifier == configuration.modelIdentifier, reply.modelRevision == configuration.modelRevision,
              reply.implementationVersion == configuration.implementationVersion,
              reply.decodingStrategyID == configuration.decodingStrategyID, reply.languageMode == request.languageMode,
              reply.sampleRate == request.sampleRate, reply.pcmSHA256 == request.pcmSHA256 else { throw WhisperAdapterFailure.invalidEnvelope }
        guard reply.complete, reply.sourceFrameCount == request.frameCount,
              reply.processedFrameCount == request.frameCount else { throw WhisperAdapterFailure.incompleteTrack }
        var result: [TranscriptSegment] = []
        var previousStart: Double = -1
        var duplicates = Set<String>()
        for segment in reply.segments {
            try Task.checkCancellation()
            let text = segment.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end >= segment.start, segment.start >= previousStart,
                  segment.end <= duration else { throw WhisperAdapterFailure.invalidSegment }
            previousStart = segment.start
            guard duplicates.insert("\(segment.start):\(segment.end):\(text)").inserted else { throw WhisperAdapterFailure.invalidSegment }
            // Real trial contains valid text/segment timing with missing or unsafe
            // word lists. Preserve that transcript and mark conservative handling.
            // Never expand/clip/interpolate timestamps to make the words fit.
            let timing = WhisperWordTimingPolicy.assess(segment, cleanText: text)
            result.append(TranscriptSegment(id: "whisper-\(result.count + 1)", speaker: "Konuşma",
                start: segment.start, end: segment.end, text: text,
                words: timing.words, wordTimingIssue: timing.issue))
        }
        return result
    }
}
