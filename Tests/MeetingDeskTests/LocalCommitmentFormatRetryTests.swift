import FoundationModels
import XCTest
@testable import MeetingDesk

private actor CommitmentFormatRetryCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

final class LocalCommitmentFormatRetryTests: XCTestCase {
    private let states = ["agreed_or_committed_future_task", "cancelled_or_rejected", "already_completed", "only_proposed_or_unaccepted", "not_a_future_execution_task"]

    func testAllFiveValidStatesPreserveTheirVerdictWithoutRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        for state in states {
            let calls = CommitmentFormatRetryCounter()
            let initial = try generated(valid(state))
            let strict = try LocalSummaryService.commitmentAllowsAction(initial)
            let result = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(initial) {
                await calls.increment(); throw CancellationError()
            }
            XCTAssertEqual(result, state == "agreed_or_committed_future_task")
            XCTAssertEqual(result, strict)
            let count = await calls.value(); XCTAssertEqual(count, 0)
        }
    }

    func testBlankMissingWrongAndExtraFieldsGetExactlyOneStrictFreshResponse() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let invalid: [[String: Any]] = [
            ["sourceObservation": " \t\n", "commitmentState": states[0]],
            ["commitmentState": states[0]],
            ["sourceObservation": "Kaynak bir iş bildiriyor."],
            ["sourceObservation": true, "commitmentState": states[0]],
            ["sourceObservation": "Kaynak bir iş bildiriyor.", "commitmentState": 1],
            ["observation": "Kaynak bir iş bildiriyor.", "commitmentState": states[0]],
            ["sourceObservation": "Kaynak bir iş bildiriyor.", "commitmentState": states[0], "owner": "Onur"]
        ]
        let replacement = try generated(valid(states[0]))
        for wire in invalid {
            let calls = CommitmentFormatRetryCounter()
            let result = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(generated(wire)) {
                await calls.increment(); return replacement
            }
            XCTAssertTrue(result)
            let count = await calls.value(); XCTAssertEqual(count, 1)
        }
    }

    func testUnknownOrTranslatedEnumIsFormatFailureRatherThanFalseVerdict() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let replacement = try generated(valid("already_completed"))
        for state in ["pending", "üstlenildi", "AGREED_OR_COMMITTED_FUTURE_TASK", " agreed_or_committed_future_task", ""] {
            let initial = try generated(valid(state))
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(initial)) { error in
                XCTAssertEqual(error as? LocalSummaryService.CommitmentResponseError, .invalidFormat)
            }
            let calls = CommitmentFormatRetryCounter()
            let result = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(initial) {
                await calls.increment(); return replacement
            }
            XCTAssertFalse(result, "Only the new valid already-completed classification returns false")
            let count = await calls.value(); XCTAssertEqual(count, 1)
        }
    }

    func testSecondInvalidResponseThrowsOldLocalizedMessageWithoutThirdAttemptOrFalseFallback() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let initial = try generated(["sourceObservation": "", "commitmentState": states[0]])
        let replacement = try generated(valid("unknown"))
        let calls = CommitmentFormatRetryCounter()
        do {
            _ = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(initial) {
                await calls.increment(); return replacement
            }
            XCTFail("Invalid structured output cannot become a false verdict or empty actions")
        } catch {
            XCTAssertTrue(error is MeetingError)
            XCTAssertEqual(error.localizedDescription, LocalSummaryService.CommitmentResponseError.invalidFormat.localizedDescription)
        }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testEveryStateStillRequiresNonblankObservationDuringRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let initial = try generated(["commitmentState": states[0]])
        for state in states {
            let calls = CommitmentFormatRetryCounter()
            let replacement = try generated(["sourceObservation": " \n", "commitmentState": state])
            do {
                _ = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(initial) {
                    await calls.increment(); return replacement
                }
                XCTFail("Even non-action states cannot bypass strict observation validation")
            } catch { XCTAssertTrue(error is MeetingError) }
            let count = await calls.value(); XCTAssertEqual(count, 1)
        }
    }

    func testRetryClosureCancellationPropagatesUnchanged() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let calls = CommitmentFormatRetryCounter()
        do {
            _ = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(generated([:])) {
                await calls.increment(); throw CancellationError()
            }
            XCTFail("Cancellation must abort commitment evaluation")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testCancellationAfterFreshResponseStopsBeforeAcceptingItsValidVerdict() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let initial = try generated([:]), replacement = try generated(valid(states[0]))
        let calls = CommitmentFormatRetryCounter()
        let task = Task {
            try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(initial) {
                await calls.increment()
                withUnsafeCurrentTask { $0?.cancel() }
                return replacement
            }
        }
        do { _ = try await task.value; XCTFail("A cancelled fresh request cannot return an action verdict") }
        catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testUnrelatedFailureFromFreshRequestIsNotCaughtOrRetriedAgain() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let calls = CommitmentFormatRetryCounter()
        do {
            _ = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(generated([:])) {
                await calls.increment(); throw MeetingError.message("Synthetic request failure")
            }
            XCTFail("A request failure cannot become a false classification")
        } catch { XCTAssertEqual(error.localizedDescription, "Synthetic request failure") }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testRetryInstructionsAppendOnlyFormatCorrectionAndKeepAllOriginalStateCodes() {
        for language in ["English", "Turkish"] {
            let original = LocalSummaryService.actionCommitmentInstructions(language: language)
            let retry = LocalSummaryService.actionCommitmentRetryInstructions(language: language)
            XCTAssertTrue(retry.hasPrefix(original))
            XCTAssertGreaterThan(retry.utf8.count, original.utf8.count)
            for state in states { XCTAssertTrue(retry.contains(state)) }
            XCTAssertTrue(retry.contains("sourceObservation"))
            XCTAssertTrue(retry.contains("commitmentState"))
        }
    }

    private func valid(_ state: String) -> [String: Any] {
        ["sourceObservation": "Kaynak, bu işin bildirilen durumunu açıklıyor.", "commitmentState": state]
    }

    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
}
