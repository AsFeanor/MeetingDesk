import Foundation
import CryptoKit

struct MeetingLibrary {
    let root: URL
    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("MeetingDesk", isDirectory: true)
    }
    func directory(for id: UUID) -> URL { root.appendingPathComponent(id.uuidString, isDirectory: true) }
    func audioURL(for meeting: Meeting) -> URL? {
        guard let name = meeting.audioFileName, !name.contains("/"), name != ".." else { return nil }
        return directory(for: meeting.id).appendingPathComponent(name)
    }
    func audioURL(for meeting: Meeting, source: PlaybackSource) -> URL? {
        guard let mixed = audioURL(for: meeting) else { return nil }
        guard source != .mixed else { return mixed }
        let stem = mixed.deletingPathExtension().lastPathComponent
        let track = mixed.deletingLastPathComponent().appendingPathComponent("\(stem)-\(source.rawValue).m4a")
        return FileManager.default.fileExists(atPath: track.path) ? track : nil
    }
    func save(_ meeting: Meeting) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let dir = directory(for: meeting.id)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .deferredToDate
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let destination = dir.appendingPathComponent("meeting.json")
        try encoder.encode(meeting).write(to: destination, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
    }
    func load() throws -> (meetings: [Meeting], unreadable: Int) {
        guard FileManager.default.fileExists(atPath: root.path) else { return ([], 0) }
        let dirs = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .deferredToDate
        var meetings: [Meeting] = []
        var unreadable = 0
        for dir in dirs {
            let url = dir.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            do { meetings.append(try decoder.decode(Meeting.self, from: Data(contentsOf: url))) }
            catch { unreadable += 1 }
        }
        return (meetings.sorted { $0.createdAt > $1.createdAt }, unreadable)
    }

    private func transcriptHistory(for id: UUID) -> URL { directory(for: id).appendingPathComponent(".transcript-history", isDirectory: true) }
    func hasTranscriptVersion(for id: UUID) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: transcriptHistory(for: id), includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "json" }
    }
    func saveTranscriptVersion(_ meeting: Meeting) throws {
        let folder = transcriptHistory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let name = String(format: "%020.6f", Date().timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
        let file = folder.appendingPathComponent(name)
        try JSONEncoder().encode(meeting).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func latestTranscriptVersion(for id: UUID) throws -> Meeting? {
        let folder = transcriptHistory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let file = files.first else { return nil }
        let previous = try JSONDecoder().decode(Meeting.self, from: Data(contentsOf: file))
        guard previous.id == id else { throw MeetingError.message("Önceki döküm bu toplantıya ait değil; kayıt değiştirilmedi.") }
        return previous
    }

    private func notesHistory(for id: UUID) -> URL { directory(for: id).appendingPathComponent(".notes-history", isDirectory: true) }
    func hasNotesVersion(for id: UUID) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(at: notesHistory(for: id), includingPropertiesForKeys: nil)) ?? []).contains { $0.pathExtension == "json" }
    }
    func saveNotesVersion(_ meeting: Meeting) throws {
        let folder = notesHistory(for: meeting.id)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let version = MeetingNotesVersion(meeting: meeting)
        let name = String(format: "%020.6f", version.savedAt.timeIntervalSince1970) + "-" + UUID().uuidString + ".json"
        let file = folder.appendingPathComponent(name)
        try JSONEncoder().encode(version).write(to: file, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }
    func latestNotesVersion(for id: UUID) throws -> MeetingNotesVersion? {
        let folder = notesHistory(for: id)
        guard FileManager.default.fileExists(atPath: folder.path) else { return nil }
        let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
        guard let file = files.first else { return nil }
        let previous = try JSONDecoder().decode(MeetingNotesVersion.self, from: Data(contentsOf: file))
        guard previous.meetingID == id else { throw MeetingError.message("Önceki not sürümü bu toplantıya ait değil; kayıt değiştirilmedi.") }
        return previous
    }
}

/// Restoring a note version never replaces the recording, transcript or personal notes.
struct MeetingNotesVersion: Codable, Equatable {
    var meetingID: UUID
    var savedAt: Date
    var notes: MeetingNotes?
    var completedActions: Set<String>
    var notesNeedRefresh: Bool
    var notesEngine: String?
    var notesManualEdits: NotesManualEdits?
    var reviewedAt: Date?
    var templateRawValue: String?
    var notesTemplateRawValue: String?
    var outputLanguage: String?
    var transcriptFingerprint: String?

    init(meeting: Meeting) {
        meetingID = meeting.id
        savedAt = Date()
        notes = meeting.notes
        completedActions = meeting.completedActions
        notesNeedRefresh = meeting.notesNeedRefresh
        notesEngine = meeting.notesEngine
        notesManualEdits = meeting.notesManualEdits
        reviewedAt = meeting.reviewedAt
        templateRawValue = meeting.templateRawValue
        notesTemplateRawValue = meeting.notesTemplateRawValue
        outputLanguage = meeting.outputLanguage
        transcriptFingerprint = Self.fingerprint(of: meeting)
    }

    func matchesTranscript(of meeting: Meeting) -> Bool {
        guard let transcriptFingerprint, let current = Self.fingerprint(of: meeting) else { return false }
        return transcriptFingerprint == current
    }

    private static func fingerprint(of meeting: Meeting) -> String? {
        struct TranscriptSource: Encodable {
            var segments: [TranscriptSegment]
            var speakerNames: [String: String]
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(TranscriptSource(segments: meeting.segments, speakerNames: meeting.speakerNames)) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

enum MeetingShareScope: String, CaseIterable, Identifiable {
    case summary = "Özet ve kararlar"
    case actions = "Sadece aksiyonlar"
    case fullTranscript = "Tüm transkript"

    var id: String { rawValue }
    var explanation: String {
        switch self {
        case .summary: return "Kısa özet, kararlar, açık sorular, fikirler ve konu notları."
        case .actions: return "Aksiyonlar, tamamlanma durumu, sorumlular ve tarihler."
        case .fullTranscript: return "Tüm toplantı notları ve zaman damgalı transkript."
        }
    }
}

struct MeetingShareOptions: Equatable {
    var scope: MeetingShareScope = .summary
    var includePersonalNotes: Bool = false
}

struct MeetingShareDocument {
    var blocks: [MeetingExportBlock]
    var markdown: String { blocks.map(\.markdown).joined(separator: "\n\n") }
    var plainText: String { blocks.map(\.text).filter { !$0.isEmpty }.joined(separator: "\n\n") }
}

struct MeetingExportBlock {
    enum Kind { case title, metadata, section, subsection, paragraph, notice, bullet, action, transcriptHeading, anchor, footer }
    var kind: Kind
    var text: String
    var markdown: String
}

enum MeetingExport {
    static func markdown(_ meeting: Meeting) -> String {
        markdown(meeting, options: MeetingShareOptions(scope: .fullTranscript))
    }

    static func markdown(_ meeting: Meeting, options: MeetingShareOptions) -> String {
        document(meeting, options: options).markdown
    }

    /// Every output format consumes these same selected blocks; excluded content is never rendered.
    static func document(_ meeting: Meeting, options: MeetingShareOptions) -> MeetingShareDocument {
        var blocks: [MeetingExportBlock] = []
        let includesTranscript = options.scope == .fullTranscript
        let presentation = MeetingNotesPresentation(meeting: meeting)
        func append(_ kind: MeetingExportBlock.Kind, _ text: String, markdown: String? = nil) {
            blocks.append(MeetingExportBlock(kind: kind, text: text, markdown: markdown ?? text))
        }
        func heading(_ text: String, level: Int = 2) {
            append(level == 1 ? .title : level == 2 ? .section : .subsection, text, markdown: String(repeating: "#", count: level) + " " + text)
        }
        func notice(_ text: String) { append(.notice, text, markdown: "> " + text) }
        func evidence(_ ids: [String], links: Bool) -> String {
            let sources = ids.compactMap { id in meeting.segments.first { $0.id == id } }
            guard !sources.isEmpty else { return "" }
            return " — Kaynak: " + sources.map { segment in
                let timestamp = timeLabel(segment.start)
                guard links else { return timestamp }
                let fragment = segment.id.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(CharacterSet(charactersIn: "-_."))) ?? ""
                return "[\(timestamp)](#\(fragment))"
            }.joined(separator: ", ")
        }
        func bullet(_ item: EvidenceItem) {
            append(.bullet, "• " + item.text + evidence(item.evidence, links: false), markdown: "- " + item.text + evidence(item.evidence, links: includesTranscript))
        }
        func items(_ title: String, _ values: [EvidenceItem]) {
            guard !values.isEmpty else { return }
            heading(title)
            values.forEach(bullet)
        }
        func actions(_ notes: MeetingNotes, title: String) {
            heading(title)
            if notes.actions.isEmpty { append(.paragraph, "Bu toplantıda kaydedilmiş aksiyon bulunmuyor.") }
            for item in notes.actions {
                let done = meeting.completedActions.contains(item.id)
                let details = "\(item.text) — Sorumlu: \(item.owner ?? "Belirtilmedi") · Tarih: \(item.due ?? "Belirtilmedi")"
                append(.action, "\(done ? "☑" : "☐") " + details + evidence(item.evidence, links: false), markdown: "- [\(done ? "x" : " ")] " + details + evidence(item.evidence, links: includesTranscript))
            }
        }

        heading(meeting.title, level: 1)
        append(.metadata, "\(meeting.createdAt.formatted(date: .long, time: .shortened)) · \(timeLabel(meeting.duration))")
        if includesTranscript && meeting.transcriptionEngine == ProcessingMode.local.rawValue {
            if meeting.transcriptSourceSeparated == true {
                notice("Transkript Mac’te oluşturuldu. Mikrofon ve toplantı sesi ayrı kayıt kaynakları olarak etiketlendi. Bu etiketler kişilerin kimliğini otomatik belirlemez; kişi adları varsa kullanıcı tarafından eklenmiştir.")
            } else {
                notice("Transkript Mac’te oluşturuldu. Konuşmacılar otomatik ayrılmadı; kişi adları varsa kullanıcı tarafından eklenmiştir.")
            }
            if let language = meeting.transcribedLanguage { notice("Ses dökümünde kullanılan dil: \(language)") }
        }
        if let notes = meeting.notes {
            if meeting.notesEngine == ProcessingMode.local.rawValue {
                notice("Notlar Apple’ın yerel modeliyle oluşturuldu. Kaynaklar kontrol edilmelidir.")
            }
            if meeting.notesNeedRefresh { notice("Transkript, özet dili veya şablon değişti. Bu özet eski sürüme dayanıyor; yeniden oluşturulmalı.") }
            if meeting.notesAreReviewed, let reviewedAt = meeting.reviewedAt {
                append(.metadata, "Kullanıcı tarafından gözden geçirildi · \(reviewedAt.formatted(date: .abbreviated, time: .shortened))")
            }
            append(.metadata, "Not düzeni: \(presentation.template.label)")
            if let message = presentation.templateChangeMessage { notice(message) }
            for section in presentation.sections(for: options.scope) {
                switch section.kind {
                case .summary:
                    heading(section.title)
                    append(.paragraph, notes.summary)
                case .decisions: items(section.title, notes.decisions)
                case .actions: actions(notes, title: section.title)
                case .questions: items(section.title, notes.questions)
                case .ideas: items(section.title, notes.ideas)
                case .contexts:
                    heading(section.title)
                    if let message = section.emptyMessage { append(.paragraph, message) }
                    for topic in section.topics {
                        heading(topic.title, level: 3)
                        append(.paragraph, topic.text + evidence(topic.evidence, links: false), markdown: topic.text + evidence(topic.evidence, links: includesTranscript))
                    }
                }
            }
        } else if options.scope == .actions {
            heading("Aksiyonlar")
            append(.paragraph, "Bu toplantıda kaydedilmiş aksiyon bulunmuyor.")
        } else if options.scope == .summary {
            heading("Kısa özet")
            append(.paragraph, "Henüz toplantı özeti oluşturulmadı.")
        }
        if options.includePersonalNotes && !meeting.personalNotes.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            heading("Kendi notlarım")
            append(.paragraph, meeting.personalNotes)
        }
        if includesTranscript {
            heading("Transkript")
            if meeting.segments.isEmpty { append(.paragraph, "Henüz transkript oluşturulmadı.") }
            for segment in meeting.segments {
                let anchor = segment.id.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "\"", with: "&quot;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;")
                append(.anchor, "", markdown: "<a id=\"\(anchor)\"></a>")
                let label = "\(timeLabel(segment.start)) · \(meeting.speakerName(segment.speaker))"
                append(.transcriptHeading, label, markdown: "**\(label)**")
                append(.paragraph, segment.text)
            }
        }
        let footer = "Otomatik metin ve kaynaklar kontrol edilmeli. Bu çıktı toplantıda söylenenleri aktarır; bağımsız doğrulama içermez."
        append(.footer, footer, markdown: "---\n" + footer)
        return MeetingShareDocument(blocks: blocks)
    }
}

enum TranscriptParser {
    static func parse(_ text: String) -> [TranscriptSegment] {
        let regex = try! NSRegularExpression(pattern: "^\\[?(\\d{1,2}:\\d{2}(?::\\d{2})?)\\]?\\s*(?:[-–]\\s*)?(.*)$")
        var result: [TranscriptSegment] = []
        var currentTime: Double = 0
        var currentSpeaker = "Konuşmacı"
        var body: [String] = []
        func flush() {
            let value = body.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !value.isEmpty { result.append(TranscriptSegment(id: "s\(result.count + 1)", speaker: currentSpeaker, start: currentTime, end: currentTime, text: value)) }
            body = []
        }
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            let ns = line as NSString
            if let match = regex.firstMatch(in: line, range: NSRange(location: 0, length: ns.length)) {
                flush()
                let pieces = ns.substring(with: match.range(at: 1)).split(separator: ":").compactMap { Double($0) }
                currentTime = pieces.reduce(0) { $0 * 60 + $1 }
                var content = ns.substring(with: match.range(at: 2))
                if let colon = content.firstIndex(of: ":"), content.distance(from: content.startIndex, to: colon) < 60 {
                    let name = String(content[..<colon]).trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { currentSpeaker = name; content = String(content[content.index(after: colon)...]).trimmingCharacters(in: .whitespaces) }
                }
                body.append(content)
            } else { body.append(raw) }
        }
        flush()
        for i in result.indices {
            result[i].end = i + 1 < result.count ? max(result[i].start, result[i + 1].start) : result[i].start
        }
        return result
    }
}
