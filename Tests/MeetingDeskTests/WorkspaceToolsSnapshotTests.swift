import AppKit
import CryptoKit
import QuartzCore
import SwiftUI
import XCTest
@testable import MeetingDesk

/// Opt-in native renders of production tool views, using only generated synthetic data.
/// No window, desktop screenshot, recording, playback, or model request is used.
final class WorkspaceToolsSnapshotTests: XCTestCase {
    @MainActor
    func testRenderProductionToolsInBothAppearancesWithoutChangingSyntheticArchive() async throws {
        guard let destination = ProcessInfo.processInfo.environment["MEETINGDESK_TOOLS_SNAPSHOT_DIR"], !destination.isEmpty else {
            throw XCTSkip("Opt-in native tool visual QA. Set MEETINGDESK_TOOLS_SNAPSHOT_DIR to a fresh output directory.")
        }
        let manager = FileManager.default
        let output = URL(fileURLWithPath: destination, isDirectory: true).standardizedFileURL
        let userArchive = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MeetingDesk", isDirectory: true).standardizedFileURL
        guard output != userArchive, !output.path.hasPrefix(userArchive.path + "/") else {
            XCTFail("Visual output must be outside the user meeting archive.")
            return
        }
        if manager.fileExists(atPath: output.path) {
            guard try manager.contentsOfDirectory(atPath: output.path).isEmpty else {
                XCTFail("Use a fresh output directory; existing visual artifacts are never replaced.")
                return
            }
        } else {
            try manager.createDirectory(at: output, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        let archive = manager.temporaryDirectory.appendingPathComponent("MeetingDesk-ToolsSnapshot-\(UUID())", isDirectory: true)
        defer { try? manager.removeItem(at: archive) }
        let domain = "MeetingDesk.WorkspaceToolsSnapshotTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        defer { defaults.removePersistentDomain(forName: domain) }
        defaults.set(LocalSummaryBackend.apple.rawValue, forKey: LocalSummaryBackend.defaultsKey)
        defaults.set(false, forKey: "meetingdesk.speakerRecognitionEnabled")

        // Legacy properties read standard preferences. A volatile argument domain
        // isolates those reads without changing any persistent user preferences.
        let oldArguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
        var arguments = oldArguments
        arguments["meetingdesk.processingMode"] = ProcessingMode.local.rawValue
        arguments["meetingdesk.meetingDetectionEnabled"] = false
        arguments["meetingdesk.automaticLocalProcessing"] = false
        UserDefaults.standard.setVolatileDomain(arguments, forName: UserDefaults.argumentDomain)
        defer { UserDefaults.standard.setVolatileDomain(oldArguments, forName: UserDefaults.argumentDomain) }

        let store = AppStore(root: archive, initializeSystemServices: false, audioRetentionDefaults: defaults)
        XCTAssertFalse(store.systemServicesEnabled)
        let projectID = try XCTUnwrap(store.createProject(name: "Sentetik · Orion ürün projesi"))
        let seriesID = try XCTUnwrap(store.createSeries(name: "Sentetik · Haftalık ürün görüşmesi", projectID: projectID))
        let fixtureDate = Date(timeIntervalSince1970: 1_794_700_800)

        var previous = store.newMeeting()
        previous.title = "Sentetik · Önceki ürün değerlendirmesi"
        previous.createdAt = fixtureDate.addingTimeInterval(-7 * 86_400)
        previous.duration = 180
        previous.segments = [
            .init(id: "prior-decision", speaker: "A", start: 12, end: 30,
                  text: "Müşteri sunumunda yalnız doğrulanmış örnekleri gösterme kararı aldık.", audioSource: .system),
            .init(id: "prior-action", speaker: "B", start: 48, end: 65,
                  text: "Deneme verilerini hazırlamayı ben üstleniyorum.", audioSource: .microphone)
        ]
        previous.speakerNames = ["A": "Ece (sentetik)", "B": "Deniz (sentetik)"]
        previous.notes = .init(summary: "Sunum kapsamı daraltıldı; yalnız doğrulanmış örnekler kullanılacak.",
            decisions: [.init(id: "prior-d1", text: "Sunumda doğrulanmış örnekler kullanılsın.", evidence: ["prior-decision"])],
            actions: [.init(id: "prepare", text: "Sunum için sentetik deneme verilerini hazırla.", owner: "Deniz (sentetik)", due: "gelecek cuma", evidence: ["prior-action"])],
            questions: [], ideas: [], topics: [])
        previous.bookmarks = [.init(time: 16, note: "Sunum kapsamı kararı")]
        guard store.update(previous.id, { $0 = previous }),
              store.assignMeeting(previous.id, projectID: projectID, seriesID: seriesID) else {
            throw MeetingError.message("Sentetik önceki toplantı hazırlanamadı.")
        }

        var current = store.newMeeting()
        current.title = "Sentetik · Orion planlama ve sonraki adımlar"
        current.createdAt = fixtureDate
        current.duration = 210
        current.segments = [
            .init(id: "current-overview", speaker: "A", start: 0, end: 18,
                  text: "Bugün orion crm sunumunun kapsamını ve kuzay ekibi için yapılacakları gözden geçirelim.", audioSource: .system),
            .init(id: "current-decision", speaker: "B", start: 24, end: 42,
                  text: "Yeni akışı gelecek hafta küçük bir deneme grubuna açmaya karar verdik.", audioSource: .microphone),
            .init(id: "current-action", speaker: "A", start: 60, end: 88,
                  text: "Ece kontrol listesini hazırlayacak. Geri bildirimlerin tek yerde toplanması gerekiyor.", audioSource: .system),
            .init(id: "current-open", speaker: "B", start: 120, end: 145,
                  text: "orion crm için veri aktarımı konusu açık kaldı; bugün sorumlu veya tarih belirlemedik.", audioSource: .microphone)
        ]
        current.speakerNames = ["A": "Ece (sentetik)", "B": "Deniz (sentetik)"]
        current.notes = .init(summary: "Deneme grubunun kapsamı belirlendi. Kontrol listesi hazırlanacak; veri aktarımının sorumlusu ve tarihi henüz belirlenmedi.",
            decisions: [.init(id: "current-d1", text: "Yeni akış küçük bir deneme grubuna açılsın.", evidence: ["current-decision"])],
            actions: [
                .init(id: "prepare", text: "Deneme grubunun kontrol listesini ve geri bildirim toplama adımlarını hazırla.", owner: "Ece (sentetik)", due: "gelecek hafta", evidence: ["current-action"]),
                .init(id: "migration", text: "Veri aktarımının kapsamını netleştir.", owner: nil, due: nil, evidence: ["current-open"]),
                .init(id: "done", text: "Sunum kapsamını doğrula.", owner: "Deniz (sentetik)", due: nil, evidence: ["current-decision"])
            ], questions: [.init(id: "question", text: "Veri aktarımını kim takip edecek?", evidence: ["current-open"])], ideas: [], topics: [])
        current.completedActions = ["done"]
        current.previousMeetingID = previous.id
        current.bookmarks = [.init(time: 28, note: "Deneme grubuyla ilgili karar"), .init(time: 132, note: "")]
        guard store.update(current.id, { $0 = current }),
              store.assignMeeting(current.id, projectID: projectID, seriesID: seriesID),
              store.saveGlossaryEntry(.init(canonical: "OrionCRM", variants: ["orion crm", "oryon"])),
              store.saveGlossaryEntry(.init(canonical: "Kuzey Ekibi", variants: ["kuzay ekibi"])) else {
            throw MeetingError.message("Sentetik araç verileri hazırlanamadı.")
        }
        store.selectedID = current.id
        let currentMeeting = try XCTUnwrap(store.meetings.first { $0.id == current.id })
        let expectedMeetings = store.meetings
        let expectedCatalog = store.workspaceCatalog
        let expectedGlossary = store.glossaryEntries
        let beforeHashes = try archiveHashes(in: archive)
        XCTAssertNotNil(beforeHashes[".workspace-catalog.json"])
        XCTAssertNotNil(beforeHashes[".transcript-glossary.json"])
        XCTAssertEqual(store.meetings.count, 2)
        XCTAssertFalse(TranscriptGlossary.suggestions(segments: currentMeeting.segments, entries: store.glossaryEntries).isEmpty)
        XCTAssertNil(store.errorMessage)
        XCTAssertFalse(store.workInProgress)

        let callbacks = RenderCallbacks()
        let onOpenMeeting: (UUID, String?) -> Void = { _, _ in
            callbacks.navigation += 1; XCTFail("Rendering must not navigate to a meeting or source.")
        }
        let scopes = [ArchiveQuestionScope(id: "synthetic-project", title: "Sentetik · Orion ürün projesi",
            meetingIDs: Set(store.meetings.map(\.id)))]
        let app = NSApplication.shared
        let visibleWindowsBefore = app.windows.filter(\.isVisible).count
        var results = [[String: Any]]()

        for (appearance, scheme) in [("light", ColorScheme.light), ("dark", ColorScheme.dark)] {
            defaults.set(appearance, forKey: WorkspaceAppearance.defaultsKey)
            let variants: [(name: String, view: AnyView, size: NSSize, state: String)] = [
                ("work-items", AnyView(WorkItemsView(store: store, onOpenMeeting: onOpenMeeting)),
                    NSSize(width: 900, height: 680), "Open tasks, including unknown owner and literal due strings"),
                ("projects", AnyView(ProjectSeriesView(store: store, initialProjectID: projectID, initialSeriesID: seriesID,
                    onOpenMeeting: onOpenMeeting)), NSSize(width: 900, height: 620), "Current meeting series with two associated meetings and source history"),
                ("archive-question", AnyView(MeetingArchiveQuestionView(meetings: store.meetings, scopes: scopes,
                    isBusy: false, canNavigate: true, onAsk: { _, _ in
                        callbacks.modelRequests += 1
                        XCTFail("Native rendering must never invoke an archive model request.")
                        throw MeetingError.message("Görsel kontrol sırasında model çağrısı yapılmaz.")
                    }, onOpenSource: { _, _ in
                        callbacks.navigation += 1; XCTFail("Rendering must not open an archive source.")
                    })), NSSize(width: 900, height: 680), "Initial question form and populated scope selector; no generated answer"),
                ("glossary", AnyView(GlossaryView(store: store)), NSSize(width: 680, height: 620), "Two saved synthetic dictionary entries"),
                ("glossary-review", AnyView(GlossaryReviewView(store: store, meetingID: currentMeeting.id,
                    canPlay: { _ in false }, onPlay: { _ in
                        callbacks.playback += 1; XCTFail("Rendering must not play audio.")
                    })), NSSize(width: 900, height: 680), "Exact-match suggestion list; no suggestion selected or applied"),
                ("bookmarks", AnyView(MeetingBookmarksView(store: store, meeting: currentMeeting, onOpen: { _ in
                    callbacks.navigation += 1; XCTFail("Rendering must not open a bookmark.")
                }).padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .foregroundStyle(WorkspaceStyle.ink).background(WorkspaceStyle.canvas)),
                    NSSize(width: 900, height: 620), "Two original meeting bookmarks in a neutral test canvas"),
                ("work-items-compact", AnyView(WorkItemsView(store: store, onOpenMeeting: onOpenMeeting)),
                    NSSize(width: 900, height: 620), "Open tasks at compact height")
            ]
            for variant in variants {
                let filename = "\(variant.name)-\(appearance)-\(Int(variant.size.width))x\(Int(variant.size.height)).png"
                let richness = try await render(variant.view.defaultAppStorage(defaults).environment(\.colorScheme, scheme),
                    size: variant.size, scheme: scheme, path: output.appendingPathComponent(filename))
                results.append(["file": filename, "view": variant.name, "appearance": appearance,
                    "width": Int(variant.size.width), "height": Int(variant.size.height),
                    "state": variant.state, "sampledColorCount": richness,
                    "renderer": "NSHostingView.detached.cacheDisplay.productionToolView"])
            }
        }

        let afterHashes = try archiveHashes(in: archive)
        XCTAssertEqual(afterHashes, beforeHashes, "Native rendering must not change any synthetic archive file, including hidden catalogs.")
        XCTAssertEqual(store.meetings, expectedMeetings)
        XCTAssertEqual(store.workspaceCatalog, expectedCatalog)
        XCTAssertEqual(store.glossaryEntries, expectedGlossary)
        XCTAssertEqual(store.selectedID, currentMeeting.id)
        XCTAssertEqual(app.windows.filter(\.isVisible).count, visibleWindowsBefore)
        XCTAssertFalse(store.recorder.isRecording)
        XCTAssertFalse(store.isBusy)
        XCTAssertEqual(callbacks.modelRequests, 0)
        XCTAssertEqual(callbacks.navigation, 0)
        XCTAssertEqual(callbacks.playback, 0)
        XCTAssertEqual(results.count, 14)
        XCTAssertNil(store.errorMessage)
        try manager.removeItem(at: archive)
        let archiveRemoved = !manager.fileExists(atPath: archive.path)
        XCTAssertTrue(archiveRemoved)

        let report: [String: Any] = [
            "schemaVersion": 1, "synthetic": true, "images": results,
            "meetingCount": 2, "archiveFileSHA256Before": beforeHashes, "archiveFileSHA256After": afterHashes,
            "archiveUnchanged": beforeHashes == afterHashes, "syntheticArchiveRemovedAfterTest": archiveRemoved,
            "realArchiveAccessed": false, "windowCreatedByTest": false, "desktopScreenshotUsed": false,
            "visibleWindowCountBefore": visibleWindowsBefore, "visibleWindowCountAfter": app.windows.filter(\.isVisible).count,
            "modelInferenceRequested": callbacks.modelRequests != 0, "liveMicrophoneTested": false,
            "audioPlaybackRequested": callbacks.playback != 0, "navigationRequested": callbacks.navigation != 0,
            "interactionTested": false, "visualReviewRequired": true,
            "coverageLimitations": ["Archive Q&A initial form only; no model inference or generated answer",
                "Glossary suggestions are listed; explicit selection, comparison and application require interactive QA",
                "Bookmarks are the production component inside a neutral test canvas"]
        ]
        let reportURL = output.appendingPathComponent("tools-render-report.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL, options: .atomic)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: reportURL.path)
    }

    @MainActor
    private final class RenderCallbacks {
        var modelRequests = 0
        var navigation = 0
        var playback = 0
    }

    @MainActor
    private func render<Content: View>(_ content: Content, size: NSSize, scheme: ColorScheme, path: URL) async throws -> Int {
        let hosting = NSHostingView(rootView: content.preferredColorScheme(scheme).frame(width: size.width, height: size.height)
            .transaction { $0.animation = nil; $0.disablesAnimations = true })
        hosting.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.wantsLayer = true
        hosting.layoutSubtreeIfNeeded()
        // Release the main actor so production .task/onAppear work can settle.
        // No NSWindow or app event loop is created, and no desktop is captured.
        try await Task.sleep(for: .milliseconds(250))
        hosting.layoutSubtreeIfNeeded()
        CATransaction.flush()
        let image = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        image.size = size
        hosting.cacheDisplay(in: hosting.bounds, to: image)
        let richness = sampledColorCount(image)
        XCTAssertGreaterThan(richness, 8, "Flat native cards must still contain text/control colors, not a blank canvas.")
        var opaque = 0, samples = 0
        for y in stride(from: 0, to: image.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: image.pixelsWide, by: 16) {
                samples += 1
                if let color = image.colorAt(x: x, y: y), color.alphaComponent > 0.95 { opaque += 1 }
            }
        }
        XCTAssertGreaterThan(Double(opaque) / Double(max(1, samples)), 0.95, "Production tool background must render across the full canvas: \(path.lastPathComponent)")
        XCTAssertEqual(image.pixelsWide, Int(size.width)); XCTAssertEqual(image.pixelsHigh, Int(size.height))
        try XCTUnwrap(image.representation(using: .png, properties: [:])).write(to: path, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: path.path)
        return richness
    }

    private func archiveHashes(in root: URL) throws -> [String: String] {
        let resourceKeys: [URLResourceKey] = [.isRegularFileKey]
        let canonicalRoot = root.resolvingSymlinksInPath()
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: canonicalRoot, includingPropertiesForKeys: resourceKeys))
        var values: [String: String] = [:]
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: Set(resourceKeys)).isRegularFile == true else { continue }
            let relative = String(file.resolvingSymlinksInPath().path.dropFirst(canonicalRoot.path.count + 1))
            values[relative] = SHA256.hash(data: try Data(contentsOf: file)).map { String(format: "%02x", $0) }.joined()
        }
        return values
    }

    private func sampledColorCount(_ image: NSBitmapImageRep) -> Int {
        var colors: Set<Int> = []
        for y in stride(from: 0, to: image.pixelsHigh, by: 16) {
            for x in stride(from: 0, to: image.pixelsWide, by: 16) {
                guard let color = image.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB), color.alphaComponent > 0.2 else { continue }
                let red = Int(color.redComponent * 31), green = Int(color.greenComponent * 31), blue = Int(color.blueComponent * 31)
                colors.insert((red << 10) | (green << 5) | blue)
            }
        }
        return colors.count
    }
}
