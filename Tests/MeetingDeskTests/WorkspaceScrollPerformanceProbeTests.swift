import AppKit
import CoreGraphics
import QuartzCore
import SwiftUI
import XCTest
@testable import MeetingDesk

#if DEBUG
/// Opt-in diagnostic against production views. No timing assertion belongs in CI.
/// The runner must impose a 35 second total child-process deadline: a synchronous AppKit layout
/// cannot be interrupted by this test's cooperative deadline.
final class WorkspaceScrollPerformanceProbeTests: XCTestCase {
    @MainActor
    func testDetachedProductionWorkspaceIdleAndScroll() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MEETINGDESK_SCROLL_PROBE_OUTPUT"],
              !destination.isEmpty else {
            throw XCTSkip("Opt-in native scroll diagnostic; set MEETINGDESK_SCROLL_PROBE_OUTPUT.")
        }
        let output = URL(fileURLWithPath: destination).standardizedFileURL
        let manager = FileManager.default
        guard destination.hasPrefix("/"), !manager.fileExists(atPath: output.path) else {
            XCTFail("Choose a fresh absolute output file; probe reports are never replaced.")
            return
        }
        let started = CACurrentMediaTime()
        let deadline = started + 24
        let temporary = manager.temporaryDirectory.appendingPathComponent("MeetingDesk-Scroll-Probe-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: true,
                                    attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: temporary) }
        let archive = temporary.appendingPathComponent("synthetic-archive", isDirectory: true)
        let library = MeetingLibrary(root: archive)
        let meetings = (0..<10).map { fixture(index: $0, segmentCount: 2_000) }
        for meeting in meetings { try library.save(meeting) }
        let archiveBefore = try archiveContents(archive)

        // Suite and argument domains are in-memory only. No real persistent
        // preferences, recording source, model, or user's archive is modified.
        let domain = "MeetingDesk.ScrollProbe.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defaults.register(defaults: [LocalSummaryBackend.defaultsKey: LocalSummaryBackend.apple.rawValue,
                                    "meetingdesk.speakerRecognitionEnabled": false,
                                    "meetingdesk.speakerModelsReady": false,
                                    WorkspaceAppearance.defaultsKey: WorkspaceAppearance.light.rawValue])
        let previousArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = previousArguments
        arguments["meetingdesk.processingMode"] = ProcessingMode.local.rawValue
        arguments["meetingdesk.meetingDetectionEnabled"] = false
        arguments["meetingdesk.automaticLocalProcessing"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(previousArguments, forName: UserDefaults.argumentDomain) }

        let store = AppStore(root: archive, initializeSystemServices: false, audioRetentionDefaults: defaults)
        store.selectedID = meetings[0].id
        XCTAssertFalse(store.systemServicesEnabled)
        XCTAssertEqual(store.localSummaryBackend, .apple)
        XCTAssertFalse(store.recorder.isRecording)
        let app = NSApplication.shared
        let visibleWindowsBefore = app.windows.filter(\.isVisible).count
        var scenarios: [[String: Any]] = []
        let root = RootView(store: store, recorder: store.recorder)
        scenarios.append(try await exercise(root, name: "productionRootView.overview", defaults: defaults,
                                            size: NSSize(width: 1280, height: 850), deadline: deadline))
        if CACurrentMediaTime() < deadline {
            let transcript = TranscriptWorkspaceView(store: store, meeting: meetings[0],
                query: .constant(""), focusedSegmentID: .constant(nil),
                editingSegmentID: .constant(nil), onReviewSpeaker: { _ in })
            scenarios.append(try await exercise(transcript, name: "productionTranscriptWorkspaceView",
                defaults: defaults, size: NSSize(width: 900, height: 620), deadline: deadline))
        }
        let unchanged = try archiveContents(archive) == archiveBefore
        XCTAssertTrue(unchanged)
        XCTAssertEqual(app.windows.filter(\.isVisible).count, visibleWindowsBefore)
        XCTAssertFalse(store.recorder.isRecording)
        XCTAssertFalse(store.isBusy)
        let report: [String: Any] = [
            "schemaVersion": 1, "synthetic": true, "meetingCount": meetings.count,
            "segmentsPerMeeting": 2_000, "scenarios": scenarios,
            "probeWallMilliseconds": (CACurrentMediaTime() - started) * 1_000,
            "cooperativeDeadlineReached": CACurrentMediaTime() >= deadline,
            "archiveUnchanged": unchanged, "realArchiveAccessed": false,
            "persistentUserPreferencesModified": false, "modelInferenceRequested": false,
            "visibleWindowCreated": false, "hiddenWindowCreated": true, "capturePerformed": false,
            "physicalInputTested": false, "liveAppAcceptance": false,
            "limitations": ["Production NSHostingView attached to an owned hidden NSWindow; the window is never ordered or activated.",
                "Programmatic clip scrolling and direct local scrollWheel calls only; no globally posted input events.",
                "No display compositor, physical trackpad, live app, or real recordings were tested.",
                "Task.yield measures scheduler resume latency, not an AppKit event-loop or display turn.",
                "NSScrollView bridge discovery/displacement must be checked before interpreting scroll timing.",
                "An external process timeout is required for uninterruptible synchronous layout."]
        ]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try manager.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: output, options: .withoutOverwriting)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }

    @MainActor
    private func exercise<Content: View>(_ content: Content, name: String, defaults: UserDefaults,
        size: NSSize, deadline: CFTimeInterval) async throws -> [String: Any] {
        WorkspaceRenderProbe.start()
        defer { WorkspaceRenderProbe.stop() }
        let countsBeforeScenario = WorkspaceRenderProbe.snapshot()
        let requiresTranscript = name == "productionTranscriptWorkspaceView"
        let start = CACurrentMediaTime()
        let hosting = NSHostingView(rootView: content.defaultAppStorage(defaults)
            .environment(\.colorScheme, .light).preferredColorScheme(.light)
            .frame(width: size.width, height: size.height)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = NSAppearance(named: .aqua)
        hosting.wantsLayer = true
        // One bounded adaptation: SwiftUI may not establish native scroll
        // document geometry until its hosting view has moved into a window.
        // This owned window is never ordered, shown, or activated.
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.setContentSize(size)
        hosting.autoresizingMask = [.width, .height]
        defer { window.contentView = nil; window.close() }
        XCTAssertFalse(window.isVisible)
        let initialStart = CACurrentMediaTime()
        hosting.layoutSubtreeIfNeeded()
        let initialLayoutMilliseconds = milliseconds(since: initialStart)
        // A native draw is needed to commit SwiftUI's virtual scroll content
        // in an offscreen host. This draws only the owned synthetic view.
        let bitmap = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
            pixelsWide: Int(size.width), pixelsHigh: Int(size.height), bitsPerSample: 8,
            samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        bitmap.size = size
        // Detached SwiftUI .task work still needs actor turns. Allow bounded
        // settling, and report native document extent rather than assuming it ran.
        var settleLayouts = 0
        var lastExtents: [Int] = []
        var stablePasses = 0
        var preparationObserved = false
        while CACurrentMediaTime() < min(deadline, start + 4), stablePasses < 4 || (requiresTranscript && !preparationObserved) {
            try await Task.sleep(for: .milliseconds(40))
            hosting.layoutSubtreeIfNeeded()
            CATransaction.flush()
            if settleLayouts == 0 { hosting.cacheDisplay(in: hosting.bounds, to: bitmap) }
            settleLayouts += 1
            let extents = scrollViews(in: hosting).map { Int(documentHeight($0)) }
            stablePasses = extents == lastExtents && extents.contains(where: { $0 > Int(size.height) }) ? stablePasses + 1 : 0
            lastExtents = extents
            let counts = WorkspaceRenderProbe.snapshot()
            preparationObserved = counts["transcriptPrepare", default: 0] >= 1 &&
                counts["transcriptGroup", default: 0] >= 1 && counts["transcriptRow", default: 0] >= 1
        }
        let settlingMilliseconds = milliseconds(since: start)
        let countsAfterSettling = WorkspaceRenderProbe.snapshot()
        var idleLayout: [Double] = []
        var idleResume: [Double] = []
        var idleFrameWorkCounts: [[String: Int]] = []
        let countsBeforeIdle = WorkspaceRenderProbe.snapshot()
        for _ in 0..<12 where CACurrentMediaTime() < deadline {
            let beforeFrameCounts = WorkspaceRenderProbe.snapshot()
            let beforeYield = CACurrentMediaTime()
            await Task.yield()
            idleResume.append(milliseconds(since: beforeYield))
            let layoutStart = CACurrentMediaTime()
            hosting.layoutSubtreeIfNeeded()
            CATransaction.flush()
            idleLayout.append(milliseconds(since: layoutStart))
            try await Task.sleep(for: .milliseconds(16))
            idleFrameWorkCounts.append(countDelta(WorkspaceRenderProbe.snapshot(), beforeFrameCounts))
        }
        let countsAfterIdle = WorkspaceRenderProbe.snapshot()
        let discovered = scrollViews(in: hosting)
        var scrollResults: [[String: Any]] = []
        let countsBeforeScroll = WorkspaceRenderProbe.snapshot()
        for (index, scroll) in discovered.enumerated() where CACurrentMediaTime() < deadline {
            let countsBeforeNativeScroll = WorkspaceRenderProbe.snapshot()
            let clip = scroll.contentView
            let geometryBefore = geometry(scroll)
            let initial = clip.bounds.origin
            var synchronous: [Double] = []
            var actorResume: [Double] = []
            var frameWork: [Double] = []
            var followupLayout: [Double] = []
            var timerOvershoot: [Double] = []
            var actualMoves = 0
            var directScrollWheelCalls = 0
            var scrollWheelOffsetChanges = 0
            var maximumExtent: CGFloat = 0
            var maximumOffset: CGFloat = initial.y
            var scrollFrameWorkCounts: [[String: Int]] = []
            // Includes incremental movement, reversal, and jumps so lazy layout
            // is exercised at more than the initial viewport.
            for frame in 0..<36 where CACurrentMediaTime() < deadline {
                let beforeFrameCounts = WorkspaceRenderProbe.snapshot()
                let frameStart = CACurrentMediaTime()
                let extent = max(0, documentHeight(scroll) - clip.bounds.height)
                maximumExtent = max(maximumExtent, extent)
                let fraction: CGFloat
                if frame < 12 { fraction = CGFloat(frame + 1) / 24 }
                else if frame < 24 { fraction = 1 - CGFloat(frame - 11) / 24 }
                else { fraction = frame.isMultiple(of: 2) ? 0.95 : 0.05 }
                let before = clip.bounds.origin
                let operationStart = CACurrentMediaTime()
                clip.scroll(to: NSPoint(x: before.x, y: extent * fraction))
                scroll.reflectScrolledClipView(clip)
                hosting.layoutSubtreeIfNeeded()
                CATransaction.flush()
                if abs(clip.bounds.origin.y - before.y) <= 0.5 {
                    // Directly invoke this owned scroll view only. Constructed
                    // events are never posted through CGEvent or NSApplication.
                    let pixels: Int32 = frame < 18 ? -100 : 100
                    if let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                        wheelCount: 1, wheel1: pixels, wheel2: 0, wheel3: 0),
                       let event = NSEvent(cgEvent: cg) {
                        directScrollWheelCalls += 1
                        let beforeWheel = clip.bounds.origin
                        scroll.scrollWheel(with: event)
                        hosting.layoutSubtreeIfNeeded()
                        CATransaction.flush()
                        if abs(clip.bounds.origin.y - beforeWheel.y) > 0.5 { scrollWheelOffsetChanges += 1 }
                    }
                }
                synchronous.append(milliseconds(since: operationStart))
                let yieldStart = CACurrentMediaTime()
                await Task.yield()
                actorResume.append(milliseconds(since: yieldStart))
                let followupStart = CACurrentMediaTime()
                hosting.layoutSubtreeIfNeeded()
                CATransaction.flush()
                followupLayout.append(milliseconds(since: followupStart))
                frameWork.append(milliseconds(since: frameStart))
                let sleepStart = CACurrentMediaTime()
                try await Task.sleep(for: .milliseconds(16))
                timerOvershoot.append(max(0, milliseconds(since: sleepStart) - 16))
                if abs(clip.bounds.origin.y - before.y) > 0.5 { actualMoves += 1 }
                maximumOffset = max(maximumOffset, clip.bounds.origin.y)
                maximumExtent = max(maximumExtent, max(0, documentHeight(scroll) - clip.bounds.height))
                scrollFrameWorkCounts.append(countDelta(WorkspaceRenderProbe.snapshot(), beforeFrameCounts))
            }
            let geometryAfterScroll = geometry(scroll)
            clip.scroll(to: initial)
            scroll.reflectScrolledClipView(clip)
            scrollResults.append([
                "nativeScrollIndex": index, "nativeClass": String(describing: type(of: scroll)),
                "contentRole": "unmapped.productionSubtree",
                "viewportWidth": Double(clip.bounds.width), "viewportHeight": Double(clip.bounds.height),
                "maximumVerticalExtent": Double(maximumExtent), "maximumObservedOffset": Double(maximumOffset),
                "nativeGeometryBefore": geometryBefore, "nativeGeometryAfter": geometryAfterScroll,
                "directLocalScrollWheelCalls": directScrollWheelCalls,
                "directLocalScrollWheelOffsetChanges": scrollWheelOffsetChanges,
                "actualOffsetChanges": actualMoves, "sampledFrames": synchronous.count,
                "scrollBridgeAccessible": true, "scrollDisplacementVerified": actualMoves > 0 && maximumExtent > 0,
                "scrollAndSynchronousLayoutMilliseconds": summary(synchronous),
                "mainActorYieldResumeMilliseconds": summary(actorResume),
                "postYieldLayoutMilliseconds": summary(followupLayout),
                "scrollFrameWorkMilliseconds": summary(frameWork),
                "timerOvershootMilliseconds": summary(timerOvershoot),
                "explicitLayoutsPerFrameBase": 2,
                "explicitLayoutsTotal": synchronous.count * 2 + directScrollWheelCalls,
                "workCountsTotal": countDelta(WorkspaceRenderProbe.snapshot(), countsBeforeNativeScroll),
                "workCountsMaxPerFrame": maximumCounts(scrollFrameWorkCounts),
                "workCountsByFrame": scrollFrameWorkCounts,
                "nativeViewCountAfterScroll": nativeViewCount(hosting)
            ])
        }
        let countsAfterScenario = WorkspaceRenderProbe.snapshot()
        let displaced = scrollResults.contains { ($0["scrollDisplacementVerified"] as? Bool) == true && ($0["maximumVerticalExtent"] as? Double ?? 0) > 0 }
        let transcriptReady = preparationObserved && displaced
        return ["scenario": name, "width": Double(size.width), "height": Double(size.height),
            "initialLayoutMilliseconds": initialLayoutMilliseconds, "settlingLayouts": settleLayouts,
            "settlingMilliseconds": settlingMilliseconds,
            "idleLayoutMilliseconds": summary(idleLayout), "idleMainActorYieldResumeMilliseconds": summary(idleResume),
            "nativeScrollViewsDiscovered": discovered.count, "scrollViews": scrollResults,
            "nativeViewCount": nativeViewCount(hosting), "scenarioWallMilliseconds": milliseconds(since: start),
            "hiddenWindowCreated": true, "windowVisible": window.isVisible,
            "scrollEventDelivery": "directLocalNSScrollViewOnly.noGlobalPosting",
            "presentationReadiness": requiresTranscript ? (transcriptReady ? "prepareGroupRowsAndScrollVerified" : "unverified") : "rootOverview.nativeScrollOnly",
            "transcriptPreparationObserved": preparationObserved,
            "transcriptReadinessVerified": requiresTranscript && transcriptReady,
            "presentationCountersAccessible": true,
            "workCountsBeforeScenario": countsBeforeScenario,
            "workCountsAfterScenario": countsAfterScenario,
            "workCountsTotal": countDelta(countsAfterScenario, countsBeforeScenario),
            "workCountsSettling": countDelta(countsAfterSettling, countsBeforeScenario),
            "workCountsBeforeIdle": countsBeforeIdle, "workCountsAfterIdle": countsAfterIdle,
            "workCountsIdle": countDelta(countsAfterIdle, countsBeforeIdle),
            "idleWorkCountsByFrame": idleFrameWorkCounts,
            "idleWorkCountsMaxPerFrame": maximumCounts(idleFrameWorkCounts),
            "workCountsBeforeScroll": countsBeforeScroll, "workCountsAfterScroll": countsAfterScenario,
            "workCountsScroll": countDelta(countsAfterScenario, countsBeforeScroll),
            "workCounterLimitation": "DEBUG scalar body/pipeline/disk-query counts; no content and no physical-input or compositor measurement.",
            "deadlineReached": CACurrentMediaTime() >= deadline]
    }

    private func countDelta(_ after: [String: Int], _ before: [String: Int]) -> [String: Int] {
        Dictionary(uniqueKeysWithValues: Set(after.keys).union(before.keys).sorted().map {
            ($0, after[$0, default: 0] - before[$0, default: 0])
        })
    }
    private func maximumCounts(_ frames: [[String: Int]]) -> [String: Int] {
        var result: [String: Int] = [:]
        for frame in frames { for (key, value) in frame { result[key] = max(result[key, default: 0], value) } }
        return result
    }

    @MainActor private func documentHeight(_ scroll: NSScrollView) -> CGFloat {
        max(scroll.contentView.documentRect.height,
            scroll.documentView?.bounds.height ?? 0, scroll.documentView?.frame.height ?? 0)
    }
    @MainActor private func geometry(_ scroll: NSScrollView) -> [String: Any] {
        func rect(_ value: NSRect) -> [String: Double] {
            ["x": Double(value.origin.x), "y": Double(value.origin.y),
             "width": Double(value.width), "height": Double(value.height)]
        }
        return ["clipBounds": rect(scroll.contentView.bounds),
            "clipDocumentRect": rect(scroll.contentView.documentRect),
            "documentViewPresent": scroll.documentView != nil,
            "documentBounds": rect(scroll.documentView?.bounds ?? .zero),
            "documentFrame": rect(scroll.documentView?.frame ?? .zero),
            "documentVisibleRect": rect(scroll.documentVisibleRect),
            "verticalScrollerPresent": scroll.verticalScroller != nil,
            "verticalScrollerValue": scroll.verticalScroller?.doubleValue ?? -1,
            "verticalScrollerKnobProportion": Double(scroll.verticalScroller?.knobProportion ?? 0)]
    }

    @MainActor private func scrollViews(in view: NSView) -> [NSScrollView] {
        let own = (view as? NSScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { scrollViews(in: $0) }
    }
    @MainActor private func nativeViewCount(_ view: NSView) -> Int {
        1 + view.subviews.reduce(0) { $0 + nativeViewCount($1) }
    }
    private func milliseconds(since start: CFTimeInterval) -> Double { (CACurrentMediaTime() - start) * 1_000 }
    private func summary(_ values: [Double]) -> [String: Any] {
        let ordered = values.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !ordered.isEmpty else { return 0 }
            return ordered[min(ordered.count - 1, max(0, Int(ceil(Double(ordered.count) * fraction)) - 1))]
        }
        return ["count": values.count, "p50": percentile(0.5), "p95": percentile(0.95),
            "max": ordered.last ?? 0, "over16_67ms": values.filter { $0 > 16.67 }.count,
            "over50ms": values.filter { $0 > 50 }.count]
    }
    private func fixture(index: Int, segmentCount: Int) -> Meeting {
        var segments: [TranscriptSegment] = []
        segments.reserveCapacity(segmentCount)
        for number in 0..<segmentCount {
            let identifier: String = "synthetic-" + String(index) + "-" + String(number)
            let source: SpeakerAudioSource = number.isMultiple(of: 2) ? .system : .microphone
            let speakerPrefix: String = number.isMultiple(of: 2) ? "system:" : "microphone:"
            let speaker: String = speakerPrefix + String(number % 8)
            let text: String = "Sentetik performans örneği " + String(number)
                + ". Kısa notları ve takip işlerini birlikte değerlendiriyoruz."
            let start: Double = Double(number * 3)
            let segment = TranscriptSegment(id: identifier, speaker: speaker, start: start,
                end: start + 2, text: text, audioSource: source)
            segments.append(segment)
        }
        func source(_ number: Int) -> [String] { [segments[min(number * 30, segmentCount - 1)].id] }
        let notes = MeetingNotes(summary: "Bu kayıt yalnızca yerel arayüz performansı için üretilmiş örnek veridir.",
            decisions: (0..<4).map { .init(id: "decision-\($0)", text: "Örnek karar \($0)", evidence: source($0)) },
            actions: (0..<8).map { .init(id: "action-\($0)", text: "Örnek takip işi \($0)", owner: nil, due: nil, evidence: source($0 + 4)) },
            questions: (0..<4).map { .init(id: "question-\($0)", text: "Örnek açık konu \($0)", evidence: source($0 + 12)) },
            ideas: (0..<4).map { .init(id: "idea-\($0)", text: "Örnek öneri \($0)", evidence: source($0 + 16)) },
            topics: (0..<8).map { .init(id: "topic-\($0)", title: "Örnek başlık \($0)",
                text: "Kısa, sentetik bir konu açıklaması. Arayüzde kaydırma sırasında yerleşim çalışmasını ölçer.", evidence: source($0 + 20)) })
        return Meeting(title: "Sentetik toplantı \(index)", createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(index * 60)),
            duration: Double(segmentCount * 3), segments: segments, notes: notes,
            personalNotes: Array(repeating: "Yalnızca sentetik kişisel not örneği.", count: 30).joined(separator: "\n"),
            source: "Sentetik", transcriptionEngine: ProcessingMode.local.rawValue)
    }
    private func archiveContents(_ root: URL) throws -> [String: Data] {
        try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: root,
            includingPropertiesForKeys: nil).compactMap { directory -> (String, Data)? in
                let file = directory.appendingPathComponent("meeting.json")
                guard FileManager.default.fileExists(atPath: file.path) else { return nil }
                return (directory.lastPathComponent, try Data(contentsOf: file))
            })
    }
}
#endif
