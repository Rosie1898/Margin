import Foundation

@main
struct ChatLifecycleCheck {
    @MainActor static func main() async throws {
        precondition(CommandLine.arguments.count == 3, "Usage: chat-lifecycle PROJECT_ROOT SCRATCH_DIRECTORY")
        let scratch = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let state = scratch.appendingPathComponent("chat-lifecycle-\(UUID().uuidString)", isDirectory: true)
        let resources = scratch.appendingPathComponent("Resources", isDirectory: true)
        let service = ChatService(dataDirectory: state, resourcesDirectory: resources)
        await service.start()
        guard service.connected, let url = service.baseURL else {
            print("STARTUP_BLOCKED: \(service.error ?? service.authMessage)")
            service.stop()
            exit(2)
        }
        precondition(!service.authenticated && !service.planEnabled, "Fresh isolated backend must not inherit credentials")
        precondition(service.models.isEmpty)
        let empty = try await service.fetchThread(threadID: UUID())
        precondition(empty.isEmpty, "New thread must not inherit any other annotation's messages")
        do {
            _ = try await service.send(threadID: UUID(), documentID: String(repeating: "a", count: 64),
                                       context: ["filename":"Synthetic", "page":1, "quote":"Test", "pageText":"Test"],
                                       model:"test", effort:"low", text:"Do not send", customInstructions:"", onDelta: { _ in })
            preconditionFailure("Unauthenticated send must fail before any external call")
        } catch { precondition(error.localizedDescription.contains("登录")) }
        await service.refreshStatus()
        precondition(service.connected)
        let runtimeFile = state.appendingPathComponent("Backend/runtime.json")
        precondition(FileManager.default.fileExists(atPath: runtimeFile.path))
        let quitStarted = Date()
        let closed = await service.shutdown()
        precondition(closed, "Normal shutdown should complete without pending credentials")
        precondition(Date().timeIntervalSince(quitStarted) < 5, "Idle quit must not wait for HTTP request timeout")
        precondition(!service.connected && service.baseURL == nil && !service.authenticated)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        precondition(!FileManager.default.fileExists(atPath: runtimeFile.path), "Owned child must remove runtime marker when stopped")
        do {
            var request = URLRequest(url:url.appendingPathComponent("api/status"))
            request.timeoutInterval = 2
            _ = try await URLSession.shared.data(for:request)
            preconditionFailure("Owned loopback server must not remain running after stop")
        } catch {}
        print("CHAT_LIFECYCLE_PASSED: bundled Node launch, ephemeral loopback discovery, fresh unauthenticated status, isolated empty thread, unauthenticated guard, status refresh, stop and child cleanup. No external API calls.")
    }
}
