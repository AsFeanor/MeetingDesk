import AppKit
import Combine
import SwiftUI

/// Keeps a dismissed recording card hidden through pause and finalization. A new
/// session can show the card again, while a dismissed meeting prompt stays under
/// the detector's own suppression policy.
struct RecordingPanelVisibilityPolicy {
    enum Presentation: Equatable { case hidden, prompt, starting, recording, saving }
    private(set) var hasObservedRecordingSession = false
    private(set) var recordingSessionHidden = false

    mutating func hideRecordingSession() { recordingSessionHidden = true }
    mutating func revealRecordingSession() { recordingSessionHidden = false }

    mutating func resolve(recording: Bool, starting: Bool, workInProgress: Bool,
                          recordingPanelEnabled: Bool, hasMeetingCandidate: Bool) -> Presentation {
        if recording || starting { hasObservedRecordingSession = true }
        if recording {
            return recordingPanelEnabled && !recordingSessionHidden ? .recording : .hidden
        }
        if starting {
            return recordingPanelEnabled && !recordingSessionHidden ? .starting : .hidden
        }
        if hasObservedRecordingSession && workInProgress {
            return recordingPanelEnabled && !recordingSessionHidden ? .saving : .hidden
        }
        if hasObservedRecordingSession {
            hasObservedRecordingSession = false
            recordingSessionHidden = false
        }
        return hasMeetingCandidate && !workInProgress ? .prompt : .hidden
    }
}

@MainActor
final class FloatingRecordingPanelController {
    var onOpenMainWindow: (() -> Void)?
    private weak var store: AppStore?
    private let detector: MeetingDetector
    private let model = FloatingRecordingPanelModel()
    private var panel: RecordingControlPanel?
    private var subscriptions: Set<AnyCancellable> = []
    private var visibility = RecordingPanelVisibilityPolicy()
    private var refreshScheduled = false
    private var isStartingRecording = false
    private var isStoppingRecording = false
    private var didShutDown = false

    init(store: AppStore, detector: MeetingDetector) {
        self.store = store
        self.detector = detector
        model.start = { [weak self] in self?.startRecording() }
        model.pause = { [weak self] in self?.togglePause() }
        model.stop = { [weak self] in self?.stopRecording() }
        model.open = { [weak self] in self?.openMainWindow() }
        model.hide = { [weak self] in self?.hidePanel() }
        store.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        store.recorder.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        detector.objectWillChange.sink { [weak self] _ in self?.scheduleRefresh() }.store(in: &subscriptions)
        refresh()
    }

    func presentRecordingPanel() {
        guard !didShutDown else { return }
        visibility.revealRecordingSession()
        refresh()
    }

    func shutdown() {
        didShutDown = true
        subscriptions.removeAll()
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        onOpenMainWindow = nil
    }

    private func scheduleRefresh() {
        guard !refreshScheduled, !didShutDown else { return }
        refreshScheduled = true
        // Published emits before its backing value changes. Read the whole
        // committed state together on the next main-actor turn.
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.refreshScheduled = false
            self.refresh()
        }
    }

    private func refresh() {
        guard !didShutDown, let store else { panel?.orderOut(nil); return }
        let recorder = store.recorder
        let candidate = store.meetingDetectionEnabled ? detector.candidate : nil
        let presentation = visibility.resolve(recording: recorder.isRecording,
                                              starting: isStartingRecording,
                                              workInProgress: store.workInProgress || isStoppingRecording,
                                              recordingPanelEnabled: store.showRecordingPanel,
                                              hasMeetingCandidate: candidate != nil)
        guard presentation != .hidden else { panel?.orderOut(nil); return }
        let snapshot = FloatingRecordingPanelSnapshot(presentation: presentation,
                                                      appName: candidate?.appName ?? "Toplantı",
                                                      explanation: candidate?.evidenceDescription ?? "",
                                                      elapsed: recorder.elapsed,
                                                      paused: recorder.isPaused,
                                                      microphoneLevel: recorder.microphoneLevel,
                                                      systemLevel: recorder.systemLevel,
                                                      busy: store.isBusy || isStoppingRecording,
                                                      status: isStartingRecording ? "Ses kaydı hazırlanıyor…" : store.statusMessage)
        if model.snapshot != snapshot { model.snapshot = snapshot }
        if panel == nil { makePanel() }
        guard let panel else { return }
        // Ordering an already visible panel for every meter tick would disrupt
        // the user's window order. Only show it when its visibility changes.
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    private func makePanel() {
        let panel = RecordingControlPanel(contentRect: NSRect(x: 0, y: 0, width: 332, height: 218),
                                          styleMask: [.borderless, .nonactivatingPanel],
                                          backing: .buffered, defer: false)
        panel.title = "Toplantı kayıt kontrolü"
        panel.level = .floating
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isReleasedWhenClosed = false
        panel.contentView = RecordingPanelHostingView(rootView: FloatingRecordingPanelView(model: model))
        // Choose the display where the pointer is, without activating the app or
        // moving focus away from a meeting. Dragging then preserves the position.
        let pointer = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(pointer) } ?? NSScreen.main
        if let screen {
            let bounds = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: max(bounds.minX, bounds.maxX - panel.frame.width - 24),
                                         y: bounds.minY + 24))
        }
        self.panel = panel
    }

    private func startRecording() {
        guard let store, !store.workInProgress, !isStartingRecording else { return }
        isStartingRecording = true
        visibility.revealRecordingSession()
        // Consuming this suggestion also prevents another prompt when the user
        // finishes a recording while the same meeting is still running.
        detector.dismissCurrentMeeting()
        _ = store.newMeeting()
        refresh()
        Task { @MainActor [weak self, weak store] in
            guard let store else { return }
            await store.startRecording()
            guard let self else { return }
            self.isStartingRecording = false
            self.refresh()
            if !store.recorder.isRecording, store.errorMessage != nil { self.openMainWindow() }
        }
    }

    private func togglePause() {
        guard let store, store.recorder.isRecording, !store.isBusy, !isStoppingRecording else { return }
        if store.recorder.isPaused { store.recorder.resume() } else { store.recorder.pause() }
    }

    private func stopRecording() {
        guard let store, store.recorder.isRecording, !store.isBusy, !isStoppingRecording else { return }
        isStoppingRecording = true
        refresh()
        Task { @MainActor [weak self, weak store] in
            guard let store else { return }
            let saved = await store.finishRecording()
            guard let self else { return }
            self.isStoppingRecording = false
            self.refresh()
            if !saved { self.openMainWindow() }
        }
    }

    private func hidePanel() {
        switch model.snapshot.presentation {
        case .prompt: detector.dismissCurrentMeeting()
        case .recording, .starting, .saving: visibility.hideRecordingSession()
        case .hidden: break
        }
        panel?.orderOut(nil)
    }

    private func openMainWindow() {
        onOpenMainWindow?()
        NSApp.activate(ignoringOtherApps: true)
    }
}

private final class RecordingControlPanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

private final class RecordingPanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

private struct FloatingRecordingPanelSnapshot: Equatable {
    var presentation: RecordingPanelVisibilityPolicy.Presentation = .hidden
    var appName = "Toplantı"
    var explanation = ""
    var elapsed: Double = 0
    var paused = false
    var microphoneLevel: Double = 0
    var systemLevel: Double = 0
    var busy = false
    var status = ""
}

@MainActor
private final class FloatingRecordingPanelModel: ObservableObject {
    @Published var snapshot = FloatingRecordingPanelSnapshot()
    var start: () -> Void = {}
    var pause: () -> Void = {}
    var stop: () -> Void = {}
    var open: () -> Void = {}
    var hide: () -> Void = {}
}

private struct FloatingRecordingPanelView: View {
    @ObservedObject var model: FloatingRecordingPanelModel
    private var state: FloatingRecordingPanelSnapshot { model.snapshot }
    private let accent = Color(red: 0.05, green: 0.42, blue: 0.36)

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Image(systemName: state.presentation == .recording ? "record.circle.fill" : "waveform")
                    .foregroundStyle(state.presentation == .recording && !state.paused ? .red : accent)
                Text(header).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(action: model.hide) { Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).frame(width: 20, height: 20) }
                    .buttonStyle(.plain)
                    .accessibilityLabel(hideAccessibilityLabel)
                    .help(state.presentation == .prompt ? "Bu öneriyi kapat" : "Kartı gizle; menü çubuğundan izlemeye devam et")
            }
            switch state.presentation {
            case .prompt: prompt
            case .recording: recording
            case .starting, .saving: progress
            case .hidden: EmptyView()
            }
            Spacer(minLength: 0)
            Button("Toplantıları aç", action: model.open)
                .font(.system(size: 11))
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
        }
        .padding(16)
        .frame(width: 332, height: 218, alignment: .topLeading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).stroke(.primary.opacity(0.1), lineWidth: 1))
        .tint(accent)
    }

    private var header: String {
        switch state.presentation {
        case .prompt: return "Toplantıda olabilirsin"
        case .recording: return state.busy ? "Kayıt saklanıyor" : state.paused ? "Kayıt duraklatıldı" : "Kayıt sürüyor"
        case .starting: return "Kayıt hazırlanıyor"
        case .saving: return "Kayıt işleniyor"
        case .hidden: return "Toplantı"
        }
    }

    private var hideAccessibilityLabel: String {
        switch state.presentation {
        case .prompt: return "Bu toplantı önerisini kapat"
        case .saving: return "Kayıt kartını gizle; dosya hazırlanması devam eder"
        case .recording, .starting: return "Kayıt kartını gizle; kayıt devam eder"
        case .hidden: return "Kayıt kartını gizle"
        }
    }

    private var prompt: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(state.appName).font(.system(size: 15, weight: .medium)).lineLimit(1)
            Text(state.explanation).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
            Button(action: model.start) { Label("Kayda başla", systemImage: "record.circle").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(state.busy)
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(timeLabel(state.elapsed)).font(.system(size: 29, weight: .medium, design: .monospaced))
                .accessibilityLabel("Kayıt süresi \(timeLabel(state.elapsed))")
            HStack(spacing: 14) {
                meter("Mikrofon", value: state.microphoneLevel, icon: "mic.fill")
                meter("Toplantı sesi", value: state.systemLevel, icon: "speaker.wave.2.fill")
            }
            HStack(spacing: 8) {
                Button(action: model.pause) { Image(systemName: state.paused ? "play.fill" : "pause.fill").frame(width: 28) }
                    .buttonStyle(.bordered)
                    .accessibilityLabel(state.paused ? "Kayda devam et" : "Kaydı duraklat")
                    .help(state.paused ? "Kayda devam et" : "Kaydı duraklat")
                Button(action: model.stop) { Label("Bitir ve sakla", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                    .buttonStyle(.borderedProminent)
            }
            .controlSize(.regular)
            .disabled(state.busy)
        }
    }

    private var progress: some View {
        HStack(alignment: .top, spacing: 10) {
            ProgressView().controlSize(.small)
            Text(state.status.isEmpty ? "Kayıt Mac’te saklanıyor…" : state.status)
                .font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(5)
        }
        .padding(.top, 12)
    }

    private func meter(_ title: String, value: Double, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: icon).font(.system(size: 10)).foregroundStyle(.secondary)
            ProgressView(value: max(0, min(1, value)))
                .tint(accent)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int(max(0, min(1, value)) * 100)) yüzde")
        }
        .frame(maxWidth: .infinity)
    }
}
