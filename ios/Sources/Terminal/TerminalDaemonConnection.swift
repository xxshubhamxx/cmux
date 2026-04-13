import Foundation

enum TerminalDaemonConnectionEvent: Sendable {
    case connected
    case connectFailed(consecutiveFailures: Int)
    case workspacesJSON(String)
    case disconnected
}

/// Owns one URLSessionWebSocketTask + TerminalRemoteDaemonClient per daemon (host:port).
/// Drives workspace subscription with backoff + reconnect on the connection level.
actor TerminalDaemonConnection {
    let hostname: String
    let port: Int
    let secret: String

    private let wsClient = TerminalWebSocketDaemonClient()
    private var client: TerminalRemoteDaemonClient?
    private var lineTransport: TerminalWebSocketLineTransport?
    private var hello: TerminalRemoteDaemonHello?
    private var connectTask: Task<(TerminalRemoteDaemonClient, TerminalRemoteDaemonHello, TerminalWebSocketLineTransport?), Error>?
    private var subscriptionTask: Task<Void, Never>?
    private var subscribed = false

    init(hostname: String, port: Int, secret: String) {
        self.hostname = hostname
        self.port = port
        self.secret = secret
    }

    func currentClient() -> TerminalRemoteDaemonClient? { client }
    func currentHello() -> TerminalRemoteDaemonHello? { hello }

    /// Returns a live client for this daemon, opening a new ws if needed
    /// or replacing a stale one whose transport has failed.
    func acquireClient() async throws -> (TerminalRemoteDaemonClient, TerminalRemoteDaemonHello) {
        if let client, let hello, await !client.isClosed() {
            return (client, hello)
        }
        if client != nil {
            await teardownClient()
        }
        return try await ensureConnected()
    }

    func startWorkspaceSubscription(onEvent: @escaping @Sendable (TerminalDaemonConnectionEvent) -> Void) {
        guard subscriptionTask == nil else { return }
        subscribed = true
        subscriptionTask = Task { [weak self] in
            await self?.runSubscriptionLoop(onEvent: onEvent)
        }
    }

    func stopWorkspaceSubscription() async {
        subscribed = false
        let task = subscriptionTask
        subscriptionTask = nil
        task?.cancel()
        await task?.value
        await teardownClient()
    }

    func workspaceRename(workspaceID: String, title: String) async throws {
        let (client, _) = try await acquireClient()
        try await client.workspaceRename(workspaceID: workspaceID, title: title)
    }

    func workspacePin(workspaceID: String, pinned: Bool) async throws {
        let (client, _) = try await acquireClient()
        try await client.workspacePin(workspaceID: workspaceID, pinned: pinned)
    }

    private func runSubscriptionLoop(onEvent: @escaping @Sendable (TerminalDaemonConnectionEvent) -> Void) async {
        var consecutiveFailures = 0

        while !Task.isCancelled && subscribed {
            let connection: (TerminalRemoteDaemonClient, TerminalRemoteDaemonHello)
            do {
                connection = try await ensureConnected()
            } catch {
                consecutiveFailures += 1
                onEvent(.connectFailed(consecutiveFailures: consecutiveFailures))
                let delay = min(30.0, 5.0 * pow(2.0, Double(min(consecutiveFailures - 1, 3))))
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }
            consecutiveFailures = 0
            onEvent(.connected)

            let connectionClient = connection.0
            // Stream workspace.* push events to the caller.
            await connectionClient.setWorkspaceEventHandler { line in
                onEvent(.workspacesJSON(line))
            }

            // Initial subscribe also returns the current workspace list.
            let initialResult: TerminalRemoteDaemonWorkspaceListResult?
            do {
                initialResult = try await connectionClient.workspaceSubscribe()
            } catch {
                NSLog("📱 daemon connection: workspace.subscribe failed: %@", error.localizedDescription ?? "unknown")
                initialResult = nil
            }
            if let initialResult, let initialJSON = Self.encodeWorkspaceList(initialResult) {
                onEvent(.workspacesJSON(initialJSON))
            }

            await waitForTransportFailure(client: connectionClient)

            await connectionClient.clearWorkspaceEventHandler()
            await teardownClient()
            onEvent(.disconnected)

            if !subscribed || Task.isCancelled { break }
            // Brief pause before reconnect attempt to avoid tight loops on
            // immediate failures.
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
    }

    private func waitForTransportFailure(client: TerminalRemoteDaemonClient) async {
        // Lightweight liveness probe: poll with no-op RPCs until one fails.
        // The dispatcher fails pending RPCs when the transport drops.
        while !Task.isCancelled && subscribed {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            if Task.isCancelled || !subscribed { return }
            do {
                _ = try await client.sendHello()
            } catch {
                return
            }
        }
    }

    private func ensureConnected() async throws -> (TerminalRemoteDaemonClient, TerminalRemoteDaemonHello) {
        if let client, let hello {
            return (client, hello)
        }
        if let connectTask {
            let (c, h, _) = try await connectTask.value
            return (c, h)
        }
        let task = Task { [hostname, port, secret, wsClient] in
            try await Self.openConnection(
                wsClient: wsClient,
                hostname: hostname,
                port: port,
                secret: secret
            )
        }
        connectTask = task
        do {
            let (newClient, newHello, newLine) = try await task.value
            self.client = newClient
            self.hello = newHello
            self.lineTransport = newLine
            self.connectTask = nil
            return (newClient, newHello)
        } catch {
            self.connectTask = nil
            throw error
        }
    }

    private func teardownClient() async {
        let line = lineTransport
        client = nil
        hello = nil
        lineTransport = nil
        await line?.cancel()
    }

    private static func openConnection(
        wsClient: TerminalWebSocketDaemonClient,
        hostname: String,
        port: Int,
        secret: String
    ) async throws -> (TerminalRemoteDaemonClient, TerminalRemoteDaemonHello, TerminalWebSocketLineTransport?) {
        let transport = try await wsClient.connect(host: hostname, port: port, secret: secret)
        let client = TerminalRemoteDaemonClient(transport: transport)
        let hello = try await client.sendHello()
        return (client, hello, transport as? TerminalWebSocketLineTransport)
    }

    private static func encodeWorkspaceList(_ result: TerminalRemoteDaemonWorkspaceListResult) -> String? {
        // Re-encode the typed result back into the JSON envelope shape that
        // `handleWorkspaceResponse` already parses ({"result": {"workspaces": [...]}}).
        // The simpler path is to just serialize the workspaces inline.
        let workspaces = result.workspaces.map { ws -> [String: Any] in
            var entry: [String: Any] = [
                "id": ws.id,
                "title": ws.title,
                "directory": ws.directory,
                "pane_count": ws.paneCount,
                "created_at": ws.createdAt,
                "last_activity_at": ws.lastActivityAt,
            ]
            if let sid = ws.sessionID { entry["session_id"] = sid }
            if let preview = ws.preview { entry["preview"] = preview }
            if let unread = ws.unreadCount { entry["unread_count"] = unread }
            if let pinned = ws.pinned { entry["pinned"] = pinned }
            if let panes = ws.panes {
                entry["panes"] = panes.map { p -> [String: Any] in
                    var pd: [String: Any] = ["id": p.id]
                    if let sid = p.sessionID { pd["session_id"] = sid }
                    if let t = p.title { pd["title"] = t }
                    if let d = p.directory { pd["directory"] = d }
                    return pd
                }
            }
            return entry
        }
        let envelope: [String: Any] = [
            "result": [
                "workspaces": workspaces,
                "selected_workspace_id": result.selectedWorkspaceID as Any,
                "change_seq": result.changeSeq,
            ],
        ]
        guard let data = try? JSONSerialization.data(withJSONObject: envelope) else { return nil }
        return String(data: data, encoding: .utf8)
    }
}
