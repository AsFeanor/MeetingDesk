import SwiftUI

struct RecordingBookmarkButton: View {
    @ObservedObject var store: AppStore
    @State private var savedID: UUID?
    @State private var note = ""
    @State private var showingNote = false
    var body: some View {
        Button {
            guard let id = store.markImportantMoment() else { return }
            savedID = id; note = ""; showingNote = true
        } label: { Label("Önemli an", systemImage: "bookmark") }
            .buttonStyle(WorkspaceQuietButtonStyle()).disabled(!store.canMarkImportantMoment)
            .help("Bu anı işaretle · ⌘⇧M. Kayıt sürerken diğer uygulamalardan da kullanılabilir.")
            .popover(isPresented: $showingNote) {
                VStack(alignment: .leading, spacing: 12) {
                    Label("An işaretlendi", systemImage: "bookmark.fill").font(.headline)
                    TextField("İstersen kısa bir not ekle", text: $note, axis: .vertical).lineLimit(2...4)
                        .textFieldStyle(.roundedBorder).accessibilityLabel("Önemli an notu")
                    HStack {
                        Button("Not eklemeden kapat") { showingNote = false }.buttonStyle(.plain)
                        Spacer()
                        Button("Kaydet") {
                            guard let id = savedID, let meeting = store.recordingMeeting ?? store.selected,
                                  store.editBookmark(id, note: note, in: meeting.id) else { return }
                            showingNote = false
                        }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(note.count > 1000 || !store.canEditCarryover)
                    }.font(.caption)
                }.padding(20).frame(width: 340)
            }
    }
}

struct MeetingBookmarksView: View {
    @ObservedObject var store: AppStore
    let meeting: Meeting
    let onOpen: (MeetingBookmark) -> Void
    @State private var editing: MeetingBookmark?
    @State private var note = ""
    private var bookmarks: [MeetingBookmark] { MeetingBookmarkPolicy.ordered(in: meeting) }
    var body: some View {
        if !bookmarks.isEmpty {
            VStack(alignment: .leading, spacing: 14) {
                Label("Önemli anlar", systemImage: "bookmark").font(.system(size: 17, weight: .semibold))
                ForEach(bookmarks) { bookmark in
                    HStack(alignment: .top, spacing: 12) {
                        Button { onOpen(bookmark) } label: {
                            Label(timeLabel(bookmark.time), systemImage: "play.circle")
                                .font(.system(size: 11, weight: .semibold).monospacedDigit())
                        }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
                            .disabled(store.workInProgress)
                            .accessibilityLabel("İşaretli anı aç, \(timeLabel(bookmark.time))")
                        Text(bookmark.note.isEmpty ? "Önemli an" : bookmark.note)
                            .font(.system(size: 12)).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                        Menu {
                            Button("Notu düzenle") { note = bookmark.note; editing = bookmark }
                            Button("İşareti sil", role: .destructive) { _ = store.deleteBookmark(bookmark.id, in: meeting.id) }
                        } label: { Image(systemName: "ellipsis") }
                            .menuStyle(.borderlessButton).fixedSize().disabled(!store.canEditCarryover)
                            .accessibilityLabel("Önemli an seçenekleri")
                    }.padding(12).background(WorkspaceStyle.canvas, in: RoundedRectangle(cornerRadius: 9))
                }
            }.padding(18).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 13))
                .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(WorkspaceStyle.border))
                .sheet(item: $editing) { bookmark in
                    VStack(alignment: .leading, spacing: 15) {
                        Text("Önemli an · \(timeLabel(bookmark.time))").font(.headline)
                        TextField("Kısa not", text: $note, axis: .vertical).lineLimit(3...6).textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Vazgeç") { editing = nil }.keyboardShortcut(.cancelAction)
                            Spacer()
                            Button("Kaydet") {
                                if store.editBookmark(bookmark.id, note: note, in: meeting.id) { editing = nil }
                            }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(note.count > 1000 || !store.canEditCarryover)
                        }
                    }.padding(24).frame(width: 420)
                }
        }
    }
}
