import Foundation
import Security
import CryptoKit
import Darwin

protocol LoginCredentialStorage: Sendable {
    func load() throws -> Data?
    func save(_ data: Data) throws
    func delete() throws
}

/// One item owned by this app, scoped to its data directory. No access/ID token is persisted.
final class LoginKeychainStore: LoginCredentialStorage, @unchecked Sendable {
    let service: String
    let account: String
    let label: String
    private let labelLock = NSLock()
    private var labelRefreshAttempted = false

    init(dataDirectory: URL, service: String = "local.leaf.pdfreader.chatgpt-login",
         preferredLanguages: [String] = Locale.preferredLanguages) {
        self.service = service
        let location = dataDirectory.standardizedFileURL.path
        self.account = SHA256.hash(data: Data(location.utf8)).map { String(format: "%02x", $0) }.joined()
        // Keychain dialogs belong to macOS, so their item name follows the system.
        self.label = Self.loginLabel(language: .system.resolved(preferredLanguages: preferredLanguages))
    }

    static func loginLabel(language: ReaderLanguage) -> String {
        let signIn: String
        switch language.resolved() {
        case .zhHans: signIn = "ChatGPT 登录"
        case .zhHant: signIn = "ChatGPT 登入"
        case .ja: signIn = "ChatGPT ログイン"
        case .ko: signIn = "ChatGPT 로그인"
        case .fr: signIn = "Connexion ChatGPT"
        case .de: signIn = "ChatGPT-Anmeldung"
        case .es: signIn = "Inicio de sesión de ChatGPT"
        case .pt: signIn = "Login do ChatGPT"
        case .en, .system: signIn = "ChatGPT sign-in"
        }
        return "Margin · " + signIn
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    func load() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else { throw KeychainFailure(status: status) }
        guard data.count <= 131_072 else { throw KeychainFailure(message: "保存的登录数据过大，请退出登录后重试。") }
        // Migrate only after authorized access. A cosmetic failure must not lose a login.
        refreshLabelOnce()
        return data
    }

    func save(_ data: Data) throws {
        guard data.count <= 131_072 else { throw KeychainFailure(message: "登录数据过大，无法保存到钥匙串。") }
        let update = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = label
            // The macOS login Keychain protects this item using the caller's ACL.
            // Do not opt in to iCloud synchronization or the entitlement-requiring
            // data-protection Keychain, which an ad-hoc local app cannot access.
            status = SecItemAdd(item as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        refreshLabelOnce()
    }

    private func refreshLabelOnce() {
        labelLock.lock()
        let shouldRefresh = !labelRefreshAttempted
        labelRefreshAttempted = true
        labelLock.unlock()
        // A declined rename is retried on the next launch, not every token refresh.
        if shouldRefresh { try? refreshLabel() }
    }

    private func refreshLabel() throws {
        // ACL edits can prompt even when normal password operations suppress UI.
        var interactionAllowed: DarwinBoolean = false
        guard SecKeychainGetUserInteractionAllowed(&interactionAllowed) == errSecSuccess,
              interactionAllowed.boolValue else { return }
        var request = query
        request[kSecReturnAttributes as String] = true
        request[kSecReturnRef as String] = true
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        guard status == errSecSuccess, let attributes = result as? [String: Any],
              let reference = attributes[kSecValueRef as String] else { throw KeychainFailure(status: status) }
        let item = reference as! SecKeychainItem
        var access: SecAccess?
        let accessStatus = SecKeychainItemCopyAccess(item, &access)
        guard accessStatus == errSecSuccess, let access else { throw KeychainFailure(status: accessStatus) }
        let accessChanged = try Self.updatePromptDescriptions(in: access, label: label)
        var update: [String: Any] = [:]
        if attributes[kSecAttrLabel as String] as? String != label { update[kSecAttrLabel as String] = label }
        if accessChanged { update[kSecAttrAccess as String] = access }
        guard !update.isEmpty else { return }
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        guard updateStatus == errSecSuccess else { throw KeychainFailure(status: updateStatus) }
    }

    static func updatePromptDescriptions(in access: SecAccess, label: String) throws -> Bool {
        var list: CFArray?
        var accessStatus = SecAccessCopyACLList(access, &list)
        guard accessStatus == errSecSuccess, let entries = list as? [SecACL] else { throw KeychainFailure(status: accessStatus) }

        // The dialog uses ACL descriptions, not the item's display label alone.
        // Preserve trusted applications, authorizations and prompt requirements.
        let knownLabels = Set(ReaderLanguage.allCases.map { Self.loginLabel(language: $0) })
        var accessChanged = false
        for entry in entries {
            var applications: CFArray?, description: CFString?
            var selector = SecKeychainPromptSelector()
            accessStatus = SecACLCopyContents(entry, &applications, &description, &selector)
            guard accessStatus == errSecSuccess, let name = description as String?,
                  knownLabels.contains(name), name != label else { continue }
            accessStatus = SecACLSetContents(entry, applications, label as CFString, selector)
            guard accessStatus == errSecSuccess else { throw KeychainFailure(status: accessStatus) }
            accessChanged = true
        }
        return accessChanged
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainFailure(status: status) }
    }
}

struct KeychainFailure: LocalizedError {
    let message: String
    init(status: OSStatus) { message = "无法访问 macOS 钥匙串（状态 \(status)）。请解锁 Mac 并允许 Margin 访问它自己的登录条目。" }
    init(message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// A process-wide file lock prevents two app copies from rotating the same refresh token.
final class LoginProfileLock {
    private var descriptor: Int32 = -1
    init(directory: URL) throws {
        let filename = directory.appendingPathComponent("login-session.lock").path
        descriptor = Darwin.open(filename, O_CREAT | O_RDWR | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw KeychainFailure(message: "无法锁定本机登录数据，请检查应用数据目录权限。") }
        guard flock(descriptor, LOCK_EX | LOCK_NB) == 0 else {
            Darwin.close(descriptor); descriptor = -1
            throw KeychainFailure(message: "另一个 Margin 窗口正在使用这份登录数据，请关闭另一个应用实例后重试。")
        }
    }
    func release() { if descriptor >= 0 { flock(descriptor, LOCK_UN); Darwin.close(descriptor); descriptor = -1 } }
    deinit { release() }
}

/// Bidirectional anonymous pipes. No credential ever enters URLSession or a file.
final class KeychainPipeBridge: @unchecked Sendable {
    let input = Pipe()
    let output = Pipe()
    private let store: any LoginCredentialStorage
    private let onLifecycleError: @Sendable (String) -> Void
    private let queue = DispatchQueue(label: "local.leaf.pdfreader.keychain-ipc")
    private var buffer = Data()
    private var stopped = false

    init(store: any LoginCredentialStorage, onLifecycleError: @escaping @Sendable (String) -> Void = { _ in }) {
        self.store = store
        self.onLifecycleError = onLifecycleError
        output.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let bytes = handle.availableData
            self?.queue.async { [weak self] in self?.receive(bytes) }
        }
    }

    private func receive(_ data: Data) {
        guard !stopped else { return }
        if data.isEmpty { output.fileHandleForReading.readabilityHandler = nil; return }
        buffer.append(data)
        guard buffer.count <= 262_144 else { stopOnQueue(); return }
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
            guard let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any] else { continue }
            if object["channel"] as? String == "leaf.lifecycle.v1", object["event"] as? String == "shutdown_error",
               let message = object["message"] as? String {
                onLifecycleError(String(message.prefix(2000))); continue
            }
            guard
                  object["channel"] as? String == "leaf.keychain.v1",
                  let id = object["id"] as? String, UUID(uuidString: id) != nil,
                  let action = object["action"] as? String else { continue }
            var reply: [String: Any] = ["channel": "leaf.keychain.v1", "id": id]
            do {
                switch action {
                case "load":
                    if let bytes = try store.load() {
                        guard let credential = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else {
                            throw KeychainFailure(message: "钥匙串中的登录格式无效，请退出登录后重试。")
                        }
                        reply["credential"] = credential
                    }
                case "save":
                    guard let credential = object["credential"] as? [String: Any] else {
                        throw KeychainFailure(message: "登录数据不完整，未写入钥匙串。")
                    }
                    let allowed = Set(["version", "hostId", "clientId", "subject", "refreshToken", "scopes", "email", "label"])
                    guard Set(credential.keys).isSubset(of: allowed), credential["refreshToken"] is String else {
                        throw KeychainFailure(message: "登录数据格式无效，未写入钥匙串。")
                    }
                    try store.save(JSONSerialization.data(withJSONObject: credential))
                case "delete": try store.delete()
                default: throw KeychainFailure(message: "不支持的钥匙串操作。")
                }
                reply["ok"] = true
            } catch {
                reply["ok"] = false
                reply["error"] = (error as? KeychainFailure)?.message ?? "钥匙串操作未完成，请重试。"
            }
            if let bytes = try? JSONSerialization.data(withJSONObject: reply) {
                do { try input.fileHandleForWriting.write(contentsOf: bytes + Data([10])) }
                catch { stopOnQueue(); return }
            }
        }
    }

    func stop() { queue.async { [weak self] in self?.stopOnQueue() } }
    private func stopOnQueue() {
        guard !stopped else { return }; stopped = true
        output.fileHandleForReading.readabilityHandler = nil
        try? input.fileHandleForWriting.close(); try? output.fileHandleForReading.close()
        buffer.removeAll(keepingCapacity: false)
    }
    deinit { output.fileHandleForReading.readabilityHandler = nil; try? input.fileHandleForWriting.close() }
}
