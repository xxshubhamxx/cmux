import Foundation

/// Thin facade preserving the old per-surface bridge API while routing all
/// socket I/O through the single shared `DaemonConnection`. Creates no socket
/// of its own.
///
/// The bridge can be constructed with a nil `sessionID` (daemon hasn't minted
/// one yet via `workspace.open_pane`). Writes and `start(cols:rows:)` calls
/// are buffered until `assignSessionID(_:)` lands, at which point the pending
/// subscription fires and buffered writes flush in order.
final class DaemonTerminalBridge: @unchecked Sendable {
    private(set) var sessionID: String?
    private let shellCommand: String
    private var started = false
    private var subscribed = false
    private let lock = NSLock()
    private var pendingStart: (cols: Int, rows: Int)?
    private var pendingWrites: [Data] = []
    private var pendingResize: (cols: Int, rows: Int)?

    var onOutput: ((_ data: Data) -> Void)?
    var onDisconnect: ((_ error: String?) -> Void)?
    /// Authoritative `session.view_size` delivery from the daemon.
    var onViewSize: ((_ cols: Int, _ rows: Int) -> Void)?

    init(socketPath: String, sessionID: String?, shellCommand: String) {
        // socketPath is ignored — DaemonConnection owns the socket path.
        _ = socketPath
        self.sessionID = sessionID
        self.shellCommand = shellCommand
    }

    deinit { stopInternal() }

    /// Populate the daemon-minted session id. Flushes any buffered
    /// `start`/`writeToSession`/`resize` calls in order.
    func assignSessionID(_ sid: String) {
        lock.lock()
        guard sessionID == nil else { lock.unlock(); return }
        sessionID = sid
        let shouldStart = started && !subscribed
        let pendingStart = self.pendingStart
        let pendingResize = self.pendingResize
        let pendingWrites = self.pendingWrites
        self.pendingStart = nil
        self.pendingResize = nil
        self.pendingWrites = []
        lock.unlock()

        if shouldStart, let ps = pendingStart {
            subscribe(cols: ps.cols, rows: ps.rows)
        }
        if let pr = pendingResize {
            DaemonConnection.shared.resizeSession(sessionID: sid, cols: pr.cols, rows: pr.rows)
        }
        for data in pendingWrites {
            DaemonConnection.shared.writeToSession(sessionID: sid, data: data)
        }
    }

    func start(cols: Int, rows: Int) {
        lock.lock()
        guard !started else { lock.unlock(); return }
        started = true
        guard let sid = sessionID else {
            pendingStart = (cols, rows)
            lock.unlock()
            return
        }
        subscribed = true
        lock.unlock()
        subscribe(sessionID: sid, cols: cols, rows: rows)
    }

    private func subscribe(cols: Int, rows: Int) {
        guard let sid = sessionID else { return }
        lock.lock()
        subscribed = true
        lock.unlock()
        subscribe(sessionID: sid, cols: cols, rows: rows)
    }

    private func subscribe(sessionID: String, cols: Int, rows: Int) {
        DaemonConnection.shared.subscribeTerminal(
            sessionID: sessionID,
            shellCommand: shellCommand,
            cols: cols,
            rows: rows,
            onOutput: { [weak self] data in self?.onOutput?(data) },
            onDisconnect: { [weak self] err in self?.onDisconnect?(err) },
            onViewSize: { [weak self] c, r in self?.onViewSize?(c, r) }
        )
    }

    func stop() { stopInternal() }

    private func stopInternal() {
        lock.lock()
        let wasStarted = started
        let wasSubscribed = subscribed
        let sid = sessionID
        started = false
        subscribed = false
        pendingStart = nil
        pendingResize = nil
        pendingWrites.removeAll()
        lock.unlock()
        guard wasStarted, wasSubscribed, let sid else { return }
        DaemonConnection.shared.unsubscribeTerminal(sessionID: sid)
    }

    func writeToSession(_ data: Data) {
        lock.lock()
        if let sid = sessionID {
            lock.unlock()
            DaemonConnection.shared.writeToSession(sessionID: sid, data: data)
            return
        }
        pendingWrites.append(data)
        lock.unlock()
    }

    func resize(cols: Int, rows: Int) {
        lock.lock()
        if let sid = sessionID {
            lock.unlock()
            DaemonConnection.shared.resizeSession(sessionID: sid, cols: cols, rows: rows)
            return
        }
        pendingResize = (cols, rows)
        lock.unlock()
    }
}
