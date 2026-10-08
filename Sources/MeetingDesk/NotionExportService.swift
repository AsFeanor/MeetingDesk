import Foundation

struct NotionExportReceipt: Equatable {
    let pageID: String
    let url: URL
}

struct NotionExportFailure: LocalizedError {
    let message: String
    let createdPageURL: URL?
    /// An uncertain write is never automatically repeated: Notion may have saved it.
    let exportMayHaveSucceeded: Bool
    var errorDescription: String? { message }
}

enum NotionPageIdentifier {
    static func parse(_ input: String) throws -> String {
        let value = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = normalizedUUID(value) { return id }
        guard value.utf8.count <= 2048, let url = URL(string: value),
              url.scheme?.lowercased() == "https", url.user == nil, url.password == nil,
              url.port == nil, let host = url.host?.lowercased(),
              host == "notion.so" || host == "www.notion.so" || host == "notion.com" ||
              host == "www.notion.com" || host == "app.notion.com" ||
              (host.hasSuffix(".notion.site") && host.count > ".notion.site".count) else {
            throw MeetingError.message("Notion hedef sayfasının bağlantısını veya sayfa kimliğini girin.")
        }
        let component = url.lastPathComponent
        if let id = normalizedUUID(String(component.suffix(36))) { return id }
        if let id = normalizedUUID(String(component.suffix(32))) { return id }
        throw MeetingError.message("Bu bağlantıda geçerli bir Notion sayfa kimliği bulunamadı.")
    }

    static func normalizedUUID(_ value: String) -> String? {
        let plain = value.replacingOccurrences(of: "-", with: "")
        guard (value.count == 32 || value.count == 36), plain.count == 32,
              plain.unicodeScalars.allSatisfy({ CharacterSet(charactersIn: "0123456789abcdefABCDEF").contains($0) }) else { return nil }
        let chars = Array(plain)
        let formatted = [String(chars[0..<8]), String(chars[8..<12]), String(chars[12..<16]),
                         String(chars[16..<20]), String(chars[20..<32])].joined(separator: "-")
        guard let uuid = UUID(uuidString: formatted) else { return nil }
        if value.count == 36, value.lowercased() != uuid.uuidString.lowercased() { return nil }
        return uuid.uuidString.lowercased()
    }

    static func pageURL(_ pageID: String, proposed: String? = nil) -> URL {
        if let proposed, let url = URL(string: proposed),
           url.scheme?.lowercased() == "https", url.user == nil, url.password == nil, url.port == nil,
           ["notion.so", "www.notion.so", "app.notion.com", "notion.com", "www.notion.com"].contains(url.host?.lowercased() ?? ""),
           (try? parse(proposed)) == normalizedUUID(pageID) { return url }
        // Only locally validated UUIDs reach this method; never open an arbitrary API-supplied URL.
        return URL(string: "https://www.notion.so/" + pageID.replacingOccurrences(of: "-", with: ""))!
    }
}

struct NotionExportBlock {
    var type: String
    var text: [String]
    var checked: Bool? = nil
    var bold: Bool = false
    var color: String = "default"

    var json: [String: Any] {
        var content: [String: Any] = [
            "rich_text": text.map { part in
                ["type": "text", "text": ["content": part], "annotations": ["bold": bold]] as [String: Any]
            },
            "color": color
        ]
        if let checked { content["checked"] = checked }
        return ["object": "block", "type": type, type: content]
    }
}

struct NotionExportPlan {
    let beforeTranscript: [NotionExportBlock]
    let transcript: [NotionExportBlock]
    let afterTranscript: [NotionExportBlock]
    let hasTranscript: Bool

    init(document: MeetingShareDocument) {
        var before: [NotionExportBlock] = []
        var transcript: [NotionExportBlock] = []
        var after: [NotionExportBlock] = []
        var inTranscript = false
        for block in document.blocks {
            if block.kind == .title || block.kind == .anchor { continue }
            if block.kind == .section && block.text == "Transkript" {
                inTranscript = true
                continue
            }
            if block.kind == .footer {
                after.append(contentsOf: Self.convert(block))
            } else if inTranscript {
                transcript.append(contentsOf: Self.convert(block))
            } else {
                before.append(contentsOf: Self.convert(block))
            }
        }
        beforeTranscript = before
        self.transcript = transcript
        afterTranscript = after
        hasTranscript = inTranscript
    }

    /// Split by UTF-16 length, keeping valid Unicode scalars and every original character.
    /// This is conservative for Notion's 2,000 character text.content limit.
    static func textChunks(_ text: String, limit: Int = 2000) -> [String] {
        guard !text.isEmpty else { return [] }
        var chunks: [String] = [], current = "", units = 0
        for scalar in text.unicodeScalars {
            let size = scalar.value > 0xFFFF ? 2 : 1
            if units + size > limit && !current.isEmpty {
                chunks.append(current); current = ""; units = 0
            }
            current.unicodeScalars.append(scalar)
            units += size
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }

    private static func convert(_ block: MeetingExportBlock) -> [NotionExportBlock] {
        var text = block.text, type = "paragraph", checked: Bool? = nil
        var bold = false, color = "default"
        switch block.kind {
        case .title, .anchor: return []
        case .section: type = "heading_2"
        case .subsection: type = "heading_3"
        case .bullet:
            type = "bulleted_list_item"
            if text.hasPrefix("• ") { text.removeFirst(2) }
        case .action:
            type = "to_do"; checked = text.hasPrefix("☑ ")
            if text.hasPrefix("☑ ") || text.hasPrefix("☐ ") { text.removeFirst(2) }
        case .transcriptHeading: bold = true; color = "gray"
        case .metadata, .footer: color = "gray"
        case .notice: type = "quote"; color = "gray"
        case .paragraph: break
        }
        let pieces = textChunks(text)
        guard !pieces.isEmpty else { return [] }
        // Keeping each block under 32,000 UTF-16 units also bounds its encoded byte size.
        return stride(from: 0, to: pieces.count, by: 16).enumerated().map { index, start in
            NotionExportBlock(type: index == 0 ? type : "paragraph",
                              text: Array(pieces[start..<min(start + 16, pieces.count)]),
                              checked: index == 0 ? checked : nil, bold: bold, color: color)
        }
    }

    static func batches(_ blocks: [NotionExportBlock]) throws -> [[NotionExportBlock]] {
        var batches: [[NotionExportBlock]] = [], batch: [NotionExportBlock] = []
        for block in blocks {
            let candidate = batch + [block]
            let size = try JSONSerialization.data(withJSONObject: ["children": candidate.map(\.json)]).count
            if candidate.count > 100 || size > 400_000 {
                guard !batch.isEmpty else { throw MeetingError.message("Bir Notion metin bloğu çok büyük; metni kısaltıp yeniden deneyin.") }
                batches.append(batch)
                batch = [block]
            } else { batch = candidate }
        }
        if !batch.isEmpty { batches.append(batch) }
        return batches
    }
}

private final class NotionNoRedirectDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        // The bearer token is sent only to api.notion.com; redirects never receive it.
        completionHandler(nil)
    }
}

private struct NotionRequestFailure: Error {
    let message: String
    var uncertainWrite = false
    var committedResourceID: String? = nil
}

actor NotionExportService {
    typealias Transport = (URLRequest) async throws -> (Data, HTTPURLResponse)
    typealias Sleep = (Double) async throws -> Void
    static let apiVersion = "2026-03-11"
    private let transport: Transport
    private let sleep: Sleep
    private let minimumRequestInterval: Double
    private var previousRequestAt: Date?

    init(transport: Transport? = nil, sleep: @escaping Sleep = { seconds in
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }, minimumRequestInterval: Double = 0.4) {
        self.sleep = sleep
        self.minimumRequestInterval = max(0, minimumRequestInterval)
        if let transport { self.transport = transport } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.urlCache = nil
            configuration.urlCredentialStorage = nil
            configuration.httpShouldSetCookies = false
            configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
            configuration.timeoutIntervalForRequest = 60
            let session = URLSession(configuration: configuration, delegate: NotionNoRedirectDelegate(), delegateQueue: nil)
            self.transport = { request in
                let (data, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse else {
                    throw NotionRequestFailure(message: "Notion’dan geçerli bir yanıt alınamadı.", uncertainWrite: true)
                }
                return (data, http)
            }
        }
    }

    static func validatedToken(_ token: String) throws -> String {
        let value = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (20...512).contains(value.utf8.count),
              value.unicodeScalars.allSatisfy({ $0.value >= 33 && $0.value <= 126 }) else {
            throw MeetingError.message("Geçerli bir Notion bağlantı anahtarı girin.")
        }
        return value
    }

    func export(document: MeetingShareDocument, title: String, parentPageID: String, token: String,
                progress: (@MainActor (String) -> Void)? = nil,
                onPageCreated: (@MainActor (NotionExportReceipt) -> Void)? = nil) async throws -> NotionExportReceipt {
        let token = try Self.validatedToken(token)
        let parentID = try NotionPageIdentifier.parse(parentPageID)
        let titleParts = NotionExportPlan.textChunks(title.isEmpty ? "Toplantı" : title)
        guard titleParts.count <= 100 else { throw MeetingError.message("Notion sayfa başlığı çok uzun; daha kısa bir başlık seçin.") }
        let plan = NotionExportPlan(document: document)
        // Preflight all sizes before creating a remote page.
        let before = try NotionExportPlan.batches(plan.beforeTranscript)
        let transcript = try NotionExportPlan.batches(plan.transcript)
        let after = try NotionExportPlan.batches(plan.afterTranscript)
        let body: [String: Any] = [
            "parent": ["type": "page_id", "page_id": parentID],
            "properties": ["title": ["type": "title", "title": titleParts.map { ["type": "text", "text": ["content": $0]] as [String: Any] }]],
            "icon": ["type": "emoji", "emoji": "📝"]
        ]
        let createData = try JSONSerialization.data(withJSONObject: body)
        guard createData.count <= 400_000 else { throw MeetingError.message("Notion sayfa başlığı çok büyük; daha kısa bir başlık seçin.") }
        var receipt: NotionExportReceipt?
        do {
            await progress?("Notion sayfası oluşturuluyor…")
            let response = try await request(method: "POST", path: "pages", data: createData, token: token)
            guard let rawID = response["id"] as? String, let pageID = NotionPageIdentifier.normalizedUUID(rawID) else {
                throw NotionRequestFailure(message: "Notion sayfayı oluşturmuş olabilir, ancak bağlantısı doğrulanamadı. Yeniden göndermeden önce hedef sayfayı kontrol edin.", uncertainWrite: true)
            }
            let page = NotionExportReceipt(pageID: pageID,
                                          url: NotionPageIdentifier.pageURL(pageID, proposed: response["url"] as? String))
            receipt = page
            await onPageCreated?(page)
            for batch in before {
                await progress?("Toplantı notları Notion’a aktarılıyor…")
                _ = try await append(batch, parentID: pageID, token: token)
            }
            if plan.hasTranscript {
                await progress?("Transkript bölümü hazırlanıyor…")
                let toggle = NotionExportBlock(type: "toggle", text: ["Transkript · Zaman damgalı konuşmalar"], bold: true)
                let response = try await append([toggle], parentID: pageID, token: token)
                guard let results = response["results"] as? [[String: Any]], let first = results.first,
                      let rawID = first["id"] as? String, let toggleID = NotionPageIdentifier.normalizedUUID(rawID) else {
                    throw NotionRequestFailure(message: "Transkript bölümünün bağlantısı doğrulanamadı.", uncertainWrite: true)
                }
                for (index, batch) in transcript.enumerated() {
                    await progress?("Transkript aktarılıyor · \(index + 1)/\(transcript.count)")
                    _ = try await append(batch, parentID: toggleID, token: token)
                }
            }
            for batch in after { _ = try await append(batch, parentID: pageID, token: token) }
            await progress?("Notion’a aktarıldı.")
            return page
        } catch {
            let failure = error as? NotionRequestFailure
            if receipt == nil, let committedID = failure?.committedResourceID,
               let pageID = NotionPageIdentifier.normalizedUUID(committedID) {
                receipt = NotionExportReceipt(pageID: pageID, url: NotionPageIdentifier.pageURL(pageID))
                if let receipt { await onPageCreated?(receipt) }
            }
            let detail = failure?.message ?? (error is CancellationError ? "Notion aktarımı tamamlanmadan kesildi." : "Notion’a bağlantı kurulamadı. İnternet bağlantısını kontrol edin.")
            let suffix = receipt == nil ? "" : " Oluşturulan sayfayı açıp eksik içeriği kontrol edebilirsiniz; otomatik olarak yeni bir kopya oluşturulmadı."
            throw NotionExportFailure(message: detail + suffix, createdPageURL: receipt?.url,
                                      exportMayHaveSucceeded: receipt != nil || failure?.uncertainWrite == true || failure == nil)
        }
    }

    private func append(_ blocks: [NotionExportBlock], parentID: String, token: String) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["children": blocks.map(\.json)])
        return try await request(method: "PATCH", path: "blocks/\(parentID)/children", data: data, token: token)
    }

    private func request(method: String, path: String, data: Data, token: String) async throws -> [String: Any] {
        let url = URL(string: "https://api.notion.com/v1/" + path)!
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = data
        request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        request.setValue(Self.apiVersion, forHTTPHeaderField: "Notion-Version")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        var retries = 0
        while true {
            try Task.checkCancellation()
            if let previousRequestAt {
                let remaining = minimumRequestInterval - Date().timeIntervalSince(previousRequestAt)
                if remaining > 0 { try await sleep(remaining) }
            }
            previousRequestAt = Date()
            let dataResponse: Data, http: HTTPURLResponse
            do { (dataResponse, http) = try await transport(request) }
            catch { throw NotionRequestFailure(message: "Notion’dan yanıt alınamadı. Sayfa oluşturulmuş olabilir; yeniden göndermeden önce hedef sayfayı kontrol edin.", uncertainWrite: true) }
            guard http.url?.scheme == "https", http.url?.host == "api.notion.com", http.url?.port == nil else {
                throw NotionRequestFailure(message: "Notion yanıtının adresi doğrulanamadı.", uncertainWrite: true)
            }
            let response = (try? JSONSerialization.jsonObject(with: dataResponse)) as? [String: Any] ?? [:]
            if (200..<300).contains(http.statusCode) { return response }
            let extra = response["additional_data"] as? [String: Any]
            let blocked = extra?["rate_limit_reason"] as? String == "public_api_request_blocked"
            if [429, 529].contains(http.statusCode) && !blocked && retries < 3 {
                let rawDelay = http.value(forHTTPHeaderField: "Retry-After") ?? extra?["retry_after"] as? String
                let delay = rawDelay.flatMap(Double.init) ?? pow(2, Double(retries))
                // Never retry sooner than Retry-After. Long workspace limits are surfaced for a later attempt.
                guard delay.isFinite, delay >= 0, delay <= 60 else {
                    throw NotionRequestFailure(message: "Notion şu an istekleri sınırlıyor. Bir süre sonra tekrar deneyin.")
                }
                try await sleep(max(delay, pow(2, Double(retries))) + 0.1)
                retries += 1
                continue
            }
            let message: String
            switch http.statusCode {
            case 401: message = "Notion bağlantı anahtarı kabul edilmedi. Ayarlardan yeniden kaydedin."
            case 403: message = "Notion yazma izni vermedi. Bağlantının içerik ekleme iznini ve çalışma alanının blok sınırını kontrol edin."
            case 404: message = "Notion hedef sayfasına erişilemiyor. Sayfanın bağlantılar menüsünden bu bağlantıya erişim verin."
            case 400: message = "Notion bu içeriği kabul etmedi. Hedefin bir sayfa olduğundan ve başlığın geçerli olduğundan emin olun."
            case 429, 529: message = "Notion şu an istekleri sınırlıyor. Bir süre sonra tekrar deneyin."
            case 500...599: message = "Notion aktarımı doğrulanamadı. İçerik kaydedilmiş olabilir; yeniden göndermeden önce hedef sayfayı kontrol edin."
            case 300...399: message = "Notion beklenmeyen bir yönlendirme döndürdü; bağlantı anahtarı başka adrese gönderilmedi."
            default: message = "Notion aktarımı tamamlanamadı. Bağlantı ayarlarını kontrol edin."
            }
            // 5xx write failures can occur after commit. Never repeat POST/PATCH automatically.
            throw NotionRequestFailure(message: message, uncertainWrite: http.statusCode >= 500 && http.statusCode != 529,
                                       committedResourceID: extra?["committed_resource_id"] as? String)
        }
    }
}
