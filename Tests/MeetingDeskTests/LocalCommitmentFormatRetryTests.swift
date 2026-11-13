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

    func testMissingWrongAndExtraFieldsGetExactlyOneStrictFreshResponse() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let invalid: [[String: Any]] = [
            [:],
            ["sourceObservation": "A factual sentence without the required state."],
            ["commitmentState": 1],
            ["commitmentState": NSNull()],
            ["sourceObservation": "No longer requested", "commitmentState": states[0]],
            ["observation": "No longer requested", "commitmentState": states[0]],
            ["commitmentState": states[0], "owner": "Onur"]
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
        let initial = try generated(valid("unknown"))
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

    func testEveryValidStateOnlyReplacementIsAcceptedAfterExactlyOneMissingStateRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let initial = try generated(["sourceObservation": "A factual sentence without the required state."])
        for state in states {
            let calls = CommitmentFormatRetryCounter()
            let replacement = try generated(valid(state))
            let result = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(initial) {
                await calls.increment(); return replacement
            }
            XCTAssertEqual(result, state == "agreed_or_committed_future_task")
            let count = await calls.value(); XCTAssertEqual(count, 1)
        }
    }

    func testRepeatedObservationOnlyResponseCannotBecomeFalseOrTriggerAThirdRequest() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let missing = try generated(["sourceObservation": "A complete factual sentence with no state."])
        XCTAssertTrue(missing.isComplete)
        let calls = CommitmentFormatRetryCounter()
        do {
            _ = try await LocalSummaryService.commitmentAllowsActionWithFormatRetry(missing) {
                await calls.increment(); return missing
            }
            XCTFail("Missing state must abort rather than produce an empty action list")
        } catch {
            XCTAssertTrue(error is MeetingError)
            XCTAssertEqual(error.localizedDescription, LocalSummaryService.CommitmentResponseError.invalidFormat.localizedDescription)
        }
        let count = await calls.value(); XCTAssertEqual(count, 1)
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
            XCTAssertFalse(retry.contains("sourceObservation"))
            XCTAssertTrue(retry.contains("exactly one field: commitmentState"))
            XCTAssertTrue(retry.contains("commitmentState"))
        }
    }

    private func valid(_ state: String) -> [String: Any] {
        ["commitmentState": state]
    }

    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
}
