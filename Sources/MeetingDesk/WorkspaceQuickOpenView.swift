import SwiftUI

struct WorkspaceQuickOpenKey: FocusedValueKey {
    typealias Value = () -> Void
}

extension FocusedValues {
    var workspaceQuickOpen: (() -> Void)? {
        get { self[WorkspaceQuickOpenKey.self] }
        set { self[WorkspaceQuickOpenKey.self] = newValue }
    }
}

struct WorkspaceQuickOpenView: View {
    let meetings: [Meeting]
    let selectedID: UUID?
    let canNavigate: Bool
    let onSelect: (UUID) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var searchFocused: Bool
    @State private var query = ""
    @State private var highlightedID: UUID?
    @State private var didOpen = false

    private var searching: Bool { !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var results: [Meeting] {
        let matching = meetings.filter { MeetingArchiveSearch.matches($0, query: query) }
            .sorted {
                if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
                return $0.id.uuidString < $1.id.uuidString
            }
        return searching ? matching : Array(matching.prefix(20))
    }

    var body: some View {
        VStack(spacing: 0) {
            searchHeader
            Divider().overlay(WorkspaceStyle.border)
            if !canNavigate {
                Label("Kayıt veya ses kontrolü sürerken toplantı değiştiremezsin. Aramada kalabilirsin.", systemImage: "lock")
                    .font(.system(size: 11))
                    .foregroundStyle(WorkspaceStyle.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.vertical, 11)
                    .background(WorkspaceStyle.elevated.opacity(0.6))
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if results.isEmpty { emptyState }
                    else {
                        LazyVStack(alignment: .leading, spacing: 5) {
                            HStack {
                                Text(searching ? "\(results.count) sonuç" : "Son toplantılar")
                                Spacer()
                                if !searching && meetings.count > 20 { Text("Daha eskileri arayarak bul") }
                            }
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(WorkspaceStyle.muted)
                            .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 6)
                            ForEach(results) { meeting in
                                resultRow(meeting).id(meeting.id)
                            }
                        }.padding(12)
                    }
                }
                .onChange(of: highlightedID) { _, id in
                    guard let id else { return }
                    withAnimation(reduceMotion ? nil : .easeOut(duration: 0.12)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
            Divider().overlay(WorkspaceStyle.border)
            keyboardFooter
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 450, idealHeight: 500)
        .background(WorkspaceStyle.surface)
        .foregroundStyle(WorkspaceStyle.ink)
        .task {
            highlightedID = results.first(where: { $0.id == selectedID })?.id ?? results.first?.id
            searchFocused = true
        }
        .onChange(of: query) { _, _ in highlightedID = results.first?.id }
        .onChange(of: meetings) { _, _ in
            if !results.contains(where: { $0.id == highlightedID }) { highlightedID = results.first?.id }
        }
        .onKeyPress(.downArrow) { moveHighlight(by: 1); return .handled }
        .onKeyPress(.upArrow) { moveHighlight(by: -1); return .handled }
        .onKeyPress(.return) { openHighlighted(); return .handled }
    }

    private var searchHeader: some View {
        HStack(spacing: 12) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 18, weight: .medium)).foregroundStyle(WorkspaceStyle.accent)
            TextField("Toplantı, kişi veya konuşulan bir şey…", text: $query)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($searchFocused)
                .onSubmit { openHighlighted() }
                .accessibilityLabel("Toplantı arşivinde ara")
            Button { dismiss() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(WorkspaceStyle.muted)
                    .frame(width: 28, height: 28)
                    .background(WorkspaceStyle.elevated, in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            .help("Kapat (Esc)")
            .accessibilityLabel("Aramayı kapat")
        }.padding(20)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: meetings.isEmpty ? "tray" : "doc.text.magnifyingglass")
                .font(.system(size: 30, weight: .light)).foregroundStyle(WorkspaceStyle.muted)
            Text(meetings.isEmpty ? "İlk toplantına yer hazır" : "Bu aramada toplantı bulunamadı")
                .font(.system(size: 16, weight: .semibold))
            Text(meetings.isEmpty ? "Bir toplantı kaydet veya transkript içe aktar. Sonra buradan hızla açabilirsin." : "Başlık, kişi, karar, görev veya transkriptte geçen başka bir kelimeyi dene.")
                .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
                .multilineTextAlignment(.center).frame(maxWidth: 340)
        }.frame(maxWidth: .infinity).padding(.vertical, 65).padding(.horizontal, 30)
    }

    private var keyboardFooter: some View {
        HStack(spacing: 20) {
            Label("Gezin", systemImage: "arrow.up.arrow.down")
            Label("Toplantıyı aç", systemImage: "return")
                .opacity(canNavigate ? 1 : 0.45)
            Spacer()
            Text("Başlıkların ötesinde ara")
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(WorkspaceStyle.muted)
        .padding(.horizontal, 20).padding(.vertical, 13)
        .background(WorkspaceStyle.canvas)
    }

    private func resultRow(_ meeting: Meeting) -> some View {
        let highlighted = highlightedID == meeting.id
        return Button { open(meeting.id) } label: {
            HStack(spacing: 12) {
                Image(systemName: meeting.notes == nil ? "waveform" : "doc.text")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(highlighted ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                    .frame(width: 36, height: 36)
                    .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 5) {
                    Text(meeting.title).font(.system(size: 13, weight: .medium)).lineLimit(2)
                    HStack(spacing: 6) {
                        Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                        if meeting.duration > 0 { Text("·"); Text(timeLabel(meeting.duration)) }
                        if meeting.id == selectedID { Text("· Açık") }
                    }
                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 8)
                if meeting.notes != nil {
                    Image(systemName: "checkmark.circle")
                        .foregroundStyle(WorkspaceStyle.accent).help("Toplantı notu hazır")
                }
                if highlighted {
                    Image(systemName: "return").font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                }
            }
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .background(highlighted ? WorkspaceStyle.accent.opacity(0.08) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 11))
            .overlay(RoundedRectangle(cornerRadius: 11).strokeBorder(highlighted ? WorkspaceStyle.accent.opacity(0.22) : .clear))
            .contentShape(RoundedRectangle(cornerRadius: 11))
        }
        .buttonStyle(.plain)
        .disabled(!canNavigate)
        .accessibilityLabel("\(meeting.title), \(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))")
        .accessibilityAddTraits(highlighted ? .isSelected : [])
    }

    private func moveHighlight(by step: Int) {
        guard !results.isEmpty else { highlightedID = nil; return }
        let current = results.firstIndex(where: { $0.id == highlightedID }) ?? (step > 0 ? -1 : 0)
        let next = min(results.count - 1, max(0, current + step))
        highlightedID = results[next].id
    }

    private func openHighlighted() {
        guard let id = highlightedID ?? results.first?.id else { return }
        open(id)
    }

    private func open(_ id: UUID) {
        guard canNavigate, !didOpen, meetings.contains(where: { $0.id == id }) else { return }
        didOpen = true
        onSelect(id)
        dismiss()
    }
}
