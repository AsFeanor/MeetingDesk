import Foundation
import Combine
import Security

enum NotionCredentialKeychain {
    private static var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "com.altugegesari.meetingdesk.notion-export",
         kSecAttrAccount as String: "connection-token"]
    }

    static func load() throws -> String? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw failure() }
        guard let data = result as? Data, let token = String(data: data, encoding: .utf8) else { throw failure() }
        return token
    }

    static func save(_ token: String) throws {
        let token = try NotionExportService.validatedToken(token)
        let attributes: [String: Any] = [kSecValueData as String: Data(token.utf8)]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query.merging(attributes) { _, new in new }
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else { throw failure() }
        } else if status != errSecSuccess { throw failure() }
    }

    static func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw failure() }
    }

    private static func failure() -> MeetingError {
        .message("Notion anahtarı Anahtar Zinciri’nde okunamadı veya kaydedilemedi. Ayarlardan yeniden deneyin.")
    }
}

struct NotionCredentialStore {
    var load: () throws -> String?
    var save: (String) throws -> Void
    var delete: () throws -> Void

    static var keychain: NotionCredentialStore {
        NotionCredentialStore(load: NotionCredentialKeychain.load,
                              save: NotionCredentialKeychain.save,
                              delete: NotionCredentialKeychain.delete)
    }
}

@MainActor
final class NotionConnection: ObservableObject {
    @Published var parentPageInput: String
    @Published private(set) var hasToken = false
    @Published private(set) var isExporting = false
    @Published private(set) var statusMessage = ""
    @Published private(set) var lastExportURL: URL?
    @Published private(set) var incompleteExportURL: URL?
    @Published private(set) var exportMayHaveSucceeded = false

    var isConfigured: Bool { hasToken && (try? NotionPageIdentifier.parse(parentPageInput)) != nil }
    var canExport: Bool { isConfigured && !isExporting && !exportMayHaveSucceeded }

    private let defaults: UserDefaults
    private let loadCredentials: Bool
    private let service: NotionExportService
    private let credentialStore: NotionCredentialStore
    private static let parentKey = "MeetingDeskNotionParentPage"
    private static let lastKey = "MeetingDeskNotionLastExport"
    private static let incompleteKey = "MeetingDeskNotionIncompleteExport"
    private static let uncertainKey = "MeetingDeskNotionUncertainExport"

    init(loadCredentials: Bool = true, defaults: UserDefaults = .standard, service: NotionExportService = NotionExportService(),
         credentialStore: NotionCredentialStore = .keychain) {
        self.defaults = defaults
        self.loadCredentials = loadCredentials
        self.service = service
        self.credentialStore = credentialStore
        parentPageInput = defaults.string(forKey: Self.parentKey) ?? ""
        if let last = defaults.string(forKey: Self.lastKey), let id = try? NotionPageIdentifier.parse(last) {
            lastExportURL = NotionPageIdentifier.pageURL(id, proposed: last)
        }
        if let incomplete = defaults.string(forKey: Self.incompleteKey), let id = try? NotionPageIdentifier.parse(incomplete) {
            incompleteExportURL = NotionPageIdentifier.pageURL(id, proposed: incomplete)
        }
        exportMayHaveSucceeded = defaults.bool(forKey: Self.uncertainKey)
        if exportMayHaveSucceeded {
            statusMessage = "Önceki aktarım tamamlanamamış olabilir. Yeni bir kopya oluşturmadan önce Notion hedefini kontrol edin."
        }
        if loadCredentials { refresh() }
    }

    func refresh() {
        guard loadCredentials else { return }
        do {
            hasToken = try credentialStore.load().flatMap { try? NotionExportService.validatedToken($0) } != nil
        } catch { hasToken = false; statusMessage = error.localizedDescription }
    }

    func saveConnection(token: String, parentPage: String) throws {
        guard !isExporting else { throw MeetingError.message("Notion aktarımı bitene kadar bağlantı ayarları değiştirilemez.") }
        let parent = try NotionPageIdentifier.parse(parentPage)
        guard loadCredentials else { throw MeetingError.message("Bu önizlemede Notion bağlantısı kaydedilemez.") }
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { try credentialStore.save(NotionExportService.validatedToken(trimmed)) }
        else if !hasToken { throw MeetingError.message("Bir Notion bağlantı anahtarı girin.") }
        parentPageInput = parent
        defaults.set(parent, forKey: Self.parentKey)
        refresh()
        if !exportMayHaveSucceeded { statusMessage = "Notion bağlantısı kaydedildi. Hedef sayfaya bağlantı erişimi verdiğinizden emin olun." }
    }

    func disconnect() throws {
        guard !isExporting else { throw MeetingError.message("Notion aktarımı bitene kadar bağlantı kaldırılamaz.") }
        guard loadCredentials else { return }
        try credentialStore.delete()
        hasToken = false
        parentPageInput = ""
        defaults.removeObject(forKey: Self.parentKey)
        // Keep an incomplete page link available even when the credential is removed.
        statusMessage = "Notion bağlantısı kaldırıldı."
    }

    /// Called only by the explicit “Yeni bir kopya oluştur” action after reviewing a partial/uncertain export.
    func acknowledgeIncompleteExport() {
        guard !isExporting else { return }
        exportMayHaveSucceeded = false
        incompleteExportURL = nil
        defaults.removeObject(forKey: Self.uncertainKey)
        defaults.removeObject(forKey: Self.incompleteKey)
        statusMessage = "Yeni bir Notion sayfasına aktarım yapabilirsiniz."
    }

    func export(document: MeetingShareDocument, title: String) async throws -> NotionExportReceipt {
        guard canExport, loadCredentials else {
            throw MeetingError.message(exportMayHaveSucceeded ? "Önceki aktarımı kontrol edip yeni bir kopya oluşturmayı seçin." : "Önce Ayarlar’dan Notion bağlantısını kurun.")
        }
        guard let token = try credentialStore.load() else { hasToken = false; throw MeetingError.message("Notion bağlantı anahtarı bulunamadı.") }
        let parent = try NotionPageIdentifier.parse(parentPageInput)
        isExporting = true
        // Persist before the first remote write. A crash must not invite an implicit duplicate.
        exportMayHaveSucceeded = true
        defaults.set(true, forKey: Self.uncertainKey)
        defer { isExporting = false }
        do {
            let receipt = try await service.export(document: document, title: title, parentPageID: parent, token: token,
                progress: { [weak self] message in self?.statusMessage = message },
                onPageCreated: { [weak self] receipt in
                    self?.incompleteExportURL = receipt.url
                    self?.defaults.set(receipt.url.absoluteString, forKey: Self.incompleteKey)
                })
            lastExportURL = receipt.url
            defaults.set(receipt.url.absoluteString, forKey: Self.lastKey)
            incompleteExportURL = nil
            exportMayHaveSucceeded = false
            defaults.removeObject(forKey: Self.incompleteKey)
            defaults.removeObject(forKey: Self.uncertainKey)
            statusMessage = "Notion’a aktarıldı."
            return receipt
        } catch {
            if let failure = error as? NotionExportFailure {
                incompleteExportURL = failure.createdPageURL
                exportMayHaveSucceeded = failure.exportMayHaveSucceeded
                defaults.set(failure.exportMayHaveSucceeded, forKey: Self.uncertainKey)
                if let url = failure.createdPageURL { defaults.set(url.absoluteString, forKey: Self.incompleteKey) }
                else { defaults.removeObject(forKey: Self.incompleteKey) }
            } else {
                // Local validation failed before any remote write.
                exportMayHaveSucceeded = false
                defaults.removeObject(forKey: Self.uncertainKey)
            }
            statusMessage = error.localizedDescription
            throw error
        }
    }
}
