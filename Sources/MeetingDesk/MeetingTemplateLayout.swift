import Foundation

enum MeetingNotesSectionKind: String, CaseIterable {
    case summary, decisions, actions, questions, ideas, contexts
}

struct MeetingTemplateContextSection: Identifiable {
    let id: String
    let title: String
    let englishTitle: String
    let guidance: String
    func label(english: Bool) -> String { english ? englishTitle : title }
}

extension MeetingTemplate {
    var contextSections: [MeetingTemplateContextSection] {
        let other = MeetingTemplateContextSection(id: "other", title: "Diğer konular", englishTitle: "Other discussion",
            guidance: "Other supported context that does not fit the template's focused sections; never discard relevant discussion.")
        switch self {
        case .general:
            return [.init(id: "discussion", title: "Konuşulan konular", englishTitle: "Discussion topics",
                          guidance: "Group the supported discussion context by subject without treating it as an accepted decision.")]
        case .team:
            return [.init(id: "progress", title: "Durum ve ilerleme", englishTitle: "Status and progress",
                          guidance: "Explicitly reported work, current status and progress; distinguish completed work from plans."),
                    .init(id: "blockers", title: "Engeller ve bağımlılıklar", englishTitle: "Blockers and dependencies",
                          guidance: "Explicit obstacles, dependencies and help needed; do not invent risks or dependencies."), other]
        case .product:
            return [.init(id: "needs", title: "İhtiyaçlar ve problemler", englishTitle: "Needs and problems",
                          guidance: "Stated user needs and concrete product problems; no invented personas or priorities."),
                    .init(id: "feedback", title: "Ürün geri bildirimleri", englishTitle: "Product feedback",
                          guidance: "Observed or stated product feedback and its context; distinguish opinions from verified results."),
                    .init(id: "alternatives", title: "Seçenekler ve değerlendirmeler", englishTitle: "Options and trade-offs",
                          guidance: "Discussed alternatives and explicit trade-offs; an option is not a selected roadmap or promise."), other]
        case .customer:
            return [.init(id: "needs", title: "Müşteri ihtiyaçları", englishTitle: "Customer needs",
                          guidance: "Needs and requests stated by the customer, preserving their uncertainty; no inferred commercial terms."),
                    .init(id: "concerns", title: "Endişeler ve beklentiler", englishTitle: "Concerns and expectations",
                          guidance: "Explicit customer concerns and expectations; do not turn requests into accepted commitments."), other]
        }
    }

    var sectionOrder: [MeetingNotesSectionKind] {
        switch self {
        case .general: return [.summary, .decisions, .actions, .questions, .ideas, .contexts]
        case .team: return [.summary, .contexts, .actions, .decisions, .questions, .ideas]
        case .product: return [.summary, .contexts, .decisions, .ideas, .questions, .actions]
        case .customer: return [.summary, .contexts, .questions, .actions, .decisions, .ideas]
        }
    }

    func summaryTitle(english: Bool) -> String {
        switch self {
        case .general: return english ? "Meeting summary" : "Toplantı özeti"
        case .team: return english ? "Team status summary" : "Ekip durum özeti"
        case .product: return english ? "Product review summary" : "Ürün değerlendirme özeti"
        case .customer: return english ? "Customer conversation summary" : "Müşteri görüşmesi özeti"
        }
    }
    func decisionsTitle(english: Bool) -> String {
        switch self {
        case .product: return english ? "Accepted product decisions" : "Kabul edilen ürün kararları"
        case .customer: return english ? "Agreed outcomes" : "Kabul edilen sonuçlar"
        default: return english ? "Decisions" : "Kararlar"
        }
    }
    func actionsTitle(english: Bool) -> String {
        switch self {
        case .team: return english ? "Next steps" : "Sonraki adımlar"
        case .customer: return english ? "Explicit commitments and follow-up" : "Verilen sözler ve takip"
        default: return english ? "Actions" : "Aksiyonlar"
        }
    }
    func questionsTitle(english: Bool) -> String {
        switch self {
        case .product: return english ? "Open product questions" : "Açık ürün soruları"
        case .customer: return english ? "Customer questions awaiting answers" : "Yanıt bekleyen müşteri soruları"
        default: return english ? "Open questions" : "Açık sorular"
        }
    }
    func ideasTitle(english: Bool) -> String { english ? "Ideas under consideration" : "Değerlendirilen fikirler" }

    var generationGuidance: String {
        let emphasis: String
        switch self {
        case .general: emphasis = "The summary should cover the discussion, explicitly accepted outcomes and unresolved issues in a balanced way."
        case .team: emphasis = "The summary should lead with explicitly reported progress/current status, then stated blockers or dependencies and accepted next steps. Do not use a generic chronological recap."
        case .product: emphasis = "The summary should lead with stated user needs/problems and product feedback, then compare discussed options and distinguish accepted product decisions from open questions. Do not use a generic chronological recap."
        case .customer: emphasis = "The summary should lead with the customer's stated needs and concerns, then distinguish questions/requests from explicit commitments and follow-up. Do not use a generic chronological recap."
        }
        let groups = contextSections.map { "\($0.id): \($0.guidance)" }.joined(separator: "\n")
        return """
        Meeting template: \(rawValue). \(emphasis)
        Generate structured context topics for this template. For every topic, sectionID must be one of: \(contextSections.map(\.id).joined(separator: ", ")). Use sectionID to classify the topic, a short descriptive title, and evidence from the supplied source entries. Section descriptions:
        \(groups)
        Leave sections without supported information empty; never fill an empty section with assumptions. Keep agreed decisions/actions and unresolved questions in their own original categories. Never infer owners, dates, agreement, or identities. Never infer priorities or commitments from a template.
        """
    }
}
