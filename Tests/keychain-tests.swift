import Foundation

@main
struct KeychainChecks {
    static func main() {
        do { try run(); report("passed", message: "Synthetic Keychain operations, profile lock and private-pipe checks passed; item deleted.") }
        catch { report("blocked", message: error.localizedDescription); print("KEYCHAIN_TESTS_BLOCKED: \(error.localizedDescription)"); exit(2) }
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
        let store = LoginKeychainStore(dataDirectory: directory, service: "local.leaf.pdfreader.synthetic-test.\(UUID().uuidString)")
        defer { try? store.delete() }
        let empty = try store.load(); precondition(empty == nil)
        print("KEYCHAIN_CHECK_EMPTY_READ_OK")
        let first = Data("synthetic-refresh-one".utf8), second = Data("synthetic-refresh-two".utf8)
        try store.save(first); let savedFirst = try store.load(); precondition(savedFirst == first)
        try store.save(second); let savedSecond = try store.load(); precondition(savedSecond == second)
        try store.delete(); let deleted = try store.load(); precondition(deleted == nil)

        let lock = try LoginProfileLock(directory: directory)
        do { _ = try LoginProfileLock(directory: directory); preconditionFailure("Second profile owner was admitted") }
        catch { precondition(error.localizedDescription.contains("另一个")) }
        lock.release(); let nextLock = try LoginProfileLock(directory: directory); nextLock.release()

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
            precondition(reply["id"] as? String == id && reply["ok"] as? Bool == true)
            return reply
        }
        let fixture: [String: Any] = ["version": 1, "refreshToken": "synthetic-only-no-real-credential", "clientId": "test-client",
                                     "hostId": "test-host", "subject": "test-subject", "scopes": ["test"], "email": "test@example.invalid", "label": "Synthetic Test"]
        _ = try exchange("save", credential: fixture)
        let loaded = try exchange("load")["credential"] as! [String: Any]
        precondition(loaded["refreshToken"] as? String == fixture["refreshToken"] as? String)
        _ = try exchange("delete"); let finalDeleted = try store.load(); precondition(finalDeleted == nil)
        print("KEYCHAIN_TESTS_PASSED: isolated synthetic item save/read/rotation/delete, app profile flock, private-pipe roundtrip, cleanup. No real account credentials accessed.")
    }
}
