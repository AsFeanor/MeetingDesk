import AppKit
import Carbon
import Combine

/// Registers one explicit hotkey only while recording. It does not observe keys,
/// request Accessibility access, or record activity in another application.
@MainActor
final class RecordingBookmarkShortcut {
    private weak var store: AppStore?
    private var handler: EventHandlerRef?
    private var hotkey: EventHotKeyRef?
    private var subscription: AnyCancellable?
    private var lastTrigger: ContinuousClock.Instant?
    nonisolated private static let signature: OSType = 0x4D64426D

    init(store: AppStore) {
        self.store = store
        var specification = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let context = Unmanaged.passUnretained(self).toOpaque()
        let status = InstallEventHandler(GetApplicationEventTarget(), { _, event, context in
            guard let event, let context else { return OSStatus(eventNotHandledErr) }
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                nil, numericCast(MemoryLayout<EventHotKeyID>.size), nil, &id)
            guard status == noErr, id.signature == RecordingBookmarkShortcut.signature, id.id == 1 else {
                return OSStatus(eventNotHandledErr)
            }
            let owner = Unmanaged<RecordingBookmarkShortcut>.fromOpaque(context).takeUnretainedValue()
            Task { @MainActor [weak owner] in owner?.mark() }
            return noErr
        }, 1, &specification, context, &handler)
        guard status == noErr else { return }
        subscription = store.recorder.$isRecording.removeDuplicates().sink { [weak self] active in
            Task { @MainActor [weak self] in self?.setActive(active) }
        }
    }
    private func mark() {
        let now = ContinuousClock.now
        if let lastTrigger, lastTrigger.duration(to: now) < .seconds(0.5) { return }
        lastTrigger = now
        _ = store?.markImportantMoment()
    }
    private func setActive(_ active: Bool) {
        if !active {
            if let hotkey { UnregisterEventHotKey(hotkey) }
            hotkey = nil
            return
        }
        guard hotkey == nil else { return }
        let id = EventHotKeyID(signature: Self.signature, id: 1)
        let result = RegisterEventHotKey(UInt32(kVK_ANSI_M), UInt32(cmdKey | shiftKey), id,
            GetApplicationEventTarget(), 0, &hotkey)
        if result != noErr {
            hotkey = nil
            store?.statusMessage = "⌘⇧M başka bir uygulamada kullanılıyor. Kayıt kartındaki Önemli an düğmesini kullanabilirsin."
        }
    }
    deinit {
        if let hotkey { UnregisterEventHotKey(hotkey) }
        if let handler { RemoveEventHandler(handler) }
    }
}
