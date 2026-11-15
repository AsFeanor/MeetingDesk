import Foundation

extension AppStore {
    // Like personal notes, task check-offs may be saved during recording. They
    // never change the selected meeting or touch a recording file.
    var canEditCarryover: Bool {
        !isBusy && !preparingLocalSummaryModel && !showMicrophoneCheck && !notion.isExporting
    }
    var previousMeetingLinks: [UUID: UUID] {
        Dictionary(grouping: meetings, by: \.id).compactMapValues { values in
            values.count == 1 ? values[0].previousMeetingID : nil
        }
    }

    func setPreviousMeeting(_ previousID: UUID?, for meetingID: UUID) {
        guard canEditCarryover, selectedID == meetingID,
              let current = meetings.first(where: { $0.id == meetingID }) else { return }
        if let previousID {
            guard CarryoverActions.eligiblePreviousMeetings(for: current, in: meetings).contains(where: { $0.id == previousID }) else { return }
        }
        update(meetingID) { $0.previousMeetingID = previousID }
    }

    func completeCarryoverAction(sourceMeetingID: UUID, actionID: String, in meetingID: UUID) {
        guard canEditCarryover, selectedID == meetingID,
              let current = meetings.first(where: { $0.id == meetingID }),
              CarryoverActions.containsPendingTask(sourceMeetingID: sourceMeetingID, actionID: actionID,
                for: current, previousMeetingID: current.previousMeetingID, in: meetings,
                previousLinks: previousMeetingLinks) else { return }
        update(sourceMeetingID) { $0.completedActions.insert(actionID) }
    }
}
