import Foundation

/// Owns one URLSessionWebSocketTask + TerminalRemoteDaemonClient per daemon (host:port).
/// Workspace subscription and (eventually) terminal sessions share this connection.
actor TerminalDaemonConnection {
    let hostname: String
    let port: Int
    let secret: String

    private let wsClient = TerminalWebSocketDaemonClient()
    private var client: TerminalRemoteDaemonClient?
    private var lineTransport: TerminalWebSocketLineTransport?
    private var hello: TerminalRemoteDaemonHello?
    private var connectTask: Task<(TerminalRemoteDaemonClient, TerminalRemoteDaemonHello, TerminalWebSocketLineTransport?), Error>?

    init(hostname: String, port: Int, secret: String) {
        self.hostname = hostname
        self.port = port
        self.secret = secret
    }

    func connect() async throws -> (TerminalRemoteDaemonClient, TerminalRemoteDaemonHello) {
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

    func currentClient() -> TerminalRemoteDaemonClient? { client }
    func currentHello() -> TerminalRemoteDaemonHello? { hello }

    func disconnect() async {
        let line = lineTransport
        client = nil
        hello = nil
        lineTransport = nil
        connectTask?.cancel()
        connectTask = nil
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
}
