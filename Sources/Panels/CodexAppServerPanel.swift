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

enum CodexAppServerTranscriptRole: Equatable {
    case user
    case assistant
    case event
    case stderr
    case error
}

struct CodexAppServerTranscriptItem: Identifiable, Equatable {
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

enum CodexAppServerApprovalDecision: String {
    case accept
    case decline
    case cancel
}

@MainActor
final class CodexAppServerPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .codexAppServer

    private(set) var workspaceId: UUID

    @Published var promptText: String = ""
    @Published var cwd: String
    @Published private(set) var status: CodexAppServerPanelStatus = .stopped
    @Published private(set) var transcriptItems: [CodexAppServerTranscriptItem] = []
    @Published private(set) var pendingRequests: [CodexAppServerPendingRequest] = []

    private let client: CodexAppServerClient
    private var threadId: String?
    private var currentTurnId: String?
    private var activeAssistantItemId: UUID?
    private var isStarted = false
    private var isClosed = false

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
        client: CodexAppServerClient = CodexAppServerClient()
    ) {
        self.id = id
        self.workspaceId = workspaceId
        self.cwd = cwd
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
            status = .ready
            appendEvent(
                title: String(localized: "codexAppServer.event.started", defaultValue: "App server started"),
                body: currentWorkingDirectory()
            )
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
        case .notification(let method, let params):
            handleNotification(method: method, params: params)
        case .serverRequest(let id, let method, let params):
            pendingRequests.append(
                CodexAppServerPendingRequest(
                    id: id,
                    method: method,
                    params: params,
                    summary: Self.prettyJSON(params)
                )
            )
            appendEvent(
                title: String(localized: "codexAppServer.event.request", defaultValue: "Approval requested"),
                body: method
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

    private func handleNotification(method: String, params: [String: Any]?) {
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
                body: commandSummary(from: item)
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
            transcriptItems[index].body += delta
            transcriptItems[index].date = Date()
        } else {
            let item = CodexAppServerTranscriptItem(
                role: .assistant,
                title: String(localized: "codexAppServer.role.assistant", defaultValue: "Codex"),
                body: delta,
                isStreaming: true
            )
            activeAssistantItemId = item.id
            transcriptItems.append(item)
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

    private func append(role: CodexAppServerTranscriptRole, title: String, body: String) {
        let trimmedBody = body.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBody.isEmpty else { return }
        transcriptItems.append(
            CodexAppServerTranscriptItem(
                role: role,
                title: title,
                body: trimmedBody
            )
        )
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

    private func commandSummary(from item: [String: Any]) -> String {
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
