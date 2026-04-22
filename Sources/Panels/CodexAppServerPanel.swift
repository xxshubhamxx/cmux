import Foundation
import Combine

enum CodexAppServerPanelStatus: Equatable {
    case stopped
    case starting
    case ready
    case running
    case failed(String)

    var localizedTitle: String {
        switch self {
        case .stopped:
            return String(localized: "codexAppServer.status.stopped", defaultValue: "Stopped")
        case .starting:
            return String(localized: "codexAppServer.status.starting", defaultValue: "Starting")
        case .ready:
            return String(localized: "codexAppServer.status.ready", defaultValue: "Ready")
        case .running:
            return String(localized: "codexAppServer.status.running", defaultValue: "Running")
        case .failed:
            return String(localized: "codexAppServer.status.failed", defaultValue: "Failed")
        }
    }

    var isBusy: Bool {
        switch self {
        case .starting, .running:
            return true
        case .stopped, .ready, .failed:
            return false
        }
    }
}

enum CodexAppServerTranscriptRole: Equatable, Sendable {
    case user
    case assistant
    case event
    case stderr
    case error
}

struct CodexAppServerTranscriptItem: Identifiable, Equatable, Sendable {
    let id: UUID
    var role: CodexAppServerTranscriptRole
    var title: String
    var body: String
    var date: Date
    var isStreaming: Bool

    init(
        id: UUID = UUID(),
        role: CodexAppServerTranscriptRole,
        title: String,
        body: String,
        date: Date = Date(),
        isStreaming: Bool = false
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.body = body
        self.date = date
        self.isStreaming = isStreaming
    }
}

struct CodexAppServerPendingRequest: Identifiable {
    let id: Int
    let method: String
    let params: [String: Any]?
    let summary: String

    var supportsDecisionResponse: Bool {
        method == "item/commandExecution/requestApproval"
            || method == "item/fileChange/requestApproval"
    }
}

struct CodexAppServerResumeSnapshot: Equatable {
    var threadId: String
    var cwd: String?
    var transcriptItems: [CodexAppServerTranscriptItem]
    var totalRestoredItemCount: Int
    var didTruncate: Bool
    var responseWasTruncated: Bool
}

enum CodexAppServerApprovalDecision: String {
    case accept
    case decline
    case cancel
}

@MainActor
final class CodexAppServerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .codexAppServer

    private static let restoredTranscriptItemLimit = 250
    private static let maxTranscriptItems = 500
    private static let maxTranscriptItemCharacters = 160_000

    private(set) var workspaceId: UUID

    @Published var promptText: String = ""
    @Published var cwd: String
    @Published private(set) var status: CodexAppServerPanelStatus = .stopped
    @Published private(set) var transcriptItems: [CodexAppServerTranscriptItem] = []
    @Published private(set) var pendingRequests: [CodexAppServerPendingRequest] = []

    private let client: CodexAppServerClient
    private let initialResumeThreadId: String?
    private var threadId: String?
    private var currentTurnId: String?
    private var activeAssistantItemId: UUID?
    private var isStarted = false
    private var isClosed = false
    private var didResumeInitialThread = false

    var displayTitle: String {
        String(localized: "codexAppServer.panel.title", defaultValue: "Codex")
    }

    var displayIcon: String? {
        "sparkles"
    }

    var canSendPrompt: Bool {
        !status.isBusy && !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    init(
        id: UUID = UUID(),
        workspaceId: UUID,
        cwd: String,
        resumeThreadId: String? = nil,
        client: CodexAppServerClient = CodexAppServerClient()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.cwd = cwd
        self.initialResumeThreadId = resumeThreadId?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.client = client
        self.client.onEvent = { [weak self] event in
            Task { @MainActor in
                self?.handle(event)
            }
        }
    }

    deinit {
        client.stop()
    }

    func start() async {
        guard !isStarted, status != .starting else { return }
        status = .starting
        do {
            try await client.startAndInitialize()
            isStarted = true
            if let initialResumeThreadId, !initialResumeThreadId.isEmpty, !didResumeInitialThread {
                status = .running
                let response = try await client.resumeThread(
                    threadId: initialResumeThreadId,
                    cwd: currentWorkingDirectory()
                )
                didResumeInitialThread = true
                applyResumeResponse(response, fallbackThreadId: initialResumeThreadId)
                status = .ready
                appendEvent(
                    title: String(localized: "codexAppServer.event.resumed", defaultValue: "Thread resumed"),
                    body: threadId ?? initialResumeThreadId
                )
            } else {
                status = .ready
                appendEvent(
                    title: String(localized: "codexAppServer.event.started", defaultValue: "App server started"),
                    body: currentWorkingDirectory()
                )
            }
        } catch {
            status = .failed(error.localizedDescription)
            appendError(error.localizedDescription)
        }
    }

    func stop() {
        if isStarted {
            client.stop()
        }
        isStarted = false
        threadId = nil
        currentTurnId = nil
        activeAssistantItemId = nil
        pendingRequests.removeAll()
        status = .stopped
    }

    func sendPrompt() async {
        let text = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, !status.isBusy else { return }
        promptText = ""
        appendUser(text)

        do {
            if !isStarted {
                await start()
            }
            guard isStarted else { return }
            let resolvedThreadId: String
            if let threadId {
                resolvedThreadId = threadId
            } else {
                let newThreadId = try await client.startThread(cwd: currentWorkingDirectory())
                threadId = newThreadId
                resolvedThreadId = newThreadId
            }

            status = .running
            currentTurnId = try await client.startTurn(
                threadId: resolvedThreadId,
                text: text,
                cwd: currentWorkingDirectory()
            )
        } catch {
            status = .failed(error.localizedDescription)
            appendError(error.localizedDescription)
        }
    }

    func resolvePendingRequest(_ request: CodexAppServerPendingRequest, decision: CodexAppServerApprovalDecision) {
        do {
            guard request.supportsDecisionResponse else {
                try client.rejectServerRequest(
                    id: request.id,
                    message: String(
                        localized: "codexAppServer.request.unsupported",
                        defaultValue: "cmux does not support this Codex app-server request yet."
                    )
                )
                removePendingRequest(id: request.id)
                return
            }

            try client.respondToServerRequest(id: request.id, result: ["decision": decision.rawValue])
            removePendingRequest(id: request.id)
            appendEvent(
                title: String(localized: "codexAppServer.event.approvalSent", defaultValue: "Approval response sent"),
                body: request.method
            )
        } catch {
            appendError(error.localizedDescription)
        }
    }

    func close() {
        isClosed = true
        stop()
    }

    func focus() {}

    func unfocus() {}

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
    }

    private func handle(_ event: CodexAppServerEvent) {
        guard !isClosed else { return }
        switch event {
        case .notification(let notification):
            handleNotification(notification)
        case .serverRequest(let request):
            pendingRequests.append(
                CodexAppServerPendingRequest(
                    id: request.id,
                    method: request.rawMethod,
                    params: request.paramsObject,
                    summary: Self.prettyJSON(request.paramsObject)
                )
            )
            appendEvent(
                title: String(localized: "codexAppServer.event.request", defaultValue: "Approval requested"),
                body: request.rawMethod
            )
        case .stderr(let text):
            append(
                role: .stderr,
                title: String(localized: "codexAppServer.event.stderr", defaultValue: "stderr"),
                body: text.trimmingCharacters(in: .whitespacesAndNewlines)
            )
        case .terminated(let statusCode):
            isStarted = false
            status = .stopped
            threadId = nil
            currentTurnId = nil
            activeAssistantItemId = nil
            pendingRequests.removeAll()
            appendEvent(
                title: String(localized: "codexAppServer.event.terminated", defaultValue: "App server exited"),
                body: String(statusCode)
            )
        }
    }

    private func handleNotification(_ notification: CodexAppServerServerNotification) {
        let method = notification.rawMethod
        let params = notification.paramsObject

        switch method {
        case "thread/started":
            if let thread = params?["thread"] as? [String: Any],
               let threadId = thread["id"] as? String {
                self.threadId = threadId
            }
        case "turn/started":
            status = .running
        case "turn/completed":
            status = .ready
            currentTurnId = nil
            finishStreamingAssistant()
        case "item/agentMessage/delta":
            appendAssistantDelta(Self.stringValue(named: "delta", in: params))
        case "item/commandExecution/outputDelta":
            appendCommandDelta(Self.stringValue(named: "delta", in: params))
        case "item/completed":
            handleCompletedItem(params?["item"] as? [String: Any])
        default:
            appendEvent(title: method, body: Self.prettyJSON(params))
        }
    }

    private func handleCompletedItem(_ item: [String: Any]?) {
        guard let item else { return }
        let type = item["type"] as? String ?? item["kind"] as? String ?? ""
        switch type {
        case "agentMessage":
            let text = Self.stringValue(named: "text", in: item)
                ?? Self.stringValue(named: "message", in: item)
                ?? Self.stringValue(named: "content", in: item)
            if let text, !text.isEmpty {
                if activeAssistantItemId == nil || transcriptItems.last?.role != .assistant {
                    appendAssistantDelta(text)
                }
                finishStreamingAssistant()
            }
        case "commandExecution":
            appendEvent(
                title: String(localized: "codexAppServer.event.command", defaultValue: "Command"),
                body: Self.commandSummary(from: item)
            )
        case "fileChange":
            appendEvent(
                title: String(localized: "codexAppServer.event.fileChange", defaultValue: "File change"),
                body: Self.prettyJSON(item)
            )
        default:
            appendEvent(title: type.isEmpty ? "item/completed" : type, body: Self.prettyJSON(item))
        }
    }

    private func appendUser(_ text: String) {
        append(
            role: .user,
            title: String(localized: "codexAppServer.role.user", defaultValue: "You"),
            body: text
        )
    }

    private func appendAssistantDelta(_ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        if let id = activeAssistantItemId,
           let index = transcriptItems.firstIndex(where: { $0.id == id }) {
            transcriptItems[index].body = Self.truncatedTranscriptBody(transcriptItems[index].body + delta)
            transcriptItems[index].date = Date()
        } else {
            let item = CodexAppServerTranscriptItem(
                role: .assistant,
                title: String(localized: "codexAppServer.role.assistant", defaultValue: "Codex"),
                body: Self.truncatedTranscriptBody(delta),
                isStreaming: true
            )
            activeAssistantItemId = item.id
            transcriptItems.append(item)
            trimTranscriptItemsIfNeeded()
        }
    }

    private func appendCommandDelta(_ delta: String?) {
        guard let delta, !delta.isEmpty else { return }
        append(
            role: .event,
            title: String(localized: "codexAppServer.event.output", defaultValue: "Output"),
            body: delta
        )
    }

    private func finishStreamingAssistant() {
        guard let id = activeAssistantItemId,
              let index = transcriptItems.firstIndex(where: { $0.id == id }) else {
            activeAssistantItemId = nil
            return
        }
        transcriptItems[index].isStreaming = false
        activeAssistantItemId = nil
    }

    private func appendEvent(title: String, body: String) {
        append(role: .event, title: title, body: body)
    }

    private func appendError(_ message: String) {
        append(
            role: .error,
            title: String(localized: "codexAppServer.event.error", defaultValue: "Error"),
            body: message
        )
    }

    private func applyResumeResponse(_ response: [String: Any], fallbackThreadId: String) {
        let snapshot = Self.resumeSnapshot(
            from: response,
            fallbackThreadId: fallbackThreadId,
            restoredItemLimit: Self.restoredTranscriptItemLimit
        )
        threadId = snapshot.threadId
        if let resumedCwd = snapshot.cwd, !resumedCwd.isEmpty {
            cwd = resumedCwd
        }

        activeAssistantItemId = nil

        if snapshot.responseWasTruncated {
            appendEvent(
                title: String(localized: "codexAppServer.event.historyOmitted", defaultValue: "History omitted"),
                body: String(
                    localized: "codexAppServer.event.historyOmitted.body",
                    defaultValue: "Codex returned a very large history. The thread is connected, and new messages will stream here."
                )
            )
            return
        }

        guard !snapshot.transcriptItems.isEmpty else { return }
        if snapshot.didTruncate {
            transcriptItems = [Self.historyTruncatedItem(snapshot: snapshot)] + snapshot.transcriptItems
        } else {
            transcriptItems = snapshot.transcriptItems
        }
    }

    static func resumeSnapshot(
        from response: [String: Any],
        fallbackThreadId: String,
        restoredItemLimit: Int
    ) -> CodexAppServerResumeSnapshot {
        let thread = response["thread"] as? [String: Any]
        let resolvedThreadId = Self.stringValue(named: "id", in: thread) ?? fallbackThreadId
        let resolvedCwd = Self.stringValue(named: "cwd", in: response)
            ?? Self.stringValue(named: "cwd", in: thread)
        let responseWasTruncated = (response["_cmuxResponseTruncated"] as? Bool) == true
        guard !responseWasTruncated else {
            return CodexAppServerResumeSnapshot(
                threadId: resolvedThreadId,
                cwd: resolvedCwd,
                transcriptItems: [],
                totalRestoredItemCount: 0,
                didTruncate: false,
                responseWasTruncated: true
            )
        }

        let turns = thread?["turns"] as? [[String: Any]] ?? []
        var restoredItems: [CodexAppServerTranscriptItem] = []
        for turn in turns {
            let date = Self.dateValue(named: "startedAt", in: turn) ?? Date()
            let items = turn["items"] as? [[String: Any]] ?? []
            for item in items {
                if let restoredItem = restoredTranscriptItem(fromThreadItem: item, date: date) {
                    restoredItems.append(restoredItem)
                }
            }
        }

        let totalRestoredItemCount = restoredItems.count
        let limit = max(1, restoredItemLimit)
        let didTruncate = totalRestoredItemCount > limit
        if didTruncate {
            restoredItems = Array(restoredItems.suffix(limit))
        }

        return CodexAppServerResumeSnapshot(
            threadId: resolvedThreadId,
            cwd: resolvedCwd,
            transcriptItems: restoredItems,
            totalRestoredItemCount: totalRestoredItemCount,
            didTruncate: didTruncate,
            responseWasTruncated: false
        )
    }

    private static func historyTruncatedItem(snapshot: CodexAppServerResumeSnapshot) -> CodexAppServerTranscriptItem {
        let format = String(
            localized: "codexAppServer.event.historyTruncated.body",
            defaultValue: "Showing the latest %1$ld of %2$ld restored items."
        )
        let body = String(
            format: format,
            locale: Locale.current,
            snapshot.transcriptItems.count,
            snapshot.totalRestoredItemCount
        )
        return CodexAppServerTranscriptItem(
            role: .event,
            title: String(localized: "codexAppServer.event.historyTruncated", defaultValue: "Earlier history omitted"),
            body: body,
            date: snapshot.transcriptItems.first?.date ?? Date()
        )
    }

    private static func restoredTranscriptItem(
        fromThreadItem item: [String: Any],
        date: Date
    ) -> CodexAppServerTranscriptItem? {
        let type = Self.stringValue(named: "type", in: item) ?? ""
        switch type {
        case "userMessage":
            guard let text = Self.userMessageText(from: item), !text.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .user,
                title: String(localized: "codexAppServer.role.user", defaultValue: "You"),
                body: text,
                date: date
            )
        case "agentMessage":
            guard let text = Self.stringValue(named: "text", in: item), !text.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .assistant,
                title: String(localized: "codexAppServer.role.assistant", defaultValue: "Codex"),
                body: text,
                date: date
            )
        case "plan":
            guard let text = Self.stringValue(named: "text", in: item), !text.isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.plan", defaultValue: "Plan"),
                body: text,
                date: date
            )
        case "commandExecution":
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.command", defaultValue: "Command"),
                body: Self.commandSummary(from: item),
                date: date
            )
        case "fileChange":
            return CodexAppServerTranscriptItem(
                role: .event,
                title: String(localized: "codexAppServer.event.fileChange", defaultValue: "File change"),
                body: Self.prettyJSON(item),
                date: date
            )
        default:
            let body = Self.stringValue(named: "text", in: item) ?? Self.prettyJSON(item)
            guard !body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return CodexAppServerTranscriptItem(
                role: .event,
                title: type.isEmpty
                    ? String(localized: "codexAppServer.event.item", defaultValue: "Item")
                    : type,
                body: body,
                date: date
            )
        }
    }

    private func append(role: CodexAppServerTranscriptRole, title: String, body: String) {
        let trimmedBody = Self.truncatedTranscriptBody(body.trimmingCharacters(in: .whitespacesAndNewlines))
        guard !trimmedBody.isEmpty else { return }
        transcriptItems.append(
            CodexAppServerTranscriptItem(
                role: role,
                title: title,
                body: trimmedBody
            )
        )
        trimTranscriptItemsIfNeeded()
    }

    private func trimTranscriptItemsIfNeeded() {
        let overflow = transcriptItems.count - Self.maxTranscriptItems
        guard overflow > 0 else { return }

        var remainingToRemove = overflow
        transcriptItems.removeAll { item in
            guard remainingToRemove > 0 else { return false }
            if let activeAssistantItemId, item.id == activeAssistantItemId {
                return false
            }
            remainingToRemove -= 1
            return true
        }
    }

    private static func truncatedTranscriptBody(_ body: String) -> String {
        guard body.count > maxTranscriptItemCharacters else { return body }
        let prefix = String(
            localized: "codexAppServer.transcriptItem.truncatedPrefix",
            defaultValue: "[Earlier output omitted]"
        )
        return "\(prefix)\n\(String(body.suffix(maxTranscriptItemCharacters)))"
    }

    private func removePendingRequest(id: Int) {
        pendingRequests.removeAll { $0.id == id }
    }

    private func currentWorkingDirectory() -> String {
        cwd.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func stringValue(named key: String, in object: [String: Any]?) -> String? {
        guard let value = object?[key] else { return nil }
        if let value = value as? String {
            return value
        }
        if let value = value as? NSNumber {
            return value.stringValue
        }
        return nil
    }

    private static func dateValue(named key: String, in object: [String: Any]?) -> Date? {
        guard let value = object?[key] else { return nil }
        if let value = value as? NSNumber {
            return Date(timeIntervalSince1970: value.doubleValue)
        }
        if let value = value as? Double {
            return Date(timeIntervalSince1970: value)
        }
        if let value = value as? Int {
            return Date(timeIntervalSince1970: TimeInterval(value))
        }
        return nil
    }

    private static func userMessageText(from item: [String: Any]) -> String? {
        guard let content = item["content"] as? [[String: Any]] else { return nil }
        let parts = content.compactMap { input -> String? in
            if let text = stringValue(named: "text", in: input) {
                return text
            }
            if let url = stringValue(named: "url", in: input) {
                return url
            }
            return nil
        }
        let text = parts.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func commandSummary(from item: [String: Any]) -> String {
        if let command = item["command"] as? String {
            return command
        }
        if let command = item["command"] as? [String] {
            return command.joined(separator: " ")
        }
        return Self.prettyJSON(item)
    }

    private static func prettyJSON(_ value: Any?) -> String {
        guard let value else { return "{}" }
        let object: Any
        if JSONSerialization.isValidJSONObject(value) {
            object = value
        } else {
            object = ["value": String(describing: value)]
        }
        guard let data = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        ),
              let text = String(data: data, encoding: .utf8) else {
            return String(describing: value)
        }
        return text
    }
}
