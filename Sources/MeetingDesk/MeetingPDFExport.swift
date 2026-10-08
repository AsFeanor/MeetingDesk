import AppKit
import CoreText

enum MeetingPDFExport {
    static func data(meeting: Meeting, options: MeetingShareOptions = MeetingShareOptions()) throws -> Data {
        try data(document: MeetingExport.document(meeting, options: options), title: meeting.title)
    }

    /// CoreText writes actual glyphs and text into each page; there is no screenshot or line limit.
    static func data(document: MeetingShareDocument, title: String) throws -> Data {
        let text = attributedText(document)
        guard text.length > 0 else { throw MeetingError.message("PDF için paylaşılacak içerik bulunamadı.") }
        let output = NSMutableData()
        var pageRect = CGRect(x: 0, y: 0, width: 595.28, height: 841.89)
        guard let consumer = CGDataConsumer(data: output as CFMutableData),
              let context = CGContext(consumer: consumer, mediaBox: &pageRect,
                                      [kCGPDFContextTitle: title, kCGPDFContextCreator: "Toplantı"] as CFDictionary) else {
            throw MeetingError.message("PDF belgesi oluşturulamadı.")
        }
        let contentRect = CGRect(x: 52, y: 56, width: pageRect.width - 104, height: pageRect.height - 108)
        let framesetter = CTFramesetterCreateWithAttributedString(text as CFAttributedString)
        var position = 0
        var page = 1
        while position < text.length {
            let path = CGPath(rect: contentRect, transform: nil)
            let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: position, length: 0), path, nil)
            let visible = CTFrameGetVisibleStringRange(frame)
            guard visible.length > 0 else {
                context.closePDF()
                throw MeetingError.message("PDF metni sayfaya yerleştirilemedi; içerik kısaltılmadı.")
            }
            context.beginPDFPage(nil)
            context.saveGState()
            context.textMatrix = .identity
            CTFrameDraw(frame, context)
            drawPageNumber(page, in: context, pageRect: pageRect)
            context.restoreGState()
            context.endPDFPage()
            position += visible.length
            page += 1
        }
        context.closePDF()
        guard output.length > 0 else { throw MeetingError.message("PDF dosyası boş oluşturuldu.") }
        return output as Data
    }

    private static func attributedText(_ document: MeetingShareDocument) -> NSAttributedString {
        let result = NSMutableAttributedString(string: "")
        for block in document.blocks where !block.text.isEmpty {
            let paragraph = NSMutableParagraphStyle()
            paragraph.lineBreakMode = .byWordWrapping
            paragraph.lineSpacing = 3
            paragraph.paragraphSpacing = 9
            var font = NSFont.systemFont(ofSize: 11)
            var color = NSColor.black
            switch block.kind {
            case .title:
                font = .systemFont(ofSize: 22, weight: .semibold)
                paragraph.paragraphSpacing = 12
            case .section:
                font = .systemFont(ofSize: 15, weight: .semibold)
                paragraph.paragraphSpacingBefore = 11
                paragraph.paragraphSpacing = 8
            case .subsection:
                font = .systemFont(ofSize: 12, weight: .semibold)
                paragraph.paragraphSpacingBefore = 8
            case .transcriptHeading:
                font = .monospacedDigitSystemFont(ofSize: 10, weight: .semibold)
                paragraph.paragraphSpacingBefore = 8
                paragraph.paragraphSpacing = 4
            case .metadata, .notice, .footer:
                font = .systemFont(ofSize: 9)
                color = NSColor(white: 0.32, alpha: 1)
            case .bullet, .action:
                paragraph.firstLineHeadIndent = 0
                paragraph.headIndent = 12
            case .paragraph, .anchor: break
            }
            result.append(NSAttributedString(string: block.text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: paragraph
            ]))
        }
        return result
    }

    private static func drawPageNumber(_ page: Int, in context: CGContext, pageRect: CGRect) {
        let value = NSAttributedString(string: "\(page)", attributes: [
            .font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor(white: 0.45, alpha: 1)
        ])
        let line = CTLineCreateWithAttributedString(value as CFAttributedString)
        let width = CTLineGetTypographicBounds(line, nil, nil, nil)
        context.textPosition = CGPoint(x: (pageRect.width - width) / 2, y: 29)
        CTLineDraw(line, context)
    }
}
