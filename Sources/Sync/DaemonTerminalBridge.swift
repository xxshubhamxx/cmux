import Foundation

/// Thin facade preserving the old per-surface bridge API while routing all
/// socket I/O through the single shared `DaemonConnection`. Creates no socket
/// of its own. Call sites (GhosttyTerminalView, TerminalController) remain
/// unchanged; they construct one of these per surface and use the same
/// methods as before, but the daemon traffic funnels into one connection.
final class DaemonTerminalBridge: @unchecked Sendable {
    let sessionID: String
    private let shellCommand: String
    private var started = false
    private let lock = NSLock()

    var onOutput: ((_ data: Data) -> Void)?
    var onDisconnect: ((_ error: String?) -> Void)?

    init(socketPath: String, sessionID: String, shellCommand: String) {
        // socketPath is ignored — DaemonConnection owns the socket path.
        _ = socketPath
        self.sessionID = sessionID
        self.shellCommand = shellCommand
    }

    deinit { stopInternal() }

    static func computeSessionID(workspaceID: UUID, surfaceID: UUID) -> String {
        DaemonConnection.computeSessionID(workspaceID: workspaceID, surfaceID: surfaceID)
    }

    static func preCreateSession(
        socketPath: String,
        workspaceID: UUID,
        surfaceID: UUID,
        shellCommand: String,
        cols: Int = 80,
        rows: Int = 24,
        sessionID: String? = nil
    ) {
        _ = socketPath
        DaemonConnection.preCreateSession(
            workspaceID: workspaceID,
            surfaceID: surfaceID,
            shellCommand: shellCommand,
            cols: cols,
            rows: rows,
            sessionID: sessionID
        )
    }

    func start(cols: Int, rows: Int) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        lock.unlock()
        DaemonConnection.shared.subscribeTerminal(
            sessionID: sessionID,
            shellCommand: shellCommand,
            cols: cols,
            rows: rows,
            onOutput: { [weak self] data in self?.onOutput?(data) },
            onDisconnect: { [weak self] err in self?.onDisconnect?(err) }
        )
    }

    func stop() { stopInternal() }

    private func stopInternal() {
        lock.lock()
        let wasStarted = started
        started = false
        lock.unlock()
        guard wasStarted else { return }
        DaemonConnection.shared.unsubscribeTerminal(sessionID: sessionID)
    }

    func writeToSession(_ data: Data) {
        DaemonConnection.shared.writeToSession(sessionID: sessionID, data: data)
    }

    func resize(cols: Int, rows: Int) {
        DaemonConnection.shared.resizeSession(sessionID: sessionID, cols: cols, rows: rows)
    }
}
