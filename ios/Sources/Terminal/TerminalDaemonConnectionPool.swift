import Foundation

/// Process-wide registry of TerminalDaemonConnection actors, keyed by host
/// stableID. Workspace subscription and terminal sessions for the same daemon
/// share one ws + one TerminalRemoteDaemonClient.
final class TerminalDaemonConnectionPool: @unchecked Sendable {
    static let shared = TerminalDaemonConnectionPool()

    private let lock = NSLock()
    private var connections: [String: TerminalDaemonConnection] = [:]

    func connection(
        stableID: String,
        hostname: String,
        port: Int,
        secret: String
    ) -> TerminalDaemonConnection {
        lock.lock()
        defer { lock.unlock() }
        if let existing = connections[stableID] { return existing }
        let connection = TerminalDaemonConnection(
            hostname: hostname,
            port: port,
            secret: secret
        )
        connections[stableID] = connection
        return connection
    }

    func remove(stableID: String) -> TerminalDaemonConnection? {
        lock.lock()
        defer { lock.unlock() }
        return connections.removeValue(forKey: stableID)
    }
}
