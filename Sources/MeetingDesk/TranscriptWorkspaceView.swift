import SwiftUI

private enum TranscriptSourceFilter: String, CaseIterable, Identifiable {
    case all, microphone, system, mixed
    var id: String { rawValue }
    var source: SpeakerAudioSource? {
        switch self { case .all: return nil; case .microphone: return .microphone; case .system: return .system; case .mixed: return .mixed }
    }
    var label: String {
        switch self { case .all: return "Tüm sesler"; case .microphone: return "Mikrofon"; case .system: return "Toplantı sesi"; case .mixed: return "Birleşik kayıt" }
    }
}

/// Reading state is a projection. Editing always targets an original segment ID.
struct TranscriptWorkspaceView: View {
    @ObservedObject var store: AppStore
    let meeting: Meeting
    @Binding var query: String
    @Binding var focusedSegmentID: String?
    @Binding var editingSegmentID: String?
    let onReviewSpeaker: (String?) -> Void
    var onReviewTerms: () -> Void = {}
    @State private var sourceFilter: TranscriptSourceFilter = .all
    @State private var flowing = true
    @State private var hideEchoes = true
    @StateObject private var presentation = TranscriptPresentationModel()
    @State private var pendingFocusID: String?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var snapshot: TranscriptPresentationSnapshot? {
        presentation.matches(TranscriptPresentationInput(meeting: meeting)) ? presentation.snapshot : nil
    }
    private var sources: Set<SpeakerAudioSource> { snapshot?.sources ?? [] }
    private var request: TranscriptPresentationRequest {
        TranscriptPresentationRequest(input: TranscriptPresentationInput(meeting: meeting),
            grouping: .init(source: sourceFilter.source, flowing: flowing, hideEchoes: hideEchoes), query: query)
    }
    var body: some View {
        VStack(spacing: 0) {
            if !meeting.segments.isEmpty { searchAndViewControls }
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 16) {
                        if meeting.segments.isEmpty {
                            Text(store.recorder.isRecording ? "Transkript, kayıt bittikten sonra hazırlanır." : "Henüz transkript yok.")
                                .foregroundStyle(WorkspaceStyle.muted).padding(.vertical, 30)
                        } else {
                            MeetingSpeakerControls(store: store, meeting: meeting, onReview: onReviewSpeaker)
                            if snapshot == nil {
                                HStack { ProgressView().controlSize(.small); Text("Konuşma görünümü hazırlanıyor…").font(.caption).foregroundStyle(WorkspaceStyle.muted) }
                            } else if presentation.rows.isEmpty {
                                Label("Bu görünümde eşleşen konuşma yok.", systemImage: "text.magnifyingglass")
                                    .font(.callout).foregroundStyle(WorkspaceStyle.muted).padding(.vertical, 18)
                            } else {
                                ForEach(presentation.rows) { row in conversationCard(row).id(row.id) }
                            }
                        }
                    }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
                }
                .onChange(of: focusedSegmentID) { _, value in pendingFocusID = value; revealFocus(proxy) }
                .onChange(of: presentation.revision) { _, _ in if pendingFocusID != nil { revealFocus(proxy) } }
                .onAppear { pendingFocusID = focusedSegmentID; revealFocus(proxy) }
            }
        }
        .background(WorkspaceStyle.canvas)
        .foregroundStyle(WorkspaceStyle.ink)
        .tint(WorkspaceStyle.accent)
        .task(id: request) { await presentation.update(request) }
        .onDisappear { presentation.cancel() }
    }

    private var searchAndViewControls: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceStyle.muted)
                TextField("Bu transkriptte ara…", text: $query).textFieldStyle(.plain)
                    .accessibilityLabel("Transkriptte metin veya konuşmacı ara")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill") }.buttonStyle(.plain).accessibilityLabel("Aramayı temizle")
                }
                if sources.count > 1 {
                    Picker("Ses kaynağı", selection: $sourceFilter) {
                        ForEach(TranscriptSourceFilter.allCases.filter { $0.source == nil || sources.contains($0.source!) }) {
                            Text($0.label).tag($0)
                        }
                    }.labelsHidden().frame(width: 138)
                }
            }.font(.system(size: 12)).padding(12).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border))
            HStack(spacing: 14) {
                Picker("Metin görünümü", selection: $flowing) {
                    Text("Akıcı").tag(true); Text("Parçalar").tag(false)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 170)
                Button("Yazım önerileri", systemImage: "text.badge.checkmark", action: onReviewTerms)
                    .buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(store.workInProgress)
                Spacer(minLength: 0)
                if snapshot?.hiddenSegmentIDs.isEmpty == false {
                    Toggle("Çift yazılanları gizle", isOn: $hideEchoes).toggleStyle(.checkbox)
                        .disabled(sourceFilter != .all).help("Yalnız Tüm sesler görünümünde yinelenen mikrofon metnini süzer. Özgün metin korunur.")
                }
            }.font(.system(size: 11))
            if let hidden = snapshot?.hiddenSegmentIDs, !hidden.isEmpty, hideEchoes && sourceFilter == .all {
                Text("\(hidden.count) çift mikrofon parçası bu görünümde gizli. Tüm parçalar ve ses kayıtları korunuyor.")
                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
            }
        }.padding(.horizontal, 28).padding(.top, 18)
    }

    private func conversationCard(_ row: TranscriptPresentationRow) -> some View {
        let block = row.block
        let editing = editingSegmentID.map(row.sourceIDs.contains) == true
        let focused = focusedSegmentID.map(row.sourceIDs.contains) == true
        let name = row.name
        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                if !flowing { WorkspaceAvatar(name: name, size: 28) }
                VStack(alignment: .leading, spacing: 3) {
                    Text(name).font(.system(size: 12, weight: .semibold))
                    Text(sourceLabel(block.source)).font(.system(size: 9)).foregroundStyle(WorkspaceStyle.muted)
                }
                Button(timeLabel(block.start)) { store.seek(block.start) }.buttonStyle(.plain)
                    .foregroundStyle(WorkspaceStyle.accent).font(.system(size: 10).monospacedDigit())
                Spacer(minLength: 0)
                if row.canReview {
                    Button("Bu kim?") { onReviewSpeaker(block.speaker) }.font(.caption).disabled(store.workInProgress)
                }
                Button(editing ? "Bitti" : "Düzelt") { editingSegmentID = editing ? nil : block.id }
                    .font(.caption).disabled(store.workInProgress)
            }
            if editing {
                ForEach(block.segments) { segment in originalSegmentEditor(segment) }
            } else {
                Text(row.text).font(.system(size: 14)).lineSpacing(6).textSelection(.enabled)
            }
        }.padding(.horizontal, flowing ? 4 : 18).padding(.vertical, flowing ? 8 : 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(focused ? WorkspaceStyle.accent.opacity(0.07) : flowing ? Color.clear : WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(focused ? WorkspaceStyle.accent.opacity(0.4) : WorkspaceStyle.border.opacity(flowing ? 0 : 0.6)))
    }

    private func originalSegmentEditor(_ segment: TranscriptSegment) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(timeLabel(segment.start)).font(.system(size: 10).monospacedDigit()).foregroundStyle(WorkspaceStyle.muted)
            if meeting.speakerRecognitionEngine != nil {
                SpeakerAssignmentPicker(store: store, meeting: meeting, segment: segment)
            } else if meeting.transcriptionEngine == ProcessingMode.local.rawValue {
                TextField("Bu bölümün konuşmacısı", text: Binding(get: {
                    store.meetings.first { $0.id == meeting.id }?.segments.first { $0.id == segment.id }?.speaker ?? segment.speaker
                }, set: { store.nameLocalSpeaker(meetingID: meeting.id, segmentID: segment.id, name: $0) }))
                    .textFieldStyle(.roundedBorder)
            }
            TextEditor(text: Binding(get: {
                store.meetings.first { $0.id == meeting.id }?.segments.first { $0.id == segment.id }?.text ?? segment.text
            }, set: { value in
                store.update(meeting.id) { item in
                    if let index = item.segments.firstIndex(where: { $0.id == segment.id }) {
                        item.segments[index].text = value
                        item.segments[index].words = nil
                        item.notesNeedRefresh = item.notes != nil
                    }
                }
            })).frame(minHeight: 90).font(.body)
        }.disabled(store.workInProgress)
    }

    private func revealFocus(_ proxy: ScrollViewProxy) {
        guard let id = pendingFocusID, focusedSegmentID == id else { return }
        query = ""; sourceFilter = .all
        if snapshot?.hiddenSegmentIDs.contains(id) == true { hideEchoes = false }
        Task { @MainActor in
            await Task.yield()
            guard pendingFocusID == id, focusedSegmentID == id, presentation.matches(request),
                  let target = presentation.blockID(containing: id, input: TranscriptPresentationInput(meeting: meeting)) else { return }
            pendingFocusID = nil
            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .center) }
        }
    }
    private func sourceLabel(_ source: SpeakerAudioSource) -> String {
        switch source { case .microphone: return "Mikrofon"; case .system: return "Toplantı sesi"; case .mixed: return "Birleşik kayıt" }
    }
}
