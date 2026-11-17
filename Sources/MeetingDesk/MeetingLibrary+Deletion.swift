import Foundation

enum MeetingDeletionError: LocalizedError {
    case busy, missingMeeting, ambiguousMeeting, changedMeeting, unsafeArchive, notMoved

    var errorDescription: String? {
        switch self {
        case .busy: return "Devam eden işlem veya paylaşım bittikten sonra toplantıyı silebilirsin."
        case .missingMeeting: return "Toplantı artık listede bulunmuyor. Listeyi yeniden açıp tekrar dene."
        case .ambiguousMeeting: return "Toplantı kimliği yineleniyor. Hiçbir klasör değiştirilmedi."
        case .changedMeeting: return "Toplantı değişti. Güncel içeriğini kontrol edip yeniden silmeyi dene."
        case .unsafeArchive: return "Toplantı klasörü veya kayıtlı bilgileri doğrulanamadı. Hiçbir klasör değiştirilmedi."
        case .notMoved: return "Toplantı klasörü Çöp Sepeti’ne taşınamadı. Liste değiştirilmedi."
        }
    }
}

extension MeetingLibrary {
    /// Moves one complete, owned meeting directory. The injected mover is used by
    /// temporary-archive tests; production uses macOS Trash, never removeItem.
    @discardableResult
    func moveMeetingToTrash(_ meeting: Meeting,
                            trashItem: (URL) throws -> URL? = MeetingLibrary.moveDirectoryToTrash) throws -> URL? {
        let files = FileManager.default
        guard root.isFileURL,
              try files.attributesOfItem(atPath: root.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw MeetingDeletionError.unsafeArchive
        }
        let canonicalRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        let directory = directory(for: meeting.id).standardizedFileURL
        guard directory.lastPathComponent == meeting.id.uuidString,
              directory.deletingLastPathComponent().resolvingSymlinksInPath() == canonicalRoot,
              try files.attributesOfItem(atPath: directory.path)[.type] as? FileAttributeType == .typeDirectory,
              directory.resolvingSymlinksInPath() == canonicalRoot.appendingPathComponent(meeting.id.uuidString, isDirectory: true) else {
            throw MeetingDeletionError.unsafeArchive
        }
        let metadata = directory.appendingPathComponent("meeting.json")
        guard try files.attributesOfItem(atPath: metadata.path)[.type] as? FileAttributeType == .typeRegular,
              metadata.resolvingSymlinksInPath() == directory.resolvingSymlinksInPath().appendingPathComponent("meeting.json") else {
            throw MeetingDeletionError.unsafeArchive
        }
        let saved: Meeting
        do { saved = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: metadata)) }
        catch { throw MeetingDeletionError.unsafeArchive }
        guard saved == meeting else { throw MeetingDeletionError.changedMeeting }

        // A single directory move keeps audio, notes, transcript and all histories
        // together. It does not traverse links within that directory.
        let receipt = try trashItem(directory)
        do {
            _ = try files.attributesOfItem(atPath: directory.path)
            throw MeetingDeletionError.notMoved
        } catch let error as NSError where error.domain == NSCocoaErrorDomain && error.code == NSFileReadNoSuchFileError {
            return receipt
        }
    }

    static func moveDirectoryToTrash(_ directory: URL) throws -> URL? {
        var result: NSURL?
        try FileManager.default.trashItem(at: directory, resultingItemURL: &result)
        return result as URL?
    }
}
