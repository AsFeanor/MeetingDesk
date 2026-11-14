import SwiftUI
import AppKit

@main
struct MeetingDeskApp: App {
    @StateObject private var store = AppStore()
    @NSApplicationDelegateAdaptor(MeetingAppDelegate.self) private var delegate
    @Environment(\.openWindow) private var openWindow
    @FocusedValue(\.workspaceQuickOpen) private var quickOpen

    var body: some Scene {
        WindowGroup("Toplantı", id: "main") {
            RootView(store: store, recorder: store.recorder)
                .onAppear {
                    delegate.configure(with: store)
                    delegate.onOpenMainWindow = { openWindow(id: "main") }
                }
                .frame(minWidth: 900, minHeight: 620)
                .tint(WorkspaceStyle.accent)
        }
        .defaultSize(width: 1280, height: 850)
        .windowToolbarStyle(.unifiedCompact)
        .commands {
            CommandGroup(after: .appInfo) {
                UpdateMenu(updater: store.updates)
            }
            CommandGroup(replacing: .newItem) {
                Button("Yeni toplantı") { guard !store.workInProgress else { return }; _ = store.newMeeting() }
                    .keyboardShortcut("n").disabled(store.workInProgress)
                Button("Kayıt içe aktar…") { store.importAudio() }
                    .disabled(store.workInProgress)
            }
            CommandGroup(after: .newItem) {
                Button("Toplantı bul…") { quickOpen?() }.keyboardShortcut("k").disabled(quickOpen == nil)
            }
            CommandGroup(after: .appSettings) {
                Button("Ayarlar…") { store.showSettings = true; openWindow(id: "main") }
                    .keyboardShortcut(",")
            }
        }
        MenuBarExtra {
            Text(store.recorder.isRecording ? "\(store.recorder.isPaused ? "Duraklatıldı" : "Kaydediliyor") · \(timeLabel(store.recorder.elapsed))" : "Toplantı")
            Button("Toplantıları aç") { openWindow(id: "main"); NSApp.activate(ignoringOtherApps: true) }
            if store.recorder.isRecording {
                Button(store.recorder.isPaused ? "Kayda devam et" : "Kaydı duraklat") {
                    if store.recorder.isPaused { store.recorder.resume() } else { store.recorder.pause() }
                }
                Button("Kaydı bitir ve sakla") { Task { await store.finishRecording() } }
                    .disabled(store.isBusy)
            } else {
                Button("Yeni kayıt başlat") {
                    guard !store.workInProgress else { return }
                    _ = store.newMeeting()
                    openWindow(id: "main")
                    Task { await store.startRecording() }
                }.disabled(store.workInProgress)
            }
            if store.recorder.isRecording {
                Button("Kayıt kartını göster") { delegate.presentRecordingPanel() }
            }
            Divider()
            Button("Çık") { NSApp.terminate(nil) }
        } label: {
            Image(systemName: store.recorder.isRecording ? "record.circle.fill" : "waveform")
                .foregroundStyle(store.recorder.isRecording ? .red : .primary)
        }
    }
}

@MainActor
final class MeetingAppDelegate: NSObject, NSApplicationDelegate {
    weak var store: AppStore?
    var onOpenMainWindow: (() -> Void)?
    private var recordingPanel: FloatingRecordingPanelController?

    func configure(with store: AppStore) {
        self.store = store
        guard store.systemServicesEnabled, recordingPanel == nil else { return }
        let controller = FloatingRecordingPanelController(store: store, detector: store.meetingDetector)
        controller.onOpenMainWindow = { [weak self] in self?.onOpenMainWindow?() }
        recordingPanel = controller
    }

    func presentRecordingPanel() {
        store?.showRecordingPanel = true
        recordingPanel?.presentRecordingPanel()
    }

    func applicationWillTerminate(_ notification: Notification) {
        store?.meetingDetector.stop()
        recordingPanel?.shutdown()
    }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let store else { return .terminateNow }
        // Never let an updater relaunch discard an in-flight transcript or saved recording.
        guard !store.isBusy, !store.showMicrophoneCheck, !store.notion.isExporting, !store.hasPendingRecordingSession || store.recorder.isRecording else { return .terminateCancel }
        guard store.recorder.isRecording else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "Toplantı kaydı sürüyor"
        alert.informativeText = "Çıkmadan önce kaydı bitirip saklayabilirsin."
        alert.addButton(withTitle: "Kaydı sakla ve çık")
        alert.addButton(withTitle: "Kayda devam et")
        guard alert.runModal() == .alertFirstButtonReturn else { return .terminateCancel }
        Task {
            let saved = await store.finishRecording(allowAutomaticProcessing: false)
            sender.reply(toApplicationShouldTerminate: saved)
        }
        return .terminateLater
    }
}

private struct UpdateMenu: View {
    @ObservedObject var updater: AppUpdater
    var body: some View {
        Button("Güncellemeleri kontrol et…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
