import AppKit
import Foundation

enum SummaryModelRuntimeError: LocalizedError {
    case missingRuntime, couldNotStart, needsUpdate

    var errorDescription: String? {
        switch self {
        case .missingRuntime: return "Özet altyapısı bu uygulama paketinde bulunamadı. Toplantı’yı güncelleyip yeniden dene."
        case .couldNotStart: return "Özet altyapısı başlatılamadı. Toplantı’yı kapatıp yeniden aç ve tekrar dene."
        case .needsUpdate: return "Özet altyapısını yenilemek için Toplantı’yı güncelle."
        }
    }
}

/// The application owns this bundled runtime and private loopback listener.
/// No external application, globally installed executable or login service is used.
/// Only a process started by this instance is stopped when the application exits.
final class SummaryModelRuntime: @unchecked Sendable {
    private let lock = NSLock()
    private var ownedProcess: Process?
    private var terminationObserver: NSObjectProtocol?

    static var isBundled: Bool { executableURL != nil }
    private static var executableURL: URL? {
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/LocalSummaryRuntime", isDirectory: true)
            .appendingPathComponent("ollama", isDirectory: false)
        return FileManager.default.isExecutableFile(atPath: executable.path) ? executable : nil
    }

    init() {
        terminationObserver = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification,
            object: nil, queue: nil) { [weak self] _ in self?.stopOwnedServer() }
    }

    deinit {
        if let terminationObserver { NotificationCenter.default.removeObserver(terminationObserver) }
        stopOwnedServer()
    }

    var isOwnedServerRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return ownedProcess?.isRunning == true
    }

    func startOwnedServer() throws {
        lock.lock(); defer { lock.unlock() }
        if ownedProcess?.isRunning == true { return }
        guard let executable = Self.executableURL else { throw SummaryModelRuntimeError.missingRuntime }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["serve"]
        process.currentDirectoryURL = executable.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment["OLLAMA_HOST"] = "127.0.0.1:11471"
        environment["OLLAMA_NO_CLOUD"] = "1"
        environment["OLLAMA_DEBUG_LOG_REQUESTS"] = "0"
        environment["OLLAMA_DEBUG"] = "0"
        environment["OLLAMA_NOHISTORY"] = "1"
        environment["OLLAMA_NUM_PARALLEL"] = "1"
        environment["OLLAMA_MAX_LOADED_MODELS"] = "1"
        environment["OLLAMA_MODELS"] = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ollama", isDirectory: true).appendingPathComponent("models", isDirectory: true).path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { [weak self] finished in self?.clearOwnedProcess(finished) }
        do { try process.run(); ownedProcess = process }
        catch { throw SummaryModelRuntimeError.couldNotStart }
    }

    func stopOwnedServer() {
        lock.lock()
        let process = ownedProcess
        ownedProcess = nil
        lock.unlock()
        if process?.isRunning == true { process?.terminate() }
    }

    private func clearOwnedProcess(_ finished: Process) {
        lock.lock(); defer { lock.unlock() }
        if ownedProcess === finished { ownedProcess = nil }
    }
}
