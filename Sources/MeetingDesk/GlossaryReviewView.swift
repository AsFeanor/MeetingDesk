import SwiftUI

struct GlossaryReviewInput: Equatable {
    var meetingID: UUID
    var segments: [TranscriptSegment]
    var entries: [GlossaryEntry]
}

/// Playback publications never enter the cache key or rerun dictionary matching.
@MainActor
final class GlossaryReviewModel: ObservableObject {
    @Published private(set) var suggestions: [GlossarySuggestion] = []
    @Published private(set) var isLoading = false
    private var renderedInput: GlossaryReviewInput?
    private var worker: Task<[GlossarySuggestion], Never>?
    private var token = UUID()
    private(set) var preparationCount = 0

    func update(_ input: GlossaryReviewInput) async {
        let request = UUID(); token = request
        worker?.cancel()
        guard renderedInput != input else { isLoading = false; return }
        // Keep the previous rendered result cached while a different request runs.
        // Returning to it can cancel pending work without publishing an empty list.
        isLoading = true
        preparationCount += 1
        let task = Task.detached(priority: .userInitiated) {
            TranscriptGlossary.suggestions(segments: input.segments, entries: input.entries)
        }
        worker = task
        let result = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        guard !Task.isCancelled, !task.isCancelled, token == request else { return }
        renderedInput = input
        suggestions = result; isLoading = false; worker = nil
    }

    func matches(_ input: GlossaryReviewInput) -> Bool { renderedInput == input && !isLoading }
    func cancel() { token = UUID(); worker?.cancel(); worker = nil; isLoading = false }
}

struct GlossaryReviewView: View {
    @ObservedObject var store: AppStore
    let meetingID: UUID
    var canPlay: (TranscriptSegment) -> Bool
    var onPlay: (TranscriptSegment) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var review = GlossaryReviewModel()
    @State private var selectedSuggestionID: String?
    @State private var localError: String?

    init(store: AppStore, meetingID: UUID, canPlay: @escaping (TranscriptSegment) -> Bool = { _ in true },
         onPlay: @escaping (TranscriptSegment) -> Void) {
        self.store = store; self.meetingID = meetingID; self.canPlay = canPlay; self.onPlay = onPlay
    }

    private var meeting: Meeting? { store.meetings.first { $0.id == meetingID } }
    private var input: GlossaryReviewInput {
        GlossaryReviewInput(meetingID: meetingID, segments: meeting?.segments ?? [], entries: store.glossaryEntries)
    }
    private var active: Bool { meeting != nil && store.selectedID == meetingID }
    private var selected: GlossarySuggestion? {
        guard review.matches(input) else { return nil }
        return review.suggestions.first { $0.id == selectedSuggestionID }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            Label("Sözlük önerilerini incele", systemImage: "text.badge.checkmark").font(.title2.weight(.semibold))
            Text(meeting?.title ?? "Toplantı bulunamadı").font(.headline)
            Text("Bir öneri seç, önceki ve sonraki metni karşılaştır; istersen özgün kaydı dinleyip yalnız bu düzeltmeyi uygula.")
                .font(.callout).foregroundStyle(.secondary)
            if !active {
                Text("Seçili toplantı değişti. Önerileri ilgili toplantıdan yeniden açın.").foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.isLoading || !review.matches(input) {
                ProgressView("Öneriler hazırlanıyor…").frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if review.suggestions.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "text.magnifyingglass").font(.system(size: 32)).foregroundStyle(.secondary)
                    Text(store.glossaryEntries.isEmpty ? "Önce kişisel sözlüğe terim ekle." : "Bu transkriptte kesin bir sözlük eşleşmesi yok.")
                        .font(.headline).multilineTextAlignment(.center)
                    Text("Yalnız tam kelime ve ifadeler önerilir. Belirsiz veya çakışan eşleşmeler atlanır.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack(alignment: .top, spacing: 16) {
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(review.suggestions) { suggestion in suggestionButton(suggestion) }
                        }
                    }.frame(width: 230)
                    Divider()
                    if let selected { preview(selected) }
                    else { Text("Karşılaştırmak için soldan bir öneri seç.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity) }
                }.frame(maxHeight: .infinity)
            }
            if let localError { Text(localError).font(.caption).foregroundStyle(.red) }
            HStack {
                Text("\(review.suggestions.count) tekil öneri").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Kapat") { dismiss() }.buttonStyle(WorkspaceQuietButtonStyle()).keyboardShortcut(.cancelAction)
                if let selected {
                    Button("Yalnız bu düzeltmeyi uygula") {
                        if store.applyGlossarySuggestion(selected, meetingID: meetingID) {
                            selectedSuggestionID = nil; localError = nil
                        } else { localError = store.errorMessage ?? "Düzeltme uygulanamadı." }
                    }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress || !active)
                }
            }
        }
        .padding(26).frame(minWidth: 680, idealWidth: 900, maxWidth: 1100, minHeight: 520, idealHeight: 680, maxHeight: 900)
        .background(WorkspaceStyle.canvas).foregroundStyle(WorkspaceStyle.ink).tint(WorkspaceStyle.accent)
        .task(id: input) { await review.update(input) }
        .onDisappear { review.cancel() }
    }

    private func suggestionButton(_ suggestion: GlossarySuggestion) -> some View {
        Button {
            selectedSuggestionID = suggestion.id; localError = nil
        } label: {
            VStack(alignment: .leading, spacing: 5) {
                Text("\(suggestion.matchedText) → \(suggestion.canonical)").font(.callout.weight(.medium)).multilineTextAlignment(.leading)
                Text("\(timeLabel(suggestion.segment.start)) · \(meeting?.speakerName(suggestion.segment.speaker) ?? suggestion.segment.speaker)")
                    .font(.caption).foregroundStyle(.secondary)
            }.padding(10).frame(maxWidth: .infinity, alignment: .leading)
                .background(selectedSuggestionID == suggestion.id ? WorkspaceStyle.accent.opacity(0.12) : WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 8))
        }.buttonStyle(.plain).accessibilityLabel("\(suggestion.matchedText) yerine \(suggestion.canonical); \(timeLabel(suggestion.segment.start))")
    }

    private func preview(_ suggestion: GlossarySuggestion) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Önce").font(.headline)
                Text(suggestion.beforeText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text("Sonra").font(.headline)
                Text(suggestion.afterText).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                Text("\(timeLabel(suggestion.segment.start)) · \(sourceLabel(suggestion.segment))")
                    .font(.caption).foregroundStyle(.secondary)
                Button("Özgün kaydı dinle", systemImage: "play.circle") { onPlay(suggestion.segment) }
                    .disabled(store.workInProgress || !active || !canPlay(suggestion.segment))
                if !canPlay(suggestion.segment) { Text("Bu parçanın özgün ses kaydı bulunamadı.").font(.caption).foregroundStyle(.secondary) }
                Text("Değişiklik yalnız bu metin parçasına uygulanır. Önceki transkript sürümüne dönebilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func sourceLabel(_ segment: TranscriptSegment) -> String {
        switch segment.audioSource {
        case .microphone: return "Mikrofon"
        case .system: return "Toplantı sesi"
        case .mixed: return "Birleşik kayıt"
        case nil: return "Özgün ses kaynağı"
        }
    }
}
