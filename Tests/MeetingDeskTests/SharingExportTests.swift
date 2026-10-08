import XCTest
import PDFKit
@testable import MeetingDesk

final class SharingExportTests: XCTestCase {
    func testPersonalNotesAreExcludedFromEveryScopeUnlessExplicitlyIncluded() {
        let meeting = fixture()
        XCTAssertFalse(MeetingExport.markdown(meeting).contains(meeting.personalNotes))
        for scope in MeetingShareScope.allCases {
            let excluded = MeetingExport.document(meeting, options: MeetingShareOptions(scope: scope))
            XCTAssertFalse(excluded.markdown.contains(meeting.personalNotes))
            XCTAssertFalse(excluded.plainText.contains(meeting.personalNotes))
            let included = MeetingExport.document(meeting, options: MeetingShareOptions(scope: scope, includePersonalNotes: true))
            XCTAssertTrue(included.markdown.contains(meeting.personalNotes))
            XCTAssertTrue(included.plainText.contains(meeting.personalNotes))
        }
    }

    func testSummaryAndActionsHaveDistinctContentAndOnlyPlainSourceTimestamps() {
        let meeting = fixture()
        let summary = MeetingExport.document(meeting, options: MeetingShareOptions(scope: .summary))
        XCTAssertTrue(summary.markdown.contains("PAYLAŞILACAK ÖZET"))
        XCTAssertTrue(summary.markdown.contains("KARAR METNİ"))
        XCTAssertTrue(summary.markdown.contains("AÇIK SORU"))
        XCTAssertTrue(summary.markdown.contains("KONU NOTU"))
        XCTAssertFalse(summary.markdown.contains("AKSİYON METNİ"))
        let actions = MeetingExport.document(meeting, options: MeetingShareOptions(scope: .actions))
        XCTAssertTrue(actions.markdown.contains("- [x] AKSİYON METNİ"))
        XCTAssertTrue(actions.markdown.contains("Sorumlu: Belirtilmedi · Tarih: Belirtilmedi"))
        XCTAssertFalse(actions.markdown.contains("PAYLAŞILACAK ÖZET"))
        XCTAssertFalse(actions.markdown.contains("KARAR METNİ"))
        for selected in [summary, actions] {
            XCTAssertTrue(selected.markdown.contains("Kaynak: 02:14"))
            XCTAssertFalse(selected.markdown.contains("](#"))
            XCTAssertFalse(selected.markdown.contains("<a id="))
            XCTAssertFalse(selected.markdown.contains("TRANSKRİPTTEKİ GİZLİ AYRINTI"))
            XCTAssertFalse(selected.plainText.contains("TRANSKRİPTTEKİ GİZLİ AYRINTI"))
            XCTAssertFalse(selected.markdown.contains("## Transkript"))
        }
    }

    func testFullExportKeepsAllContentAndItsTimestampTargets() {
        let meeting = fixture()
        let full = MeetingExport.document(meeting, options: MeetingShareOptions(scope: .fullTranscript))
        XCTAssertEqual(full.markdown, MeetingExport.markdown(meeting))
        XCTAssertTrue(full.markdown.contains("PAYLAŞILACAK ÖZET"))
        XCTAssertTrue(full.markdown.contains("AKSİYON METNİ"))
        XCTAssertTrue(full.markdown.contains("TRANSKRİPTTEKİ GİZLİ AYRINTI"))
        XCTAssertTrue(full.markdown.contains("[02:14](#s1)"))
        XCTAssertTrue(full.markdown.contains("<a id=\"s1\"></a>"))
        XCTAssertTrue(full.plainText.contains("Kaynak: 02:14"))
        XCTAssertFalse(full.plainText.contains("<a id="))
    }

    func testSourceIDsAreEscapedAndMissingSourcesNeverCreateDeadLinks() {
        var meeting = fixture()
        meeting.segments[0].id = "speaker\"<1&"
        meeting.notes?.decisions[0].evidence = [meeting.segments[0].id, "missing"]
        let full = MeetingExport.markdown(meeting)
        XCTAssertTrue(full.contains("<a id=\"speaker&quot;&lt;1&amp;\"></a>"))
        XCTAssertTrue(full.contains("#speaker%22%3C1%26"))
        XCTAssertFalse(full.contains("#missing"))
        meeting.segments = []
        XCTAssertFalse(MeetingExport.markdown(meeting).contains("](#"))
    }

    func testSourceLabelsAndReviewedNotesAreDescribedWithoutClaimingSpeakerIdentities() {
        var meeting = fixture()
        meeting.transcriptionEngine = ProcessingMode.local.rawValue
        meeting.transcriptSourceSeparated = true
        meeting.reviewedAt = Date(timeIntervalSince1970: 1_000)
        let full = MeetingExport.markdown(meeting)
        XCTAssertTrue(full.contains("ayrı kayıt kaynakları olarak etiketlendi"))
        XCTAssertTrue(full.contains("kişilerin kimliğini otomatik belirlemez"))
        XCTAssertTrue(full.contains("Kullanıcı tarafından gözden geçirildi"))
        XCTAssertFalse(full.contains("Konuşmacılar otomatik ayrılmadı"))
        let summary = MeetingExport.markdown(meeting, options: MeetingShareOptions(scope: .summary))
        XCTAssertTrue(summary.contains("Kullanıcı tarafından gözden geçirildi"))
        XCTAssertFalse(summary.contains("ayrı kayıt kaynakları"))
        meeting.notesNeedRefresh = true
        XCTAssertFalse(MeetingExport.markdown(meeting).contains("Kullanıcı tarafından gözden geçirildi"))
    }

    func testPDFSelectionDoesNotLeakPersonalNotesOrExcludedTranscript() throws {
        let meeting = fixture()
        for scope in [MeetingShareScope.summary, .actions] {
            let selection = MeetingExport.document(meeting, options: MeetingShareOptions(scope: scope))
            let data = try MeetingPDFExport.data(document: selection, title: meeting.title)
            let pdf = try XCTUnwrap(PDFDocument(data: data))
            let text = try XCTUnwrap(pdf.string)
            XCTAssertFalse(text.contains(meeting.personalNotes))
            XCTAssertFalse(text.contains("TRANSKRİPTTEKİ GİZLİ AYRINTI"))
            XCTAssertTrue(text.contains(scope == .actions ? "AKSİYON METNİ" : "PAYLAŞILACAK ÖZET"))
            XCTAssertTrue(text.contains("02:14"))
        }
        let includedData = try MeetingPDFExport.data(meeting: meeting, options: MeetingShareOptions(scope: .actions, includePersonalNotes: true))
        XCTAssertTrue(try XCTUnwrap(PDFDocument(data: includedData)?.string).contains(meeting.personalNotes))
    }

    func testPDFIsPaginatedSelectableAndPreservesLongTurkishContentToTheEnd() throws {
        var meeting = fixture()
        let paragraphs = String(repeating: "İstanbul görüşmesi: çığ, öğe, şüphe ve kararlar. Uzun açıklama, kaynaklarıyla birlikte okunabilir.\n", count: 220)
        let longWord = String(repeating: "çığöüşİ", count: 700)
        meeting.segments[0].text = paragraphs + longWord + "\nSON SATIR KORUNDU: İstanbul, Iğdır, Çeşme."
        let data = try MeetingPDFExport.data(meeting: meeting, options: MeetingShareOptions(scope: .fullTranscript))
        XCTAssertTrue(data.starts(with: Data("%PDF".utf8)))
        let pdf = try XCTUnwrap(PDFDocument(data: data))
        XCTAssertGreaterThan(pdf.pageCount, 1)
        var pageBodies: [String] = []
        for index in 0..<pdf.pageCount {
            let page = try XCTUnwrap(pdf.page(at: index))
            let pageText = try XCTUnwrap(page.string)
            XCTAssertFalse(pageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            let selected = try XCTUnwrap(page.selection(for: NSRange(location: 0, length: pageText.utf16.count)))
            XCTAssertTrue(page.bounds(for: .mediaBox).insetBy(dx: -0.5, dy: -0.5).contains(selected.bounds(for: page)), "Uzun satırlar sayfanın dışına taşmamalı.")
            let lines = pageText.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)
            XCTAssertEqual(lines.last, String(index + 1), "Seçilebilir sayfa numarası son satırda olmalı.")
            pageBodies.append(lines.dropLast().joined(separator: "\n"))
        }
        let extracted = try XCTUnwrap(pdf.string)
        XCTAssertTrue(extracted.contains("İstanbul görüşmesi"))
        XCTAssertTrue(extracted.contains("SON SATIR KORUNDU"))
        XCTAssertTrue(extracted.contains("Iğdır"))
        // Page footers interrupt a word that crosses pages in PDFDocument.string.
        // Remove only each expected last-line footer before comparing every source character.
        let compact = pageBodies.joined().components(separatedBy: .whitespacesAndNewlines).joined()
        XCTAssertTrue(compact.contains(longWord), "Uzun, boşluksuz Türkçe metnin tüm karakterleri PDF içinde seçilebilir kalmalı.")
        XCTAssertFalse(extracted.contains(meeting.personalNotes))
        XCTAssertFalse(extracted.contains("<a id="))
        XCTAssertFalse(extracted.contains("](#"))
    }

    private func fixture() -> Meeting {
        var meeting = Meeting(title: "Türkçe paylaşım")
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 134, end: 160, text: "TRANSKRİPTTEKİ GİZLİ AYRINTI")]
        meeting.personalNotes = "SADECE BANA AİT KİŞİSEL NOT"
        meeting.notes = MeetingNotes(
            summary: "PAYLAŞILACAK ÖZET",
            decisions: [EvidenceItem(id: "d1", text: "KARAR METNİ", evidence: ["s1"])],
            actions: [ActionItem(id: "a1", text: "AKSİYON METNİ", owner: nil, due: nil, evidence: ["s1"])],
            questions: [EvidenceItem(id: "q1", text: "AÇIK SORU", evidence: ["s1"])],
            ideas: [EvidenceItem(id: "i1", text: "FİKİR", evidence: ["s1"])],
            topics: [TopicNote(id: "t1", title: "KONU", text: "KONU NOTU", evidence: ["s1"])])
        meeting.completedActions = ["a1"]
        return meeting
    }
}
