import AppKit
import QuartzCore
import SwiftUI
import XCTest
@testable import MeetingDesk

/// Opt-in native artifact generation, not a screenshot of the user's desktop.
/// Runs against the production RootView and a synthetic, isolated archive.
/// The external runner bounds this test process because AppKit rendering is synchronous.
final class WorkspaceVisualSnapshotTests: XCTestCase {
    @MainActor
    func testRenderProductionWorkspaceInBothAppearancesAndWindowSizes() throws {
        let environment = ProcessInfo.processInfo.environment
        guard let destination = environment["MEETINGDESK_UI_SNAPSHOT_DIR"], !destination.isEmpty else {
            throw XCTSkip("Opt-in native visual QA. Set MEETINGDESK_UI_SNAPSHOT_DIR to an empty output directory.")
        }
        guard let fixturePath = environment["MEETINGDESK_UI_FIXTURE_PATH"], !fixturePath.isEmpty else {
            XCTFail("MEETINGDESK_UI_FIXTURE_PATH must point to the supplied synthetic fixture JSON.")
            return
        }

        let output = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
        let fixtures = URL(fileURLWithPath: fixturePath).standardizedFileURL
        guard output.path != fixtures.deletingLastPathComponent().path else {
            XCTFail("Output must be separate from fixture source files.")
            return
        }
        let manager = FileManager.default
        if manager.fileExists(atPath: output.path) {
            guard try manager.contentsOfDirectory(atPath: output.path).isEmpty else {
                XCTFail("Use a fresh output directory; visual QA artifacts are never silently replaced.")
                return
            }
        } else {
            try manager.createDirectory(at: output, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fixture = try decoder.decode(SnapshotFixture.self, from: Data(contentsOf: fixtures))
        guard fixture.synthetic, fixture.meetings.count == 6,
              fixture.meetings.contains(where: { $0.id == fixture.selectedMeetingID }) else {
            XCTFail("Use the supplied six-meeting synthetic fixture.")
            return
        }

        let archive = output.appendingPathComponent("synthetic-archive", isDirectory: true)
        let library = MeetingLibrary(root: archive)
        for meeting in fixture.meetings {
            try library.save(meeting)
            if let name = meeting.audioFileName {
                let audio = library.directory(for: meeting.id).appendingPathComponent(name)
                // A local silent placeholder makes the real playback controls visible.
                // It is never played and is not evidence of live capture or audio quality.
                try silentWAV().write(to: audio)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: audio.path)
            }
        }
        let expectedArchiveHashes = try archiveContents(in: archive)

        let domain = "MeetingDesk.WorkspaceVisualSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(LocalSummaryBackend.apple.rawValue, forKey: LocalSummaryBackend.defaultsKey)
        defaults.set(false, forKey: "meetingdesk.speakerRecognitionEnabled")

        // In-memory argument-domain values isolate legacy properties that still read
        // standard preferences. No standard persistent preference is changed.
        let oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["meetingdesk.processingMode"] = ProcessingMode.local.rawValue
        arguments["meetingdesk.meetingDetectionEnabled"] = false
        arguments["meetingdesk.automaticLocalProcessing"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }

        let store = AppStore(root: archive, initializeSystemServices: false,
                             audioRetentionDefaults: defaults)
        store.selectedID = fixture.selectedMeetingID
        XCTAssertFalse(store.systemServicesEnabled)
        XCTAssertFalse(store.recorder.isRecording)
        XCTAssertNil(store.errorMessage)

        let app = NSApplication.shared
        let visibleWindowsBefore = app.windows.filter(\.isVisible).count
        var results = [[String: Any]]()
        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            defaults.set(appearance, forKey: "meetingdesk.appearance")
            for size in [NSSize(width: 1280, height: 850), NSSize(width: 900, height: 680), NSSize(width: 900, height: 620)] {
                let filename = "workspace-\(appearance)-\(Int(size.width))x\(Int(size.height)).png"
                let content = RootView(store: store, recorder: store.recorder)
                    .defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme)
                    .preferredColorScheme(scheme)
                    .frame(width: size.width, height: size.height)
                    .transaction { transaction in
                        transaction.animation = nil
                        transaction.disablesAnimations = true
                    }

                let image: NSBitmapImageRep
                let method: String
                if environment["MEETINGDESK_UI_RENDERER"] == "swiftui" {
                    let renderer = ImageRenderer(content: content)
                    renderer.proposedSize = ProposedViewSize(width: size.width, height: size.height)
                    renderer.scale = 1
                    image = NSBitmapImageRep(cgImage: try XCTUnwrap(renderer.cgImage,
                        "SwiftUI ImageRenderer returned no image; no desktop screenshot fallback is attempted."))
                    method = "ImageRenderer.productionRootView"
                } else {
                    let hosting = NSHostingView(rootView: content)
                    hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                    hosting.frame = NSRect(origin: .zero, size: size)
                    hosting.wantsLayer = true
                    hosting.layoutSubtreeIfNeeded()
                    // No NSWindow is created or ordered, and no app event loop is started.
                    RunLoop.main.run(until: Date().addingTimeInterval(0.12))
                    hosting.layoutSubtreeIfNeeded()
                    CATransaction.flush()
                    image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil,
                        pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
                    image.size = size
                    hosting.cacheDisplay(in: hosting.bounds, to: image)
                    method = "NSHostingView.detached.cacheDisplay.productionRootView"
                }

                XCTAssertEqual(image.pixelsWide, Int(size.width))
                XCTAssertEqual(image.pixelsHigh, Int(size.height))
                let richness = sampledColorCount(image)
                XCTAssertGreaterThan(richness, 12,
                    "Output may be blank or unsupported. Inspect the native artifact before claiming visual verification.")
                let png = try XCTUnwrap(image.representation(using: .png, properties: [:]))
                let path = output.appendingPathComponent(filename)
                try png.write(to: path, options: .atomic)
                try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
                results.append(["file": filename, "width": image.pixelsWide,
                                "height": image.pixelsHigh, "appearance": appearance,
                                "sampledColorCount": richness, "renderer": method])
            }
        }

        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            defaults.set(appearance, forKey: WorkspaceAppearance.defaultsKey)
            let variants: [(String, AnyView, NSSize)] = [
                ("quick-open", AnyView(WorkspaceQuickOpenView(meetings: store.meetings, selectedID: store.selectedID,
                    canNavigate: true, onSelect: { _ in })), NSSize(width: 600, height: 500)),
                ("settings", AnyView(WorkspaceSettingsView(store: store)), NSSize(width: 780, height: 660))
            ]
            for (name, content, size) in variants {
                let filename = "\(name)-\(appearance).png"
                try renderAdditional(content.defaultAppStorage(defaults).environment(\.colorScheme, scheme),
                    size: size, scheme: scheme, path: output.appendingPathComponent(filename))
                results.append(["file": filename, "width": Int(size.width), "height": Int(size.height), "appearance": appearance])
            }
            for (name, selected) in [("welcome", Optional<UUID>.none), ("new-meeting", fixture.meetings.first(where: { $0.segments.isEmpty && $0.audioFileName == nil && $0.notes == nil })?.id)] {
                store.selectedID = selected
                let filename = "\(name)-\(appearance)-900x620.png"
                try renderAdditional(RootView(store: store, recorder: store.recorder).defaultAppStorage(defaults)
                    .environment(\.colorScheme, scheme), size: NSSize(width: 900, height: 620), scheme: scheme,
                    path: output.appendingPathComponent(filename))
                results.append(["file": filename, "width": 900, "height": 620, "appearance": appearance])
            }
            store.selectedID = fixture.selectedMeetingID
        }

        // A second entirely synthetic archive exercises the actual transcript component.
        let conversationArchive = output.appendingPathComponent("synthetic-conversation", isDirectory: true)
        let conversationStore = AppStore(root: conversationArchive, initializeSystemServices: false, audioRetentionDefaults: defaults)
        var conversation = conversationStore.newMeeting()
        conversation.title = "Örnek konuşma akışı"
        conversation.duration = 60
        let ece = SpeakerReviewPerson(name: "Ece"), deniz = SpeakerReviewPerson(name: "Deniz")
        func segment(_ id: String, _ speaker: String, _ source: SpeakerAudioSource, _ start: Double, _ text: String) -> TranscriptSegment {
            let pieces = text.split(separator: " ").enumerated().map { index, value in
                TranscriptWord(text: String(value) + (index == text.split(separator: " ").count - 1 ? "" : " "), start: start + Double(index) * 0.5, end: start + Double(index + 1) * 0.5)
            }
            return TranscriptSegment(id: id, speaker: speaker, start: start, end: pieces.last!.end, text: text, words: pieces, audioSource: source)
        }
        conversation.segments = [
            segment("remote-one", "system:A", .system, 2, "Yeni arayüzün kayıt akışını bugün birlikte değerlendirelim."),
            segment("echo-one", "microphone:A", .microphone, 2.08, "Yeni arayüzün kayıt akışını bugün birlikte değerlendirelim."),
            segment("local-one", "microphone:B", .microphone, 8, "Önceki toplantıdan kalan kontrast kontrolünü tamamladım."),
            segment("remote-two", "system:A", .system, 14, "Güzel. Kayıt bittikten sonra notları da kontrol edelim."),
            segment("remote-three", "system:A", .system, 19, "Kısa ses parçalarıyla kararların kaynağını dinleyebiliriz.")
        ]
        conversation.speakerTurns = conversation.segments.map { .init(speakerID: $0.speaker, source: $0.audioSource!, start: $0.start, end: $0.end) }
        conversation.speakerReviewPeople = [ece, deniz]
        conversation.speakerReviewAssignments = ["system:A": ece.id, "microphone:A": ece.id, "microphone:B": deniz.id]
        conversation.speakerRecognitionEngine = "synthetic-fixture"
        XCTAssertTrue(conversationStore.update(conversation.id) { $0 = conversation })
        let conversationBefore = try archiveContents(in: conversationArchive)
        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            defaults.set(appearance, forKey: WorkspaceAppearance.defaultsKey)
            let content = TranscriptWorkspaceView(store: conversationStore, meeting: conversation, query: .constant(""), focusedSegmentID: .constant(nil), editingSegmentID: .constant(nil), onReviewSpeaker: { _ in })
            let filename = "transcript-\(appearance)-900x620.png"
            try renderAdditional(content.defaultAppStorage(defaults).environment(\.colorScheme, scheme),
                size: NSSize(width: 900, height: 620), scheme: scheme, path: output.appendingPathComponent(filename))
            results.append(["file": filename, "width": 900, "height": 620, "appearance": appearance])
        }
        XCTAssertEqual(try archiveContents(in: conversationArchive), conversationBefore)

        XCTAssertEqual(try archiveContents(in: archive), expectedArchiveHashes,
                       "Rendering must not mutate synthetic meeting data.")
        XCTAssertEqual(app.windows.filter(\.isVisible).count, visibleWindowsBefore)
        XCTAssertFalse(store.recorder.isRecording)
        XCTAssertFalse(store.isBusy)
        let report: [String: Any] = ["schemaVersion": 1, "synthetic": true,
            "productionView": "RootView", "images": results,
            "realArchiveAccessed": false, "launchServicesUsed": false,
            "visibleWindowCreated": false, "liveMicrophoneTested": false,
            "modelInferenceRequested": false, "interactionTested": false,
            "visualReviewRequired": true, "archiveUnchanged": true]
        let path = output.appendingPathComponent("render-report.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
            .write(to: path, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    @MainActor
    private func renderAdditional<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, path: URL) throws {
        let hosting = NSHostingView(rootView: content.preferredColorScheme(scheme).frame(width: size.width, height: size.height)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.12))
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        XCTAssertGreaterThan(sampledColorCount(image), 12)
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
    }

    private struct SnapshotFixture: Decodable {
        let synthetic: Bool
        let selectedMeetingID: UUID
        let meetings: [Meeting]
    }

    private func archiveContents(in root: URL) throws -> [String: Data] {
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        return try Dictionary(uniqueKeysWithValues: files.compactMap { dir -> (String, Data)? in
            let file = dir.appendingPathComponent("meeting.json")
            guard FileManager.default.fileExists(atPath: file.path) else { return nil }
            return (dir.lastPathComponent, try Data(contentsOf: file))
        })
    }

    private func sampledColorCount(_ image: NSBitmapImageRep) -> Int {
        var colors = Set<Int>()
        for y in stride(from: 0, to: image.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: image.pixelsWide, by: 16) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                      color.alphaComponent > 0.2 else { continue }
                let r = Int(color.redComponent * 31), g = Int(color.greenComponent * 31)
                let b = Int(color.blueComponent * 31)
                colors.insert((r << 10) | (g << 5) | b)
            }
        }
        return colors.count
    }

    private func silentWAV() -> Data {
        let samples: UInt32 = 4_000
        let bytes = samples * 2
        var data = Data()
        func text(_ value: String) { data.append(contentsOf: value.utf8) }
        func u16(_ value: UInt16) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        func u32(_ value: UInt32) { var v = value.littleEndian; withUnsafeBytes(of: &v) { data.append(contentsOf: $0) } }
        text("RIFF"); u32(36 + bytes); text("WAVEfmt "); u32(16)
        u16(1); u16(1); u32(16_000); u32(32_000); u16(2); u16(16)
        text("data"); u32(bytes); data.append(Data(repeating: 0, count: Int(bytes)))
        return data
    }
}
