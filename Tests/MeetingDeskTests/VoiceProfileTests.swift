import XCTest
@testable import MeetingDesk

final class VoiceProfileTests: XCTestCase {
    private func sample(_ vector: [Float] = [1, 0], duration: Double = 5, model: String = "campplus-v2") -> SpeakerVoiceSample {
        SpeakerVoiceSample(speakerID: "system-1", embedding: vector, cleanDuration: duration, modelID: model)
    }

    private func profile(_ name: String = "Onur", vector: [Float] = [1, 0], model: String = "campplus-v2") -> VoiceProfile {
        VoiceProfile(name: name, modelID: model, samples: [vector])
    }

    func testNormalizesEmbeddingsWithoutAssumingTheirScale() throws {
        let profiles = try VoiceProfileEnrollment.remember(name: "  Onur \n", sample: sample([30, 40]), existing: [])
        XCTAssertEqual(profiles.first?.name, "Onur")
        XCTAssertEqual(profiles[0].samples[0][0], 0.6, accuracy: 0.00001)
        XCTAssertEqual(profiles[0].samples[0][1], 0.8, accuracy: 0.00001)
        XCTAssertEqual(VoiceProfileMatcher.match(sample: sample([3, 4]), profiles: profiles)?.automatic, true)
    }

    func testDistinctSpeakerIsUnknownRatherThanAssignedToOnlyStoredPerson() {
        XCTAssertNil(VoiceProfileMatcher.match(sample: sample([0, 1]), profiles: [profile()]))
        XCTAssertNil(VoiceProfileMatcher.match(sample: sample([-1, 0]), profiles: [profile()]))
    }

    func testTwoPeopleAreMatchedUsingTheirOwnVoiceSamples() {
        let profiles = [profile("Onur"), profile("Altuğ", vector: [0, 1])]
        XCTAssertEqual(VoiceProfileMatcher.match(sample: sample([10, 0]), profiles: profiles)?.name, "Onur")
        XCTAssertEqual(VoiceProfileMatcher.match(sample: sample([0, 10]), profiles: profiles)?.name, "Altuğ")
        XCTAssertTrue(VoiceProfileMatcher.match(sample: sample([10, 0]), profiles: profiles)?.automatic == true)
    }

    func testHighSimilarityStillNeedsMarginAgainstAnotherPerson() {
        let profiles = [profile("Onur"), profile("Altuğ", vector: [0.98, 0.2])]
        let result = VoiceProfileMatcher.match(sample: sample(), profiles: profiles)
        XCTAssertEqual(result?.name, "Onur")
        XCTAssertEqual(result?.automatic, false)
    }

    func testEqualScoresAndEqualNamesNeverMergeDifferentIdentities() {
        let profiles = [profile("Deniz"), profile("Deniz")]
        XCTAssertNotEqual(profiles[0].id, profiles[1].id)
        XCTAssertEqual(VoiceProfileMatcher.match(sample: sample(), profiles: profiles)?.automatic, false)
        var duplicate = profiles
        duplicate[1].id = duplicate[0].id
        XCTAssertNil(VoiceProfileMatcher.match(sample: sample(), profiles: duplicate))
    }

    func testMediumSimilarityIsSuggestionOnly() {
        let result = VoiceProfileMatcher.match(sample: sample([0.72, 0.694]), profiles: [profile()])
        XCTAssertNotNil(result)
        XCTAssertEqual(result?.automatic, false)
    }

    func testModelVersionsCannotBeComparedEvenWithIdenticalDimensions() {
        XCTAssertNil(VoiceProfileMatcher.match(sample: sample(model: "campplus-new"), profiles: [profile()]))
        XCTAssertNil(VoiceProfileMatcher.match(sample: sample(), profiles: [profile(vector: [1, 0, 0])]))
        var malformed = profile()
        malformed.samples.append([1, 0, 0])
        XCTAssertNil(VoiceProfileMatcher.match(sample: sample(), profiles: [malformed]))
    }

    func testInvalidOrInsufficientSpeechCannotEnrollOrRecognize() {
        for duration in [Double.nan, .infinity, -1, 0, 2.999] {
            XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(duration: duration), existing: []))
            XCTAssertNil(VoiceProfileMatcher.match(sample: sample(duration: duration), profiles: [profile()]))
        }
        for vector: [Float] in [[], [1], [0, 0], [.nan, 1], [.infinity, 1], Array(repeating: 1, count: 4_097)] {
            XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(vector), existing: []))
            XCTAssertNil(VoiceProfileMatcher.match(sample: sample(vector), profiles: [profile()]))
        }
        XCTAssertNoThrow(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(duration: 3), existing: []))
    }

    func testExtremeFiniteVectorsAreNormalizedWithoutOverflowOrUnderflow() throws {
        let large = try XCTUnwrap(VoiceVector.normalized([Float.greatestFiniteMagnitude, Float.greatestFiniteMagnitude]))
        XCTAssertEqual(large[0], Float(sqrt(0.5)), accuracy: 0.00001)
        let small = try XCTUnwrap(VoiceVector.normalized([Float.leastNonzeroMagnitude, 0]))
        XCTAssertEqual(small, [1, 0])
    }

    func testInvalidNamesAndEmptyModelIdentifiersAreRejected() {
        for name in ["", " \n", "Onur\nBaşterzi", String(repeating: "a", count: 101)] {
            XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: name, sample: sample(), existing: []))
        }
        for model in ["", " campplus", "campplus\n"] {
            XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(model: model), existing: []))
        }
    }

    func testEnrollmentAddsOnlyExplicitlySelectedIdentityAndCapsExamples() throws {
        var profiles = [profile()]
        let id = profiles[0].id
        for index in 1...15 {
            profiles = try VoiceProfileEnrollment.remember(name: "Onur", sample: sample([1, Float(index) / 100]), existing: profiles, profileID: id)
        }
        XCTAssertEqual(profiles.count, 1)
        XCTAssertEqual(profiles[0].id, id)
        XCTAssertEqual(profiles[0].samples.count, 12)
        let expected = try XCTUnwrap(VoiceVector.normalized([1, 0.04]))
        XCTAssertEqual(profiles[0].samples[0][1], expected[1], accuracy: 0.00001)
        let before = profiles
        _ = VoiceProfileMatcher.match(sample: sample(), profiles: profiles)
        XCTAssertEqual(profiles, before, "Recognition must not train or alter a profile")
    }

    func testExplicitProfileCannotBeSilentlyReplacedOrChangedToAnotherModel() throws {
        let profiles = [profile()]
        XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(), existing: profiles, profileID: UUID()))
        XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(model: "new-model"), existing: profiles, profileID: profiles[0].id))
        XCTAssertThrowsError(try VoiceProfileEnrollment.remember(name: "Onur", sample: sample([1, 0, 0]), existing: profiles, profileID: profiles[0].id))
        let separate = try VoiceProfileEnrollment.remember(name: "Onur", sample: sample(model: "new-model"), existing: profiles)
        XCTAssertEqual(separate.count, 2)
        XCTAssertNotEqual(separate[0].id, separate[1].id)
        XCTAssertEqual(separate.map(\.modelID), ["campplus-v2", "new-model"])
    }
}
