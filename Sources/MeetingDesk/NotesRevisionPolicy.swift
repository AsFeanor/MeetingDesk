import Foundation

struct EvidenceNoteEdit: Codable, Equatable {
    var original: EvidenceItem?
    var value: EvidenceItem?
}

enum ActionNoteField: String, Codable, Hashable { case text, owner, due }

struct ActionNoteEdit: Codable, Equatable {
    var original: ActionItem?
    var value: ActionItem?
    var fields: Set<ActionNoteField>
}

enum TopicNoteField: String, Codable, Hashable { case title, text }

struct TopicNoteEdit: Codable, Equatable {
    var original: TopicNote?
    var value: TopicNote?
    var fields: Set<TopicNoteField>
}

/// Original model output remains alongside each correction, so a new model ID
/// cannot erase a user's wording or move a correction to an unrelated item.
struct NotesManualEdits: Codable, Equatable {
    var summary: String?
    // Missing provenance belongs to the legacy general-template summary.
    var summaryTemplateRawValue: String?
    var decisions: [EvidenceNoteEdit] = []
    var actions: [ActionNoteEdit] = []
    var questions: [EvidenceNoteEdit] = []
    var ideas: [EvidenceNoteEdit] = []
    var topics: [TopicNoteEdit] = []

    var isEmpty: Bool {
        summary == nil && decisions.isEmpty && actions.isEmpty && questions.isEmpty && ideas.isEmpty && topics.isEmpty
    }
}

enum NotesRevisionPolicy {
    static func applyEdits(to meeting: Meeting, editedNotes: MeetingNotes, at: Date = Date()) -> Meeting {
        guard let existing = meeting.notes else { return meeting }
        var result = meeting
        var edited = editedNotes
        // Evidence is read-only in the editor and is also enforced at this boundary.
        edited.decisions = preserveEvidence(edited.decisions, originals: existing.decisions)
        edited.questions = preserveEvidence(edited.questions, originals: existing.questions)
        edited.ideas = preserveEvidence(edited.ideas, originals: existing.ideas)
        for index in edited.actions.indices {
            if let original = existing.actions.first(where: { $0.id == edited.actions[index].id }) {
                edited.actions[index].evidence = original.evidence
            } else {
                edited.actions[index].evidence = []
            }
            edited.actions[index].owner = optionalText(edited.actions[index].owner)
            edited.actions[index].due = optionalText(edited.actions[index].due)
        }
        for index in edited.topics.indices {
            let original = existing.topics.first { $0.id == edited.topics[index].id }
            edited.topics[index].evidence = original?.evidence ?? []
            edited.topics[index].sectionID = original?.sectionID
        }
        guard edited != existing else { return result }
        var edits = meeting.notesManualEdits ?? NotesManualEdits()
        if edited.summary != existing.summary {
            // An older correction may already be visible as a separate topic.
            // Keep it when the user replaces the active template's summary.
            if let previousSummary = edits.summary,
               template(edits.summaryTemplateRawValue) != template(meeting.notesTemplateRawValue),
               let preserved = existing.topics.first(where: {
                   $0.text == previousSummary && $0.evidence.isEmpty && $0.sectionID == nil
               }), !edits.topics.contains(where: { $0.value?.id == preserved.id }) {
                edits.topics.append(TopicNoteEdit(original: nil, value: preserved, fields: [.title, .text]))
            }
            edits.summary = edited.summary
            edits.summaryTemplateRawValue = template(meeting.notesTemplateRawValue).rawValue
        }
        edits.decisions = recordEvidenceEdits(previous: existing.decisions, edited: edited.decisions, tracked: edits.decisions)
        edits.questions = recordEvidenceEdits(previous: existing.questions, edited: edited.questions, tracked: edits.questions)
        edits.ideas = recordEvidenceEdits(previous: existing.ideas, edited: edited.ideas, tracked: edits.ideas)
        edits.actions = recordActionEdits(previous: existing.actions, edited: edited.actions, tracked: edits.actions)
        edits.topics = recordTopicEdits(previous: existing.topics, edited: edited.topics, tracked: edits.topics)
        result.notes = edited
        result.notesManualEdits = edits.isEmpty ? nil : edits
        result.completedActions.formIntersection(Set(edited.actions.map(\.id)))
        result.reviewedAt = nil
        return result
    }

    static func reconcileGenerated(_ generated: MeetingNotes, into meeting: Meeting,
                                   engine: String? = nil, at: Date = Date()) -> Meeting {
        var result = meeting
        var notes = generated
        var edits = meeting.notesManualEdits ?? NotesManualEdits()
        let generatedTemplate = meeting.template
        let changedTemplate = template(meeting.notesTemplateRawValue) != generatedTemplate
        var usedIDs = Set(allIDs(notes))
        if let summary = edits.summary {
            if template(edits.summaryTemplateRawValue) == generatedTemplate {
                notes.summary = summary
            } else {
                // A correction for another template must not replace this
                // template's fresh summary or disappear from the document.
                notes.topics.append(TopicNote(id: availableID("manual-summary-preserved", usedIDs: &usedIDs),
                    title: meeting.outputLanguage == "English" ? "Preserved summary correction" : "Korunan özet düzeltmesi",
                    text: summary, evidence: [], sectionID: nil))
            }
        }
        mergeEvidence(&notes.decisions, edits: &edits.decisions, usedIDs: &usedIDs)
        mergeEvidence(&notes.questions, edits: &edits.questions, usedIDs: &usedIDs)
        mergeEvidence(&notes.ideas, edits: &edits.ideas, usedIDs: &usedIDs)
        let actionMappings = mergeActions(&notes.actions, edits: &edits.actions, usedIDs: &usedIDs)
        mergeTopics(&notes.topics, edits: &edits.topics, usedIDs: &usedIDs, changedTemplate: changedTemplate)
        var completed = Set<String>()
        var matched = Set<Int>()
        for old in meeting.notes?.actions ?? [] where meeting.completedActions.contains(old.id) {
            if let mapped = actionMappings[old.id], let index = notes.actions.firstIndex(where: { $0.id == mapped }) {
                completed.insert(mapped)
                matched.insert(index)
                continue
            }
            if let index = bestMatch(text: old.text, evidence: old.evidence, in: notes.actions.map { ($0.text, $0.evidence) }, excluding: matched) {
                completed.insert(notes.actions[index].id)
                matched.insert(index)
            } else {
                // Completed work stays visible even when fresh output omits it.
                var retained = old
                retained.id = availableID(old.id, usedIDs: &usedIDs)
                notes.actions.append(retained)
                completed.insert(retained.id)
                matched.insert(notes.actions.count - 1)
            }
        }
        result.notes = notes
        result.notesManualEdits = edits.isEmpty ? nil : edits
        result.completedActions = completed
        let sourceIDs = Set(meeting.segments.map(\.id))
        result.notesNeedRefresh = allEvidence(notes).contains { !sourceIDs.contains($0) }
        result.notesEngine = engine ?? meeting.notesEngine
        result.notesTemplateRawValue = generatedTemplate.rawValue
        result.reviewedAt = nil
        return result
    }

    static func markReviewed(_ meeting: Meeting, at: Date = Date()) -> Meeting {
        var result = meeting
        guard result.notes != nil, !result.notesNeedRefresh else { return result }
        result.reviewedAt = at
        return result
    }

    static func invalidateReview(_ meeting: Meeting) -> Meeting {
        var result = meeting
        result.reviewedAt = nil
        return result
    }

    private static func optionalText(_ value: String?) -> String? {
        let text = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return text.isEmpty ? nil : text
    }

    private static func template(_ value: String?) -> MeetingTemplate {
        MeetingTemplate(rawValue: value ?? "") ?? .general
    }

    private static func preserveEvidence(_ values: [EvidenceItem], originals: [EvidenceItem]) -> [EvidenceItem] {
        values.map { value in
            var item = value
            item.evidence = originals.first { $0.id == value.id }?.evidence ?? []
            return item
        }
    }

    private static func recordEvidenceEdits(previous: [EvidenceItem], edited: [EvidenceItem], tracked: [EvidenceNoteEdit]) -> [EvidenceNoteEdit] {
        var result = tracked
        for old in previous {
            let new = edited.first { $0.id == old.id }
            guard new != old else { continue }
            if let index = result.firstIndex(where: { $0.value?.id == old.id }) {
                result[index].value = new
            } else { result.append(EvidenceNoteEdit(original: old, value: new)) }
        }
        for new in edited where !previous.contains(where: { $0.id == new.id }) {
            result.append(EvidenceNoteEdit(original: nil, value: new))
        }
        return result.filter { $0.original != $0.value }
    }

    private static func recordActionEdits(previous: [ActionItem], edited: [ActionItem], tracked: [ActionNoteEdit]) -> [ActionNoteEdit] {
        var result = tracked
        for old in previous {
            let new = edited.first { $0.id == old.id }
            guard new != old else { continue }
            if let index = result.firstIndex(where: { $0.value?.id == old.id }) {
                result[index].value = new
                result[index].fields.formUnion(changedFields(old, new))
            } else {
                result.append(ActionNoteEdit(original: old, value: new, fields: changedFields(old, new)))
            }
        }
        for new in edited where !previous.contains(where: { $0.id == new.id }) {
            result.append(ActionNoteEdit(original: nil, value: new, fields: [.text, .owner, .due]))
        }
        return result.filter { $0.original != $0.value }
    }

    private static func changedFields(_ old: ActionItem, _ new: ActionItem?) -> Set<ActionNoteField> {
        guard let new else { return [.text, .owner, .due] }
        var fields = Set<ActionNoteField>()
        if old.text != new.text { fields.insert(.text) }
        if old.owner != new.owner { fields.insert(.owner) }
        if old.due != new.due { fields.insert(.due) }
        return fields
    }

    private static func recordTopicEdits(previous: [TopicNote], edited: [TopicNote], tracked: [TopicNoteEdit]) -> [TopicNoteEdit] {
        var result = tracked
        for old in previous {
            let new = edited.first { $0.id == old.id }
            guard new != old else { continue }
            var fields = Set<TopicNoteField>()
            if old.title != new?.title { fields.insert(.title) }
            if old.text != new?.text { fields.insert(.text) }
            if let index = result.firstIndex(where: { $0.value?.id == old.id }) {
                result[index].value = new
                result[index].fields.formUnion(fields)
            } else { result.append(TopicNoteEdit(original: old, value: new, fields: fields)) }
        }
        for new in edited where !previous.contains(where: { $0.id == new.id }) {
            result.append(TopicNoteEdit(original: nil, value: new, fields: [.title, .text]))
        }
        return result.filter { $0.original != $0.value }
    }

    private static func mergeEvidence(_ items: inout [EvidenceItem], edits: inout [EvidenceNoteEdit], usedIDs: inout Set<String>) {
        var matched = Set<String>()
        for index in edits.indices {
            let edit = edits[index]
            let original = edit.original ?? edit.value
            let candidates = items.map { ($0.text, $0.evidence) }
            let excluded = Set(items.indices.filter { matched.contains(items[$0].id) })
            let match = original.flatMap { bestMatch(text: $0.text, evidence: $0.evidence, in: candidates, excluding: excluded) }
            if let match {
                let id = items[match].id
                matched.insert(id)
                if var value = edit.value {
                    value.id = id
                    items[match] = value
                    edits[index].value = value
                } else { items.remove(at: match) }
            } else if var value = edit.value {
                value.id = availableID(value.id, usedIDs: &usedIDs)
                items.append(value)
                matched.insert(value.id)
                edits[index].value = value
            }
        }
    }

    private static func mergeActions(_ items: inout [ActionItem], edits: inout [ActionNoteEdit], usedIDs: inout Set<String>) -> [String: String] {
        var mappings: [String: String] = [:]
        var matched = Set<String>()
        for index in edits.indices {
            let edit = edits[index]
            let original = edit.original ?? edit.value
            let excluded = Set(items.indices.filter { matched.contains(items[$0].id) })
            let match = original.flatMap { bestMatch(text: $0.text, evidence: $0.evidence, in: items.map { ($0.text, $0.evidence) }, excluding: excluded) }
            if let match {
                matched.insert(items[match].id)
                guard var value = edit.value else { items.remove(at: match); continue }
                var item = items[match]
                if edit.fields.contains(.text) { item.text = value.text }
                if edit.fields.contains(.owner) { item.owner = value.owner }
                if edit.fields.contains(.due) { item.due = value.due }
                item.evidence = value.evidence
                value = item
                items[match] = item
                edits[index].value = value
                if let oldID = edit.value?.id { mappings[oldID] = item.id }
            } else if var value = edit.value {
                value.id = availableID(value.id, usedIDs: &usedIDs)
                items.append(value)
                matched.insert(value.id)
                edits[index].value = value
                if let oldID = edit.value?.id { mappings[oldID] = value.id }
            }
        }
        return mappings
    }

    private static func mergeTopics(_ items: inout [TopicNote], edits: inout [TopicNoteEdit], usedIDs: inout Set<String>,
                                    changedTemplate: Bool) {
        var matched = Set<String>()
        for index in edits.indices {
            let edit = edits[index]
            let original = edit.original ?? edit.value
            let excluded = Set(items.indices.filter { matched.contains(items[$0].id) })
            let match = original.flatMap { bestMatch(text: $0.text, evidence: $0.evidence, in: items.map { ($0.text, $0.evidence) }, excluding: excluded) }
            if let match {
                matched.insert(items[match].id)
                guard let value = edit.value else { items.remove(at: match); continue }
                var item = items[match]
                if edit.fields.contains(.title) { item.title = value.title }
                if edit.fields.contains(.text) { item.text = value.text }
                item.evidence = value.evidence
                items[match] = item
                edits[index].value = item
            } else if var value = edit.value {
                value.id = availableID(value.id, usedIDs: &usedIDs)
                if changedTemplate { value.sectionID = nil }
                items.append(value)
                matched.insert(value.id)
                edits[index].value = value
            }
        }
    }

    /// Similar word sets can hide cancelled actions, reversed roles or different
    /// amounts. Only exact wording after case/whitespace normalization can match,
    /// with source overlap when sources exist. Uncertainty stays separate.
    private static func bestMatch(text: String, evidence: [String], in candidates: [(String, [String])], excluding: Set<Int> = []) -> Int? {
        let normalized = normalize(text)
        guard !normalized.isEmpty else { return nil }
        let sources = Set(evidence)
        var matches: [Int] = []
        for (index, candidate) in candidates.enumerated() where !excluding.contains(index) {
            let other = normalize(candidate.0)
            let sourceOverlap = !sources.intersection(candidate.1).isEmpty
            let compatibleSources = sources.isEmpty ? candidate.1.isEmpty : sourceOverlap
            if other == normalized, compatibleSources {
                matches.append(index)
            }
        }
        guard matches.count == 1 else { return nil }
        return matches[0]
    }

    private static func normalize(_ text: String) -> String {
        let folded = text.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
        return folded.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    private static func availableID(_ preferred: String, usedIDs: inout Set<String>) -> String {
        if !preferred.isEmpty, usedIDs.insert(preferred).inserted { return preferred }
        let id = "manual-\(UUID().uuidString)"
        usedIDs.insert(id)
        return id
    }

    private static func allIDs(_ notes: MeetingNotes) -> [String] {
        notes.decisions.map(\.id) + notes.actions.map(\.id) + notes.questions.map(\.id) + notes.ideas.map(\.id) + notes.topics.map(\.id)
    }

    private static func allEvidence(_ notes: MeetingNotes) -> [String] {
        (notes.decisions + notes.questions + notes.ideas).flatMap(\.evidence)
            + notes.actions.flatMap(\.evidence) + notes.topics.flatMap(\.evidence)
    }
}
