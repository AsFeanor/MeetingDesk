import Foundation
import Darwin

/// Uses the caller's library root, including isolated test/preview roots.
final class GlossaryStore {
    private struct Archive: Codable {
        var version = 1
        var entries: [GlossaryEntry]
    }

    let root: URL
    var fileURL: URL { root.appendingPathComponent(".transcript-glossary.json", isDirectory: false) }
    private let files: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        files = fileManager
    }

    func load() throws -> [GlossaryEntry] {
        guard root.isFileURL else { throw GlossaryError.invalidStorage }
        if let attributes = try attributes(at: root), attributes[.type] as? FileAttributeType != .typeDirectory {
            throw GlossaryError.invalidStorage
        }
        guard let attributes = try attributes(at: fileURL) else { return [] }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 10 * 1_024 * 1_024 else {
            throw GlossaryError.invalidArchive
        }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw GlossaryError.invalidArchive }
            try GlossaryValidation.entries(archive.entries)
            return archive.entries
        } catch { throw GlossaryError.invalidArchive }
    }

    func save(_ entries: [GlossaryEntry]) throws {
        try GlossaryValidation.entries(entries)
        // An unreadable, malformed or newer archive is never replaced with an empty UI state.
        _ = try load()
        if try attributes(at: root) == nil {
            try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temporary = root.appendingPathComponent(".transcript-glossary-\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw GlossaryError.invalidStorage
        }
        defer { try? files.removeItem(at: temporary) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Archive(entries: entries))
            guard data.count <= 10 * 1_024 * 1_024 else { throw GlossaryError.invalidStorage }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            try temporary.withUnsafeFileSystemRepresentation { source in
                try fileURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination, Darwin.rename(source, destination) == 0 else {
                        throw GlossaryError.invalidStorage
                    }
                }
            }
        } catch { throw GlossaryError.invalidStorage }
    }

    private func attributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try files.attributesOfItem(atPath: url.path) }
        catch {
            let failure = error as NSError
            if failure.domain == NSCocoaErrorDomain,
               [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(failure.code) { return nil }
            throw GlossaryError.invalidStorage
        }
    }
}
