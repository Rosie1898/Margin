import Foundation
import Combine
import CryptoKit

/// Access tokens stay in the local process; its refresh credential is saved by the native Keychain bridge.
@MainActor
final class ChatService: ObservableObject {
    @Published private(set) var connected = false
    @Published private(set) var authenticated = false
    @Published private(set) var planEnabled = false
    @Published private(set) var accountLabel = ""
    @Published private(set) var authMessage = "正在启动本地连接服务…"
    @Published private(set) var models: [CatalogModel] = []
    @Published var error: String?
    private(set) var baseURL: URL?

    private let dataDirectory: URL
    private let resourcesDirectory: URL?
    private let network: URLSession
    private var process: Process?
    private var statusTask: Task<Void, Never>?
    private var csrfToken: String?
    private var starting = false
    private var loadingModels = false
    private var lifecycleID = UUID()
    private var activeJobs: [UUID: String] = [:]
    private var submitting: Set<UUID> = []
    private var pendingCancellations: Set<UUID> = []
    private var connectionError: String?
    private var authWarning: String?
    private var credentialBridge: KeychainPipeBridge?
    private var profileLock: LoginProfileLock?
    private let credentialStorage: any LoginCredentialStorage
    private var shuttingDown = false
    private var shutdownFailure: String?

    init(dataDirectory: URL, resourcesDirectory: URL? = Bundle.main.resourceURL,
         credentialStorage: (any LoginCredentialStorage)? = nil, networkSession: URLSession? = nil) {
        self.dataDirectory = dataDirectory
        self.resourcesDirectory = resourcesDirectory
        self.credentialStorage = credentialStorage ?? LoginKeychainStore(dataDirectory: dataDirectory)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 300
        configuration.timeoutIntervalForResource = 300
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        network = networkSession ?? URLSession(configuration: configuration, delegate: NoRedirects(), delegateQueue: nil)
    }

    func start() async {
        guard !starting else { return }
        if process?.isRunning == true, baseURL != nil {
            await refreshStatus()
            return
        }
        starting = true
        shuttingDown = false
        defer { starting = false }
        error = nil
        authMessage = "正在启动本地连接服务…"
        let generation = UUID()
        lifecycleID = generation
        do {
            let runtimeURL = try launchProcess(generation: generation)
            let deadline = Date().addingTimeInterval(15)
            while Date() < deadline {
                try Task.checkCancellation()
                guard lifecycleID == generation else { return }
                guard process?.isRunning == true else {
                    throw ServiceError("本地连接服务未能启动。请确认应用内的 Node 和 Backend 文件完整。")
                }
                if let data = try? Data(contentsOf: runtimeURL),
                   let runtime = try? JSONDecoder().decode(RuntimeState.self, from: data),
                   let url = Self.validLoopbackURL(runtime.baseUrl) {
                    baseURL = url
                    do {
                        try await loadStatus()
                        guard lifecycleID == generation else { return }
                        beginStatusPolling()
                        if authenticated && planEnabled && models.isEmpty { await refreshModels() }
                        return
                    } catch {
                        // The runtime file may precede the first accepted request by a few milliseconds.
                    }
                }
                try await Task.sleep(nanoseconds: 150_000_000)
            }
            throw ServiceError("本地连接服务启动超时。请退出阅读器后重新打开。")
        } catch {
            guard lifecycleID == generation else { return }
            let message = Self.friendly(error)
            stop()
            self.error = message
            authMessage = "本地连接服务暂不可用"
        }
    }

    private func launchProcess(generation: UUID) throws -> URL {
        guard let resourcesDirectory else { throw ServiceError("无法找到应用资源目录。") }
        let executable = resourcesDirectory.appendingPathComponent("node")
        let script = resourcesDirectory.appendingPathComponent("Backend/server.mjs")
        guard FileManager.default.isExecutableFile(atPath: executable.path),
              FileManager.default.fileExists(atPath: script.path) else {
            throw ServiceError("应用缺少本地连接组件。请使用完整的 .app 文件启动阅读器。")
        }
        let backendDirectory = dataDirectory.appendingPathComponent("Backend", isDirectory: true)
        try FileManager.default.createDirectory(at: backendDirectory, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let runtimeURL = backendDirectory.appendingPathComponent("runtime.json")
        let lock = try LoginProfileLock(directory: backendDirectory)
        if FileManager.default.fileExists(atPath: runtimeURL.path) { try FileManager.default.removeItem(at: runtimeURL) }
        let child = Process()
        child.executableURL = executable
        child.arguments = [script.path]
        child.currentDirectoryURL = script.deletingLastPathComponent()
        var environment = ProcessInfo.processInfo.environment
        environment.removeValue(forKey: "NODE_OPTIONS")
        environment.removeValue(forKey: "NODE_PATH")
        environment["LEAF_DATA_DIR"] = backendDirectory.path
        environment["LEAF_PARENT_PID"] = String(ProcessInfo.processInfo.processIdentifier)
        environment["LEAF_KEYCHAIN_BRIDGE"] = "1"
        environment["LEAF_EXIT_ON_STDIN_EOF"] = "1"
        environment["PORT"] = "0"
        child.environment = environment
        // Anonymous pipes carry only this app's credential operations. Nothing is logged.
        let bridge = KeychainPipeBridge(store: credentialStorage) { [weak self] message in
            Task { @MainActor [weak self] in
                guard let self, self.lifecycleID == generation else { return }
                self.shutdownFailure = message
            }
        }
        child.standardOutput = bridge.output
        child.standardError = FileHandle.nullDevice
        child.standardInput = bridge.input
        child.terminationHandler = { [weak self] child in
            bridge.stop()
            lock.release()
            let exitCode = child.terminationStatus
            Task { @MainActor [weak self] in
                guard let self, self.process === child, !self.shuttingDown else { return }
                self.statusTask?.cancel()
                self.connected = false
                self.authenticated = false
                self.planEnabled = false
                self.csrfToken = nil
                self.baseURL = nil
                self.accountLabel = ""
                self.authMessage = "本地连接服务已停止"
                self.error = "本地连接服务已退出（状态 \(exitCode)）。请重新打开阅读器。"
            }
        }
        do { try child.run() }
        catch { bridge.stop(); throw error }
        credentialBridge = bridge
        profileLock = lock
        process = child
        return runtimeURL
    }

    func stop() {
        shuttingDown = true
        lifecycleID = UUID()
        statusTask?.cancel()
        statusTask = nil
        if process?.isRunning == true { process?.terminate() }
        process = nil
        // The termination handler retains the pipe and profile lock until the
        // child has actually exited, so an immediate relaunch cannot race refresh.
        credentialBridge = nil
        profileLock = nil
        baseURL = nil
        csrfToken = nil
        connected = false
        authenticated = false
        planEnabled = false
        accountLabel = ""
        authMessage = "本地连接服务已停止"
        activeJobs.removeAll()
        pendingCancellations.removeAll()
    }

    /// Normal app quit keeps the parent and pipes alive until rotated login
    /// credentials are durable. A failed secure write cancels normal quit.
    func shutdown() async -> Bool {
        guard let child = process, child.isRunning else { stop(); return true }
        shuttingDown = true
        statusTask?.cancel(); statusTask = nil
        shutdownFailure = nil
        child.terminate()
        let deadline = Date().addingTimeInterval(120)
        while child.isRunning, Date() < deadline {
            try? await Task.sleep(nanoseconds: 200_000_000)
            if !child.isRunning { break }
            // Never issue HTTP while the HTTP listener is draining. A blocked
            // URLSession request would make the shutdown deadline ineffective.
            if let failure = shutdownFailure {
                error = failure
                shuttingDown = false; beginStatusPolling(); return false
            }
        }
        guard !child.isRunning else {
            error = "登录安全保存仍未完成，已取消退出。请解锁钥匙串后重试。"
            shuttingDown = false; beginStatusPolling(); return false
        }
        stop(); return true
    }

    func refreshStatus() async {
        do {
            try await loadStatus()
            if authenticated && planEnabled && models.isEmpty { await refreshModels() }
        } catch { recordConnectionError(error) }
    }

    private func loadStatus() async throws {
        let status: StatusResponse = try await request("/api/status")
        guard !status.csrfToken.isEmpty else { throw ServiceError("本地连接返回了不完整的状态，请重新打开阅读器。") }
        csrfToken = status.csrfToken
        connected = true
        authenticated = status.authenticated
        planEnabled = status.planEnabled
        accountLabel = Self.nonempty(status.account?.label) ?? Self.nonempty(status.account?.email) ?? ""
        models = status.models
        switch status.auth.status {
        case "pending": authMessage = status.auth.message ?? "请在浏览器中完成 ChatGPT 登录和授权。"
        case "restoring": authMessage = status.auth.message ?? "正在恢复已保存的 ChatGPT 登录…"
        case "restore_error": authMessage = status.auth.message ?? "暂时无法恢复登录，请稍后重试。"
        case "error", "shutdown_error": authMessage = status.auth.message ?? status.lastError ?? "登录未完成，请重新登录。"
        default:
            authMessage = authenticated
                ? (planEnabled ? "已连接 ChatGPT 套餐" : "已登录，尚未获得套餐调用权限。")
                : (status.auth.message ?? "登录 ChatGPT 后，可对划线内容提问。")
        }
        if ["restore_error", "error", "shutdown_error"].contains(status.auth.status) {
            authWarning = authMessage; error = authMessage
        } else if status.auth.status == "success", error == authWarning {
            error = nil; authWarning = nil
        }
        if error == connectionError { error = nil }
        connectionError = nil
    }

    private func beginStatusPolling() {
        statusTask?.cancel()
        statusTask = Task { [weak self] in
            var failureCount = 0
            while !Task.isCancelled {
                do { try await Task.sleep(nanoseconds: 2_000_000_000) }
                catch { return }
                guard !Task.isCancelled, let self else { return }
                do {
                    try await self.loadStatus()
                    failureCount = 0
                    if self.authenticated && self.planEnabled && self.models.isEmpty { await self.refreshModels() }
                } catch {
                    guard !Task.isCancelled else { return }
                    failureCount += 1
                    if failureCount >= 3 { self.recordConnectionError(error) }
                }
            }
        }
    }

    private func recordConnectionError(_ error: Error) {
        connected = false
        let message = Self.friendly(error)
        connectionError = message
        self.error = message
    }

    func beginLogin() async -> URL? {
        error = nil
        do {
            let response: LoginResponse = try await request("/api/auth/start", body: [:])
            guard let url = URL(string: response.url), url.scheme == "https", url.host == "auth.openai.com",
                  url.user == nil, url.password == nil else { throw ServiceError("登录服务返回的授权地址无效。") }
            authMessage = "请在浏览器中完成 ChatGPT 登录和授权。"
            return url
        } catch {
            self.error = Self.friendly(error)
            return nil
        }
    }

    func refreshModels() async {
        guard !loadingModels else { return }
        loadingModels = true
        defer { loadingModels = false }
        do {
            let response: ModelResponse = try await request("/api/models")
            models = response.models
        } catch { self.error = Self.friendly(error) }
    }

    func logout() async {
        error = nil
        do {
            let result: LogoutResponse = try await request("/api/logout", body: [:])
            await refreshStatus()
            if result.revocationConfirmed == false {
                error = result.message ?? "本机登录已清除，但未能确认远端撤销。"
            }
        } catch { self.error = Self.friendly(error) }
    }

    func send(threadID: UUID, documentID: String, context: [String: Any], model: String,
              effort: String, text: String, customInstructions: String, reference: [String: Any]? = nil, onDelta: @escaping (String) -> Void) async throws -> [ChatMessage] {
        guard !submitting.contains(threadID) else { throw ServiceError("这条讨论正在回复，请等待或先取消。") }
        guard connected && authenticated && planEnabled else { throw ServiceError("请先登录 ChatGPT 并完成套餐授权。") }
        submitting.insert(threadID)
        defer {
            submitting.remove(threadID)
            activeJobs.removeValue(forKey: threadID)
            pendingCancellations.remove(threadID)
        }
        var documentContext = context
        let image = documentContext.removeValue(forKey: "imageDataUrl") ?? documentContext.removeValue(forKey: "imageDataURL")
        documentContext.removeValue(forKey: "imageDataURL")
        var body: [String: Any] = ["threadId": threadID.uuidString.lowercased(), "documentId": documentID,
                                   "context": documentContext, "model": model, "effort": effort, "text": text, "customInstructions": customInstructions,
                                   "requestId": UUID().uuidString.lowercased()]
        if let image { body["imageDataUrl"] = image }
        if let reference { body["reference"] = reference }
        do {
            let start: JobStartResponse = try await request("/api/chat/start", body: body)
            guard UUID(uuidString: start.jobId) != nil else { throw ServiceError("本地服务返回了无效的回复标识。") }
            activeJobs[threadID] = start.jobId
            if pendingCancellations.contains(threadID) { await cancel(threadID: threadID) }
            let deadline = Date().addingTimeInterval(230)
            var lastText = ""
            while Date() < deadline {
                try Task.checkCancellation()
                let job: JobResponse = try await request("/api/chat/status?id=\(start.jobId)")
                guard UUID(uuidString: job.threadId) == threadID, job.id.lowercased() == start.jobId.lowercased() else {
                    throw ServiceError("回复与当前划线不匹配，已停止显示。请重新打开这条讨论。")
                }
                if job.text != lastText { lastText = job.text; onDelta(job.text) }
                switch job.status {
                case "completed": return try await fetchThread(threadID: threadID)
                case "failed": throw ServiceError(job.error ?? "这次回复未完成。问题已保留，可以重新提问。")
                case "running", "pending": break
                default: throw ServiceError("本地服务返回了未知的回复状态，请重新打开这条讨论。")
                }
                try await Task.sleep(nanoseconds: 300_000_000)
            }
            await cancel(threadID: threadID)
            throw ServiceError("等待回复超时，已请求取消。请重新打开讨论查看已保存的内容。")
        } catch {
            if Task.isCancelled, let jobID = activeJobs[threadID] {
                // A new task is needed because this task's URLSession work is already cancelled.
                Task { [weak self] in await self?.cancelJob(jobID) }
            }
            throw ServiceError(Self.friendly(error))
        }
    }

    func fetchThread(threadID: UUID) async throws -> [ChatMessage] {
        let thread: ThreadResponse = try await request("/api/chat/thread?id=\(threadID.uuidString.lowercased())")
        return Self.mapMessages(thread.messages)
    }

    func cancel(threadID: UUID) async {
        if let jobID = activeJobs[threadID] { await cancelJob(jobID); return }
        if submitting.contains(threadID) { pendingCancellations.insert(threadID); return }
        do {
            // This lookup is scoped to one annotation, including a job restored after a view change.
            let thread: ThreadResponse = try await request("/api/chat/thread?id=\(threadID.uuidString.lowercased())")
            if thread.busy, let jobID = thread.jobId, UUID(uuidString: jobID) != nil { await cancelJob(jobID) }
        } catch { self.error = Self.friendly(error) }
    }

    private func cancelJob(_ jobID: String) async {
        do {
            let _: EmptyResponse = try await request("/api/chat/cancel", body: ["jobId": jobID])
        } catch { self.error = Self.friendly(error) }
    }

    private func request<Response: Decodable>(_ path: String, body: [String: Any]? = nil) async throws -> Response {
        guard let baseURL, let url = URL(string: path, relativeTo: baseURL)?.absoluteURL else {
            throw ServiceError("本地连接服务尚未就绪，请稍候或重新打开阅读器。")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 300
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(baseURL.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        if let body {
            guard let csrfToken else { throw ServiceError("本地连接尚未准备好，请稍候重试。") }
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(csrfToken, forHTTPHeaderField: "X-CSRF-Token")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await network.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ServiceError("本地服务没有返回有效的响应。") }
        guard (200...299).contains(http.statusCode) else {
            let returned = try? JSONDecoder().decode(ErrorResponse.self, from: data)
            throw ServiceError(returned?.error ?? "本地请求失败（HTTP \(http.statusCode)）。")
        }
        do { return try JSONDecoder().decode(Response.self, from: data) }
        catch { throw ServiceError("本地服务的响应格式无法识别，请重新打开阅读器。") }
    }

    // Internal helpers are also exercised by the native decoding check.
    static func decodeMessages(_ data: Data) throws -> [ChatMessage] {
        mapMessages(try JSONDecoder().decode(ThreadResponse.self, from: data).messages)
    }

    private static func mapMessages(_ messages: [MessageResponse]) -> [ChatMessage] {
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let seconds = ISO8601DateFormatter()
        return messages.enumerated().map { index, message in
            let date = fractional.date(from: message.createdAt) ?? seconds.date(from: message.createdAt) ?? Date(timeIntervalSince1970: 0)
            let id = message.id.flatMap(UUID.init(uuidString:)) ?? stableUUID(message.id ?? "\(index)|\(message.role)|\(message.createdAt)|\(message.text)")
            return ChatMessage(id: id, role: message.role, text: message.text, model: message.model,
                               effort: message.effort, createdAt: date, failed: message.status == "failed" || message.failed == true,
                               reference: message.reference)
        }
    }

    private static func stableUUID(_ key: String) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(key.utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    static func validLoopbackURL(_ value: String) -> URL? {
        guard let url = URL(string: value), url.scheme == "http", url.host == "127.0.0.1",
              let port = url.port, (1...65535).contains(port), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil, url.path.isEmpty || url.path == "/" else { return nil }
        return url
    }

    private static func nonempty(_ value: String?) -> String? {
        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return value
    }

    private static func friendly(_ error: Error) -> String {
        if error is CancellationError { return "已停止等待回复。已提交的问题仍保存在本机。" }
        if let error = error as? URLError {
            switch error.code {
            case .cancelled: return "已取消本地请求。"
            case .timedOut: return "本地连接等待超时，请稍后重试。"
            default: return "无法连接本地服务，请确认阅读器仍在运行，或重新打开阅读器。"
            }
        }
        return error.localizedDescription
    }
}

private struct ServiceError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

private final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private struct RuntimeState: Decodable { let baseUrl: String }
private struct LogoutResponse: Decodable { let loggedOut: Bool; let revocationConfirmed: Bool?; let message: String? }
private struct StatusResponse: Decodable {
    let authenticated: Bool
    let planEnabled: Bool
    let account: AccountResponse?
    let auth: AuthorizationResponse
    let csrfToken: String
    let models: [CatalogModel]
    let lastError: String?
}
private struct AccountResponse: Decodable { let email: String?; let label: String? }
private struct AuthorizationResponse: Decodable { let status: String; let message: String? }
private struct ModelResponse: Decodable { let models: [CatalogModel] }
private struct LoginResponse: Decodable { let url: String }
private struct ErrorResponse: Decodable { let error: String }
private struct EmptyResponse: Decodable {}
private struct JobStartResponse: Decodable { let jobId: String }
private struct JobResponse: Decodable {
    let id: String
    let threadId: String
    let status: String
    let text: String
    let error: String?
}
private struct ThreadResponse: Decodable {
    let messages: [MessageResponse]
    let busy: Bool
    let jobId: String?
}
private struct MessageResponse: Decodable {
    let id: String?
    let role: String
    let text: String
    let model: String?
    let effort: String?
    let createdAt: String
    let status: String?
    let failed: Bool?
    let reference: ChatReferenceSummary?
}
