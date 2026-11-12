import Foundation
import Darwin

/// Synchronous, small local store. AppStore uses it only on the main actor.
final class VoiceProfileStore {
    private struct Archive: Codable {
        var version = 1
        var profiles: [VoiceProfile]
    }

    let root: URL
    var fileURL: URL { root.appendingPathComponent("voice-profiles.json", isDirectory: false) }
    private let files: FileManager

    init(root: URL, fileManager: FileManager = .default) {
        self.root = root.standardizedFileURL
        self.files = fileManager
    }

    func load() throws -> [VoiceProfile] {
        guard root.isFileURL else { throw VoiceProfileError.invalidStorage }
        if let attributes = try? files.attributesOfItem(atPath: root.path), attributes[.type] as? FileAttributeType != .typeDirectory {
            throw VoiceProfileError.invalidStorage
        }
        guard let attributes = try? files.attributesOfItem(atPath: fileURL.path) else { return [] }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 10 * 1_024 * 1_024 else {
            throw VoiceProfileError.invalidArchive
        }
        do {
            let archive = try JSONDecoder().decode(Archive.self, from: Data(contentsOf: fileURL))
            guard archive.version == 1 else { throw VoiceProfileError.invalidArchive }
            try VoiceProfileValidation.profiles(archive.profiles)
            return archive.profiles
        } catch { throw VoiceProfileError.invalidArchive }
    }

    func save(_ profiles: [VoiceProfile]) throws {
        try VoiceProfileValidation.profiles(profiles)
        // Never silently replace a malformed or newer-format existing archive.
        _ = try load()
        if !files.fileExists(atPath: root.path) {
            try files.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        let temporary = root.appendingPathComponent(".voice-profiles-\(UUID().uuidString).tmp")
        guard files.createFile(atPath: temporary.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw VoiceProfileError.invalidStorage
        }
        defer { try? files.removeItem(at: temporary) }
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            let data = try encoder.encode(Archive(profiles: profiles))
            guard data.count <= 10 * 1_024 * 1_024 else { throw VoiceProfileError.invalidStorage }
            let handle = try FileHandle(forWritingTo: temporary)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch {
                try? handle.close()
                throw error
            }
            try temporary.withUnsafeFileSystemRepresentation { source in
                try fileURL.withUnsafeFileSystemRepresentation { destination in
                    guard let source, let destination, Darwin.rename(source, destination) == 0 else {
                        throw VoiceProfileError.invalidStorage
                    }
                }
            }
        } catch { throw VoiceProfileError.invalidStorage }
    }
}
