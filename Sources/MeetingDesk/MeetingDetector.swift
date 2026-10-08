import AppKit
import Combine
import CoreAudio
import CoreGraphics

struct DetectedMeeting: Identifiable, Equatable, Sendable {
    enum Confidence: Int, Equatable, Sendable {
        case nativeMicrophone
        case browserMeetingWindow
    }

    let id: String
    let appName: String
    let evidenceDescription: String
    let confidence: Confidence
}

/// Only these transient fields enter the detection policy. Audio and meeting-window
/// titles are never captured, persisted or sent to a service.
struct MeetingAudioProcess: Equatable, Sendable {
    let processID: Int32
    let bundleIdentifier: String
    let isInputRunning: Bool
}

struct MeetingBrowserWindow: Equatable, Sendable {
    let bundleIdentifier: String
    let title: String
}

enum MeetingDetectionSignals {
    private static let nativeApps: [(id: String, name: String)] = [
        ("us.zoom.xos", "Zoom"),
        ("com.microsoft.teams2", "Microsoft Teams"),
        ("com.microsoft.teams", "Microsoft Teams"),
        ("com.cisco.webexmeetingsapp", "Webex"),
        ("com.cisco.webex", "Webex"),
        ("com.apple.FaceTime", "FaceTime"),
        ("com.tinyspeck.slackmacgap", "Slack")
    ]

    static let browserApps: [(id: String, name: String)] = [
        ("com.google.Chrome", "Chrome"),
        ("com.microsoft.edgemac", "Edge"),
        ("com.brave.Browser", "Brave"),
        ("org.chromium.Chromium", "Chromium"),
        ("com.apple.Safari", "Safari")
    ]

    static func browserID(for bundleIdentifier: String) -> String? {
        browserApps.first { belongs(bundleIdentifier, to: $0.id) }?.id
    }

    static func detect(processes: [MeetingAudioProcess], browserWindows: [MeetingBrowserWindow],
                       ownProcessID: Int32, ownBundleIdentifier: String?) -> [DetectedMeeting] {
        var result: [String: DetectedMeeting] = [:]
        for process in processes where process.isInputRunning {
            guard process.processID != ownProcessID,
                  !belongs(process.bundleIdentifier, to: "com.altugegesari.meetingdesk"),
                  ownBundleIdentifier.map({ !belongs(process.bundleIdentifier, to: $0) }) ?? true else { continue }

            if let app = nativeApps.first(where: { belongs(process.bundleIdentifier, to: $0.id) }) {
                let meeting = DetectedMeeting(id: "native:\(app.id)", appName: app.name,
                    evidenceDescription: "\(app.name) mikrofonu kullanıyor. Toplantıda olabilirsin.",
                    confidence: .nativeMicrophone)
                result[meeting.id] = meeting
                continue
            }

            guard let browser = browserApps.first(where: { belongs(process.bundleIdentifier, to: $0.id) }) else { continue }
            for window in browserWindows where browserID(for: window.bundleIdentifier) == browser.id {
                guard let service = recognizedBrowserMeeting(window.title) else { continue }
                let meeting = DetectedMeeting(id: "browser:\(browser.id):\(service.id)",
                    appName: "\(service.name) (\(browser.name))",
                    evidenceDescription: "Tarayıcı mikrofonu ve toplantı penceresi görüldü; aynı sekme olduğu doğrulanamıyor.",
                    confidence: .browserMeetingWindow)
                result[meeting.id] = meeting
            }
        }
        return result.values.sorted {
            if $0.confidence != $1.confidence { return $0.confidence.rawValue < $1.confidence.rawValue }
            return $0.id < $1.id
        }
    }

    private static func belongs(_ bundleIdentifier: String, to root: String) -> Bool {
        bundleIdentifier == root || bundleIdentifier.hasPrefix(root + ".")
    }

    private static func recognizedBrowserMeeting(_ title: String) -> (id: String, name: String)? {
        let value = title.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .replacingOccurrences(of: "ı", with: "i")
        // A generic "Meet" word can occur in any page, so require the service name
        // or Google's recognizable call-code window title instead.
        if value.contains("google meet") || value.range(of: #"(?:^|\s)meet\s*[-–—]\s*[a-z]{3}-[a-z]{4}-[a-z]{3}(?:\s|$)"#,
                                                      options: .regularExpression) != nil {
            return ("google-meet", "Google Meet")
        }
        let callWords = ["meeting", "toplanti", "call", "arama"]
        guard callWords.contains(where: value.contains) else { return nil }
        if value.contains("microsoft teams") { return ("teams", "Microsoft Teams") }
        if value.contains("zoom") { return ("zoom", "Zoom") }
        if value.contains("webex") { return ("webex", "Webex") }
        return nil
    }
}

/// Debounces short microphone checks and hides a dismissed suggestion for the
/// remaining microphone session. Missing samples cannot instantly re-arm it.
struct MeetingDetectionPolicy {
    private struct Sighting {
        var meeting: DetectedMeeting
        let firstSeen: Date
        var lastSeen: Date
        var qualified: Bool
    }

    let activationDelay: TimeInterval
    let disappearanceDelay: TimeInterval
    let resumeDelay: TimeInterval
    private var sightings: [String: Sighting] = [:]
    private var dismissed = Set<String>()
    private var selectedID: String?
    private var isSuspended = false
    private var resumeAfter: Date?

    init(activationDelay: TimeInterval = 6, disappearanceDelay: TimeInterval = 20,
         resumeDelay: TimeInterval = 15) {
        self.activationDelay = activationDelay
        self.disappearanceDelay = disappearanceDelay
        self.resumeDelay = resumeDelay
    }

    mutating func observe(_ meetings: [DetectedMeeting], at now: Date) -> DetectedMeeting? {
        let currentIDs = Set(meetings.map(\.id))
        for (id, sighting) in sightings where now.timeIntervalSince(sighting.lastSeen) >= disappearanceDelay
                || (!sighting.qualified && !currentIDs.contains(id)) {
            sightings.removeValue(forKey: id)
            dismissed.remove(id)
            if selectedID == id { selectedID = nil }
        }
        for meeting in meetings {
            if var sighting = sightings[meeting.id] {
                sighting.meeting = meeting
                sighting.lastSeen = now
                sighting.qualified = sighting.qualified || now.timeIntervalSince(sighting.firstSeen) >= activationDelay
                sightings[meeting.id] = sighting
            } else {
                sightings[meeting.id] = Sighting(meeting: meeting, firstSeen: now, lastSeen: now,
                                                qualified: activationDelay <= 0)
            }
        }
        guard !isSuspended, resumeAfter.map({ now >= $0 }) ?? true else { return nil }
        let available = sightings.values.filter {
            !dismissed.contains($0.meeting.id) && $0.qualified
        }.sorted {
            if $0.meeting.confidence != $1.meeting.confidence {
                return $0.meeting.confidence.rawValue < $1.meeting.confidence.rawValue
            }
            return $0.meeting.id < $1.meeting.id
        }
        let selected = available.first { $0.meeting.id == selectedID } ?? available.first
        selectedID = selected?.meeting.id
        return selected?.meeting
    }

    mutating func dismissCurrentMeeting() {
        if let selectedID { dismissed.insert(selectedID) }
        selectedID = nil
    }

    mutating func setSuspended(_ suspended: Bool, at now: Date) {
        guard suspended != isSuspended else { return }
        isSuspended = suspended
        if !suspended { resumeAfter = now.addingTimeInterval(resumeDelay) }
    }

    mutating func reset() {
        sightings.removeAll()
        dismissed.removeAll()
        selectedID = nil
        resumeAfter = nil
    }
}

@MainActor
final class MeetingDetector: ObservableObject {
    @Published private(set) var candidate: DetectedMeeting?
    private var policy = MeetingDetectionPolicy()
    private var timer: Timer?
    private var isRunning = false
    private let sample: () -> [DetectedMeeting]
    private let now: () -> Date

    init(sample: (() -> [DetectedMeeting])? = nil, now: @escaping () -> Date = Date.init) {
        self.sample = sample ?? { MeetingDetectionReader.sample() }
        self.now = now
    }

    func start() {
        guard timer == nil else { return }
        isRunning = true
        poll()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in self?.poll() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        isRunning = false
        timer?.invalidate()
        timer = nil
        policy.reset()
        candidate = nil
    }

    func setSuspended(_ suspended: Bool) {
        policy.setSuspended(suspended, at: now())
        if suspended { candidate = nil }
    }

    func dismissCurrentMeeting() {
        policy.dismissCurrentMeeting()
        candidate = nil
    }

    private func poll() {
        guard isRunning else { return }
        candidate = policy.observe(sample(), at: now())
    }

    deinit { timer?.invalidate() }
}

@MainActor
private enum MeetingDetectionReader {
    static func sample() -> [DetectedMeeting] {
        let processes = audioProcesses()
        guard processes.contains(where: { $0.isInputRunning }) else { return [] }
        let windows: [MeetingBrowserWindow]
        // This only checks an existing grant. Detection never asks for screen,
        // microphone or Accessibility access and never creates an audio stream.
        if processes.contains(where: { MeetingDetectionSignals.browserID(for: $0.bundleIdentifier) != nil }),
           CGPreflightScreenCaptureAccess() {
            windows = visibleBrowserWindows()
        } else {
            windows = []
        }
        return MeetingDetectionSignals.detect(processes: processes, browserWindows: windows,
            ownProcessID: ProcessInfo.processInfo.processIdentifier,
            ownBundleIdentifier: Bundle.main.bundleIdentifier)
    }

    private static func audioProcesses() -> [MeetingAudioProcess] {
        var address = property(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        let system = AudioObjectID(kAudioObjectSystemObject)
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr,
              size > 0, size <= 1_048_576, size % UInt32(MemoryLayout<AudioObjectID>.size) == 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        let status = objects.withUnsafeMutableBytes {
            AudioObjectGetPropertyData(system, &address, 0, nil, &size, $0.baseAddress!)
        }
        guard status == noErr else { return [] }
        return objects.compactMap { object in
            guard let active = uint32(object, selector: kAudioProcessPropertyIsRunningInput), active != 0,
                  let processID = processID(object) else { return nil }
            let bundle = bundleIdentifier(object)
                ?? NSRunningApplication(processIdentifier: processID)?.bundleIdentifier
                ?? ""
            guard !bundle.isEmpty else { return nil }
            return MeetingAudioProcess(processID: processID, bundleIdentifier: bundle, isInputRunning: true)
        }
    }

    private static func visibleBrowserWindows() -> [MeetingBrowserWindow] {
        guard let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        return windows.compactMap { window in
            guard (window[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let process = window[kCGWindowOwnerPID as String] as? NSNumber,
                  let bundle = NSRunningApplication(processIdentifier: process.int32Value)?.bundleIdentifier,
                  MeetingDetectionSignals.browserID(for: bundle) != nil,
                  let title = window[kCGWindowName as String] as? String, !title.isEmpty else { return nil }
            return MeetingBrowserWindow(bundleIdentifier: bundle, title: title)
        }
    }

    private static func property(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func uint32(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = property(selector)
        var result: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }

    private static func processID(_ object: AudioObjectID) -> Int32? {
        var address = property(kAudioProcessPropertyPID)
        var result: pid_t = 0
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result
    }

    private static func bundleIdentifier(_ object: AudioObjectID) -> String? {
        var address = property(kAudioProcessPropertyBundleID)
        var result: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<CFString?>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &size, &result) == noErr else { return nil }
        return result?.takeRetainedValue() as String?
    }
}
