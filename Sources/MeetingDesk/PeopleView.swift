import Foundation
import SwiftUI

/// All named people are visible here, including meeting-only names for which
/// the user did not ask the app to remember a voice.
struct PeopleView: View {
    @ObservedObject var store: AppStore
    var onOpenMeeting: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var entries: [PeopleDirectoryEntry] {
        PeopleDirectory.entries(meetings: store.meetings, profiles: store.voiceProfiles)
    }
    private var cleanQuery: String { query.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var filtered: [PeopleDirectoryEntry] {
        guard !cleanQuery.isEmpty else { return entries }
        return entries.filter { entry in
            if matches(entry.name) { return true }
            return store.meetings.contains { entry.meetingIDs.contains($0.id) && matches($0.title) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Kişiler", systemImage: "person.2").font(.title2.weight(.semibold))
                    Text("Toplantılarda isim verdiğin ve sesini hatırlattığın kişiler.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Text(cleanQuery.isEmpty ? "\(entries.count) kişi kaydı" : "\(filtered.count) / \(entries.count) kayıt")
                    .font(.caption).foregroundStyle(.secondary).padding(.top, 5)
            }
            TextField("İsim veya toplantı ara", text: $query).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Kişilerde isim veya toplantı ara")
            if entries.isEmpty {
                emptyDirectory
            } else if filtered.isEmpty {
                emptySearch
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(filtered) { entry in
                            PeopleDirectoryRow(store: store, entry: entry, meetings: meetings(for: entry), onOpenMeeting: onOpenMeeting)
                        }
                    }.padding(.vertical, 2)
                }
            }
            HStack {
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            }
        }
        .padding(26)
        .frame(width: 620, height: 650)
    }

    private var emptyDirectory: some View {
        VStack(spacing: 12) {
            Image(systemName: "person.2").font(.system(size: 38, weight: .light)).foregroundStyle(.secondary)
            Text("Henüz kişi eklenmedi").font(.headline)
            Text("Bir toplantıda “Konuşmacıları düzenle” ekranından kişiye isim verdiğinde burada görünür. Sesini hatırlatmayı seçmesen de kişi listelenir.")
                .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 410)
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var emptySearch: some View {
        VStack(spacing: 12) {
            Image(systemName: "magnifyingglass").font(.system(size: 34, weight: .light)).foregroundStyle(.secondary)
            Text("Aramana uygun kişi yok").font(.headline)
            Button("Aramayı temizle") { query = "" }
        }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func matches(_ value: String) -> Bool {
        let locale = Locale(identifier: "tr_TR")
        let options: String.CompareOptions = [.caseInsensitive, .diacriticInsensitive]
        return value.folding(options: options, locale: locale)
            .contains(cleanQuery.folding(options: options, locale: locale))
    }

    private func meetings(for entry: PeopleDirectoryEntry) -> [Meeting] {
        let ids = Set(entry.meetingIDs)
        return store.meetings.filter { ids.contains($0.id) }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }
}

private struct PeopleDirectoryRow: View {
    @ObservedObject var store: AppStore
    let entry: PeopleDirectoryEntry
    let meetings: [Meeting]
    var onOpenMeeting: (UUID) -> Void
    @State private var renaming = false
    @State private var name: String
    @State private var renameError: String?
    @State private var showForgetConfirmation = false
    @State private var showMeetings = false

    init(store: AppStore, entry: PeopleDirectoryEntry, meetings: [Meeting], onOpenMeeting: @escaping (UUID) -> Void) {
        self.store = store
        self.entry = entry
        self.meetings = meetings
        self.onOpenMeeting = onOpenMeeting
        _name = State(initialValue: entry.name)
    }

    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }
    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: entry.profileID == nil ? "person.crop.circle" : "person.crop.circle.badge.checkmark")
                    .font(.title2).foregroundStyle(.tint).frame(width: 32)
                VStack(alignment: .leading, spacing: 4) {
                    Text(entry.name).font(.headline).textSelection(.enabled)
                    Text(entry.profileID == nil ? "Yalnız toplantıda isim verildi" : "Sesi hatırlanıyor")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 8)
                if entry.profileID != nil {
                    Menu {
                        Button("Adını değiştir") { name = entry.name; renameError = nil; renaming = true }
                        Button("Sesini unut", role: .destructive) { showForgetConfirmation = true }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(unavailable)
                    .accessibilityLabel("\(entry.name) için kişi seçenekleri")
                }
            }
            if renaming, entry.profileID != nil {
                VStack(alignment: .leading, spacing: 7) {
                    HStack(spacing: 9) {
                        TextField("Kişinin adı", text: $name).textFieldStyle(.roundedBorder)
                            .disabled(unavailable).onSubmit(saveName)
                            .accessibilityLabel("\(entry.name) için yeni isim")
                        Button("Vazgeç") { renaming = false; renameError = nil }.disabled(unavailable)
                        Button("Kaydet", action: saveName)
                            .disabled(unavailable || cleanName.isEmpty || cleanName.count > 100 || cleanName == entry.name)
                    }
                    Text("Kayıtlı ses profilinin adı güncellenir. Toplantılarda daha önce yazılmış isimler korunur.")
                        .font(.caption).foregroundStyle(.secondary)
                    if let renameError { Text(renameError).font(.caption).foregroundStyle(.red) }
                }
            }
            if let lastSeen = entry.lastSeen {
                Text("Son toplantı: \(lastSeen.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if meetings.count == 1, let meeting = meetings.first {
                meetingLink(meeting)
            } else if meetings.count > 1 {
                DisclosureGroup("\(meetings.count) toplantı", isExpanded: $showMeetings) {
                    VStack(alignment: .leading, spacing: 10) {
                        ForEach(meetings) { meeting in meetingLink(meeting) }
                    }.padding(.top, 9)
                }.font(.callout)
            } else {
                Text("Henüz bir toplantıya bağlanmadı.").font(.caption).foregroundStyle(.secondary)
            }
            if entry.profileID == nil, !meetings.isEmpty {
                Text("Bu kişinin eşleştirmelerini ilgili toplantıda “Konuşmacıları düzenle” ekranından gözden geçirebilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: entry.name) { _, updated in if !renaming { name = updated } }
        .onChange(of: entry.profileID) { _, updated in if updated == nil { renaming = false; renameError = nil } }
        .confirmationDialog("\(entry.name) için sesi unut?", isPresented: $showForgetConfirmation, titleVisibility: .visible) {
            Button("Sesini unut", role: .destructive) {
                guard let profileID = entry.profileID else { return }
                store.deleteVoiceProfile(id: profileID)
            }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Kaydedilmiş ses profili silinir. Toplantılardaki isimler ve konuşmalar korunur; toplantı geçmişi olan kişi listede kalır.")
        }
    }

    private func meetingLink(_ meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(meeting.title).font(.callout).lineLimit(1)
                Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Button("Toplantıyı aç") { onOpenMeeting(meeting.id) }
                .font(.caption).disabled(unavailable)
                .accessibilityLabel("\(meeting.title) toplantısını aç")
        }
    }

    private func saveName() {
        guard !unavailable, let profileID = entry.profileID else { return }
        store.errorMessage = nil
        store.renameVoiceProfile(id: profileID, name: cleanName)
        if store.voiceProfiles.first(where: { $0.id == profileID })?.name == cleanName {
            renaming = false; renameError = nil
        } else { renameError = store.errorMessage ?? "İsim kaydedilemedi. Yeniden deneyebilirsin." }
    }
}
