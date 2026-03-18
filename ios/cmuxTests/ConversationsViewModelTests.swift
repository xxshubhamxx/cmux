import Combine
import XCTest
@testable import cmux_DEV

@MainActor
final class ConversationsViewModelTests: XCTestCase {
    func testWorkspaceRowsAppearAheadOfOlderConversations() throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)
        let viewModel = ConversationsViewModel(
            autoLoad: false,
            inboxCacheRepository: inboxCache
        )

        viewModel.receiveConversationPageForTesting([
            .fixture(
                id: "conversation_123",
                title: "Fix Tailscale attach",
                preview: "agent replied",
                unread: false,
                updatedAt: 10_000
            )
        ])
        viewModel.replaceWorkspaceRowsForTesting([
            .fixture(
                workspaceID: "workspace_123",
                title: "orb / cmux",
                preview: "feature/dogfood-inbox",
                latestEventSeq: 4,
                lastReadEventSeq: 1,
                lastActivityAt: Date(timeIntervalSince1970: 20)
            )
        ])

        XCTAssertEqual(viewModel.inboxItems.map(\.kind), [.workspace, .conversation])
        XCTAssertEqual(try inboxCache.load().first?.workspaceID, "workspace_123")
    }

    func testWorkspaceSyncUpdatesInboxAndLocalReadState() async throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)
        let workspaceSyncService = StubWorkspaceSyncService()
        let viewModel = ConversationsViewModel(
            autoLoad: false,
            inboxCacheRepository: inboxCache,
            workspaceSyncService: workspaceSyncService
        )

        viewModel.receiveConversationPageForTesting([
            .fixture(
                id: "conversation_123",
                title: "Fix Tailscale attach",
                preview: "agent replied",
                unread: false,
                updatedAt: 10_000
            )
        ])

        workspaceSyncService.send([
            UnifiedInboxItem(
                kind: .workspace,
                workspaceID: "workspace_123",
                machineID: "machine_123",
                teamID: "team_123",
                title: "orb / cmux",
                preview: "preview 1",
                unreadCount: 1,
                sortDate: Date(timeIntervalSince1970: 20),
                accessoryLabel: "Mac Mini",
                symbolName: "terminal",
                tmuxSessionName: "cmux-nightly",
                latestEventSeq: 4,
                lastReadEventSeq: 2,
                tailscaleHostname: "cmux-macmini.tail",
                tailscaleIPs: ["100.64.0.10"]
            )
        ])

        try await waitForCondition {
            viewModel.inboxItems.contains(where: { $0.workspaceID == "workspace_123" })
        }

        XCTAssertEqual(viewModel.inboxItems.map(\.kind), [.workspace, .conversation])
        XCTAssertEqual(try inboxCache.load().first?.workspaceID, "workspace_123")

        viewModel.markWorkspaceReadLocally(workspaceID: "workspace_123")

        let cachedWorkspace = try XCTUnwrap(
            inboxCache.load().first(where: { $0.workspaceID == "workspace_123" })
        )
        XCTAssertEqual(cachedWorkspace.unreadCount, 0)
        XCTAssertEqual(cachedWorkspace.lastReadEventSeq, 4)
    }

    func testCachedBootTracksAnalyticsWithWorkspaceCounts() throws {
        let database = try AppDatabase.inMemory()
        let inboxCache = InboxCacheRepository(database: database)
        try inboxCache.save([
            UnifiedInboxItem(
                kind: .workspace,
                workspaceID: "workspace_123",
                machineID: "machine_123",
                teamID: "team_123",
                title: "orb / cmux",
                preview: "preview 1",
                unreadCount: 3,
                sortDate: Date(),
                accessoryLabel: "Mac Mini",
                symbolName: "terminal",
                tmuxSessionName: "cmux-nightly",
                latestEventSeq: 5,
                lastReadEventSeq: 2,
                tailscaleHostname: "cmux-macmini.tail",
                tailscaleIPs: ["100.64.0.10"]
            )
        ])
        let analyticsTracker = StubConversationsAnalyticsTracker()

        _ = ConversationsViewModel(
            autoLoad: false,
            inboxCacheRepository: inboxCache,
            analyticsTracker: analyticsTracker
        )

        XCTAssertEqual(analyticsTracker.events.count, 1)
        XCTAssertEqual(analyticsTracker.events.first?.event, .iosGRDBBootCompleted)
        XCTAssertEqual(analyticsTracker.events.first?.properties.source, "cache_boot")
        XCTAssertEqual(analyticsTracker.events.first?.properties.workspaceCount, 1)
        XCTAssertEqual(analyticsTracker.events.first?.properties.unreadCount, 3)
    }
}

@MainActor
private final class StubWorkspaceSyncService: UnifiedInboxWorkspaceSyncing {
    private let subject = CurrentValueSubject<[UnifiedInboxItem], Never>([])

    var workspaceItemsPublisher: AnyPublisher<[UnifiedInboxItem], Never> {
        subject.eraseToAnyPublisher()
    }

    func connect(teamID: String) {}

    func send(_ items: [UnifiedInboxItem]) {
        subject.send(items)
    }
}

@MainActor
private final class StubConversationsAnalyticsTracker: MobileAnalyticsTracking {
    private(set) var events: [(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties)] = []

    func capture(event: MobileAnalyticsEventName, properties: MobileAnalyticsProperties) {
        events.append((event, properties))
    }
}

@MainActor
private func waitForCondition(
    timeout: Duration = .seconds(1),
    pollInterval: Duration = .milliseconds(10),
    _ condition: @escaping @MainActor () -> Bool
) async throws {
    let clock = ContinuousClock()
    let deadline = clock.now + timeout
    while clock.now < deadline {
        if condition() {
            return
        }
        try await Task.sleep(for: pollInterval)
    }
    XCTFail("Timed out waiting for condition.")
}
