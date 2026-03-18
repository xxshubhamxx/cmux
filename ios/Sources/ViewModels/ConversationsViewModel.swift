import Foundation
import Combine
import UIKit
import UserNotifications
import ConvexMobile

/// ViewModel for managing conversations list from Convex
@MainActor
class ConversationsViewModel: ObservableObject {
    @Published var conversations: [ConvexConversation] = []
    @Published var inboxItems: [UnifiedInboxItem] = []
    @Published var isLoading = true
    @Published var error: String?
    @Published var isLoadingMore = false
    @Published var hasMore = false

    private var cancellables = Set<AnyCancellable>()
    private var teamId: String?
    private let convex = ConvexClientManager.shared
    private let inboxCacheRepository: InboxCacheRepository?
    private let workspaceSyncService: UnifiedInboxWorkspaceSyncing?
    private let analyticsTracker: MobileAnalyticsTracking?
    private var lastPrewarmAt: Date?
    private var firstPage: [ConvexConversation] = []
    private var extraConversations: [ConvexConversation] = []
    private var workspaceInboxItems: [UnifiedInboxItem] = []
    private var continueCursor: String?
    private var lastLoadedCursor: String?
    private let pageSize: Double = 50
    private var lastBadgeCount = -1

    private enum ConversationListSource {
        case firstPage
        case extra
    }

    private struct RemovedConversation {
        let entry: ConvexConversation
        let source: ConversationListSource
        let index: Int
    }

    init(
        autoLoad: Bool = true,
        inboxCacheRepository: InboxCacheRepository? = ConversationsViewModel.makeDefaultInboxCacheRepository(),
        workspaceSyncService: UnifiedInboxWorkspaceSyncing? = nil,
        analyticsTracker: MobileAnalyticsTracking? = nil
    ) {
        self.inboxCacheRepository = inboxCacheRepository
        self.workspaceSyncService = workspaceSyncService ?? UnifiedInboxSyncService(
            inboxCacheRepository: inboxCacheRepository
        )
        self.analyticsTracker = analyticsTracker ?? MobileAnalyticsClient()
        loadCachedState()
        observeWorkspaceSync()

        if autoLoad {
            Task {
                await loadConversations()
            }
        } else {
            isLoading = false
        }
    }

    /// Create a new conversation with sandbox
    /// Returns the conversation ID on success
    func createConversation(initialMessage: String) async throws -> String {
        if !UITestConfig.mockDataEnabled {
            await NotificationManager.shared.requestAuthorizationIfNeeded(trigger: .createConversation)
        }

        var teamId = self.teamId
        if teamId == nil {
            teamId = await getFirstTeamId()
        }
        guard let teamId else {
            throw ConversationError.noTeam
        }

        print("📱 ConversationsViewModel: Creating conversation for team \(teamId)")

        // Call acp:startConversation action
        let startArgs = AcpStartConversationArgs(
            clientConversationId: nil,
            sandboxId: nil,
            providerId: .claude,
            cwd: "/workspace",
            teamSlugOrId: teamId
        )
        let response: AcpStartConversationReturn = try await convex.client.action(
            "acp:startConversation",
            with: startArgs.asDictionary()
        )

        print("📱 ConversationsViewModel: Created conversation \(response.conversationId), status: \(response.status)")

        // Send initial message if provided
        if !initialMessage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let contentItem = AcpSendMessageArgsContentItem(
                name: nil,
                text: initialMessage,
                mimeType: nil,
                data: nil,
                uri: nil,
                type: .text
            )
            let sendArgs = AcpSendMessageArgs(
                clientMessageId: nil,
                content: [contentItem],
                conversationId: response.conversationId
            )

            let _: AcpSendMessageReturn = try await convex.client.action(
                "acp:sendMessage",
                with: sendArgs.asDictionary()
            )
            print("📱 ConversationsViewModel: Sent initial message")
        }

        return response.conversationId.rawValue
    }

    func loadConversations() async {
        if UITestConfig.mockDataEnabled {
            conversations = UITestMockData.conversations()
            error = nil
            hasMore = false
            isLoadingMore = false
            rebuildInboxItems()
            isLoading = false
            return
        }
        guard await convex.waitUntilAuthenticated() else {
            print("📱 ConversationsViewModel: Auth timeout")
            error = "Authentication timeout"
            isLoading = false
            return
        }

        // Get team ID first
        guard let teamId = await getFirstTeamId() else {
            print("📱 ConversationsViewModel: Failed to get team ID")
            error = "Failed to get team"
            isLoading = false
            return
        }

        self.teamId = teamId
        self.firstPage = []
        self.extraConversations = []
        self.continueCursor = nil
        self.lastLoadedCursor = nil
        self.hasMore = false
        self.isLoadingMore = false
        NSLog("📱 ConversationsViewModel: Using team \(teamId)")
        workspaceSyncService?.connect(teamID: teamId)

        // Subscribe to conversations (paginated response)
        let paginationOpts = ConversationsListPagedWithLatestArgsPaginationOpts(
            id: nil,
            endCursor: nil,
            maximumRowsRead: nil,
            maximumBytesRead: nil,
            numItems: pageSize,
            cursor: nil
        )
        let listArgs = ConversationsListPagedWithLatestArgs(
            includeArchived: nil,
            teamSlugOrId: teamId,
            paginationOpts: paginationOpts,
            scope: .all
        )
        convex.client
            .subscribe(
                to: "conversations:listPagedWithLatest",
                with: listArgs.asDictionary(),
                yielding: ConversationsPage.self
            )
            .receive(on: DispatchQueue.main)
            .sink(
                receiveCompletion: { [weak self] completion in
                    if case .failure(let err) = completion {
                        print("📱 ConversationsViewModel: Subscription error: \(err)")
                        self?.error = err.localizedDescription
                        self?.isLoading = false
                    }
                },
                receiveValue: { [weak self] page in
                    guard let self else { return }
                    NSLog("📱 ConversationsViewModel: Received \(page.page.count) conversations (isDone: \(page.isDone), cursor: \(page.continueCursor))")
                    self.firstPage = page.page
                    if self.extraConversations.isEmpty && self.lastLoadedCursor == nil {
                        self.continueCursor = page.isDone ? nil : page.continueCursor
                        self.hasMore = !page.isDone
                    }
                    self.conversations = self.mergeConversations(firstPage: page.page)
                    self.rebuildInboxItems()
                    self.isLoading = false
                }
            )
            .store(in: &cancellables)
    }

    func loadMore() async {
        guard !isLoadingMore, hasMore else {
            return
        }
        guard let teamId else {
            return
        }
        guard let cursor = continueCursor else {
            hasMore = false
            return
        }
        if cursor == lastLoadedCursor {
            NSLog("📱 ConversationsViewModel: Skipping load; cursor already loaded")
            return
        }

        isLoadingMore = true
        defer { isLoadingMore = false }

        do {
            NSLog("📱 ConversationsViewModel: Loading more (cursor: \(cursor))")
            let paginationOpts = ConversationsListPagedWithLatestArgsPaginationOpts(
                id: nil,
                endCursor: nil,
                maximumRowsRead: nil,
                maximumBytesRead: nil,
                numItems: pageSize,
                cursor: cursor
            )
            let listArgs = ConversationsListPagedWithLatestArgs(
                includeArchived: nil,
                teamSlugOrId: teamId,
                paginationOpts: paginationOpts,
                scope: .all
            )

            let page = try await fetchPage(args: listArgs)
            NSLog("📱 ConversationsViewModel: Load more received \(page.page.count) conversations")
            let appendedCount = appendExtraConversations(page.page)
            lastLoadedCursor = cursor
            continueCursor = page.isDone ? nil : page.continueCursor
            hasMore = !page.isDone
            if appendedCount == 0 {
                NSLog("📱 ConversationsViewModel: No new conversations appended; stopping pagination")
                hasMore = false
            }
            conversations = mergeConversations(firstPage: firstPage)
            rebuildInboxItems()
        } catch {
            NSLog("📱 ConversationsViewModel: Load more failed: \(error)")
        }
    }

    func prewarmSandbox() async {
        if let lastPrewarmAt, Date().timeIntervalSince(lastPrewarmAt) < 10 {
            return
        }
        lastPrewarmAt = Date()

        guard convex.isAuthenticated else {
            return
        }

        var teamId = self.teamId
        if teamId == nil {
            teamId = await getFirstTeamId()
        }
        guard let teamId else {
            return
        }

        do {
            let args = AcpPrewarmSandboxArgs(teamSlugOrId: teamId)
            let _: AcpPrewarmSandboxReturn = try await convex.client.action(
                "acp:prewarmSandbox",
                with: args.asDictionary()
            )
        } catch {
            print("📱 ConversationsViewModel: Prewarm failed: \(error)")
        }
    }

    func togglePin(_ conversation: ConvexConversation) async {
        guard let teamId else { return }
        let conversationId = conversation._id
        let isPinned = conversation.conversation.pinned == true

        updateConversation(conversationId.rawValue) { entry in
            let updatedConversation = entry.conversation.updating(
                pinned: !isPinned,
                isArchived: nil
            )
            return entry.updating(conversation: updatedConversation)
        }

        do {
            if isPinned {
                let args = ConversationsUnpinArgs(
                    conversationId: conversationId,
                    teamSlugOrId: teamId
                )
                let _: ConversationsUnpinReturn = try await convex.client.mutation(
                    "conversations:unpin",
                    with: args.asDictionary()
                )
            } else {
                let args = ConversationsPinArgs(
                    conversationId: conversationId,
                    teamSlugOrId: teamId
                )
                let _: ConversationsPinReturn = try await convex.client.mutation(
                    "conversations:pin",
                    with: args.asDictionary()
                )
            }
        } catch {
            updateConversation(conversationId.rawValue) { entry in
                let updatedConversation = entry.conversation.updating(
                    pinned: isPinned,
                    isArchived: nil
                )
                return entry.updating(conversation: updatedConversation)
            }
            NSLog("📱 ConversationsViewModel: Failed to toggle pin: \(error)")
        }
    }

    func deleteConversation(_ conversation: ConvexConversation) async {
        guard let teamId else { return }
        let conversationId = conversation._id

        let removed = removeConversation(conversationId.rawValue)
        do {
            let args = ConversationsRemoveArgs(
                conversationId: conversationId,
                teamSlugOrId: teamId
            )
            let _: ConversationsRemoveReturn = try await convex.client.mutation(
                "conversations:remove",
                with: args.asDictionary()
            )
        } catch {
            if let removed {
                restoreConversation(removed)
            }
            NSLog("📱 ConversationsViewModel: Failed to delete conversation: \(error)")
        }
    }

    func markRead(_ conversation: ConvexConversation) async {
        guard let teamId else { return }
        let conversationId = conversation._id
        let lastReadAt = conversation.latestMessageAt
        let wasUnread = conversation.unread
        let previousLastReadAt = conversation.lastReadAt
        let wasManualUnread = ConversationReadOverrides.isManualUnread(conversationId.rawValue)

        ConversationReadOverrides.clearManualUnread(conversationId.rawValue)
        updateConversation(conversationId.rawValue) { entry in
            entry.updating(unread: false, lastReadAt: lastReadAt)
        }

        do {
            let args = ConversationReadsMarkReadArgs(
                lastReadAt: lastReadAt,
                conversationId: conversationId,
                teamSlugOrId: teamId
            )
            let _: ConversationReadsMarkReadReturn = try await convex.client.mutation(
                "conversationReads:markRead",
                with: args.asDictionary()
            )
        } catch {
            if wasManualUnread {
                ConversationReadOverrides.markManualUnread(conversationId.rawValue)
            } else {
                ConversationReadOverrides.clearManualUnread(conversationId.rawValue)
            }
            updateConversation(conversationId.rawValue) { entry in
                entry.updating(unread: wasUnread, lastReadAt: previousLastReadAt)
            }
            NSLog("📱 ConversationsViewModel: Failed to mark read: \(error)")
        }
    }

    func markUnread(_ conversation: ConvexConversation) async {
        guard let teamId else { return }
        let conversationId = conversation._id
        let wasUnread = conversation.unread
        let previousLastReadAt = conversation.lastReadAt
        let wasManualUnread = ConversationReadOverrides.isManualUnread(conversationId.rawValue)

        ConversationReadOverrides.markManualUnread(conversationId.rawValue)
        updateConversation(conversationId.rawValue) { entry in
            entry.updating(unread: true, lastReadAt: 0)
        }

        do {
            let args = ConversationReadsMarkUnreadArgs(
                conversationId: conversationId,
                teamSlugOrId: teamId
            )
            let _: ConversationReadsMarkUnreadReturn = try await convex.client.mutation(
                "conversationReads:markUnread",
                with: args.asDictionary()
            )
        } catch {
            if wasManualUnread {
                ConversationReadOverrides.markManualUnread(conversationId.rawValue)
            } else {
                ConversationReadOverrides.clearManualUnread(conversationId.rawValue)
            }
            updateConversation(conversationId.rawValue) { entry in
                entry.updating(unread: wasUnread, lastReadAt: previousLastReadAt)
            }
            NSLog("📱 ConversationsViewModel: Failed to mark unread: \(error)")
        }
    }

    private func updateAppBadge() {
        let unreadCount = inboxItems.filter(\.isUnread).count
        if unreadCount == lastBadgeCount {
            return
        }
        lastBadgeCount = unreadCount
        UNUserNotificationCenter.current().setBadgeCount(unreadCount) { error in
            if let error {
                NSLog("📱 ConversationsViewModel: Failed to set badge count: \(error)")
            }
        }
    }

    private func updateConversation(
        _ conversationId: String,
        transform: (ConvexConversation) -> ConvexConversation
    ) {
        firstPage = firstPage.map { entry in
            entry.id == conversationId ? transform(entry) : entry
        }
        extraConversations = extraConversations.map { entry in
            entry.id == conversationId ? transform(entry) : entry
        }
        conversations = mergeConversations(firstPage: firstPage)
        rebuildInboxItems()
    }

    private func removeConversation(_ conversationId: String) -> RemovedConversation? {
        var removed: RemovedConversation?
        if let index = firstPage.firstIndex(where: { $0.id == conversationId }) {
            let entry = firstPage.remove(at: index)
            removed = RemovedConversation(entry: entry, source: .firstPage, index: index)
        }
        if let index = extraConversations.firstIndex(where: { $0.id == conversationId }) {
            let entry = extraConversations.remove(at: index)
            if removed == nil {
                removed = RemovedConversation(entry: entry, source: .extra, index: index)
            }
        }
        conversations = mergeConversations(firstPage: firstPage)
        rebuildInboxItems()
        return removed
    }

    private func restoreConversation(_ removed: RemovedConversation) {
        let conversationId = removed.entry.id
        switch removed.source {
        case .firstPage:
            if firstPage.contains(where: { $0.id == conversationId }) {
                return
            }
            if removed.index <= firstPage.count {
                firstPage.insert(removed.entry, at: removed.index)
            } else {
                firstPage.append(removed.entry)
            }
        case .extra:
            if extraConversations.contains(where: { $0.id == conversationId }) {
                return
            }
            if removed.index <= extraConversations.count {
                extraConversations.insert(removed.entry, at: removed.index)
            } else {
                extraConversations.append(removed.entry)
            }
        }
        conversations = mergeConversations(firstPage: firstPage)
        rebuildInboxItems()
    }

    private func getFirstTeamId() async -> String? {
        return await withCheckedContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = convex.client
                .subscribe(to: "teams:listTeamMemberships", yielding: TeamsListTeamMembershipsReturn.self)
                .first()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure = completion {
                            continuation.resume(returning: nil)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { memberships in
                        // Use Stack Auth UUID (teamId) for queries
                        if let first = memberships.first {
                            print("📱 ConversationsViewModel: Team '\(first.team.displayName ?? "?")' teamId: \(first.teamId)")
                        }
                        continuation.resume(returning: memberships.first?.teamId)
                    }
                )
        }
    }

    private func fetchPage(args: ConversationsListPagedWithLatestArgs) async throws -> ConversationsListPagedWithLatestReturn {
        try await withCheckedThrowingContinuation { continuation in
            var cancellable: AnyCancellable?
            cancellable = convex.client
                .subscribe(
                    to: "conversations:listPagedWithLatest",
                    with: args.asDictionary(),
                    yielding: ConversationsPage.self
                )
                .first()
                .receive(on: DispatchQueue.main)
                .sink(
                    receiveCompletion: { completion in
                        if case .failure(let error) = completion {
                            print("📱 ConversationsViewModel: Page fetch error: \(error)")
                            continuation.resume(throwing: error)
                        }
                        cancellable?.cancel()
                    },
                    receiveValue: { page in
                        continuation.resume(returning: page)
                    }
                )
        }
    }

    private func appendExtraConversations(_ page: [ConvexConversation]) -> Int {
        let existingIds = Set(extraConversations.map(\.id))
        let firstPageIds = Set(firstPage.map(\.id))
        let newItems = page.filter { !existingIds.contains($0.id) && !firstPageIds.contains($0.id) }
        extraConversations.append(contentsOf: newItems)
        return newItems.count
    }

    private func mergeConversations(firstPage: [ConvexConversation]) -> [ConvexConversation] {
        let firstIds = Set(firstPage.map(\.id))
        let extras = extraConversations.filter { !firstIds.contains($0.id) }
        return firstPage + extras
    }

    private func rebuildInboxItems(persist: Bool = true) {
        inboxItems = UnifiedInboxSyncService.merge(
            conversations: conversations,
            workspaceItems: workspaceInboxItems
        )
        if persist {
            persistInboxItems()
        }
        updateAppBadge()
    }

    private func persistInboxItems() {
        guard let inboxCacheRepository else { return }
        do {
            try inboxCacheRepository.save(inboxItems)
        } catch {
            NSLog("📱 ConversationsViewModel: Failed to persist inbox cache: \(error)")
        }
    }

    private func loadCachedState() {
        guard let inboxCacheRepository else { return }
        do {
            let cachedItems = try inboxCacheRepository.load()
            workspaceInboxItems = cachedItems.filter { $0.kind == .workspace }
            if cachedItems.isEmpty {
                rebuildInboxItems(persist: false)
            } else {
                inboxItems = cachedItems
                updateAppBadge()
            }

            if !inboxItems.isEmpty {
                isLoading = false
            }

            analyticsTracker?.capture(
                event: .iosGRDBBootCompleted,
                properties: MobileAnalyticsProperties(
                    source: "cache_boot",
                    cacheAgeMs: Self.cacheAgeMs(for: cachedItems),
                    workspaceCount: workspaceInboxItems.count,
                    unreadCount: workspaceInboxItems.reduce(0) { $0 + $1.unreadCount }
                )
            )
        } catch {
            NSLog("📱 ConversationsViewModel: Failed to load inbox cache: \(error)")
        }
    }

    private func observeWorkspaceSync() {
        workspaceSyncService?.workspaceItemsPublisher
            .receive(on: DispatchQueue.main)
            .sink { [weak self] items in
                guard let self else { return }
                self.workspaceInboxItems = items
                self.rebuildInboxItems()
                self.isLoading = false
            }
            .store(in: &cancellables)
    }

    func conversation(for item: UnifiedInboxItem) -> ConvexConversation? {
        guard let conversationID = item.conversationID else { return nil }
        return conversations.first { $0.id == conversationID }
    }

    func workspaceItem(workspaceID: String, machineID: String?) -> UnifiedInboxItem? {
        inboxItems.first { item in
            guard item.kind == .workspace else { return false }
            guard item.workspaceID == workspaceID else { return false }
            if let machineID {
                return item.machineID == machineID
            }
            return true
        }
    }

    func markWorkspaceReadLocally(workspaceID: String) {
        workspaceInboxItems = workspaceInboxItems.map { item in
            guard item.workspaceID == workspaceID else { return item }
            return UnifiedInboxItem(
                kind: item.kind,
                conversationID: item.conversationID,
                workspaceID: item.workspaceID,
                machineID: item.machineID,
                teamID: item.teamID,
                title: item.title,
                preview: item.preview,
                unreadCount: 0,
                sortDate: item.sortDate,
                accessoryLabel: item.accessoryLabel,
                symbolName: item.symbolName,
                tmuxSessionName: item.tmuxSessionName,
                latestEventSeq: item.latestEventSeq,
                lastReadEventSeq: item.latestEventSeq ?? item.lastReadEventSeq,
                tailscaleHostname: item.tailscaleHostname,
                tailscaleIPs: item.tailscaleIPs
            )
        }
        rebuildInboxItems()
    }

    func receiveConversationPageForTesting(_ page: [ConvexConversation]) {
        firstPage = page
        extraConversations = []
        conversations = mergeConversations(firstPage: page)
        rebuildInboxItems()
        isLoading = false
    }

    func replaceWorkspaceRowsForTesting(_ rows: [AppDatabase.WorkspaceInboxRow]) {
        workspaceInboxItems = rows.map(UnifiedInboxItem.init(workspaceRow:))
        rebuildInboxItems()
    }

    nonisolated private static func makeDefaultInboxCacheRepository() -> InboxCacheRepository? {
        do {
            return InboxCacheRepository(database: try AppDatabase.live())
        } catch {
            NSLog("📱 ConversationsViewModel: Failed to open default inbox cache: \(error)")
            return nil
        }
    }

    nonisolated private static func cacheAgeMs(for items: [UnifiedInboxItem]) -> Int {
        guard let newestDate = items.map(\.sortDate).max() else {
            return 0
        }
        return max(0, Int(Date().timeIntervalSince(newestDate) * 1000))
    }
}

// MARK: - Create Conversation Types

enum ConversationError: LocalizedError {
    case noTeam
    case createFailed(String)

    var errorDescription: String? {
        switch self {
        case .noTeam:
            return "No team available"
        case .createFailed(let message):
            return "Failed to create conversation: \(message)"
        }
    }
}
