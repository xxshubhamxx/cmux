import AppKit
import Combine
import Foundation

/// Observes TabManager/workspace/notification changes and pushes `workspace.sync`
/// through the single shared `DaemonConnection`. Keeps the class name so existing
/// AppDelegate / TerminalController call sites stay intact; all socket I/O is
/// owned by `DaemonConnection.shared`.
@MainActor
final class WorkspaceDaemonBridge {
    private var tabManager: TabManager?
    private var notificationStore: TerminalNotificationStore?
    private var cancellables = Set<AnyCancellable>()
    private var workspaceCancellables: [UUID: AnyCancellable] = [:]
    private var panelCancellables: [UUID: AnyCancellable] = [:]
    private var panelSetCancellables: [UUID: AnyCancellable] = [:]

    private var syncScheduled = false
    private(set) var lastSyncTime: Date?
    private(set) var syncCount: Int = 0

    private var connection: DaemonConnection { DaemonConnection.shared }

    var isConnected: Bool { connection.isConnected }
    var statusDescription: String { connection.statusDescription }
    var socketPath: String { connection.currentSocketPath }

    init(
        authProvider: AnyObject? = nil,
        authChangePublisher: AnyPublisher<Void, Never>? = nil,
        heartbeatPublisher: AnyObject? = nil
    ) {}

    func start(tabManager: TabManager) {
        guard self.tabManager !== tabManager else { return }
        self.tabManager = tabManager
        self.notificationStore = .shared
        cancellables.removeAll()
        workspaceCancellables.removeAll()

        connection.setWorkspaceSyncProvider { [weak self] in
            guard let self else { return nil }
            return self.buildSyncParams()
        }

        tabManager.$tabs
            .sink { [weak self] workspaces in
                self?.rewireWorkspaceObservers(workspaces: workspaces)
                self?.scheduleSyncNow()
            }
            .store(in: &cancellables)

        tabManager.$selectedTabId
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSyncNow() }
            .store(in: &cancellables)

        TerminalNotificationStore.shared.$notifications
            .dropFirst()
            .sink { [weak self] _ in self?.scheduleSyncNow() }
            .store(in: &cancellables)
    }

    func stop() {
        cancellables.removeAll()
        workspaceCancellables.removeAll()
        panelCancellables.removeAll()
        panelSetCancellables.removeAll()
    }

    private func rewireWorkspaceObservers(workspaces: [Workspace]) {
        workspaceCancellables.removeAll()
        panelCancellables.removeAll()
        panelSetCancellables.removeAll()
        for workspace in workspaces {
            workspaceCancellables[workspace.id] = workspace.objectWillChange
                .sink { [weak self] _ in self?.scheduleSyncNow() }
            panelSetCancellables[workspace.id] = workspace.$panels
                .sink { [weak self] panels in
                    self?.rewirePanelObservers(panels)
                    self?.scheduleSyncNow()
                }
        }
    }

    private func rewirePanelObservers(_ panels: [UUID: any Panel]) {
        panelCancellables.removeAll()
        for panel in panels.values {
            if let terminal = panel as? TerminalPanel {
                panelCancellables[panel.id] = terminal.objectWillChange
                    .sink { [weak self] _ in self?.scheduleSyncNow() }
            }
        }
    }

    private func scheduleSyncNow() {
        guard !syncScheduled else { return }
        syncScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.syncScheduled = false
            self?.performSync()
        }
    }

    private func performSync() {
        guard let params = buildSyncParams() else { return }
        connection.sendWorkspaceSync(params)
        lastSyncTime = Date()
        syncCount += 1
    }

    private func buildSyncParams() -> [String: Any]? {
        guard let tabManager, let notificationStore else { return nil }

        let workspaces: [[String: Any]] = tabManager.tabs.map { workspace in
            let preview = workspacePreview(for: workspace)
            let terminalPanels = workspace.panels.values.compactMap { $0 as? TerminalPanel }
            let sessionIDs: [String] = terminalPanels.map { panel in
                panel.surface.savedDaemonSessionID
                    ?? DaemonConnection.computeSessionID(
                        workspaceID: workspace.id,
                        surfaceID: panel.surface.id
                    )
            }
            let paneInfos: [[String: Any]] = terminalPanels.map { panel in
                let customTitle = workspace.panelCustomTitles[panel.id]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                let resolvedTitle = (customTitle?.isEmpty == false ? customTitle : nil)
                    ?? panel.title
                let paneSID = panel.surface.savedDaemonSessionID
                    ?? DaemonConnection.computeSessionID(
                        workspaceID: workspace.id,
                        surfaceID: panel.surface.id
                    )
                return [
                    "session_id": paneSID,
                    "title": resolvedTitle,
                    "directory": panel.directory,
                ]
            }
            var entry: [String: Any] = [
                "id": workspace.id.uuidString.lowercased(),
                "title": workspace.title,
                "directory": workspace.currentDirectory,
                "preview": preview ?? "",
                "phase": workspace.activeRemoteTerminalSessionCount > 0 ? "active" : "idle",
                "color": workspace.customColor ?? "",
                "unread_count": notificationStore.unreadCount(forTabId: workspace.id),
                "pinned": workspace.isPinned,
                "panes": paneInfos,
            ]
            if let primarySessionID = sessionIDs.first {
                entry["session_id"] = primarySessionID
            }
            if sessionIDs.count > 1 {
                entry["session_ids"] = sessionIDs
            }
            entry["pane_count"] = workspace.panels.count
            return entry
        }

        return [
            "selected_workspace_id": tabManager.selectedTabId?.uuidString.lowercased() ?? "",
            "workspaces": workspaces,
        ]
    }

    private func workspacePreview(for workspace: Workspace) -> String? {
        guard let notificationStore else { return workspace.currentDirectory }
        let notification = notificationStore.latestNotification(forTabId: workspace.id)
        for candidate in [notification?.body, notification?.subtitle, workspace.currentDirectory] {
            let trimmed = candidate?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
