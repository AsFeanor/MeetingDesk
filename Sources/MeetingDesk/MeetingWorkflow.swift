import Foundation

enum AutomaticProcessingPolicy {
    static func shouldRun(enabled: Bool, mode: ProcessingMode, saved: Bool, interrupted: Bool) -> Bool {
        enabled && mode == .local && saved && !interrupted
    }
}

struct MeetingWorkflowRunner {
    static func run(meetingID: UUID,
                    transcribe: (UUID) async throws -> Void,
                    summarize: (UUID) async throws -> Void) async throws {
        try Task.checkCancellation()
        try await transcribe(meetingID)
        try Task.checkCancellation()
        try await summarize(meetingID)
        try Task.checkCancellation()
    }
}

enum MeetingArchiveSearch {
    private static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }
    static func matches(_ meeting: Meeting, query: String) -> Bool {
        let words = normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !words.isEmpty else { return true }
        var fields = [meeting.title, meeting.personalNotes]
        fields += meeting.segments.flatMap { [$0.text, meeting.speakerName($0.speaker)] }
        if let notes = meeting.notes {
            fields.append(notes.summary)
            fields += (notes.decisions + notes.questions + notes.ideas).map(\.text)
            fields += notes.actions.flatMap { [$0.text, $0.owner ?? "", $0.due ?? ""] }
            fields += notes.topics.flatMap { [$0.title, $0.text] }
        }
        let content = normalized(fields.joined(separator: "\n"))
        return words.allSatisfy(content.contains)
    }
}
