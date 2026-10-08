import Foundation

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
}

enum MeetingExport {
    static func markdown(_ meeting: Meeting) -> String {
        var lines = ["# \(meeting.title)", "", "\(meeting.createdAt.formatted(date: .long, time: .shortened)) · \(timeLabel(meeting.duration))", ""]
        if meeting.transcriptionEngine == ProcessingMode.local.rawValue {
            lines += ["> Transkript Mac’te oluşturuldu. Konuşmacılar otomatik ayrılmadı; kişi adları varsa kullanıcı tarafından eklenmiştir.", ""]
            if let language = meeting.transcribedLanguage { lines += ["> Ses dökümünde kullanılan dil: \(language)", ""] }
        }
        if meeting.notesEngine == ProcessingMode.local.rawValue {
            lines += ["> Özet Apple’ın yerel modeliyle oluşturuldu. Uzun toplantılardaki bölüm notları kaynaklarıyla birlikte kontrol edilmelidir.", ""]
        }
        func evidence(_ ids: [String]) -> String {
            let segments = ids.compactMap { id in meeting.segments.first { $0.id == id } }
            return segments.isEmpty ? "" : " — Kaynak: " + segments.map { "[\(timeLabel($0.start))](#\($0.id))" }.joined(separator: ", ")
        }
        if let notes = meeting.notes {
            if meeting.notesNeedRefresh { lines += ["> Transkript değiştirildi. Bu özet eski sürüme dayanıyor; yeniden oluşturulmalı.", ""] }
            lines += ["## Kısa özet", "", notes.summary, "", "## Kararlar", ""]
            lines += notes.decisions.map { "- \($0.text)\(evidence($0.evidence))" }
            lines += ["", "## Aksiyonlar", ""]
            lines += notes.actions.map { "- [\(meeting.completedActions.contains($0.id) ? "x" : " ")] \($0.text) — Sorumlu: \($0.owner ?? "Belirtilmedi") · Tarih: \($0.due ?? "Belirtilmedi")\(evidence($0.evidence))" }
            lines += ["", "## Açık sorular", ""]
            lines += notes.questions.map { "- \($0.text)\(evidence($0.evidence))" }
            lines += ["", "## Değerlendirilen fikirler", ""]
            lines += notes.ideas.map { "- \($0.text)\(evidence($0.evidence))" }
            for topic in notes.topics { lines += ["", "### \(topic.title)", "", topic.text + evidence(topic.evidence)] }
        }
        if !meeting.personalNotes.isEmpty { lines += ["", "## Kendi notlarım", "", meeting.personalNotes] }
        lines += ["", "## Transkript", ""]
        for segment in meeting.segments {
            lines += ["<a id=\"\(segment.id)\"></a>", "", "**\(timeLabel(segment.start)) · \(meeting.speakerName(segment.speaker))**", "", segment.text, ""]
        }
        lines += ["---", "Konuşmacı etiketleri ve otomatik metin kontrol edilmeli. Özet, toplantıda söylenenleri aktarır; bağımsız doğrulama içermez."]
        return lines.joined(separator: "\n")
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
