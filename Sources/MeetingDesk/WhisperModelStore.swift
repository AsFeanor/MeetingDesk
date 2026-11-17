import CryptoKit
import Foundation

struct WhisperModelFile: Sendable {
    let name: String
    let bytes: Int64
    let sha256: String
}

enum WhisperModelPin {
    static let identifier = "mlx-community/whisper-large-v3-turbo"
    static let revision = "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb"
    static let implementation = "mlx-whisper-0.4.3+meetingdesk-ipc1"
    static let strategy = "window-auto-20s-v1"
    static let mixedLanguage = "Türkçe + English"
    static let files = [
        WhisperModelFile(name: "config.json", bytes: 268, sha256: "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379"),
        WhisperModelFile(name: "weights.safetensors", bytes: 1_613_977_612, sha256: "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6")
    ]
}

enum WhisperModelFailure: LocalizedError {
    case missing, busy, invalidDownload, downloadFailed
    var errorDescription: String? {
        switch self {
        case .missing: return "Karma dil modeli hazır değil. Ayarlar → Genel bölümünden modeli bir kez indir. Ses kaydın korunuyor."
        case .busy: return "Karma dil modeli zaten hazırlanıyor."
        case .invalidDownload: return "Karma dil modeli doğrulanamadı. Eksik dosyalar kullanılmadı; yeniden indirmeyi deneyebilirsin."
        case .downloadFailed: return "Karma dil modeli indirilemedi. İnternet bağlantını kontrol edip yeniden dene."
        }
    }
}

/// The model cache is separate from meeting archives. Readiness never hashes a
/// multi-gigabyte file on the UI thread; operation startup verifies every byte.
actor WhisperModelStore {
    typealias Progress = @Sendable (Double) -> Void
    typealias Downloader = @Sendable (URL, WhisperModelFile, @escaping Progress) async throws -> URL
    let directory: URL
    private let files: [WhisperModelFile]
    private let downloader: Downloader
    private var preparing = false

    init(root: URL? = nil, files: [WhisperModelFile] = WhisperModelPin.files,
         downloader: @escaping Downloader = WhisperModelStore.download) {
        let base = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingDeskModels/WhisperLargeTurbo", isDirectory: true)
        directory = base.appendingPathComponent(WhisperModelPin.revision, isDirectory: true)
        self.files = files; self.downloader = downloader
    }

    func isReady() -> Bool {
        let receiptURL = directory.appendingPathComponent("verified.json")
        guard let size = try? FileManager.default.attributesOfItem(atPath: receiptURL.path)[.size] as? NSNumber,
              size.intValue <= 2_048,
              let receipt = try? Data(contentsOf: receiptURL),
              let saved = try? JSONDecoder().decode([String: String].self, from: receipt),
              saved == Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.sha256) }) else { return false }
        return files.allSatisfy { file in
            let url = directory.appendingPathComponent(file.name)
            guard let a = try? FileManager.default.attributesOfItem(atPath: url.path) else { return false }
            return a[.type] as? FileAttributeType == .typeRegular && (a[.size] as? NSNumber)?.int64Value == file.bytes
        }
    }

    func verifiedDirectory() throws -> URL {
        guard isReady() else { throw WhisperModelFailure.missing }
        try verify(directory)
        return directory
    }

    func prepare(progress: @escaping Progress) async throws {
        guard !preparing else { throw WhisperModelFailure.busy }
        preparing = true; defer { preparing = false }
        if isReady(), (try? verify(directory)) != nil { progress(1); return }
        try Task.checkCancellation()
        let fm = FileManager.default, parent = directory.deletingLastPathComponent()
        try fm.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let staging = parent.appendingPathComponent(".download-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: staging, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: staging) }
        let total = Double(files.reduce(Int64(0)) { $0 + $1.bytes })
        var completed: Int64 = 0
        for file in files {
            try Task.checkCancellation()
            let source = URL(string: "https://huggingface.co/\(WhisperModelPin.identifier)/resolve/\(WhisperModelPin.revision)/\(file.name)")!
            let done = completed
            let temporary: URL
            do { temporary = try await downloader(source, file) { progress((Double(done) + $0 * Double(file.bytes)) / total) } }
            catch is CancellationError { throw CancellationError() }
            catch { if Task.isCancelled { throw CancellationError() }; throw WhisperModelFailure.downloadFailed }
            defer { try? fm.removeItem(at: temporary) }
            let target = staging.appendingPathComponent(file.name)
            try fm.moveItem(at: temporary, to: target)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path)
            try Self.verify(target, pin: file)
            completed += file.bytes
        }
        try Task.checkCancellation()
        let receipt = try JSONEncoder().encode(Dictionary(uniqueKeysWithValues: files.map { ($0.name, $0.sha256) }))
        try receipt.write(to: staging.appendingPathComponent("verified.json"), options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: staging.appendingPathComponent("verified.json").path)
        let backup = parent.appendingPathComponent(".previous-" + UUID().uuidString, isDirectory: true)
        let existed = fm.fileExists(atPath: directory.path)
        if existed { try fm.moveItem(at: directory, to: backup) }
        do { try fm.moveItem(at: staging, to: directory) }
        catch {
            if existed { try? fm.moveItem(at: backup, to: directory) }
            throw error
        }
        if existed { try? fm.removeItem(at: backup) }
        progress(1)
    }

    private func verify(_ path: URL) throws {
        for file in files { try Self.verify(path.appendingPathComponent(file.name), pin: file) }
    }

    private static func verify(_ path: URL, pin: WhisperModelFile) throws {
        let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.size] as? NSNumber)?.int64Value == pin.bytes else { throw WhisperModelFailure.invalidDownload }
        let input = try FileHandle(forReadingFrom: path); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation(); hash.update(data: data)
        }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == pin.sha256 else { throw WhisperModelFailure.invalidDownload }
    }

    private static func download(_ source: URL, file: WhisperModelFile, progress: @escaping Progress) async throws -> URL {
        let delegate = WhisperDownloadDelegate(expectedBytes: file.bytes, progress: progress)
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCache = nil
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 3_600
        let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (temporary, response) = try await session.download(from: source)
        guard let http = response as? HTTPURLResponse, (200...299).contains(http.statusCode),
              WhisperDownloadDelegate.allowed(response.url) else { throw WhisperModelFailure.invalidDownload }
        // URLSession owns its temporary file. Move it to a private owned path
        // before invalidating the session or returning to the cache transaction.
        let owned = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-model-" + UUID().uuidString)
        try FileManager.default.moveItem(at: temporary, to: owned)
        return owned
    }
}

private final class WhisperDownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let expectedBytes: Int64
    let progress: WhisperModelStore.Progress
    // URLSession's default delegate queue is serial. Keep UI progress bounded.
    private var lastEmission: TimeInterval = 0
    init(expectedBytes: Int64, progress: @escaping WhisperModelStore.Progress) {
        self.expectedBytes = expectedBytes; self.progress = progress
    }
    static func allowed(_ url: URL?) -> Bool {
        guard let url, url.scheme == "https", url.user == nil, url.password == nil,
              url.port == nil || url.port == 443, let host = url.host?.lowercased() else { return false }
        return host == "huggingface.co" || host.hasSuffix(".huggingface.co") || host == "hf.co" || host.hasSuffix(".hf.co")
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(Self.allowed(request.url) ? request : nil)
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {}
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesWritten <= expectedBytes,
              totalBytesExpectedToWrite < 0 || totalBytesExpectedToWrite == expectedBytes else { downloadTask.cancel(); return }
        let now = Date.timeIntervalSinceReferenceDate
        if now - lastEmission >= 0.25 || totalBytesWritten == expectedBytes {
            lastEmission = now
            progress(min(1, Double(totalBytesWritten) / Double(expectedBytes)))
        }
    }
}
