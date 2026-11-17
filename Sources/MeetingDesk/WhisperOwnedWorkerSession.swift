import Darwin
import Foundation

struct WhisperWorkerLaunch: Sendable {
    /// Exact relocated application-owned paths, supplied by the runtime verifier.
    let pythonExecutable: URL
    let workerScript: URL
}

/// One child per complete transcription; the same loaded model serves both
/// sequential microphone/system requests. No system Python, daemon or listener.
actor WhisperOwnedWorkerSession: WhisperWorkerSession {
    private let launch: WhisperWorkerLaunch
    private let sessionDirectory: URL
    private let modelDirectory: URL
    private var process: Process?
    private var stdoutDrain: Task<Void, Never>?
    private var stderrDrain: Task<Void, Never>?
    private var closed = false
    private var busy = false

    init(launch: WhisperWorkerLaunch, sessionDirectory: URL, modelDirectory: URL) {
        self.launch = launch; self.sessionDirectory = sessionDirectory; self.modelDirectory = modelDirectory
    }

    func transcribe(_ request: WhisperWorkerRequest) async throws -> WhisperWorkerReply {
        guard !closed else { throw WhisperAdapterFailure.closedSession }
        guard !busy else { throw WhisperAdapterFailure.concurrentRequest }
        busy = true
        defer { busy = false }
        try Task.checkCancellation()
        let job = sessionDirectory.appendingPathComponent("jobs", isDirectory: true)
            .appendingPathComponent(request.requestID.uuidString, isDirectory: true)
        guard URL(fileURLWithPath: request.pcmPath).deletingLastPathComponent() == job,
              URL(fileURLWithPath: request.resultPath) == job.appendingPathComponent("result.json"),
              request.modelDirectory == modelDirectory.path else { throw WhisperAdapterFailure.invalidEnvelope }
        try startIfNeeded()
        try Self.writeJSON(request, to: job.appendingPathComponent("request.json"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(7_200))
        let errorURL = job.appendingPathComponent("error.json")
        let resultURL = job.appendingPathComponent("result.json")
        while true {
            try Task.checkCancellation()
            guard !closed else { throw CancellationError() }
            if FileManager.default.fileExists(atPath: errorURL.path) {
                let failure: WorkerError = try Self.readJSON(errorURL, limit: 65_536)
                guard failure.schemaVersion == 1, failure.requestID == request.requestID,
                      !failure.complete else { throw WhisperAdapterFailure.invalidEnvelope }
                if failure.errorCode == "no-speech" { throw WhisperAdapterFailure.noSpeech }
                if failure.errorCode == "cancelled" { throw CancellationError() }
                throw WhisperAdapterFailure.workerFailed
            }
            if FileManager.default.fileExists(atPath: resultURL.path) {
                let reply: WhisperWorkerReply = try Self.readJSON(resultURL, limit: 64 * 1_024 * 1_024)
                guard reply.requestID == request.requestID else { throw WhisperAdapterFailure.invalidEnvelope }
                return reply
            }
            guard process?.isRunning == true else { throw WhisperAdapterFailure.workerFailed }
            guard ContinuousClock.now < deadline else { throw WhisperAdapterFailure.workerDeadline }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    func finishAndClose() async throws {
        guard !closed else { return }
        guard !busy else { throw WhisperAdapterFailure.concurrentRequest }
        guard let process else { closed = true; return }
        try Self.sentinel(sessionDirectory.appendingPathComponent("finish"))
        if !(await waitForExit(process, seconds: 20)) {
            await cancelAndClose()
            throw WhisperAdapterFailure.workerDeadline
        }
        await drainPipes()
        closed = true
        guard process.terminationReason == .exit, process.terminationStatus == 0 else { throw WhisperAdapterFailure.workerFailed }
    }

    func cancelAndClose() async {
        closed = true
        guard let process else { return }
        try? Self.sentinel(sessionDirectory.appendingPathComponent("cancel"))
        // Cooperative GPU cancellation is checked between bounded 20s windows.
        if !(await waitForExit(process, seconds: 20)), process.isRunning {
            process.terminate()
            if !(await waitForExit(process, seconds: 2)), process.isRunning {
                // This is the exact Process instance launched here, never a scan.
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
                _ = await waitForExit(process, seconds: 5)
            }
        }
        await drainPipes()
    }

    private func startIfNeeded() throws {
        if process != nil { return }
        for url in [launch.pythonExecutable, launch.workerScript] {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard url.isFileURL, attributes[.type] as? FileAttributeType == .typeRegular else { throw WhisperAdapterFailure.runtimeUnavailable }
        }
        guard FileManager.default.isExecutableFile(atPath: launch.pythonExecutable.path) else { throw WhisperAdapterFailure.runtimeUnavailable }
        try WhisperPrivateFiles.makeDirectory(sessionDirectory, existingAllowed: true)
        let tmp = sessionDirectory.appendingPathComponent("tmp", isDirectory: true)
        try WhisperPrivateFiles.makeDirectory(tmp, existingAllowed: false)
        let child = Process(), stdout = Pipe(), stderr = Pipe()
        child.qualityOfService = .utility
        child.executableURL = launch.pythonExecutable
        child.arguments = ["-I", "-B", launch.workerScript.path, "--session-directory", sessionDirectory.path, "--model", modelDirectory.path]
        child.environment = ["PATH": "/usr/bin:/bin", "TMPDIR": tmp.path,
            "HF_HUB_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1", "TRANSFORMERS_OFFLINE": "1"]
        child.currentDirectoryURL = sessionDirectory
        child.standardInput = FileHandle.nullDevice
        child.standardOutput = stdout; child.standardError = stderr
        do { try child.run() }
        catch {
            try? stdout.fileHandleForReading.close(); try? stdout.fileHandleForWriting.close()
            try? stderr.fileHandleForReading.close(); try? stderr.fileHandleForWriting.close()
            throw WhisperAdapterFailure.runtimeUnavailable
        }
        process = child
        // Close the parent's writer ends so readers receive EOF after child exit.
        try? stdout.fileHandleForWriting.close(); try? stderr.fileHandleForWriting.close()
        stdoutDrain = Self.discardPipe(stdout.fileHandleForReading)
        stderrDrain = Self.discardPipe(stderr.fileHandleForReading)
    }

    private static func discardPipe(_ handle: FileHandle) -> Task<Void, Never> {
        Task.detached(priority: .utility) {
            defer { try? handle.close() }
            // Constant memory; process output is never retained or logged.
            while let data = try? handle.read(upToCount: 16_384), !data.isEmpty { }
        }
    }

    private func drainPipes() async {
        if let stdoutDrain { await stdoutDrain.value }
        if let stderrDrain { await stderrDrain.value }
        stdoutDrain = nil; stderrDrain = nil
    }

    private func waitForExit(_ child: Process, seconds: Int) async -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while child.isRunning && ContinuousClock.now < deadline {
            // Cleanup must continue even when the caller's task is cancelled.
            await Self.uncancelledPause()
        }
        return !child.isRunning
    }

    private static func uncancelledPause() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.05) { continuation.resume() }
        }
    }

    private struct WorkerError: Decodable { let schemaVersion: Int; let requestID: UUID?; let errorCode: String; let complete: Bool }
    private static func readJSON<Value: Decodable>(_ url: URL, limit: Int) throws -> Value {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = (attributes[.size] as? NSNumber)?.intValue, size > 0, size <= limit else { throw WhisperAdapterFailure.invalidEnvelope }
        let data = try Data(contentsOf: url, options: .mappedIfSafe)
        guard data.count == size, data.count <= limit else { throw WhisperAdapterFailure.invalidEnvelope }
        do { return try JSONDecoder().decode(Value.self, from: data) }
        catch { throw WhisperAdapterFailure.invalidEnvelope }
    }

    private static func writeJSON<Value: Encodable>(_ value: Value, to url: URL) throws {
        guard !FileManager.default.fileExists(atPath: url.path) else { throw WhisperAdapterFailure.invalidEnvelope }
        let data = try JSONEncoder().encode(value)
        let partial = url.appendingPathExtension("part")
        let descriptor = Darwin.open(partial.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw WhisperAdapterFailure.invalidEnvelope }
        let writer = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? writer.close(); try? FileManager.default.removeItem(at: partial) }
        try writer.write(contentsOf: data); try writer.synchronize(); try writer.close()
        try FileManager.default.moveItem(at: partial, to: url)
    }

    private static func sentinel(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { return }
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC | O_NOFOLLOW, mode_t(0o600))
        guard descriptor >= 0 else { throw WhisperAdapterFailure.workerFailed }
        Darwin.close(descriptor)
    }
}
