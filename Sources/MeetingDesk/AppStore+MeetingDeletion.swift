import Foundation

extension AppStore {
    /// An open sharing sheet owns an export snapshot, including save-panel work
    /// that is synchronous and is not represented by Notion's export state.
    var isMeetingDeletionBlocked: Bool {
        workInProgress || preparingSpeakerModels || !meetingSharingSessions.isEmpty
    }

    func canMoveMeetingToTrash(_ id: UUID) -> Bool {
        !isMeetingDeletionBlocked && meetings.filter { $0.id == id }.count == 1
    }

    func beginMeetingSharingSession() -> UUID {
        let id = UUID()
        meetingSharingSessions.insert(id)
        return id
    }

    func endMeetingSharingSession(_ id: UUID) { meetingSharingSessions.remove(id) }

    /// Confirmation passes the displayed snapshot. Both memory and the durable
    /// metadata must still match before the one recoverable filesystem move.
    @discardableResult
    func moveMeetingToTrash(_ id: UUID, expectedMeeting: Meeting? = nil,
                            trashItem: ((URL) throws -> URL?)? = nil) -> Bool {
        guard !isMeetingDeletionBlocked else {
            errorMessage = MeetingDeletionError.busy.localizedDescription
            return false
        }
        let matches = meetings.filter { $0.id == id }
        guard matches.count == 1, let meeting = matches.first else {
            errorMessage = (matches.isEmpty ? MeetingDeletionError.missingMeeting : MeetingDeletionError.ambiguousMeeting).localizedDescription
            return false
        }
        if let expectedMeeting, expectedMeeting != meeting {
            errorMessage = MeetingDeletionError.changedMeeting.localizedDescription
            return false
        }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return false }

        let previousStatus = statusMessage
        isDeletingMeeting = true
        // Existing updater/quit protection observes isBusy; use the same barrier
        // during this synchronous persistence operation without cancelling work.
        isBusy = true
        statusMessage = "Toplantı Çöp Sepeti’ne taşınıyor…"
        defer { isDeletingMeeting = false; isBusy = false }
        do {
            if let trashItem { _ = try library.moveMeetingToTrash(meeting, trashItem: trashItem) }
            else { _ = try library.moveMeetingToTrash(meeting) }

            // Until Trash succeeds, playback, selection, meeting entries and all
            // other archives remain untouched. This also handles paused players.
            stopPlaybackForDeletedMeeting(id)
            let wasSelected = selectedID == id
            meetings.removeAll { $0.id == id }
            if wasSelected { selectedID = meetings.isEmpty ? nil : meetings[min(index, meetings.count - 1)].id }

            // Existing cross-meeting UUID links are intentionally retained in
            // other archives: source lookup now reports unavailable and cannot
            // surface/complete deleted tasks; restoring from Trash restores links.
            // Project/series catalogs and global voice profiles are not rewritten.
            errorMessage = nil
            statusMessage = "Toplantı Çöp Sepeti’ne taşındı. Finder’daki Çöp Sepeti’nden geri alabilirsin."
            return true
        } catch {
            statusMessage = previousStatus
            errorMessage = "Toplantı silinemedi. Liste değiştirilmedi. \(error.localizedDescription)"
            return false
        }
    }
}
