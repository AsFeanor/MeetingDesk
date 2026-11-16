import SwiftUI

struct MeetingArchiveQuestionView: View {
    let meetings: [Meeting]
    var scopes: [ArchiveQuestionScope] = []
    let isBusy: Bool
    var canNavigate = true
    let onAsk: (String, Set<UUID>?) async throws -> ArchiveAnswer
    let onOpenSource: (UUID, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @FocusState private var questionFocused: Bool
    @State private var question = ""
    @State private var scopeID = "all"
    @State private var answer: ArchiveAnswer?
    @State private var answerIsCurrent = false
    @State private var submitting = false
    @State private var failure: String?
    @State private var requestID = UUID()
    @State private var validationID = UUID()
    @State private var askTask: Task<Void, Never>?
    @State private var validationTask: Task<Void, Never>?

    private var availableScopes: [ArchiveQuestionScope] {
        var seen: Set<String> = [ArchiveQuestionScope.all.id]
        return [.all] + scopes.filter { seen.insert($0.id).inserted }
    }
    private var selectedScope: ArchiveQuestionScope {
        availableScopes.first { $0.id == scopeID } ?? .all
    }
    private var canAsk: Bool {
        !submitting && !isBusy && !question.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && question.utf8.count <= ArchiveQuestionIndex.maximumQuestionBytes
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(WorkspaceStyle.border)
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Kapsam").font(.system(size: 11, weight: .medium)).foregroundStyle(WorkspaceStyle.muted)
                    Picker("Aranacak toplantılar", selection: $scopeID) {
                        ForEach(availableScopes) { scope in Text(scope.title).tag(scope.id) }
                    }.labelsHidden().frame(maxWidth: 360).disabled(submitting)
                    Spacer()
                }
                HStack(alignment: .bottom, spacing: 12) {
                    TextField("Örneğin: Müşteri sunumu için ne kararlaştırdık?", text: $question, axis: .vertical)
                        .textFieldStyle(.plain).font(.system(size: 14)).lineLimit(2...4)
                        .focused($questionFocused).onSubmit { submit() }
                        .accessibilityLabel("Toplantı geçmişine sor")
                    Button(action: submit) {
                        Label(submitting ? "Yanıtlanıyor…" : "Sor", systemImage: "arrow.up")
                    }.buttonStyle(WorkspaceQuietButtonStyle()).disabled(!canAsk)
                        .keyboardShortcut(.return, modifiers: .command)
                }.padding(14)
                    .background(WorkspaceStyle.canvas, in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(WorkspaceStyle.border))
                Text("Sor’a bastığında ilgili konuşma bölümleri Mac’teki yerel modelle değerlendirilir. Yanıtın altındaki toplantı ve zaman bağlantılarından kaynağı açabilirsin.")
                    .font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(3)
            }.padding(20)
            Divider().overlay(WorkspaceStyle.border)
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if submitting {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            Text("Seçili kaynaklarda soruna yanıt aranıyor…").font(.system(size: 12))
                        }.padding(.vertical, 20)
                    }
                    if let failure {
                        Label(failure, systemImage: "exclamationmark.triangle")
                            .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.recording)
                    }
                    if let answer {
                        if answerIsCurrent {
                            answerBody(answer)
                        } else {
                            Label("Kaynaklar değişti veya güncelliği kontrol ediliyor. Yanıtı güncel kaynaklarla yeniden sor.", systemImage: "arrow.clockwise")
                                .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
                        }
                    } else if !submitting && failure == nil {
                        VStack(alignment: .leading, spacing: 9) {
                            Text("Geçmiş konuşmalarını hatırla").font(.system(size: 16, weight: .semibold))
                            Text("Bir karar, konuşulan bir konu veya açıkça verilen bir söz hakkında sor. Yeterli kaynak bulunamazsa yanıt üretilmez.")
                                .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(4)
                        }.padding(.vertical, 30)
                    }
                }.frame(maxWidth: .infinity, alignment: .leading).padding(20)
            }
        }
        .frame(minWidth: 620, idealWidth: 720, minHeight: 520, idealHeight: 650)
        .background(WorkspaceStyle.surface).foregroundStyle(WorkspaceStyle.ink)
        .task { questionFocused = true }
        .onChange(of: meetings) { _, _ in validateAnswer() }
        .onChange(of: scopeID) { _, _ in clearAnswer() }
        .onChange(of: availableScopes) { _, scopes in
            if !scopes.contains(where: { $0.id == scopeID }) { scopeID = "all" }
            clearAnswer()
        }
        .onDisappear { askTask?.cancel(); validationTask?.cancel() }
    }

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "text.bubble").font(.system(size: 19)).foregroundStyle(WorkspaceStyle.accent)
            VStack(alignment: .leading, spacing: 3) {
                Text("Toplantı geçmişine sor").font(.system(size: 17, weight: .semibold))
                Text("Yerel yanıt · toplantı ve zaman kaynakları").font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
            }
            Spacer()
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.system(size: 11, weight: .semibold)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).keyboardShortcut(.cancelAction).accessibilityLabel("Kapat")
        }.padding(20)
    }

    @ViewBuilder
    private func answerBody(_ answer: ArchiveAnswer) -> some View {
        Text(answer.question).font(.system(size: 14, weight: .semibold)).textSelection(.enabled)
        if answer.abstained {
            Label(answer.abstentionMessage, systemImage: "doc.text.magnifyingglass")
                .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
        } else {
            ForEach(answer.paragraphs) { paragraph in
                VStack(alignment: .leading, spacing: 10) {
                    Text(paragraph.text).font(.system(size: 13)).lineSpacing(4).textSelection(.enabled)
                    VStack(alignment: .leading, spacing: 7) {
                        Text("“\(paragraph.quote)”").font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                            .lineSpacing(3).textSelection(.enabled)
                        Button {
                            // Recheck immediately on explicit source navigation as well as after archive changes.
                            guard canNavigate, answer.isCurrent(in: meetings) else {
                                answerIsCurrent = false; return
                            }
                            onOpenSource(paragraph.source.meetingID, paragraph.source.segmentID)
                        } label: {
                            Label("\(paragraph.source.meetingTitle) · \(paragraph.source.meetingDate.formatted(date: .abbreviated, time: .omitted)) · \(timeLabel(paragraph.source.start))", systemImage: "play.circle")
                                .font(.system(size: 11, weight: .medium)).multilineTextAlignment(.leading)
                        }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(!canNavigate)
                            .accessibilityLabel("Kaynağı aç: \(paragraph.source.meetingTitle), \(timeLabel(paragraph.source.start))")
                    }.padding(12).frame(maxWidth: .infinity, alignment: .leading)
                        .background(WorkspaceStyle.canvas, in: RoundedRectangle(cornerRadius: 9))
                }
            }
        }
        VStack(alignment: .leading, spacing: 5) {
            Text(answer.disclosure)
            if answer.context.omittedOversizedPassageCount > 0 {
                Text("\(answer.context.omittedOversizedPassageCount) uzun konuşma bölümü kısaltılmadan dışarıda bırakıldı.")
            }
            if !answer.abstained { Text("Yanıt, alıntıların model tarafından yorumudur. Ayrıntı ve bağlam için kaynak konuşmayı kontrol edebilirsin.") }
        }.font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(3)
    }

    private func submit() {
        guard canAsk else { return }
        let id = UUID(); requestID = id
        let submittedQuestion = question.trimmingCharacters(in: .whitespacesAndNewlines)
        let submittedScope = selectedScope.meetingIDs
        submitting = true; failure = nil; answer = nil; answerIsCurrent = false
        askTask = Task {
            defer { if requestID == id { submitting = false } }
            do {
                let result = try await onAsk(submittedQuestion, submittedScope)
                try Task.checkCancellation()
                guard requestID == id else { return }
                answer = result
                validateAnswer()
            } catch is CancellationError { }
            catch {
                guard requestID == id else { return }
                failure = error.localizedDescription
            }
        }
    }

    private func clearAnswer() {
        requestID = UUID(); askTask?.cancel(); submitting = false
        answer = nil; answerIsCurrent = false; failure = nil
        validationTask?.cancel(); validationID = UUID()
    }

    private func validateAnswer() {
        validationTask?.cancel(); answerIsCurrent = false
        guard let answer else { return }
        let id = UUID(); validationID = id
        let snapshot = meetings
        validationTask = Task {
            let valid = await Task.detached(priority: .utility) { answer.isCurrent(in: snapshot) }.value
            guard !Task.isCancelled, validationID == id, self.answer?.id == answer.id else { return }
            answerIsCurrent = valid
        }
    }
}
