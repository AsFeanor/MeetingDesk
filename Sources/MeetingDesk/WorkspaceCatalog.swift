import Foundation
import Darwin

struct MeetingProject: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
}

struct MeetingSeries: Codable, Identifiable, Equatable {
    var id: UUID = UUID()
    var name: String
    var projectID: UUID?
}

/// Captures the membership displayed when an edit command was prepared.
struct MeetingOrganizationMembership: Equatable {
    let projectID: UUID?
    let seriesID: UUID?

    init(projectID: UUID?, seriesID: UUID?) {
        self.projectID = projectID
        self.seriesID = seriesID
    }

    init(meeting: Meeting) {
        self.init(projectID: meeting.projectID, seriesID: meeting.seriesID)
    }
}

struct WorkspaceCatalog: Codable, Equatable {
    var projects: [MeetingProject] = []
    var series: [MeetingSeries] = []

    func validate() throws {
        let ids = projects.map(\.id) + series.map(\.id)
        guard Set(ids).count == ids.count else { throw MeetingError.message("Proje veya seri kimliği yineleniyor; katalog değiştirilmedi.") }
        for name in projects.map(\.name) + series.map(\.name) { _ = try Self.cleanName(name) }
        let projectIDs = Set(projects.map(\.id))
        guard series.allSatisfy({ $0.projectID.map { projectIDs.contains($0) } ?? true }) else {
            throw MeetingError.message("Bir serinin bağlı olduğu proje bulunamıyor; katalog değiştirilmedi.")
        }
    }

    static func cleanName(_ name: String) throws -> String {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !clean.isEmpty, clean.count <= 120 else { throw MeetingError.message("1–120 karakter arasında bir ad yaz.") }
        return clean
    }
}

/// A separate local file leaves historical meeting JSON readable without migration.
/// Callers pass the archive root explicitly; tests always use a temporary archive.
struct WorkspaceCatalogStore {
    let root: URL
    var url: URL { root.appendingPathComponent(".workspace-catalog.json") }

    func load() throws -> WorkspaceCatalog {
        guard FileManager.default.fileExists(atPath: url.path) else { return WorkspaceCatalog() }
        let value = try JSONDecoder().decode(WorkspaceCatalog.self, from: Data(contentsOf: url))
        try value.validate()
        return value
    }

    func save(_ catalog: WorkspaceCatalog, replacing expected: WorkspaceCatalog? = nil) throws {
        try catalog.validate()
        // An unreadable or externally changed catalog must never be overwritten.
        let stored = try load()
        if let expected, stored != expected { throw MeetingError.message("Proje listesi değişti. Listeyi yeniden açıp tekrar dene.") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(catalog)
        let temporary = root.appendingPathComponent(".workspace-catalog-\(UUID().uuidString).tmp")
        let descriptor = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); try? FileManager.default.removeItem(at: temporary) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard rename(temporary.path, url.path) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
    }
}
