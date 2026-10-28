import Foundation
import Security

@main
struct KeychainChecks {
    static var phase = "startup"
    static func main() {
        defer { SecKeychainSetUserInteractionAllowed(true) }
        do { try run(); report("passed", message: "Synthetic Keychain operations, profile lock and private-pipe checks passed; item deleted.") }
        catch { report("blocked", message: error.localizedDescription); print("KEYCHAIN_TESTS_BLOCKED [\(phase)]: \(error.localizedDescription)"); exit(2) }
    }
    static func check(_ condition: Bool, _ message: String = "Keychain regression failed") throws {
        guard condition else { throw KeychainFailure(message: message) }
    }
    static func report(_ status: String, message: String) {
        guard let path = Bundle.main.object(forInfoDictionaryKey: "MarginSyntheticResultPath") as? String else { return }
        let result: [String: Any] = ["status": status, "message": message, "realAccountCredentialsAccessed": false]
        if let data = try? JSONSerialization.data(withJSONObject: result, options: .prettyPrinted) {
            try? data.write(to: URL(fileURLWithPath: path), options: .atomic)
        }
    }
    static func run() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("margin-keychain-check-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = LoginKeychainStore(dataDirectory: directory, service: "local.leaf.pdfreader.synthetic-test.\(UUID().uuidString)",
                                      preferredLanguages: ["en-CN", "zh-Hans-CN"])
        defer { try? store.delete() }
        try check(store.label == "Margin · ChatGPT sign-in", "Language must take priority over region")
        for (preferred, expected) in [(["zh-Hans-CN"], "Margin · ChatGPT 登录"), (["zh-TW"], "Margin · ChatGPT 登入"),
                                       (["ja-JP"], "Margin · ChatGPT ログイン"), (["ko-KR"], "Margin · ChatGPT 로그인"),
                                       (["fr-CA"], "Margin · Connexion ChatGPT"), (["de-DE"], "Margin · ChatGPT-Anmeldung"),
                                       (["es-MX"], "Margin · Inicio de sesión de ChatGPT"), (["pt-BR"], "Margin · Login do ChatGPT"),
                                       (["it-IT"], "Margin · ChatGPT sign-in"), ([], "Margin · ChatGPT sign-in")] {
            try check(LoginKeychainStore(dataDirectory: directory, preferredLanguages: preferred).label == expected)
        }
        let empty = try store.load(); try check(empty == nil)
        let first = Data("synthetic-refresh-one".utf8), second = Data("synthetic-refresh-two".utf8)

        // Check the migration on a copied access object without approving a system dialog.
        let legacy = LoginKeychainStore(dataDirectory: directory, service: store.service, preferredLanguages: ["zh-Hans"])
        phase = "create legacy fixture"
        try legacy.save(first)
        phase = "read legacy metadata"
        let before = try metadata(store)
        try check(before.label == legacy.label && before.prompts.contains(legacy.label))
        phase = "plan name migration"
        let migrated = try metadata(store, renameTo: store.label)
        try check(migrated.prompts.contains(store.label) && !migrated.prompts.contains(legacy.label))
        try check(migrated.rules == before.rules, "Renaming must preserve the item's access rules")

        // Refusing a metadata change must preserve credential loading and rotation.
        phase = "load after declined migration"
        SecKeychainSetUserInteractionAllowed(false)
        let savedFirst = try store.load(); try check(savedFirst == first)
        SecKeychainSetUserInteractionAllowed(true)
        let persisted = try metadata(store)
        let repeated = try store.load(); try check(repeated == first)
        let unchanged = try metadata(store)
        try check(unchanged == persisted, "Repeated loads must not retry a declined rename")
        phase = "rotate synthetic credential"
        try store.save(second); let savedSecond = try store.load(); try check(savedSecond == second)
        phase = "delete legacy fixture"
        try store.delete(); let deleted = try store.load(); try check(deleted == nil)

        // New English items must have an English name in both metadata locations.
        phase = "create English fixture"
        try store.save(first)
        let created = try metadata(store)
        try check(created.label == store.label && created.prompts.contains(store.label))
        try store.delete()

        phase = "profile lock"
        let lock = try LoginProfileLock(directory: directory)
        do { _ = try LoginProfileLock(directory: directory); preconditionFailure("Second profile owner was admitted") }
        catch { try check(error.localizedDescription.contains("另一个")) }
        lock.release(); let nextLock = try LoginProfileLock(directory: directory); nextLock.release()

        phase = "private pipes"
        let bridge = KeychainPipeBridge(store: store)
        defer { bridge.stop() }
        func exchange(_ action: String, credential: [String: Any]? = nil) throws -> [String: Any] {
            let id = UUID().uuidString
            var object: [String: Any] = ["channel": "leaf.keychain.v1", "id": id, "action": action]
            if let credential { object["credential"] = credential }
            let data = try JSONSerialization.data(withJSONObject: object) + Data([10])
            try bridge.output.fileHandleForWriting.write(contentsOf: data)
            let response = bridge.input.fileHandleForReading.availableData
            let reply = try JSONSerialization.jsonObject(with: response) as! [String: Any]
            try check(reply["id"] as? String == id && reply["ok"] as? Bool == true)
            return reply
        }
        let fixture: [String: Any] = ["version": 1, "refreshToken": "synthetic-only-no-real-credential", "clientId": "test-client",
                                     "hostId": "test-host", "subject": "test-subject", "scopes": ["test"], "email": "test@example.invalid", "label": "Synthetic Test"]
        _ = try exchange("save", credential: fixture)
        let loaded = try exchange("load")["credential"] as! [String: Any]
        try check(loaded["refreshToken"] as? String == fixture["refreshToken"] as? String)
        _ = try exchange("delete"); let finalDeleted = try store.load(); try check(finalDeleted == nil)
        print("KEYCHAIN_TESTS_PASSED: system-language labels, in-memory prompt migration, preserved access rules, declined-migration credential recovery, storage, profile lock and private pipes; synthetic item deleted.")
    }

    struct Metadata: Equatable {
        var label: String
        var prompts: [String]
        var rules: [String]
    }

    static func metadata(_ store: LoginKeychainStore, renameTo label: String? = nil) throws -> Metadata {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: store.service, kSecAttrAccount as String: store.account,
            kSecReturnAttributes as String: true, kSecReturnRef as String: true]
        var result: CFTypeRef?
        var status = SecItemCopyMatching(query as CFDictionary, &result)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        let attributes = result as! [String: Any]
        let reference = attributes[kSecValueRef as String] as! SecKeychainItem
        var access: SecAccess?, list: CFArray?
        status = SecKeychainItemCopyAccess(reference, &access)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        if let label {
            try check(try LoginKeychainStore.updatePromptDescriptions(in: access!, label: label))
            try check(try !LoginKeychainStore.updatePromptDescriptions(in: access!, label: label), "Renaming must be idempotent")
        }
        status = SecAccessCopyACLList(access!, &list)
        guard status == errSecSuccess else { throw KeychainFailure(status: status) }
        var prompts: [String] = [], rules: [String] = []
        for entry in list as! [SecACL] {
            let authorizations = SecACLCopyAuthorizations(entry) as! [String]
            // macOS regenerates the integrity digest when any item attribute changes.
            if authorizations.contains(kSecACLAuthorizationIntegrity as String) { continue }
            var applications: CFArray?, description: CFString?
            var selector = SecKeychainPromptSelector()
            status = SecACLCopyContents(entry, &applications, &description, &selector)
            guard status == errSecSuccess else { throw KeychainFailure(status: status) }
            var trusted: [String] = []
            if let applications = applications as? [SecTrustedApplication] {
                for application in applications {
                    var data: CFData?
                    status = SecTrustedApplicationCopyData(application, &data)
                    guard status == errSecSuccess else { throw KeychainFailure(status: status) }
                    trusted.append((data! as Data).base64EncodedString())
                }
            } else { trusted = ["all applications"] }
            let name = description as String? ?? ""
            prompts.append(name)
            let systemDescription = name.hasPrefix("Margin · ") ? "item name" : name
            rules.append("\(authorizations.sorted())|\(trusted.sorted())|\(selector.rawValue)|\(systemDescription)")
        }
        return Metadata(label: attributes[kSecAttrLabel as String] as! String, prompts: prompts.sorted(), rules: rules.sorted())
    }
}
