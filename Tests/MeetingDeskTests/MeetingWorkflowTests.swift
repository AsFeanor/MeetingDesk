import XCTest
import AVFoundation
@testable import MeetingDesk

final class MeetingWorkflowTests: XCTestCase {
    func testAutomaticProcessingNeverStartsPaidOrFailedOrInterruptedCapture() {
        XCTAssertTrue(AutomaticProcessingPolicy.shouldRun(enabled: true, mode: .local, saved: true, interrupted: false))
        XCTAssertFalse(AutomaticProcessingPolicy.shouldRun(enabled: true, mode: .openAI, saved: true, interrupted: false))
        XCTAssertFalse(AutomaticProcessingPolicy.shouldRun(enabled: false, mode: .local, saved: true, interrupted: false))
        XCTAssertFalse(AutomaticProcessingPolicy.shouldRun(enabled: true, mode: .local, saved: false, interrupted: false))
        XCTAssertFalse(AutomaticProcessingPolicy.shouldRun(enabled: true, mode: .local, saved: true, interrupted: true))
    }

    func testWorkflowKeepsOriginalMeetingWhenSelectionChanges() async throws {
        let original = UUID()
        var selected = original
        var processed: [UUID] = []
        try await MeetingWorkflowRunner.run(meetingID: original, transcribe: { id in
            processed.append(id); selected = UUID()
        }, summarize: { id in processed.append(id) })
        XCTAssertNotEqual(selected, original)
        XCTAssertEqual(processed, [original, original])
    }

    func testFailedTranscriptPreventsSummary() async {
        var summaryCalled = false
        do {
            try await MeetingWorkflowRunner.run(meetingID: UUID(), transcribe: { _ in throw MeetingError.message("Disk dolu") }, summarize: { _ in summaryCalled = true })
            XCTFail("Save failure should end workflow")
        } catch { XCTAssertFalse(summaryCalled) }
    }

    func testFailedSummaryLeavesSavedTranscriptAvailable() async {
        var savedTranscript = false
        do {
            try await MeetingWorkflowRunner.run(meetingID: UUID(), transcribe: { _ in savedTranscript = true }, summarize: { _ in throw MeetingError.message("Model hazır değil") })
            XCTFail("Summary failure should be surfaced")
        } catch { XCTAssertTrue(savedTranscript) }
    }

    func testCancellationBetweenStepsPreventsSummary() async {
        var summaryCalled = false
        let task = Task {
            try await MeetingWorkflowRunner.run(meetingID: UUID(), transcribe: { _ in
                withUnsafeCurrentTask { $0?.cancel() }
            }, summarize: { _ in summaryCalled = true })
        }
        do { try await task.value; XCTFail("Should cancel") }
        catch { XCTAssertTrue(error is CancellationError); XCTAssertFalse(summaryCalled) }
    }

    func testSearchIncludesActionsOwnersDatesDecisionsQuestionsAndPersonalNotes() {
        var meeting = Meeting(title: "Ürün toplantısı")
        meeting.notes = MeetingNotes(summary: "Yeni özellik", decisions: [EvidenceItem(id: "d", text: "Pilot müşteriyle ilerle", evidence: [])], actions: [ActionItem(id: "a", text: "Taslağı hazırla", owner: "Elif", due: "gelecek cuma", evidence: [])], questions: [EvidenceItem(id: "q", text: "Bütçe yeterli mi?", evidence: [])], ideas: [], topics: [TopicNote(id: "t", title: "Tasarım", text: "Erişilebilirlik", evidence: [])])
        meeting.personalNotes = "Gizli değerlendirme"
        for query in ["urun", "pilot musteri", "elif cuma", "butce", "erisilebilirlik", "gizli degerlendirme", "   "] {
            XCTAssertTrue(MeetingArchiveSearch.matches(meeting, query: query), query)
        }
        XCTAssertFalse(MeetingArchiveSearch.matches(meeting, query: "elif olmayan"))
    }

    func testSearchIncludesUserProvidedSpeakerNames() {
        var meeting = Meeting(title: "Görüşme")
        meeting.segments = [TranscriptSegment(id: "s", speaker: "A", start: 0, end: 1, text: "Merhaba")]
        meeting.speakerNames = ["A": "Özgür"]
        XCTAssertTrue(MeetingArchiveSearch.matches(meeting, query: "ozgur merhaba"))
    }

    func testMicrophoneAssessmentNeverClaimsSilentCaptureReady() {
        XCTAssertEqual(MicrophoneCheckAssessment.assess(received: false, peakDBFS: -4), .noInput)
        XCTAssertEqual(MicrophoneCheckAssessment.assess(received: true, peakDBFS: -.infinity), .noInput)
        XCTAssertEqual(MicrophoneCheckAssessment.assess(received: true, peakDBFS: -55), .quiet)
        XCTAssertEqual(MicrophoneCheckAssessment.assess(received: true, peakDBFS: -0.2), .clipping)
        XCTAssertEqual(MicrophoneCheckAssessment.assess(received: true, peakDBFS: -18), .ready)
    }

    func testPreviewContainsOnlyGivenMicrophoneAndDoesNotChangeSource() async throws {
        try await MainActor.run {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-PreviewTests-\(UUID())")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: folder) }
            let input = folder.appendingPathComponent("microphone.caf")
            let output = folder.appendingPathComponent("preview.caf")
            let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
            do {
                let file = try AVAudioFile(forWriting: input, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
                buffer.frameLength = 480
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for index in 0..<480 { samples[index] = 0.1 }
                try file.write(from: buffer)
            }
            let original = try Data(contentsOf: input)
            try MicrophoneCheck.makePreview(input: input, output: output, gain: 2)
            XCTAssertEqual(try Data(contentsOf: input), original)
            let file = try AVAudioFile(forReading: output)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 480))
            try file.read(into: buffer)
            XCTAssertEqual(buffer.frameLength, 480)
            XCTAssertEqual(try XCTUnwrap(buffer.floatChannelData?[0])[0], RecorderMix.sample(system: 0, microphone: 0.1, microphoneGain: 2), accuracy: 0.00001)
        }
    }
}
