import Foundation
import XCTest
@testable import MeetingDesk

final class ChannelTranscriptionServiceTests: XCTestCase {
    private let mixedURL = URL(fileURLWithPath: "/generated-fixtures/recording.m4a")
    private let micURL = URL(fileURLWithPath: "/generated-fixtures/recording-microphone.m4a")
    private let systemURL = URL(fileURLWithPath: "/generated-fixtures/recording-system.m4a")

    func testMergeUsesRealTimelineAndUniqueStableSourceIDs() throws {
        let microphone = [segment("Local response.", start: 90, end: 94), segment("Last item.", start: 7_195, end: 7_199)]
        let system = [segment("Remote question.", start: 45, end: 50), segment("Later remote answer.", start: 120, end: 124)]
        let result = try ChannelTranscriptionService.merge(microphone: microphone, system: system)
        XCTAssertEqual(result.map(\.start), [45, 90, 120, 7_195])
        XCTAssertEqual(result.map(\.speaker), ["Toplantı sesi", "Mikrofon", "Toplantı sesi", "Mikrofon"])
        XCTAssertEqual(result.map(\.id), ["local-system-1", "local-microphone-1", "local-system-2", "local-microphone-2"])
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        XCTAssertEqual(result, try ChannelTranscriptionService.merge(microphone: microphone, system: system))
        XCTAssertEqual(result.last?.end, 7_199)
    }

    func testExactNormalizedEchoKeepsSystemCopy() throws {
        let microphone = [segment("  Kararı yarın birlikte açıklayacağız! ", start: 10.1, end: 14.1)]
        let system = [segment("Kararı yarın birlikte açıklayacağız.", start: 10, end: 14)]
        let result = try ChannelTranscriptionService.merge(microphone: microphone, system: system)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.id, "local-system-1")
        XCTAssertEqual(result.first?.text, "Kararı yarın birlikte açıklayacağız.")
        XCTAssertEqual(result.first?.start, 10)
    }

    func testEchoFilteringDoesNotDeleteDistinctOrNegatedSpeech() throws {
        let result = try ChannelTranscriptionService.merge(
            microphone: [segment("Kararı yarın birlikte açıklamayacağız.", start: 10, end: 14)],
            system: [segment("Kararı yarın birlikte açıklayacağız.", start: 10, end: 14)]
        )
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(Set(result.map(\.speaker)), ["Mikrofon", "Toplantı sesi"])
    }

    func testRepeatedPhraseAtDifferentTimeAndBriefOverlapAreRetained() throws {
        let phrase = "Bu kararı yarın açıklayacağız."
        let microphone = [segment(phrase, start: 20, end: 24), segment(phrase, start: 13.5, end: 17.5)]
        let system = [segment(phrase, start: 10, end: 14)]
        let result = try ChannelTranscriptionService.merge(microphone: microphone, system: system)
        XCTAssertEqual(result.count, 3)
        XCTAssertEqual(result.map(\.start), [10, 13.5, 20])
    }

    func testShortAgreementsAndZeroDurationUtterancesAreNotAssumedToBeEcho() throws {
        let microphone = [segment("Tamam.", start: 1, end: 2), segment("Bu kararı birlikte açıklayacağız.", start: 5, end: 5)]
        let system = microphone
        XCTAssertEqual(try ChannelTranscriptionService.merge(microphone: microphone, system: system).count, 4)
    }

    func testLegacyMixedRecordingHasExplicitFallbackNotice() async throws {
        let calls = TranscriptionCalls()
        let utterance = segment("Imported meeting.", start: 8, end: 11)
        let service = ChannelTranscriptionService { url, language, allowNoSpeech in
            await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
            return [utterance]
        }
        let result = try await service.transcribe(mixedURL: mixedURL, language: "English")
        let recorded = await calls.values()
        XCTAssertEqual(recorded, [.init(url: mixedURL, language: "English", allowNoSpeech: false)])
        XCTAssertFalse(result.sourceSeparated)
        XCTAssertTrue(result.notice?.contains("birleşik kayıt") == true)
        XCTAssertEqual(result.segments.first?.speaker, "Konuşma")
        XCTAssertEqual(result.segments.first?.id, "local-mixed-1")
        XCTAssertEqual(result.segments.first?.start, 8)
    }

    func testExplicitlyMissingEitherSourceUsesFullMixedRecording() async throws {
        let utterance = segment("Full mixed content.", start: 4, end: 6)
        for missingMicrophone in [true, false] {
            let calls = TranscriptionCalls()
            let service = ChannelTranscriptionService { url, language, allowNoSpeech in
                await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
                return [utterance]
            }
            let result = try await service.transcribe(mixedURL: mixedURL,
                microphoneURL: missingMicrophone ? nil : micURL,
                systemURL: missingMicrophone ? systemURL : nil, language: "Türkçe")
            let recorded = await calls.values()
            XCTAssertEqual(recorded, [.init(url: mixedURL, language: "Türkçe", allowNoSpeech: false)])
            XCTAssertFalse(result.sourceSeparated)
        }
    }

    func testSeparateSourcesPermitSilentTrackAndKeepOtherSource() async throws {
        let mic = micURL
        let remote = segment("Remote discussion continues.", start: 30, end: 33)
        let calls = TranscriptionCalls()
        let service = ChannelTranscriptionService { url, language, allowNoSpeech in
            await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
            return url == mic ? [] : [remote]
        }
        let result = try await service.transcribe(mixedURL: mixedURL, microphoneURL: micURL, systemURL: systemURL, language: "Türkçe")
        let recorded = await calls.values()
        XCTAssertEqual(recorded, [.init(url: micURL, language: "Türkçe", allowNoSpeech: true),
                                  .init(url: systemURL, language: "Türkçe", allowNoSpeech: true)])
        XCTAssertTrue(result.sourceSeparated)
        XCTAssertEqual(result.segments.map(\.speaker), ["Toplantı sesi"])
        XCTAssertEqual(result.segments.first?.start, 30)
        XCTAssertTrue(result.notice?.contains("Mikrofon kaynağında konuşma tanınmadı") == true)
    }

    func testSilentSystemTrackStillKeepsMicrophoneSpeech() async throws {
        let mic = micURL
        let local = segment("My microphone contribution.", start: 60, end: 63)
        let service = ChannelTranscriptionService { url, _, _ in url == mic ? [local] : [] }
        let result = try await service.transcribe(mixedURL: mixedURL, microphoneURL: micURL, systemURL: systemURL, language: "English")
        XCTAssertEqual(result.segments.map(\.speaker), ["Mikrofon"])
        XCTAssertEqual(result.segments.first?.start, 60)
        XCTAssertTrue(result.notice?.contains("Toplantı sesi kaynağında konuşma tanınmadı") == true)
    }

    func testBothSilentTracksFailInsteadOfSavingEmptyTranscript() async {
        let service = ChannelTranscriptionService { _, _, _ in [] }
        do {
            _ = try await service.transcribe(mixedURL: mixedURL, microphoneURL: micURL, systemURL: systemURL, language: "Türkçe")
            XCTFail("An empty overall transcript must not replace the saved transcript")
        } catch { XCTAssertTrue(error.localizedDescription.contains("konuşma tanınamadı")) }
    }

    func testModelAndFileErrorsNeverTriggerMixedFallback() async {
        let mic = micURL
        let local = segment("Available microphone speech.", start: 2, end: 5)
        for failingSource in [micURL, systemURL] {
            let calls = TranscriptionCalls()
            let failure = failingSource == mic ? "Model hazırlanamadı" : "Dosya okunamadı"
            let service = ChannelTranscriptionService { url, language, allowNoSpeech in
                await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
                if url == failingSource { throw MeetingError.message(failure) }
                return [local]
            }
            do {
                _ = try await service.transcribe(mixedURL: mixedURL, microphoneURL: micURL, systemURL: systemURL, language: "English")
                XCTFail("Source failures must not create an apparently complete transcript")
            } catch {
                XCTAssertTrue(error.localizedDescription.contains(failure))
                XCTAssertTrue(error.localizedDescription.contains(failingSource == mic ? "Mikrofon" : "Toplantı sesi"))
            }
            let recorded = await calls.values()
            XCTAssertFalse(recorded.contains { $0.url == mixedURL })
            XCTAssertEqual(recorded.count, failingSource == mic ? 1 : 2)
        }
    }

    func testIncompleteReadRejectsResultWithoutMixedFallback() async {
        let mic = micURL
        let local = segment("The first track is complete.", start: 2, end: 5)
        let calls = TranscriptionCalls()
        let service = ChannelTranscriptionService { url, language, allowNoSpeech in
            await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
            if url != mic { try LocalTranscriptAssembler.requireEntireFileRead(lastSampleSeconds: 600, duration: 3_600) }
            return [local]
        }
        do {
            _ = try await service.transcribe(mixedURL: mixedURL, microphoneURL: micURL, systemURL: systemURL, language: "English")
            XCTFail("Partial source audio must fail")
        } catch { XCTAssertTrue(error.localizedDescription.contains("tamamı işlenemedi")) }
        let recorded = await calls.values()
        XCTAssertEqual(recorded.map(\.url), [micURL, systemURL])
    }

    func testCancelledRequestDoesNotStartAnySource() async {
        let calls = TranscriptionCalls()
        let service = ChannelTranscriptionService { url, language, allowNoSpeech in
            await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
            return []
        }
        let mixed = mixedURL, mic = micURL, system = systemURL
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.transcribe(mixedURL: mixed, microphoneURL: mic, systemURL: system, language: "English")
        }
        await requireCancellation(task)
        let recorded = await calls.values()
        XCTAssertTrue(recorded.isEmpty)
    }

    func testCancellationAfterMicrophoneStopsBeforeSystemOrSave() async {
        let calls = TranscriptionCalls()
        let utterance = segment("A partial result.", start: 2, end: 4)
        let service = ChannelTranscriptionService { url, language, allowNoSpeech in
            await calls.append(url: url, language: language, allowNoSpeech: allowNoSpeech)
            withUnsafeCurrentTask { $0?.cancel() }
            return [utterance]
        }
        let mixed = mixedURL, mic = micURL, system = systemURL
        let task = Task { try await service.transcribe(mixedURL: mixed, microphoneURL: mic, systemURL: system, language: "English") }
        await requireCancellation(task)
        let recorded = await calls.values()
        XCTAssertEqual(recorded.map(\.url), [micURL])
    }

    func testCancellationAfterSystemStopsBeforeMergedResult() async {
        let system = systemURL
        let utterance = segment("A completed source result.", start: 2, end: 4)
        let service = ChannelTranscriptionService { url, _, _ in
            if url == system { withUnsafeCurrentTask { $0?.cancel() } }
            return [utterance]
        }
        let mixed = mixedURL, mic = micURL
        let task = Task { try await service.transcribe(mixedURL: mixed, microphoneURL: mic, systemURL: system, language: "English") }
        await requireCancellation(task)
    }

    func testCancellationAfterMixedFallbackAlsoRejectsResult() async {
        let utterance = segment("A completed mixed result.", start: 2, end: 4)
        let service = ChannelTranscriptionService { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return [utterance]
        }
        let mixed = mixedURL
        let task = Task { try await service.transcribe(mixedURL: mixed, language: "English") }
        await requireCancellation(task)
    }

    func testCancellationIsPreservedWhenEngineReportsAnotherError() async {
        let service = ChannelTranscriptionService { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            throw MeetingError.message("Engine stopped")
        }
        let mixed = mixedURL, mic = micURL, system = systemURL
        let task = Task { try await service.transcribe(mixedURL: mixed, microphoneURL: mic, systemURL: system, language: "English") }
        await requireCancellation(task)
    }

    func testInvalidTimestampsFailInsteadOfSilentlyDroppingSpeech() {
        for invalid in [segment("Invalid.", start: .nan, end: 2), segment("Invalid.", start: 5, end: 2)] {
            XCTAssertThrowsError(try ChannelTranscriptionService.merge(microphone: [invalid], system: []))
        }
    }

    func testSameFileCannotClaimToBeTwoSeparateSources() async {
        let service = ChannelTranscriptionService { _, _, _ in XCTFail("Invalid sources must be rejected first"); return [] }
        do {
            _ = try await service.transcribe(mixedURL: mixedURL, microphoneURL: micURL, systemURL: micURL, language: "English")
            XCTFail("One file must not be labeled as two sources")
        } catch { XCTAssertTrue(error.localizedDescription.contains("aynı dosya")) }
    }

    private func segment(_ text: String, start: Double, end: Double) -> TranscriptSegment {
        TranscriptSegment(id: "local-1", speaker: "Unknown participant", start: start, end: end, text: text)
    }

    private func requireCancellation(_ task: Task<ChannelTranscriptionResult, Error>, file: StaticString = #filePath, line: UInt = #line) async {
        do { _ = try await task.value; XCTFail("Cancelled work must not return a transcript", file: file, line: line) }
        catch { XCTAssertTrue(error is CancellationError, file: file, line: line) }
    }
}

private actor TranscriptionCalls {
    struct Call: Equatable {
        let url: URL
        let language: String
        let allowNoSpeech: Bool
    }
    private var captured: [Call] = []
    func append(url: URL, language: String, allowNoSpeech: Bool) {
        captured.append(Call(url: url, language: language, allowNoSpeech: allowNoSpeech))
    }
    func values() -> [Call] { captured }
}
