import XCTest
@testable import MeetingDesk

/// Encoding invariance is a byte-level input contract, not evidence that a
/// language model interpreted the encoded meeting correctly.
final class LocalModelInputEncodingTests: XCTestCase {
    func testRepeatedProductionSourceAndAssessmentInputsHaveIdenticalBytes() throws {
        let first = try fixture()
        let sourceBytes = try LocalSummaryService.modelInputData(first.sources)
        let assessmentBytes = try LocalSummaryService.modelInputData(first.input)
        let metadataBytes = try LocalSummaryService.modelInputData(first.metadata)
        for _ in 0..<32 {
            let equivalent = try fixture()
            XCTAssertEqual(try LocalSummaryService.modelInputData(equivalent.sources), sourceBytes)
            XCTAssertEqual(try LocalSummaryService.modelInputData(equivalent.input), assessmentBytes)
            XCTAssertEqual(try LocalSummaryService.modelInputData(equivalent.metadata), metadataBytes)
        }
    }

    func testLogicallyEquivalentNestedDictionariesIgnoreInsertionOrderWithoutChangingValues() throws {
        let entries = [
            ("zeta", "son"),
            ("alpha", "Ödeme\nikinci satır"),
            ("Türkçe", "İıŞşĞğ I\u{0307}"),
            ("emoji", "👩🏽‍💻 / \"alıntı\"")
        ]
        var forward: [String: String] = [:]
        var reverse: [String: String] = [:]
        for (key, value) in entries { forward[key] = value }
        for (key, value) in entries.reversed() { reverse[key] = value }
        var first: [String: [String: String]] = [:]
        first["z-group"] = forward
        first["a-group"] = reverse
        var second: [String: [String: String]] = [:]
        second["a-group"] = forward
        second["z-group"] = reverse
        XCTAssertEqual(first, second, "The inputs must be logically equivalent before comparing their encodings")
        let bytes = try LocalSummaryService.modelInputData(first)
        XCTAssertEqual(try LocalSummaryService.modelInputData(second), bytes)
        let decoded = try JSONDecoder().decode([String: [String: String]].self, from: bytes)
        XCTAssertEqual(decoded, first)
        for (group, values) in first {
            for (key, expected) in values {
                assertExactUTF8(try XCTUnwrap(decoded[group]?[key]), expected)
            }
        }
    }

    func testProductionEncodingPreservesArraysPositionsTextUnicodeAndProvidedNames() throws {
        let fixture = try fixture()
        let sourceData = try LocalSummaryService.modelInputData(fixture.sources)
        let sourceRows = try XCTUnwrap(JSONSerialization.jsonObject(with: sourceData) as? [[String: Any]])
        XCTAssertEqual(sourceRows.map { $0["id"] as? String }, ["s1", "s2", "s1"])
        for (index, row) in sourceRows.enumerated() {
            let source = fixture.sources[index]
            assertExactUTF8(try XCTUnwrap(row["text"] as? String), source.text)
            XCTAssertEqual(row["start"] as? Double, source.start)
            XCTAssertEqual(row["end"] as? Double, source.end)
            XCTAssertNil(row["speaker"])
            XCTAssertNil(row["speakerLabel"])
            if let name = source.providedSpeakerName {
                assertExactUTF8(try XCTUnwrap(row["providedSpeakerName"] as? String), name)
            } else {
                XCTAssertNil(row["providedSpeakerName"])
            }
        }
        let data = try LocalSummaryService.modelInputData(fixture.input)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let reference = try JSONSerialization.jsonObject(with: JSONEncoder().encode(fixture.input))
        XCTAssertEqual(object as NSDictionary, try XCTUnwrap(reference as? NSDictionary),
                       "Canonical ordering must preserve the complete ordinary Encodable payload")
        let candidate = try XCTUnwrap(object["candidate"] as? [String: Any])
        XCTAssertEqual(candidate["id"] as? String, "candidate-özgün")
        assertExactUTF8(try XCTUnwrap(candidate["text"] as? String), fixture.input.candidate.text)
        XCTAssertEqual(candidate["evidence"] as? [String], ["s1"])
        let supporting = try XCTUnwrap(object["supportingSources"] as? [[String: Any]])
        let others = try XCTUnwrap(object["otherSources"] as? [[String: Any]])
        XCTAssertEqual(supporting.map { $0["sourcePosition"] as? Int }, [0, 2])
        XCTAssertEqual(others.map { $0["sourcePosition"] as? Int }, [1])
        let reconstructed = (supporting + others).sorted {
            ($0["sourcePosition"] as? Int ?? -1) < ($1["sourcePosition"] as? Int ?? -1)
        }
        XCTAssertEqual(reconstructed.count, fixture.sources.count)
        for (index, row) in reconstructed.enumerated() {
            let source = fixture.sources[index]
            XCTAssertEqual(row["sourcePosition"] as? Int, index)
            XCTAssertEqual(row["id"] as? String, source.id)
            assertExactUTF8(try XCTUnwrap(row["text"] as? String), source.text)
            XCTAssertEqual(row["start"] as? Double, source.start)
            XCTAssertEqual(row["end"] as? Double, source.end)
            XCTAssertNil(row["speaker"])
            XCTAssertNil(row["speakerLabel"])
            if let name = source.providedSpeakerName {
                assertExactUTF8(try XCTUnwrap(row["providedSpeakerName"] as? String), name)
            } else {
                XCTAssertNil(row["providedSpeakerName"])
            }
        }
        let metadataData = try LocalSummaryService.modelInputData(fixture.metadata)
        let metadata = try XCTUnwrap(JSONSerialization.jsonObject(with: metadataData) as? [String: Any])
        XCTAssertEqual(Set(metadata.keys), ["candidate", "supportingSources"])
        XCTAssertEqual(try XCTUnwrap(metadata["candidate"] as? NSDictionary), candidate as NSDictionary)
        XCTAssertEqual(try XCTUnwrap(metadata["supportingSources"] as? NSArray), supporting as NSArray)
        XCTAssertNil(metadata["otherSources"])
    }

    private func fixture() throws -> (sources: [LocalSummaryService.Source], input: LocalSummaryService.ActionAssessmentInput, metadata: LocalSummaryService.ActionMetadataInput) {
        let sources: [LocalSummaryService.Source] = [
            .init(id: "original-é", speaker: "A", start: 0.25, end: 8.5,
                  text: "Ödeme 👩🏽‍💻 \"alıntı\"\nİlk parça.", providedSpeakerName: "I\u{0307}pek"),
            .init(id: "original-second", speaker: "B", start: 8.5, end: 9.75,
                  text: "Diğer kaynak: e\u{0301} / é, ₺100."),
            .init(id: "original-é", speaker: "A", start: 0.25, end: 8.5,
                  text: "Son parça\tve değişmeyen kaynak.", providedSpeakerName: "I\u{0307}pek")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        let candidate = LocalSummaryService.ActionCandidate(id: "candidate-özgün", text: "Ödeme rehberini güncelle.\nİş 👩🏽‍💻", evidence: ["original-é"])
        return (scope.sources,
                try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope),
                try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope))
    }

    private func assertExactUTF8(_ actual: String, _ expected: String, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Array(actual.utf8), Array(expected.utf8), "Encoding must not normalize or rewrite Unicode values", file: file, line: line)
    }
}
