import Foundation

/// A note keeps the layout it was generated with until regeneration succeeds.
/// All sharing formats and the overview consume this same section order.
struct MeetingNotesPresentation {
    let template: MeetingTemplate
    let english: Bool
    let sections: [MeetingNotesPresentedSection]
    let templateChangeMessage: String?

    init(meeting: Meeting) {
        template = MeetingTemplate(rawValue: meeting.notesTemplateRawValue ?? "") ?? .general
        english = meeting.outputLanguage == "English"
        guard let notes = meeting.notes else {
            sections = []
            templateChangeMessage = nil
            return
        }

        if template != meeting.template {
            templateChangeMessage = "Mevcut not \(template.label.lowercased()) düzeninde. Seçtiğin \(meeting.template.label.lowercased()) düzeni için ‘Özeti yenile’yi kullan."
        } else {
            templateChangeMessage = nil
        }

        sections = Self.sections(notes: notes, template: template, english: english)
    }

    static func sections(notes: MeetingNotes, template: MeetingTemplate,
                         english: Bool) -> [MeetingNotesPresentedSection] {
        var result: [MeetingNotesPresentedSection] = []
        for kind in template.sectionOrder {
            switch kind {
            case .summary:
                result.append(.init(id: "summary", kind: kind, title: template.summaryTitle(english: english)))
            case .decisions:
                if !notes.decisions.isEmpty {
                    result.append(.init(id: "decisions", kind: kind, title: template.decisionsTitle(english: english)))
                }
            case .actions:
                result.append(.init(id: "actions", kind: kind, title: template.actionsTitle(english: english)))
            case .questions:
                if !notes.questions.isEmpty {
                    result.append(.init(id: "questions", kind: kind, title: template.questionsTitle(english: english)))
                }
            case .ideas:
                if !notes.ideas.isEmpty {
                    result.append(.init(id: "ideas", kind: kind, title: template.ideasTitle(english: english)))
                }
            case .contexts:
                let focusedSections = template.contextSections.filter { $0.id != "other" }
                let knownIDs = Set(focusedSections.map(\.id))
                for context in focusedSections {
                    let topics = notes.topics.filter { $0.sectionID == context.id }
                    // Keep historical general notes compact. Specialized templates
                    // show missing information explicitly instead of fabricating it.
                    guard template != .general || !topics.isEmpty else { continue }
                    result.append(.init(id: "context-" + context.id, kind: kind,
                                        title: english ? context.englishTitle : context.title,
                                        topics: topics,
                                        emptyMessage: topics.isEmpty ? (english ? "No information was recorded for this section." : "Bu başlık için kayda geçmiş bilgi yok.") : nil))
                }
                let other = notes.topics.filter { topic in
                    guard let sectionID = topic.sectionID else { return true }
                    return !knownIDs.contains(sectionID)
                }
                if !other.isEmpty {
                    result.append(.init(id: "context-other", kind: kind,
                                        title: english ? "Other discussion" : "Diğer konular", topics: other))
                }
            }
        }
        return result
    }

    func sections(for scope: MeetingShareScope) -> [MeetingNotesPresentedSection] {
        sections.filter { section in
            switch scope {
            case .summary: return section.kind != .actions
            case .actions: return section.kind == .actions
            case .fullTranscript: return true
            }
        }
    }
}

struct MeetingNotesPresentedSection: Identifiable {
    var id: String
    var kind: MeetingNotesSectionKind
    var title: String
    var topics: [TopicNote] = []
    var emptyMessage: String?
}
