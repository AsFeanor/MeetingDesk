import Foundation

/// Opt-in counters for native development probes. Never publishes UI state,
/// records content, writes files, or performs work in the release application.
enum WorkspaceRenderProbe {
    enum Event: String {
        case rootBody, detailBody, overviewBody, sidebarBody, sidebarRow
        case transcriptBody, transcriptRow, transcriptPrepare, transcriptGroup
        case playbackSourceChecks, recoveryChecks, historyChecks
    }
    #if DEBUG
    private static let lock = NSLock()
    private static var enabled = false
    private static var counts: [String: Int] = [:]
    static func start() { lock.lock(); defer { lock.unlock() }; counts = [:]; enabled = true }
    static func stop() { lock.lock(); defer { lock.unlock() }; enabled = false }
    static func snapshot() -> [String: Int] { lock.lock(); defer { lock.unlock() }; return counts }
    #endif
    @inline(__always) static func record(_ event: Event) {
        #if DEBUG
        lock.lock(); defer { lock.unlock() }
        if enabled { counts[event.rawValue, default: 0] += 1 }
        #endif
    }
}
