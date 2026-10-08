import Foundation
import Combine
import Sparkle

/// Update URLs are fixed by the release configuration, never by a downloaded feed.
struct UpdateConfiguration: Equatable {
    let repository: String
    let feedURL: URL
    let publicEDKey: String
    let privateUpdates: Bool

    init(info: [String: Any]) throws {
        guard let repository = info["MeetingDeskUpdateRepository"] as? String,
              Self.isValidRepository(repository),
              let feed = info["SUFeedURL"] as? String,
              let feedURL = URL(string: feed),
              let key = info["SUPublicEDKey"] as? String,
              Self.isValidPublicKey(key) else {
            throw Self.failure("Bu sürümün güncelleme bağlantısı henüz yapılandırılmadı.")
        }
        self.repository = repository
        self.feedURL = feedURL
        self.publicEDKey = key
        self.privateUpdates = (info["MeetingDeskPrivateUpdates"] as? Bool) ?? false
        guard acceptsFeedURL(feedURL) else {
            throw Self.failure("Güncelleme bağlantısı bu uygulamanın GitHub deposuyla eşleşmiyor.")
        }
    }

    static func isValidPublicKey(_ value: String) -> Bool {
        guard value == value.trimmingCharacters(in: .whitespacesAndNewlines),
              let data = Data(base64Encoded: value), data.count == 32 else { return false }
        // Ed25519 public keys use exactly 32 bytes. Reject noncanonical encodings.
        return data.base64EncodedString() == value
    }

    static func isValidRepository(_ value: String) -> Bool {
        let pieces = value.split(separator: "/", omittingEmptySubsequences: false)
        guard pieces.count == 2, (1...39).contains(pieces[0].count),
              (1...100).contains(pieces[1].count), pieces[1] != ".", pieces[1] != ".." else { return false }
        return pieces[0].range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$", options: .regularExpression) != nil
            && pieces[1].range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil
    }

    func acceptsFeedURL(_ url: URL) -> Bool {
        guard let components = safeComponents(url) else { return false }
        let path = components.percentEncodedPath
        if privateUpdates {
            guard components.host?.lowercased() == "api.github.com",
                  ["/repos/\(repository)/contents/appcast.xml", "/repos/\(repository)/contents/Distribution/appcast.xml"].contains(path) else { return false }
            return components.queryItems == [URLQueryItem(name: "ref", value: "main")]
        }
        guard components.query == nil else { return false }
        switch components.host?.lowercased() {
        case "raw.githubusercontent.com":
            return ["/\(repository)/main/appcast.xml", "/\(repository)/main/Distribution/appcast.xml"].contains(path)
        case "github.com":
            return path == "/\(repository)/releases/latest/download/appcast.xml"
        default: return false
        }
    }

    func acceptsDownloadURL(_ url: URL) -> Bool {
        guard let components = safeComponents(url), components.query == nil else { return false }
        let path = components.percentEncodedPath
        if privateUpdates {
            guard components.host?.lowercased() == "api.github.com" else { return false }
            let prefix = "/repos/\(repository)/releases/assets/"
            guard path.hasPrefix(prefix) else { return false }
            let id = String(path.dropFirst(prefix.count))
            return id.range(of: "^[1-9][0-9]*$", options: .regularExpression) != nil
        }
        guard components.host?.lowercased() == "github.com" else { return false }
        let prefix = "/\(repository)/releases/download/"
        guard path.hasPrefix(prefix) else { return false }
        let suffix = path.dropFirst(prefix.count).split(separator: "/", omittingEmptySubsequences: false)
        return suffix.count == 2 && suffix.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Called only after URL validation, so credentials cannot follow arbitrary appcast links.
    func feedHeaders(token: String?) throws -> [String: String] {
        guard privateUpdates else { return [:] }
        let token = try Self.validatedToken(token)
        return ["Authorization": "Bearer \(token)", "Accept": "application/vnd.github.raw+json", "X-GitHub-Api-Version": "2022-11-28"]
    }

    func downloadHeaders(url: URL, token: String?) throws -> [String: String] {
        guard acceptsDownloadURL(url) else {
            throw Self.failure("Güncelleme dosyası beklenen GitHub deposunda bulunmuyor.")
        }
        guard privateUpdates else { return [:] }
        let token = try Self.validatedToken(token)
        return ["Authorization": "Bearer \(token)", "Accept": "application/octet-stream", "X-GitHub-Api-Version": "2022-11-28"]
    }

    func configureDownloadRequest(_ request: NSMutableURLRequest, token: String?) throws {
        // Sparkle initially copies its feed headers onto the archive request.
        for header in ["Authorization", "Accept", "X-GitHub-Api-Version"] {
            request.setValue(nil, forHTTPHeaderField: header)
        }
        guard let url = request.url else { throw Self.failure("Geçersiz güncelleme bağlantısı.") }
        for (name, value) in try downloadHeaders(url: url, token: token) {
            request.setValue(value, forHTTPHeaderField: name)
        }
    }

    static func validatedToken(_ token: String?) throws -> String {
        guard let token, !token.isEmpty, token.utf8.count <= 1024,
              token.unicodeScalars.allSatisfy({ (33...126).contains($0.value) }) else {
            throw failure("Özel GitHub deposundaki güncellemeler için Ayarlar’dan erişim anahtarını kaydedin.")
        }
        return token
    }

    private func safeComponents(_ url: URL) -> URLComponents? {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", components.user == nil,
              components.password == nil, components.port == nil, components.fragment == nil,
              !components.percentEncodedPath.contains("%") else { return nil }
        return components
    }

    static func failure(_ message: String) -> NSError {
        NSError(domain: "com.altugegesari.meetingdesk.update", code: 1,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

/// A downloaded update may outlive an idle period. Recheck at installation time.
@MainActor
final class UpdateInstallationGate {
    private(set) var workInProgress = false
    private var postponedInstallation: (() -> Void)?

    func requireIdle() throws {
        guard !workInProgress else {
            throw UpdateConfiguration.failure("Kayıt veya not hazırlama sürüyor. İşlem bittikten sonra güncelleyebilirsiniz.")
        }
    }

    @discardableResult
    func postponeIfBusy(_ installation: @escaping () -> Void) -> Bool {
        guard workInProgress else { return false }
        // A subsequent callback represents the same update at a newer stage.
        postponedInstallation = installation
        return true
    }

    func setWorkInProgress(_ busy: Bool) {
        workInProgress = busy
        guard !busy, postponedInstallation != nil else { return }
        // Combine @Published sends its new value before the stored property changes.
        // Wait for that setter to finish, then recheck in case new work began meanwhile.
        Task { @MainActor [weak self] in
            guard let self, !self.workInProgress, let installation = self.postponedInstallation else { return }
            self.postponedInstallation = nil
            installation()
        }
    }
}

@MainActor
final class AppUpdater: NSObject, ObservableObject, SPUUpdaterDelegate {
    @Published private(set) var canCheckForUpdates = false
    @Published private(set) var isConfigured = false
    @Published private(set) var configurationMessage = "Güncelleme bağlantısı hazırlanıyor."
    @Published private(set) var hasUpdateToken = false
    @Published var automaticallyChecksForUpdates = false {
        didSet {
            guard let updater = controller?.updater,
                  updater.automaticallyChecksForUpdates != automaticallyChecksForUpdates else { return }
            updater.automaticallyChecksForUpdates = automaticallyChecksForUpdates
        }
    }

    let versionLabel: String
    let requiresAuthentication: Bool
    private let configuration: UpdateConfiguration?
    private let gate = UpdateInstallationGate()
    private var controller: SPUStandardUpdaterController?
    private var subscriptions: Set<AnyCancellable> = []
    private var started = false

    override init() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "Geliştirme"
        let build = info["CFBundleVersion"] as? String ?? ""
        versionLabel = build.isEmpty ? version : "\(version) (\(build))"
        configuration = try? UpdateConfiguration(info: info)
        requiresAuthentication = configuration?.privateUpdates ?? false
        super.init()

        guard configuration != nil else {
            configurationMessage = "Bu geliştirme sürümünün güncelleme bağlantısı henüz yapılandırılmadı."
            return
        }
        controller = SPUStandardUpdaterController(startingUpdater: false, updaterDelegate: self, userDriverDelegate: nil)
        guard let updater = controller?.updater else { return }
        automaticallyChecksForUpdates = updater.automaticallyChecksForUpdates
        updater.publisher(for: \.canCheckForUpdates).sink { [weak self] _ in
            self?.refreshState()
        }.store(in: &subscriptions)
        updater.publisher(for: \.automaticallyChecksForUpdates).sink { [weak self] enabled in
            guard let self, self.automaticallyChecksForUpdates != enabled else { return }
            self.automaticallyChecksForUpdates = enabled
        }.store(in: &subscriptions)
        refreshCredentialState()
        startWhenReady()
    }

    func setWorkInProgress(_ busy: Bool) {
        gate.setWorkInProgress(busy)
        refreshState()
    }

    func checkForUpdates() {
        guard canCheckForUpdates else { return }
        controller?.checkForUpdates(nil)
    }

    func saveUpdateToken(_ value: String) throws {
        let token = try UpdateConfiguration.validatedToken(value.trimmingCharacters(in: .whitespacesAndNewlines))
        try GitHubUpdateKeychain.save(token)
        refreshCredentialState()
        startWhenReady()
        refreshState()
    }

    func deleteUpdateToken() throws {
        try GitHubUpdateKeychain.delete()
        controller?.updater.httpHeaders = nil
        refreshCredentialState()
        refreshState()
    }

    private func refreshCredentialState() {
        guard requiresAuthentication else { hasUpdateToken = false; return }
        hasUpdateToken = ((try? GitHubUpdateKeychain.load()) ?? nil).flatMap { try? UpdateConfiguration.validatedToken($0) } != nil
    }

    private func startWhenReady() {
        guard !started, let configuration, let updater = controller?.updater else { return }
        guard !configuration.privateUpdates || hasUpdateToken else {
            configurationMessage = "Özel GitHub güncellemeleri için erişim anahtarı gerekiyor."
            return
        }
        do {
            updater.httpHeaders = try configuration.feedHeaders(token: configuration.privateUpdates ? GitHubUpdateKeychain.load() : nil)
            updater.sendsSystemProfile = false
            updater.automaticallyDownloadsUpdates = false
            _ = updater.clearFeedURLFromUserDefaults()
            try updater.start()
            started = true
            isConfigured = true
            configurationMessage = "Yeni sürümler bu uygulamanın içinden yüklenir."
        } catch {
            configurationMessage = "Güncelleme denetimi başlatılamadı. Sürüm yapılandırmasını kontrol edin."
        }
        refreshState()
    }

    private func refreshState() {
        canCheckForUpdates = isConfigured && started && !gate.workInProgress
            && (!requiresAuthentication || hasUpdateToken) && (controller?.updater.canCheckForUpdates ?? false)
        if requiresAuthentication && !hasUpdateToken {
            configurationMessage = "Özel GitHub güncellemeleri için erişim anahtarı gerekiyor."
        } else if isConfigured {
            configurationMessage = gate.workInProgress
                ? "Kayıt veya not hazırlama bittikten sonra güncelleyebilirsiniz."
                : "Yeni sürümler bu uygulamanın içinden yüklenir."
        }
    }

    func feedURLString(for updater: SPUUpdater) -> String? { configuration?.feedURL.absoluteString }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try gate.requireIdle()
        guard let configuration, isConfigured else { throw UpdateConfiguration.failure("Güncellemeler henüz yapılandırılmadı.") }
        updater.httpHeaders = try configuration.feedHeaders(token: configuration.privateUpdates ? GitHubUpdateKeychain.load() : nil)
        // Package Info.plist also disables automatic installation so user choice is retained.
        updater.automaticallyDownloadsUpdates = false
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate updateItem: SUAppcastItem, updateCheck: SPUUpdateCheck) throws {
        try gate.requireIdle()
        guard let configuration, let url = updateItem.fileURL, configuration.acceptsDownloadURL(url) else {
            throw UpdateConfiguration.failure("Güncelleme dosyası beklenen GitHub deposunda bulunmuyor.")
        }
    }

    func updater(_ updater: SPUUpdater, shouldDownloadReleaseNotesForUpdate updateItem: SUAppcastItem) -> Bool {
        // Inline appcast notes avoid passing private authentication to a separate notes URL.
        false
    }

    func updater(_ updater: SPUUpdater, willDownloadUpdate item: SUAppcastItem, with request: NSMutableURLRequest) {
        do {
            guard let configuration else { throw UpdateConfiguration.failure("Geçersiz güncelleme bağlantısı.") }
            try configuration.configureDownloadRequest(request, token: configuration.privateUpdates ? GitHubUpdateKeychain.load() : nil)
        } catch {
            request.setValue(nil, forHTTPHeaderField: "Authorization")
            // Sparkle rejects non-HTTP schemes; the untrusted request never leaves the Mac.
            request.url = URL(string: "about:blank")!
        }
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem, untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        gate.postponeIfBusy(installHandler)
    }

    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        gate.postponeIfBusy(immediateInstallHandler)
    }
}
