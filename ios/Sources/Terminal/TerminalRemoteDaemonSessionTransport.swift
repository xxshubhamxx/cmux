import Foundation

protocol TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState?
}

protocol TerminalRemoteDaemonSessionClient: Sendable {
    func sendHello() async throws -> TerminalRemoteDaemonHello
    func sessionAttach(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus
    func terminalOpen(command: String, cols: Int, rows: Int, sessionID: String?) async throws -> TerminalRemoteDaemonTerminalOpenResult
    func terminalWrite(sessionID: String, data: Data) async throws
    func terminalRead(
        sessionID: String,
        offset: UInt64,
        maxBytes: Int,
        timeoutMilliseconds: Int
    ) async throws -> TerminalRemoteDaemonTerminalReadResult
    func sessionResize(
        sessionID: String,
        attachmentID: String,
        cols: Int,
        rows: Int
    ) async throws -> TerminalRemoteDaemonSessionStatus
    func sessionDetach(
        sessionID: String,
        attachmentID: String
    ) async throws -> TerminalRemoteDaemonSessionStatus
    func sessionClose(sessionID: String) async throws
    func sessionHistory(sessionID: String, format: String) async throws -> TerminalRemoteDaemonSessionHistoryResult
    /// Fetch the daemon's current workspace list so we can adopt an
    /// existing peer session when our saved session_id is missing.
    /// Part of the shared-session-identity plan's Step 5.
    func workspaceList() async throws -> TerminalRemoteDaemonWorkspaceListResult
}

enum TerminalRemoteDaemonSessionTransportError: LocalizedError {
    case missingCapability(String)

    var errorDescription: String? {
        switch self {
        case .missingCapability(let capability):
            return "Remote daemon is missing required capability \(capability)."
        }
    }
}

final class TerminalRemoteDaemonSessionTransport: @unchecked Sendable, TerminalTransport {
    var eventHandler: (@Sendable (TerminalTransportEvent) -> Void)?

    private let client: any TerminalRemoteDaemonSessionClient
    private let command: String
    private let sharedSessionID: String?
    // Stable attachment ID: reused across reconnections so we don't leak attachments
    private let stableAttachmentID: String = "ios-\(UUID().uuidString.prefix(8).lowercased())"
    private let resumeState: TerminalRemoteDaemonResumeState?
    private let readTimeoutMilliseconds: Int
    private let maxReadBytes: Int
    private let stateLock = NSLock()

    private var sessionID: String?
    private var attachmentID: String?
    private var nextOffset: UInt64 = 0
    private var readTask: Task<Void, Never>?
    private var closed = false
    private var pushSubscribed = false

    init(
        client: any TerminalRemoteDaemonSessionClient,
        command: String,
        sharedSessionID: String? = nil,
        resumeState: TerminalRemoteDaemonResumeState? = nil,
        readTimeoutMilliseconds: Int = 250,
        maxReadBytes: Int = 64 * 1024
    ) {
        self.client = client
        self.command = command
        self.sharedSessionID = sharedSessionID
        self.resumeState = resumeState
        self.readTimeoutMilliseconds = readTimeoutMilliseconds
        self.maxReadBytes = maxReadBytes
    }

    func connect(initialSize: TerminalGridSize) async throws {
        NSLog("📱 SessionTransport: starting connect")
        let hello = try await client.sendHello()
        NSLog("📱 SessionTransport: hello OK, capabilities=%@", hello.capabilities.joined(separator: ","))
        guard hello.capabilities.contains("terminal.stream") else {
            throw TerminalRemoteDaemonSessionTransportError.missingCapability("terminal.stream")
        }

        try await openOrAttachTerminal(initialSize: initialSize)
        NSLog("📱 SessionTransport: terminal opened, sessionID=%@", lockedSessionID() ?? "nil")

        eventHandler?(.connected)

        if hello.capabilities.contains("terminal.subscribe"),
           let pushClient = client as? any TerminalRemoteDaemonPushSubscribing {
            try await startPushSubscription(pushClient: pushClient)
            NSLog("📱 SessionTransport: push subscription active")
        } else {
            startReadLoop()
            NSLog("📱 SessionTransport: fallback polling read loop started")
        }
    }

    func send(_ data: Data) async throws {
        guard let sessionID = lockedSessionID() else { return }
        try await client.terminalWrite(sessionID: sessionID, data: data)
    }

    func resize(_ size: TerminalGridSize) async {
        guard let state = lockedSessionState() else { return }
        let result = try? await client.sessionResize(
            sessionID: state.sessionID,
            attachmentID: state.attachmentID,
            cols: max(1, size.columns),
            rows: max(1, size.rows)
        )
        if let result {
            emitEffectiveSize(cols: result.effectiveCols, rows: result.effectiveRows)
        }
    }

    func disconnect() async {
        let state = lockedSessionState()
        let readTask = takeReadTask(markClosed: false)
        readTask?.cancel()
        await readTask?.value

        await tearDownPushSubscription(sessionID: state?.sessionID)

        if let state {
            if sharedSessionID != nil {
                // Detach instead of close so other clients keep the session
                _ = try? await client.sessionDetach(
                    sessionID: state.sessionID,
                    attachmentID: state.attachmentID
                )
            } else {
                try? await client.sessionClose(sessionID: state.sessionID)
            }
        }
        clearSessionState()
        finishDisconnect(error: nil)
    }

    func suspendPreservingSession() async {
        guard let state = lockedSessionState() else { return }

        let readTask = takeReadTask(markClosed: true)
        readTask?.cancel()
        await readTask?.value

        await tearDownPushSubscription(sessionID: state.sessionID)

        _ = try? await client.sessionDetach(
            sessionID: state.sessionID,
            attachmentID: state.attachmentID
        )
        clearSessionState()
    }

    private func openOrAttachTerminal(initialSize: TerminalGridSize) async throws {
        let cols = max(1, initialSize.columns)
        let rows = max(1, initialSize.rows)

        // For shared sessions, always use the shared session ID with a stable
        // attachment ID so we don't leak attachments on reconnection.
        if let sharedSessionID {
            do {
                let status = try await client.sessionAttach(
                    sessionID: sharedSessionID,
                    attachmentID: stableAttachmentID,
                    cols: cols,
                    rows: rows
                )
                NSLog("📱 SessionTransport: attached to shared session %@ as %@", sharedSessionID, stableAttachmentID)
                withLockedState {
                    sessionID = sharedSessionID
                    attachmentID = stableAttachmentID
                    nextOffset = 0
                    closed = false
                }
                emitEffectiveSize(cols: status.effectiveCols, rows: status.effectiveRows)
                return
            } catch let error as TerminalRemoteDaemonClientError {
                if case .rpc(let code, _) = error, code == "not_found" {
                    NSLog("📱 SessionTransport: shared session %@ not found, creating", sharedSessionID)
                } else {
                    throw error
                }
            }
        }

        // Try resuming a previously saved session (non-shared only).
        // If the saved session is gone from the daemon, probe
        // `workspace.list` for a live session on the same host that
        // our ResumeState workspace can adopt — that way we don't
        // silently mint a fresh session_id diverging from mac. If no
        // peer session is available, propagate the failure up so the
        // UI surfaces an "ended" state instead of secretly starting
        // a new shell.
        if let resumeState, sharedSessionID == nil {
            do {
                let status = try await client.sessionAttach(
                    sessionID: resumeState.sessionID,
                    attachmentID: resumeState.attachmentID,
                    cols: cols,
                    rows: rows
                )
                withLockedState {
                    sessionID = resumeState.sessionID
                    attachmentID = resumeState.attachmentID
                    nextOffset = resumeState.readOffset
                    closed = false
                }
                emitEffectiveSize(cols: status.effectiveCols, rows: status.effectiveRows)
                return
            } catch let error as TerminalRemoteDaemonClientError {
                if case .rpc(let code, _) = error, code == "not_found" {
                    if let adopted = try? await attemptAdoptPeerSessionFromWorkspaceList(
                        client: client,
                        cols: cols,
                        rows: rows
                    ) {
                        withLockedState {
                            sessionID = adopted.sessionID
                            attachmentID = adopted.attachmentID
                            nextOffset = 0
                            closed = false
                        }
                        emitEffectiveSize(cols: adopted.effectiveCols, rows: adopted.effectiveRows)
                        return
                    }
                    // No peer session found. Clear saved state and fall
                    // through — for a shared-session world we'd surface
                    // "session ended" here, but today the terminal.open
                    // below still mints a deterministic id that mac's
                    // workspace.sync can eventually carry back.
                    clearSessionState()
                } else {
                    throw error
                }
            }
        }

        let openResult = try await client.terminalOpen(
            command: command,
            cols: cols,
            rows: rows,
            sessionID: sharedSessionID
        )

        withLockedState {
            sessionID = openResult.sessionID
            attachmentID = openResult.attachmentID
            nextOffset = openResult.offset
            closed = false
        }
        emitEffectiveSize(cols: openResult.effectiveCols, rows: openResult.effectiveRows)
    }

    /// Forward the daemon's authoritative view size to the event
    /// handler whenever the backend reports a real size (nonzero on
    /// both axes). Zero on either axis means the daemon hasn't settled
    /// yet, likely because no attachment has reported geometry — skip
    /// so we don't collapse the local Ghostty surface to 0 cols.
    private func emitEffectiveSize(cols: Int, rows: Int) {
        guard cols > 0, rows > 0 else { return }
        eventHandler?(.viewSize(cols: cols, rows: rows))
    }

    /// Probe the daemon's current workspace tree for any pane whose
    /// session_id is attachable — preferred over minting a fresh
    /// session when our saved session_id is gone. Returns the first
    /// pane whose `session.attach` succeeds, or nil if the daemon
    /// has no live sessions. Keeps the "never mint on iOS" invariant
    /// from the shared-session plan: we always adopt daemon-owned
    /// session IDs rather than invent our own.
    private func attemptAdoptPeerSessionFromWorkspaceList(
        client: any TerminalRemoteDaemonSessionClient,
        cols: Int,
        rows: Int
    ) async throws -> (sessionID: String, attachmentID: String, effectiveCols: Int, effectiveRows: Int)? {
        let list = try await client.workspaceList()
        for workspace in list.workspaces {
            guard let panes = workspace.panes else { continue }
            for pane in panes {
                guard let candidate = pane.sessionID, !candidate.isEmpty else { continue }
                let newAttachmentID = stableAttachmentID
                do {
                    let status = try await client.sessionAttach(
                        sessionID: candidate,
                        attachmentID: newAttachmentID,
                        cols: max(1, cols),
                        rows: max(1, rows)
                    )
                    return (candidate, newAttachmentID, status.effectiveCols, status.effectiveRows)
                } catch {
                    continue
                }
            }
        }
        return nil
    }

    private func startReadLoop() {
        withLockedState {
            readTask?.cancel()
            readTask = Task { [weak self] in
                await self?.runReadLoop()
            }
        }
    }

    private func startPushSubscription(pushClient: any TerminalRemoteDaemonPushSubscribing) async throws {
        guard let state = lockedSessionStateWithOffset() else { return }

        await pushClient.setPushHandler(sessionID: state.sessionID) { [weak self] event in
            self?.handlePushEvent(event)
        }
        withLockedState { pushSubscribed = true }

        let initialOffset: UInt64? = state.offset > 0 ? state.offset : nil
        let result: TerminalRemoteDaemonTerminalReadResult
        do {
            result = try await pushClient.terminalSubscribe(
                sessionID: state.sessionID,
                offset: initialOffset
            )
        } catch {
            await pushClient.removePushHandler(sessionID: state.sessionID)
            withLockedState { pushSubscribed = false }
            throw error
        }

        applySubscriptionPayload(
            data: result.data,
            offset: result.offset,
            truncated: result.truncated,
            eof: result.eof
        )
    }

    private func handlePushEvent(_ event: TerminalPushEvent) {
        switch event {
        case .output(let data, let offset, _, let truncated, let eof, let seq, let notifications):
            applySubscriptionPayload(data: data, offset: offset, truncated: truncated, eof: eof)
            if let notifications, let sid = lockedSessionStateWithOffset()?.sessionID {
                Task { @MainActor in
                    NotificationManager.shared.handleTerminalNotifications(
                        sessionID: sid,
                        seq: seq,
                        payload: notifications
                    )
                }
            }
        case .eof:
            clearSessionState()
            finishDisconnect(error: nil)
        case .viewSize(let cols, let rows):
            eventHandler?(.viewSize(cols: cols, rows: rows))
        }
    }

    private func applySubscriptionPayload(
        data: Data,
        offset: UInt64,
        truncated: Bool,
        eof: Bool
    ) {
        if truncated {
            NSLog("📱 SessionTransport: push payload truncated, resetting emulator buffer")
            eventHandler?(.notice("Terminal output truncated; buffer reset."))
            // RIS (ESC c) — reset to initial state. Clears emulator screen/scrollback
            // before we feed the post-truncation snapshot.
            eventHandler?(.output(Data([0x1B, 0x63])))
        }

        let newOffset = offset &+ UInt64(data.count)
        withLockedState { nextOffset = newOffset }

        if !data.isEmpty {
            eventHandler?(.output(data))
        }

        if eof {
            NSLog("📱 SessionTransport: EOF via push for session")
            clearSessionState()
            finishDisconnect(error: nil)
        }
    }

    private func runReadLoop() async {
        while !Task.isCancelled {
            guard let state = lockedSessionStateWithOffset() else { return }

            do {
                let result = try await client.terminalRead(
                    sessionID: state.sessionID,
                    offset: state.offset,
                    maxBytes: maxReadBytes,
                    timeoutMilliseconds: readTimeoutMilliseconds
                )

                withLockedState {
                    nextOffset = result.offset
                }

                if !result.data.isEmpty {
                    eventHandler?(.output(result.data))
                }

                if result.eof {
                    NSLog("📱 readLoop: EOF received for session %@, data=%d bytes", state.sessionID, result.data.count)
                    clearSessionState()
                    finishDisconnect(error: nil)
                    return
                }
            } catch let error as TerminalRemoteDaemonClientError {
                if case .rpc(let code, _) = error, code == "deadline_exceeded" {
                    continue
                }
                NSLog("📱 readLoop RPC error: %@", error.localizedDescription ?? "unknown")
                finishDisconnect(error: error.localizedDescription)
                return
            } catch {
                NSLog("📱 readLoop error: %@", String(describing: error))
                finishDisconnect(error: error.localizedDescription)
                return
            }
        }
    }

    private func finishDisconnect(error: String?) {
        stateLock.lock()
        guard !closed else {
            stateLock.unlock()
            return
        }
        closed = true
        readTask?.cancel()
        readTask = nil
        stateLock.unlock()

        eventHandler?(.disconnected(error))
    }

    private func lockedSessionID() -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionID
    }

    private func lockedSessionState() -> (sessionID: String, attachmentID: String)? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID, let attachmentID else { return nil }
        return (sessionID, attachmentID)
    }

    private func lockedSessionStateWithOffset() -> (sessionID: String, attachmentID: String, offset: UInt64)? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID, let attachmentID else { return nil }
        return (sessionID, attachmentID, nextOffset)
    }

    private func clearSessionState() {
        withLockedState {
            sessionID = nil
            attachmentID = nil
            nextOffset = 0
        }
    }

    private func takeReadTask(markClosed: Bool) -> Task<Void, Never>? {
        withLockedState {
            let task = readTask
            readTask = nil
            if markClosed {
                closed = true
            }
            return task
        }
    }

    private func tearDownPushSubscription(sessionID: String?) async {
        let wasSubscribed: Bool = withLockedState {
            let prev = pushSubscribed
            pushSubscribed = false
            return prev
        }
        guard wasSubscribed,
              let sessionID,
              let pushClient = client as? any TerminalRemoteDaemonPushSubscribing else {
            return
        }
        await pushClient.removePushHandler(sessionID: sessionID)
    }

    private func withLockedState<Result>(_ body: () -> Result) -> Result {
        stateLock.lock()
        defer { stateLock.unlock() }
        return body()
    }
}

extension TerminalRemoteDaemonSessionTransport: TerminalRemoteDaemonResumeStateSnapshotting {
    func remoteDaemonResumeStateSnapshot() -> TerminalRemoteDaemonResumeState? {
        stateLock.lock()
        defer { stateLock.unlock() }

        guard let sessionID, let attachmentID else { return nil }
        return TerminalRemoteDaemonResumeState(
            sessionID: sessionID,
            attachmentID: attachmentID,
            readOffset: nextOffset
        )
    }
}

extension TerminalRemoteDaemonSessionTransport: TerminalSessionParking {}
