import Foundation
import UniformTypeIdentifiers

/// Disabled by default. Decoding is validated too, so malformed settings cannot enable deletion.
struct AudioRetentionPolicy: Codable, Equatable {
    let days: Int?
    static let disabled = try! AudioRetentionPolicy(days: nil)

    init(days: Int?) throws {
        guard days == nil || (1...3650).contains(days!) else {
            throw MeetingError.message("Ses kayıtlarını saklama süresi 1 ile 3650 gün arasında olmalı.")
        }
        self.days = days
    }

    private enum CodingKeys: String, CodingKey { case days }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(days: values.decodeIfPresent(Int.self, forKey: .days))
    }
}

struct AudioRetentionResult {
    var updatedMeetings: [Meeting]
    var removedRecordingCount = 0
    var movedFileCount = 0
    var skippedMeetingCount = 0
    var failureMessages: [String] = []
}

/// Moves only owned recording files to the macOS Trash. It never removes meeting folders.
/// The persisted pending marker keeps interrupted and partially moved recordings retryable.
struct AudioRetentionService {
    let library: MeetingLibrary
    private let trashItem: (URL) throws -> URL?
    private let saveMeeting: (Meeting) throws -> Void
    private let files = FileManager.default

    init(library: MeetingLibrary,
         trashItem: @escaping (URL) throws -> URL? = AudioRetentionService.moveToTrash,
         saveMeeting: ((Meeting) throws -> Void)? = nil) {
        self.library = library
        self.trashItem = trashItem
        self.saveMeeting = saveMeeting ?? library.save
    }

    static func moveToTrash(_ file: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: file, resultingItemURL: &result)
        return result as URL?
    }

    func cleanup(meetings: [Meeting], policy: AudioRetentionPolicy, now: Date,
                 protectedMeetingIDs: Set<UUID> = []) -> AudioRetentionResult {
        var result = AudioRetentionResult(updatedMeetings: meetings)
        guard let days = policy.days, now.timeIntervalSinceReferenceDate.isFinite else { return result }

        for index in meetings.indices {
            let initial = meetings[index]
            guard initial.audioFileName != nil, !protectedMeetingIDs.contains(initial.id) else {
                result.skippedMeetingCount += 1
                continue
            }
            var current = initial
            do {
                // Validate every managed file before changing metadata or moving any one track.
                try validateArchive(for: current)
                let urls = try ownedFiles(for: current)
                var identities: [String: FileIdentity] = [:]
                var baseline = max(current.createdAt, current.audioSavedAt ?? current.createdAt)
                guard baseline.timeIntervalSinceReferenceDate.isFinite else { throw UnsafeArchive() }
                for url in urls {
                    if let attributes = try regularFileAttributes(at: url) {
                        identities[url.path] = FileIdentity(attributes)
                        if let modified = attributes[.modificationDate] as? Date { baseline = max(baseline, modified) }
                    }
                }
                // A clock change or a freshly replaced file must never expire immediately.
                guard baseline <= now else {
                    result.skippedMeetingCount += 1
                    continue
                }
                let expired = now.timeIntervalSince(baseline) >= Double(days) * 86_400
                let baselineChanged = current.audioSavedAt != baseline
                if baselineChanged {
                    var saved = current
                    saved.audioSavedAt = baseline
                    if !expired { saved.audioDeletionPending = nil }
                    // Establish legacy recording age before deleting; retry never ages from a vanished file.
                    try persist(saved, replacing: &current)
                    result.updatedMeetings[index] = current
                }
                guard expired else {
                    result.skippedMeetingCount += 1
                    continue
                }
                if current.audioDeletionPending != true {
                    var pending = current
                    pending.audioDeletionPending = true
                    try persist(pending, replacing: &current)
                    result.updatedMeetings[index] = current
                }
                for url in urls {
                    // Persisted identity, recovery state and symlinks are checked again for each move.
                    try validateArchive(for: current)
                    guard let attributes = try regularFileAttributes(at: url) else { continue }
                    guard identities[url.path] == FileIdentity(attributes) else { throw UnsafeArchive() }
                    _ = try trashItem(url)
                    guard try regularFileAttributes(at: url) == nil else {
                        throw MeetingError.message("Ses dosyası Çöp Sepeti’ne taşınamadı.")
                    }
                    result.movedFileCount += 1
                }
                try validateArchive(for: current)
                for url in urls {
                    guard try regularFileAttributes(at: url) == nil else { throw UnsafeArchive() }
                }
                var completed = current
                completed.audioFileName = nil
                completed.audioDeletedAt = now
                completed.audioDeletionPending = nil
                try persist(completed, replacing: &current)
                result.updatedMeetings[index] = current
                result.removedRecordingCount += 1
            } catch is UnsafeArchive {
                // Unreadable, foreign, linked or actively recovered archives are left untouched.
                result.updatedMeetings[index] = current
                result.skippedMeetingCount += 1
            } catch {
                result.updatedMeetings[index] = current
                result.failureMessages.append("\(initial.title): Ses kaydı temizliği tamamlanamadı; kalan dosyalar korunuyor. \(error.localizedDescription)")
            }
        }
        return result
    }

    private func persist(_ candidate: Meeting, replacing current: inout Meeting) throws {
        try validateArchive(for: current)
        do {
            try saveMeeting(candidate)
            // A custom or failed persistence implementation must not authorize a deletion.
            guard try readMeeting(at: metadataURL(for: candidate)) == candidate else {
                throw MeetingError.message("Ses kaydının saklama bilgisi kaydedilemedi.")
            }
            current = candidate
        } catch {
            // MeetingLibrary.save can fail after its atomic write (for example while setting permissions).
            // Reflect only a verified durable candidate, and still stop moving files on that failure.
            if (try? readMeeting(at: metadataURL(for: candidate))) == candidate { current = candidate }
            throw error
        }
    }

    private func validateArchive(for meeting: Meeting) throws {
        guard library.root.isFileURL,
              try requiredAttributes(at: library.root)[.type] as? FileAttributeType == .typeDirectory else {
            throw UnsafeArchive()
        }
        let root = library.root.standardizedFileURL.resolvingSymlinksInPath()
        let directory = library.directory(for: meeting.id).standardizedFileURL
        guard directory.lastPathComponent == meeting.id.uuidString,
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == root,
              try requiredAttributes(at: directory)[.type] as? FileAttributeType == .typeDirectory,
              directory.resolvingSymlinksInPath() == root.appendingPathComponent(meeting.id.uuidString, isDirectory: true),
              try optionalAttributes(at: directory.appendingPathComponent(".recording-recovery")) == nil,
              try readMeeting(at: metadataURL(for: meeting)) == meeting else {
            throw UnsafeArchive()
        }
    }

    private func metadataURL(for meeting: Meeting) -> URL {
        library.directory(for: meeting.id).appendingPathComponent("meeting.json")
    }

    private func readMeeting(at url: URL) throws -> Meeting {
        guard try requiredAttributes(at: url)[.type] as? FileAttributeType == .typeRegular else {
            throw UnsafeArchive()
        }
        do { return try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: url)) }
        catch { throw UnsafeArchive() }
    }

    private func ownedFiles(for meeting: Meeting) throws -> [URL] {
        guard let name = meeting.audioFileName,
              name.hasPrefix("recording."), !name.contains("/"), !name.contains("\\"),
              name == URL(fileURLWithPath: name).lastPathComponent else { throw UnsafeArchive() }
        let ext = String(name.dropFirst("recording.".count))
        guard !ext.isEmpty, ext.count <= 16,
              ext.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) && $0.isASCII }),
              isAudioOrMovieExtension(ext) else {
            throw UnsafeArchive()
        }
        let directory = library.directory(for: meeting.id)
        return [name, "recording-microphone.m4a", "recording-system.m4a"].map { directory.appendingPathComponent($0) }
    }

    private func isAudioOrMovieExtension(_ ext: String) -> Bool {
        // LaunchServices can return dynamic, undeclared types in a sandboxed test or login process.
        // These app-managed formats remain recognizable without consulting that registry.
        let known: Set<String> = ["m4a", "mp3", "wav", "wave", "aif", "aiff", "aifc", "caf", "aac",
                                  "flac", "ogg", "opus", "amr", "ac3", "mp4", "m4v", "mov", "mpeg",
                                  "mpg", "webm", "avi", "mkv", "3gp", "3g2"]
        if known.contains(ext.lowercased()) { return true }
        guard let type = UTType(filenameExtension: ext) else { return false }
        return type.conforms(to: .audio) || type.conforms(to: .movie)
    }

    private func regularFileAttributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        guard let attributes = try optionalAttributes(at: url) else { return nil }
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              url.standardizedFileURL.resolvingSymlinksInPath() == url.standardizedFileURL.deletingLastPathComponent()
                .resolvingSymlinksInPath().appendingPathComponent(url.lastPathComponent) else {
            throw UnsafeArchive()
        }
        return attributes
    }

    private func optionalAttributes(at url: URL) throws -> [FileAttributeKey: Any]? {
        do { return try files.attributesOfItem(atPath: url.path) }
        catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return nil
        } catch { throw UnsafeArchive() }
    }

    private func requiredAttributes(at url: URL) throws -> [FileAttributeKey: Any] {
        guard let attributes = try optionalAttributes(at: url) else { throw UnsafeArchive() }
        return attributes
    }

    private struct UnsafeArchive: Error {}

    private struct FileIdentity: Equatable {
        var number: UInt64?
        var device: UInt64?
        var size: UInt64?
        var modified: Date?

        init(_ attributes: [FileAttributeKey: Any]) {
            number = (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
            device = (attributes[.systemNumber] as? NSNumber)?.uint64Value
            size = (attributes[.size] as? NSNumber)?.uint64Value
            modified = attributes[.modificationDate] as? Date
        }
    }
}
