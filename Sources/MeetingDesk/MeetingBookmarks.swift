import Foundation

struct MeetingBookmark: Codable, Identifiable, Equatable {
    var id = UUID()
    var time: Double
    var note: String = ""
}

enum MeetingBookmarkPolicy {
    static func make(time: Double, limit: Double, note: String = "") throws -> MeetingBookmark {
        guard time.isFinite, limit.isFinite, time >= 0, time <= limit, limit >= 0 else {
            throw MeetingError.message("İşaretlenecek an bu kaydın dışında.")
        }
        let note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard note.count <= 1000 else { throw MeetingError.message("An notunu 1000 karaktere kadar yazabilirsin.") }
        return MeetingBookmark(time: time, note: note)
    }
    static func ordered(in meeting: Meeting) -> [MeetingBookmark] {
        let values = meeting.bookmarks ?? []
        let grouped = Dictionary(grouping: values, by: \.id)
        return values.enumerated().filter {
            grouped[$0.element.id]?.count == 1 && $0.element.time.isFinite && $0.element.time >= 0
        }.sorted {
            $0.element.time == $1.element.time ? $0.offset < $1.offset : $0.element.time < $1.element.time
        }.map(\.element)
    }
    static func source(for bookmark: MeetingBookmark, in meeting: Meeting) -> TranscriptSegment? {
        guard bookmark.time.isFinite, bookmark.time >= 0, meeting.duration.isFinite,
              bookmark.time <= meeting.duration else { return nil }
        // Never invent an association across a long gap in the transcript.
        let counts = Dictionary(grouping: meeting.segments, by: \.id).mapValues(\.count)
        return TranscriptConversation.orderedSegments(meeting.segments).first {
            counts[$0.id] == 1 && $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start
                && $0.start <= bookmark.time && bookmark.time <= $0.end
        }
    }
}

extension AppStore {
    var canMarkImportantMoment: Bool {
        recorder.isRecording && recordingMeeting != nil && canEditCarryover
    }
    @discardableResult func markImportantMoment() -> UUID? {
        guard canMarkImportantMoment, let meeting = recordingMeeting else { return nil }
        return saveBookmark(time: recorder.elapsed, limit: recorder.elapsed, note: "", meetingID: meeting.id)
    }
    @discardableResult func addBookmark(at time: Double, note: String = "", in meetingID: UUID) -> UUID? {
        guard !workInProgress, selectedID == meetingID,
              let meeting = meetings.first(where: { $0.id == meetingID }) else { return nil }
        return saveBookmark(time: time, limit: meeting.duration, note: note, meetingID: meetingID)
    }
    private func saveBookmark(time: Double, limit: Double, note: String, meetingID: UUID) -> UUID? {
        guard meetings.filter({ $0.id == meetingID }).count == 1 else { return nil }
        do {
            let bookmark = try MeetingBookmarkPolicy.make(time: time, limit: limit, note: note)
            guard update(meetingID, { $0.bookmarks = ($0.bookmarks ?? []) + [bookmark] }) else { return nil }
            statusMessage = "Önemli an işaretlendi · \(timeLabel(time))"
            return bookmark.id
        } catch { errorMessage = error.localizedDescription; return nil }
    }
    @discardableResult func editBookmark(_ bookmarkID: UUID, note: String, in meetingID: UUID) -> Bool {
        guard canEditCarryover, selectedID == meetingID,
              meetings.filter({ $0.id == meetingID }).count == 1,
              let meeting = meetings.first(where: { $0.id == meetingID }),
              (meeting.bookmarks ?? []).filter({ $0.id == bookmarkID }).count == 1 else { return false }
        let clean = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard clean.count <= 1000 else { errorMessage = "An notunu 1000 karaktere kadar yazabilirsin."; return false }
        return update(meetingID) { value in
            guard let index = value.bookmarks?.firstIndex(where: { $0.id == bookmarkID }) else { return }
            value.bookmarks?[index].note = clean
        }
    }
    @discardableResult func deleteBookmark(_ bookmarkID: UUID, in meetingID: UUID) -> Bool {
        guard canEditCarryover, selectedID == meetingID,
              meetings.filter({ $0.id == meetingID }).count == 1,
              let meeting = meetings.first(where: { $0.id == meetingID }),
              (meeting.bookmarks ?? []).filter({ $0.id == bookmarkID }).count == 1 else { return false }
        return update(meetingID) { $0.bookmarks?.removeAll { $0.id == bookmarkID } }
    }
}
