import Foundation
import XCTest
@testable import MeetingDesk

final class WhisperWorkerLifecycleTests: XCTestCase {
    private func temporaryFolder() throws -> URL {
        let root = FileManager.default.temporaryDirectory.resolvingSymlinksInPath().appendingPathComponent("WhisperLifecycleTest-\(UUID())")
        try WhisperPrivateFiles.makeDirectory(root, existingAllowed: false)
        try WhisperPrivateFiles.makeDirectory(root.appendingPathComponent("jobs"), existingAllowed: false)
        return root
    }
    private var configuration: VerifiedWhisperConfiguration {
        .init(modelDirectory: URL(fileURLWithPath: "/synthetic-model"), modelIdentifier: "synthetic", modelRevision: "pinned",
            implementationVersion: "synthetic-v1", decodingStrategyID: "window-auto-20s-v1", acceptedLanguageModes: [.turkishEnglish])
    }

    func testPrivateDirectoryAcceptsExplicitAndInferredDirectoryURLForms() throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        // An inferred URL created before its directory exists must remain valid
        // when it is validated again after creation.
        try WhisperPrivateFiles.makeDirectory(root, existingAllowed: true)
        let explicit = root.appendingPathComponent("explicit", isDirectory: true)
        try WhisperPrivateFiles.makeDirectory(explicit, existingAllowed: false)
        try WhisperPrivateFiles.makeDirectory(URL(fileURLWithPath: explicit.path, isDirectory: false), existingAllowed: true)
    }

    func testPrivateDirectoryStillRejectsSymlinkComponents() throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let actual = root.appendingPathComponent("actual", isDirectory: true)
        try WhisperPrivateFiles.makeDirectory(actual, existingAllowed: false)
        let link = root.appendingPathComponent("link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: actual)
        XCTAssertThrowsError(try WhisperPrivateFiles.makeDirectory(link.appendingPathComponent("child", isDirectory: true), existingAllowed: false))
        XCTAssertFalse(FileManager.default.fileExists(atPath: actual.appendingPathComponent("child").path))
    }

    func testAdapterReusesOneInjectedWorkerForTwoTracksThenClosesIt() async throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let preparation = FixturePCM(root: root), worker = FixtureWorker()
        let adapter = WhisperTranscriptionAdapter(configuration: configuration, preparation: preparation, worker: worker)
        for _ in 0..<2 {
            let result = try await adapter.transcribe(audioURL: root.appendingPathComponent("synthetic-input"), language: "Türkçe + English", allowNoSpeech: true)
            XCTAssertEqual(result.map(\.text), ["Türkçe with English."])
        }
        try await adapter.finishAndClose()
        let counts = await worker.counts(); XCTAssertEqual(counts.requests, 2); XCTAssertEqual(counts.finishes, 1); XCTAssertEqual(counts.cancels, 0)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path).isEmpty)
    }

    func testPartialWorkerResultClosesSessionAndRemovesOnlySyntheticPCM() async throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let untouched = root.appendingPathComponent("old-transcript.json"); try Data("old".utf8).write(to: untouched)
        let worker = FixtureWorker(partial: true)
        let adapter = WhisperTranscriptionAdapter(configuration: configuration, preparation: FixturePCM(root: root), worker: worker)
        do { _ = try await adapter.transcribe(audioURL: untouched, language: "Türkçe + English", allowNoSpeech: true); XCTFail("Partial audio must fail") }
        catch { XCTAssertTrue(error is WhisperAdapterFailure) }
        let counts = await worker.counts(); XCTAssertEqual(counts.cancels, 1)
        XCTAssertEqual(try Data(contentsOf: untouched), Data("old".utf8))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path).isEmpty)
    }

    func testCancellationWaitsForOwnedSessionBeforeRemovingPCM() async throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        let worker = FixtureWorker(wait: true)
        let adapter = WhisperTranscriptionAdapter(configuration: configuration, preparation: FixturePCM(root: root), worker: worker)
        let task = Task { try await adapter.transcribe(audioURL: root.appendingPathComponent("synthetic-input"), language: "Türkçe + English", allowNoSpeech: true) }
        for _ in 0..<200 { if await worker.counts().requests > 0 { break }; try await Task.sleep(for: .milliseconds(5)) }
        task.cancel()
        do { _ = try await task.value; XCTFail("Cancelled output must not succeed") } catch { XCTAssertTrue(error is CancellationError) }
        let counts = await worker.counts(); XCTAssertGreaterThanOrEqual(counts.cancels, 1)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("jobs").path).isEmpty)
    }

    func testOwnedProcessDrainsPipesAndServesTwoSequentialRequestsBeforeFinish() async throws {
        let root = try temporaryFolder(); defer { try? FileManager.default.removeItem(at: root) }
        // A synthetic executable replacing bundled Python. No Python packages,
        // model files, GPU work, network or user recordings are involved.
        let executable = root.appendingPathComponent("mock-runtime")
        let script = """
        #!/bin/sh
        session="$5"
        /usr/bin/printf 'started\\n' >> "$session/launches"
        while :; do
          if [ -f "$session/cancel" ]; then /usr/bin/touch "$session/exited"; exit 0; fi
          for job in "$session"/jobs/*; do
            if [ -f "$job/request.json" ] && [ ! -f "$job/result.json" ]; then
              /bin/dd if=/dev/zero bs=65536 count=4 2>/dev/null
              /bin/dd if=/dev/zero bs=65536 count=4 1>&2 2>/dev/null
              /bin/cp "$job/mock-response.json" "$job/result.json.part"
              /bin/mv "$job/result.json.part" "$job/result.json"
            fi
          done
          if [ -f "$session/finish" ]; then /usr/bin/touch "$session/exited"; exit 0; fi
          /bin/sleep 0.02
        done
        """
        try Data(script.utf8).write(to: executable); try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let dummy = root.appendingPathComponent("worker.py"); try Data("# synthetic".utf8).write(to: dummy)
        let session = WhisperOwnedWorkerSession(launch: .init(pythonExecutable: executable, workerScript: dummy), sessionDirectory: root, modelDirectory: configuration.modelDirectory)
        do {
            for _ in 0..<2 {
                let identity = UUID(), sha = String(repeating: "a", count: 64)
                let job = root.appendingPathComponent("jobs").appendingPathComponent(identity.uuidString)
                try WhisperPrivateFiles.makeDirectory(job, existingAllowed: false)
                let req = WhisperWorkerRequest(schemaVersion: 1, requestID: identity, pcmPath: job.appendingPathComponent("audio.f32").path,
                    pcmSHA256: sha, resultPath: job.appendingPathComponent("result.json").path, sampleRate: 16_000, frameCount: 16_000,
                    fullTrackTimeOffset: 0, modelDirectory: configuration.modelDirectory.path, modelIdentifier: configuration.modelIdentifier,
                    modelRevision: configuration.modelRevision, decodingStrategyID: configuration.decodingStrategyID, languageMode: .turkishEnglish, allowNoSpeech: true)
                let response = WhisperWorkerReply(schemaVersion: 1, requestID: identity, backend: "mlx-whisper",
                    modelIdentifier: configuration.modelIdentifier, modelRevision: configuration.modelRevision,
                    implementationVersion: configuration.implementationVersion, decodingStrategyID: configuration.decodingStrategyID,
                    languageMode: .turkishEnglish, sampleRate: 16_000, sourceFrameCount: 16_000, processedFrameCount: 16_000,
                    pcmSHA256: sha, complete: true, segments: [])
                try JSONEncoder().encode(response).write(to: job.appendingPathComponent("mock-response.json"))
                let received = try await session.transcribe(req)
                XCTAssertEqual(received.requestID, identity)
            }
            try await session.finishAndClose()
        } catch { await session.cancelAndClose(); throw error }
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("launches"), encoding: .utf8), "started\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("exited").path))
    }
}

private struct FixturePCM: WhisperPCMPreparing {
    let root: URL
    func prepare(audioURL: URL, requestID: UUID) async throws -> PreparedWhisperPCM {
        let folder = root.appendingPathComponent("jobs").appendingPathComponent(requestID.uuidString)
        try WhisperPrivateFiles.makeDirectory(folder, existingAllowed: false)
        let file = folder.appendingPathComponent("audio.f32"); try Data(count: 16_000 * 4).write(to: file)
        return .init(requestID: requestID, file: file, frameCount: 16_000, originalDuration: 1, sampleRate: 16_000, sha256: try WhisperPrivateFiles.sha256(file))
    }
    func discard(_ prepared: PreparedWhisperPCM) async throws { try FileManager.default.removeItem(at: prepared.file.deletingLastPathComponent()) }
}

private actor FixtureWorker: WhisperWorkerSession {
    private let partial: Bool, wait: Bool
    private var requests = 0, finishes = 0, cancels = 0
    init(partial: Bool = false, wait: Bool = false) { self.partial = partial; self.wait = wait }
    func counts() -> (requests: Int, finishes: Int, cancels: Int) { (requests, finishes, cancels) }
    func transcribe(_ request: WhisperWorkerRequest) async throws -> WhisperWorkerReply {
        requests += 1
        if wait { try await Task.sleep(for: .seconds(30)) }
        return .init(schemaVersion: 1, requestID: request.requestID, backend: "mlx-whisper", modelIdentifier: request.modelIdentifier,
            modelRevision: request.modelRevision, implementationVersion: "synthetic-v1", decodingStrategyID: request.decodingStrategyID,
            languageMode: request.languageMode, sampleRate: request.sampleRate, sourceFrameCount: request.frameCount,
            processedFrameCount: partial ? request.frameCount - 1 : request.frameCount, pcmSHA256: request.pcmSHA256, complete: true,
            segments: [.init(text: "Türkçe with English.", start: 0, end: 1, words: nil)])
    }
    func finishAndClose() async throws { finishes += 1 }
    func cancelAndClose() async { cancels += 1 }
}
