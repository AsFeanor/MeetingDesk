import SwiftUI

struct WorkspaceSidebar: View {
    @ObservedObject var store: AppStore
    @ObservedObject var recorder: AudioRecorder
    @Binding var query: String
    var onNew: () -> Void
    var onImportAudio: () -> Void
    var onImportTranscript: () -> Void
    var onPeople: () -> Void
    var onQuickOpen: () -> Void
    @AppStorage(WorkspaceAppearance.defaultsKey) private var appearanceRaw = WorkspaceAppearance.system.rawValue
    @State private var pendingOnly = false
    @State private var searchTerm = ""
    @State private var hoveredID: UUID?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var selectionLocked: Bool { recorder.isRecording || store.hasPendingRecordingSession || store.showMicrophoneCheck }
    private func pendingCount(_ meeting: Meeting) -> Int {
        meeting.notes?.actions.filter { !meeting.completedActions.contains($0.id) }.count ?? 0
    }
    private var matches: [Meeting] {
        store.meetings.filter { MeetingArchiveSearch.matches($0, query: searchTerm) && (!pendingOnly || pendingCount($0) > 0) }
            .sorted { $0.createdAt > $1.createdAt }
    }
    private var groups: [ArchiveGroup] {
        let calendar = Calendar.current, now = Date()
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let buckets = Dictionary(grouping: matches) { meeting -> Int in
            if calendar.isDate(meeting.createdAt, inSameDayAs: now) { return 0 }
            if calendar.isDate(meeting.createdAt, inSameDayAs: yesterday) { return 1 }
            if week?.contains(meeting.createdAt) == true { return 2 }
            return 3
        }
        let titles = ["Bugün", "Dün", "Bu hafta", "Önceki toplantılar"]
        return titles.indices.compactMap { index in
            guard let meetings = buckets[index], !meetings.isEmpty else { return nil }
            return ArchiveGroup(id: index, title: titles[index], meetings: meetings)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            brand.padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 25)
            primaryActions.padding(.horizontal, 16)
            search.padding(.horizontal, 16).padding(.top, 19)
            archiveHeader.padding(.horizontal, 20).padding(.top, 25).padding(.bottom, 10)
            archiveList
            footer
        }.background(WorkspaceStyle.sidebar).foregroundStyle(WorkspaceStyle.ink)
            .task(id: query) {
                if !query.isEmpty { try? await Task.sleep(for: .milliseconds(180)) }
                guard !Task.isCancelled else { return }
                searchTerm = query
            }
    }
    private var brand: some View {
        HStack(spacing: 11) {
            Image(systemName: "waveform").font(.system(size: 18, weight: .semibold))
                .foregroundStyle(WorkspaceStyle.accent).frame(width: 37, height: 37)
                .background(WorkspaceStyle.accent.opacity(0.10), in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                Text("Toplantı").font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("Konuşmaların bir arada.").font(.system(size: 10.5)).foregroundStyle(WorkspaceStyle.muted)
            }
            Spacer(minLength: 0)
        }
    }
    private var primaryActions: some View {
        VStack(spacing: 8) {
            Button {
                guard !store.workInProgress else { return }; onNew()
            } label: {
                HStack(spacing: 9) {
                    Image(systemName: "plus").font(.system(size: 12, weight: .semibold))
                    Text("Yeni toplantı").font(.system(size: 12, weight: .semibold))
                    Spacer()
                    Text("⌘ N").font(.system(size: 10, weight: .medium)).opacity(0.65)
                }.frame(maxWidth: .infinity).padding(.vertical, 2)
            }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress)
            Menu {
                Button("Ses kaydı içe aktar…", systemImage: "waveform") {
                    guard !store.workInProgress else { return }; onImportAudio()
                }
                Button("Transkript yapıştır…", systemImage: "doc.on.clipboard") {
                    guard !store.workInProgress else { return }; onImportTranscript()
                }
            } label: {
                Label("İçe aktar", systemImage: "square.and.arrow.down")
                    .font(.system(size: 11.5, weight: .medium)).frame(maxWidth: .infinity)
            }.menuStyle(.borderlessButton).padding(.horizontal, 13).padding(.vertical, 9)
                .background(WorkspaceStyle.surface.opacity(0.65), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorkspaceStyle.border, lineWidth: 1))
                .disabled(store.workInProgress)
        }
    }
    private var search: some View {
        VStack(spacing: 8) {
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).accessibilityHidden(true)
                TextField("Toplantılarda ara", text: $query).font(.system(size: 11.5)).textFieldStyle(.plain)
                    .accessibilityLabel("Toplantılarda ara")
                    .help("Başlık, transkript, kararlar, görevler, kişi adları ve kendi notlarında ara")
                if !query.isEmpty {
                    Button { query = "" } label: { Image(systemName: "xmark.circle.fill").font(.system(size: 11)) }
                        .buttonStyle(.plain).help("Aramayı temizle").accessibilityLabel("Aramayı temizle")
                }
            }.foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 11).padding(.vertical, 10)
                .background(WorkspaceStyle.canvas.opacity(0.75), in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(WorkspaceStyle.border, lineWidth: 1))
            Button(action: onQuickOpen) {
                HStack {
                    Text("Hızlı aç"); Spacer()
                    Text("⌘ K").font(.system(size: 10, weight: .medium, design: .monospaced))
                }.font(.system(size: 10.5)).foregroundStyle(WorkspaceStyle.muted)
            }.buttonStyle(.plain).padding(.horizontal, 2).help("Toplantı bul ve aç")
        }
    }
    private var archiveHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("TOPLANTILAR").font(.system(size: 9.5, weight: .semibold)).tracking(1.1)
                Spacer()
                Text("\(matches.count)").font(.system(size: 10, weight: .medium, design: .monospaced))
            }.foregroundStyle(WorkspaceStyle.muted)
            HStack(spacing: 5) {
                scope("Tümü", selected: !pendingOnly) { pendingOnly = false }
                scope("Açık aksiyonlar", selected: pendingOnly) { pendingOnly = true }
                Spacer(minLength: 0)
            }
        }
    }
    private func scope(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button {
            if reduceMotion { action() } else { withAnimation(.easeInOut(duration: 0.16), action) }
        } label: {
            Text(title).font(.system(size: 10, weight: selected ? .semibold : .regular))
                .foregroundStyle(selected ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                .padding(.horizontal, 9).padding(.vertical, 5)
                .background(selected ? WorkspaceStyle.accent.opacity(0.10) : .clear, in: Capsule())
        }.buttonStyle(.plain).accessibilityAddTraits(selected ? .isSelected : [])
    }
    private var archiveList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 19) {
                if groups.isEmpty { emptyArchive.padding(.horizontal, 12).padding(.top, 17) }
                else {
                    ForEach(groups) { group in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(group.title).font(.system(size: 10, weight: .medium))
                                .foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 12).padding(.bottom, 3)
                            ForEach(group.meetings) { meeting in row(meeting) }
                        }
                    }
                }
            }.padding(.horizontal, 8).padding(.top, 7).padding(.bottom, 20)
        }.scrollIndicators(.hidden)
    }
    private func row(_ meeting: Meeting) -> some View {
        let selected = store.selectedID == meeting.id
        let recording = recorder.isRecording && store.recordingMeeting?.id == meeting.id
        let remaining = pendingCount(meeting)
        return Button {
            guard !selectionLocked else { return }; store.selectedID = meeting.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: recording ? "record.circle.fill" : meeting.notes != nil ? "doc.text" : meeting.segments.isEmpty ? "waveform" : "text.alignleft")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(recording ? WorkspaceStyle.recording : selected ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                    .frame(width: 18).padding(.top, 2).accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 7) {
                    Text(meeting.title).font(.system(size: 12, weight: selected ? .semibold : .medium))
                        .foregroundStyle(WorkspaceStyle.ink).lineLimit(2).multilineTextAlignment(.leading)
                    HStack(spacing: 5) {
                        Text(meeting.createdAt.formatted(.dateTime.day().month(.abbreviated)))
                        if meeting.duration > 0 { Text("·"); Text(timeLabel(meeting.duration)).monospacedDigit() }
                        Spacer(minLength: 2)
                        if recording { Text(recorder.isPaused ? "Duraklatıldı" : "Kayıtta").foregroundStyle(WorkspaceStyle.recording) }
                        else if remaining > 0 {
                            Image(systemName: "circle.dotted").accessibilityHidden(true)
                            Text("\(remaining)").monospacedDigit()
                        } else if meeting.notesAreReviewed {
                            Image(systemName: "checkmark.circle").foregroundStyle(WorkspaceStyle.accent)
                                .accessibilityLabel("Notlar kontrol edildi")
                        }
                    }.font(.system(size: 9.5)).foregroundStyle(WorkspaceStyle.muted)
                }
            }.padding(.horizontal, 12).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(selected ? WorkspaceStyle.accent.opacity(0.085) : hoveredID == meeting.id ? WorkspaceStyle.surface.opacity(0.7) : .clear, in: RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .leading) {
                    if selected { Capsule().fill(WorkspaceStyle.accent).frame(width: 3, height: 22).padding(.leading, 1) }
                }.contentShape(RoundedRectangle(cornerRadius: 10))
        }.buttonStyle(.plain).disabled(selectionLocked)
            .onHover { hoveredID = $0 ? meeting.id : nil }
            .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: hoveredID)
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(meeting.title + (remaining > 0 ? " · \(remaining) açık aksiyon" : ""))
    }
    private var emptyArchive: some View {
        VStack(alignment: .leading, spacing: 9) {
            Image(systemName: query.isEmpty ? pendingOnly ? "checkmark.circle" : "tray" : "magnifyingglass")
                .font(.system(size: 21, weight: .light)).foregroundStyle(WorkspaceStyle.muted)
            Text(!query.isEmpty ? "Sonuç bulunamadı" : pendingOnly ? "Açık aksiyon yok" : "İlk toplantına hazır")
                .font(.system(size: 12, weight: .semibold))
            Text(!query.isEmpty ? "Başka bir kelime dene veya filtreyi temizle." : pendingOnly ? "Tamamlanmamış aksiyonu olan toplantılar burada görünür." : "Yeni toplantı başlat ya da mevcut bir kaydı içe aktar.")
                .font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(3)
            if !query.isEmpty || pendingOnly {
                Button("Filtreleri temizle") { query = ""; pendingOnly = false }
                    .font(.system(size: 11)).buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
            }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }
    private var footer: some View {
        VStack(spacing: 14) {
            Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            Button(action: onPeople) {
                HStack(spacing: 10) {
                    Image(systemName: "person.2").frame(width: 18); Text("Kişiler"); Spacer()
                    Text("\(PeopleDirectory.entries(meetings: store.meetings, profiles: store.voiceProfiles).count)")
                        .font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 7).padding(.vertical, 3).background(WorkspaceStyle.canvas, in: Capsule())
                }.font(.system(size: 12, weight: .medium))
            }.buttonStyle(.plain).help("Kaydettiğin kişileri ve ses profillerini gör")
            HStack(spacing: 12) {
                Button { store.showSettings = true } label: { Image(systemName: "gearshape").font(.system(size: 13)) }
                    .buttonStyle(.plain).help("Ayarlar").accessibilityLabel("Ayarlar")
                Button { store.revealArchive() } label: { Image(systemName: "folder").font(.system(size: 13)) }
                    .buttonStyle(.plain).help("Yerel arşivi aç").accessibilityLabel("Yerel arşivi aç")
                Spacer()
                Picker("Görünüm", selection: $appearanceRaw) {
                    ForEach(WorkspaceAppearance.allCases) { appearance in
                        Image(systemName: appearance.symbol).tag(appearance.rawValue).help(appearance.label)
                    }
                }.pickerStyle(.segmented).labelsHidden().frame(width: 107).help("Sistem, açık veya koyu görünüm")
            }.foregroundStyle(WorkspaceStyle.muted)
            HStack(spacing: 5) {
                Image(systemName: store.processingMode == .local ? "lock.shield" : "network")
                Text(store.processingMode == .local ? "Bu Mac’te saklanır ve işlenir" : "OpenAI modu açık")
                Spacer(minLength: 0)
            }.font(.system(size: 9)).foregroundStyle(WorkspaceStyle.muted)
        }.padding(.horizontal, 20).padding(.bottom, 18).padding(.top, 3)
    }
    private struct ArchiveGroup: Identifiable {
        let id: Int
        let title: String
        let meetings: [Meeting]
    }
}
