import Foundation
import SwiftUI
import Observation

struct WorkspacePaneID: Hashable, Codable, Sendable, CustomStringConvertible {
    let id: UUID

    init() {
        self.id = UUID()
    }

    init(id: UUID) {
        self.id = id
    }

    var description: String {
        id.uuidString
    }
}

typealias PaneID = WorkspacePaneID

struct WorkspaceTabID: Hashable, Codable, Sendable, CustomStringConvertible {
    private let rawValue: UUID

    init() {
        self.rawValue = UUID()
    }

    init(uuid: UUID) {
        self.rawValue = uuid
    }

    var uuid: UUID {
        rawValue
    }

    var description: String {
        rawValue.uuidString
    }
}

typealias TabID = WorkspaceTabID

enum WorkspaceSplitOrientation: String, Codable, Sendable {
    case horizontal
    case vertical
}

typealias SplitOrientation = WorkspaceSplitOrientation

enum WorkspaceNavigationDirection: String, Codable, Sendable {
    case left
    case right
    case up
    case down
}

typealias NavigationDirection = WorkspaceNavigationDirection

enum WorkspaceTabContextAction: String, CaseIterable, Sendable {
    case rename
    case clearName
    case closeToLeft
    case closeToRight
    case closeOthers
    case move
    case moveToLeftPane
    case moveToRightPane
    case newTerminalToRight
    case newBrowserToRight
    case reload
    case duplicate
    case togglePin
    case markAsRead
    case markAsUnread
    case toggleZoom
}

typealias TabContextAction = WorkspaceTabContextAction

struct WorkspacePixelRect: Codable, Sendable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    init(from cgRect: CGRect) {
        self.x = Double(cgRect.origin.x)
        self.y = Double(cgRect.origin.y)
        self.width = Double(cgRect.size.width)
        self.height = Double(cgRect.size.height)
    }
}

typealias PixelRect = WorkspacePixelRect

struct PaneGeometry: Codable, Sendable, Equatable {
    let paneId: String
    let frame: PixelRect
    let selectedTabId: String?
    let tabIds: [String]
}

struct LayoutSnapshot: Codable, Sendable, Equatable {
    let containerFrame: PixelRect
    let panes: [PaneGeometry]
    let focusedPaneId: String?
    let timestamp: TimeInterval
}

struct ExternalTab: Codable, Sendable, Equatable {
    let id: String
    let title: String
}

struct ExternalPaneNode: Codable, Sendable, Equatable {
    let id: String
    let frame: PixelRect
    let tabs: [ExternalTab]
    let selectedTabId: String?
}

struct ExternalSplitNode: Codable, Sendable, Equatable {
    let id: String
    let orientation: String
    let dividerPosition: Double
    let first: ExternalTreeNode
    let second: ExternalTreeNode
}

indirect enum ExternalTreeNode: Codable, Sendable, Equatable {
    case pane(ExternalPaneNode)
    case split(ExternalSplitNode)

    private enum CodingKeys: String, CodingKey {
        case type
        case pane
        case split
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(String.self, forKey: .type) {
        case "pane":
            self = .pane(try container.decode(ExternalPaneNode.self, forKey: .pane))
        case "split":
            self = .split(try container.decode(ExternalSplitNode.self, forKey: .split))
        default:
            throw DecodingError.dataCorruptedError(
                forKey: .type,
                in: container,
                debugDescription: "Unsupported external tree node"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .pane(let pane):
            try container.encode("pane", forKey: .type)
            try container.encode(pane, forKey: .pane)
        case .split(let split):
            try container.encode("split", forKey: .type)
            try container.encode(split, forKey: .split)
        }
    }
}

enum WorkspaceDropZone: Equatable, Sendable {
    case center
    case left
    case right
    case top
    case bottom

    var orientation: SplitOrientation? {
        switch self {
        case .left, .right:
            return .horizontal
        case .top, .bottom:
            return .vertical
        case .center:
            return nil
        }
    }

    var insertFirst: Bool {
        switch self {
        case .left, .top:
            return true
        case .center, .right, .bottom:
            return false
        }
    }
}

typealias DropZone = WorkspaceDropZone

private struct PaneDropZoneEnvironmentKey: EnvironmentKey {
    static let defaultValue: DropZone? = nil
}

extension EnvironmentValues {
    var paneDropZone: DropZone? {
        get { self[PaneDropZoneEnvironmentKey.self] }
        set { self[PaneDropZoneEnvironmentKey.self] = newValue }
    }
}

enum ContentViewLifecycle: Sendable {
    case recreateOnSwitch
    case keepAllAlive
}

enum NewTabPosition: Sendable {
    case current
    case end
}

struct BonsplitConfiguration: Sendable {
    var allowSplits: Bool
    var allowCloseTabs: Bool
    var allowCloseLastPane: Bool
    var allowTabReordering: Bool
    var allowCrossPaneTabMove: Bool
    var autoCloseEmptyPanes: Bool
    var contentViewLifecycle: ContentViewLifecycle
    var newTabPosition: NewTabPosition
    var appearance: Appearance

    static let `default` = BonsplitConfiguration()

    init(
        allowSplits: Bool = true,
        allowCloseTabs: Bool = true,
        allowCloseLastPane: Bool = false,
        allowTabReordering: Bool = true,
        allowCrossPaneTabMove: Bool = true,
        autoCloseEmptyPanes: Bool = true,
        contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch,
        newTabPosition: NewTabPosition = .current,
        appearance: Appearance = .default
    ) {
        self.allowSplits = allowSplits
        self.allowCloseTabs = allowCloseTabs
        self.allowCloseLastPane = allowCloseLastPane
        self.allowTabReordering = allowTabReordering
        self.allowCrossPaneTabMove = allowCrossPaneTabMove
        self.autoCloseEmptyPanes = autoCloseEmptyPanes
        self.contentViewLifecycle = contentViewLifecycle
        self.newTabPosition = newTabPosition
        self.appearance = appearance
    }

    struct SplitButtonTooltips: Sendable, Equatable {
        var newTerminal: String
        var newBrowser: String
        var splitRight: String
        var splitDown: String

        static let `default` = SplitButtonTooltips()

        init(
            newTerminal: String = "New Terminal",
            newBrowser: String = "New Browser",
            splitRight: String = "Split Right",
            splitDown: String = "Split Down"
        ) {
            self.newTerminal = newTerminal
            self.newBrowser = newBrowser
            self.splitRight = splitRight
            self.splitDown = splitDown
        }
    }

    struct Appearance: Sendable {
        struct ChromeColors: Sendable {
            var backgroundHex: String?
            var borderHex: String?

            init(backgroundHex: String? = nil, borderHex: String? = nil) {
                self.backgroundHex = backgroundHex
                self.borderHex = borderHex
            }
        }

        var tabBarHeight: CGFloat
        var tabMinWidth: CGFloat
        var tabMaxWidth: CGFloat
        var tabSpacing: CGFloat
        var minimumPaneWidth: CGFloat
        var minimumPaneHeight: CGFloat
        var showSplitButtons: Bool
        var splitButtonsOnHover: Bool
        var tabBarLeadingInset: CGFloat
        var splitButtonTooltips: SplitButtonTooltips
        var animationDuration: Double
        var enableAnimations: Bool
        var chromeColors: ChromeColors

        static let `default` = Appearance()

        init(
            tabBarHeight: CGFloat = 30,
            tabMinWidth: CGFloat = 48,
            tabMaxWidth: CGFloat = 220,
            tabSpacing: CGFloat = 0,
            minimumPaneWidth: CGFloat = 100,
            minimumPaneHeight: CGFloat = 100,
            showSplitButtons: Bool = true,
            splitButtonsOnHover: Bool = false,
            tabBarLeadingInset: CGFloat = 0,
            splitButtonTooltips: SplitButtonTooltips = .default,
            animationDuration: Double = 0.15,
            enableAnimations: Bool = false,
            chromeColors: ChromeColors = .init()
        ) {
            self.tabBarHeight = tabBarHeight
            self.tabMinWidth = tabMinWidth
            self.tabMaxWidth = tabMaxWidth
            self.tabSpacing = tabSpacing
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.showSplitButtons = showSplitButtons
            self.splitButtonsOnHover = splitButtonsOnHover
            self.tabBarLeadingInset = tabBarLeadingInset
            self.splitButtonTooltips = splitButtonTooltips
            self.animationDuration = animationDuration
            self.enableAnimations = enableAnimations
            self.chromeColors = chromeColors
        }
    }
}

enum Bonsplit {
    struct Tab: Identifiable, Hashable, Sendable {
        var id: TabID
        var title: String
        var hasCustomTitle: Bool
        var icon: String?
        var iconImageData: Data?
        var kind: String?
        var isDirty: Bool
        var showsNotificationBadge: Bool
        var isLoading: Bool
        var isPinned: Bool

        init(
            id: TabID = TabID(),
            title: String,
            hasCustomTitle: Bool = false,
            icon: String? = nil,
            iconImageData: Data? = nil,
            kind: String? = nil,
            isDirty: Bool = false,
            showsNotificationBadge: Bool = false,
            isLoading: Bool = false,
            isPinned: Bool = false
        ) {
            self.id = id
            self.title = title
            self.hasCustomTitle = hasCustomTitle
            self.icon = icon
            self.iconImageData = iconImageData
            self.kind = kind
            self.isDirty = isDirty
            self.showsNotificationBadge = showsNotificationBadge
            self.isLoading = isLoading
            self.isPinned = isPinned
        }
    }
}

protocol BonsplitDelegate: AnyObject {
    func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool
    func splitTabBar(_ controller: BonsplitController, didCreateTab tab: Bonsplit.Tab, inPane pane: PaneID)
    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID)
    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID)
    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID)
    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool
    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool
    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation)
    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID)
    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID)
    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID)
    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID)
    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot)
    func splitTabBar(_ controller: BonsplitController, shouldNotifyDuringDrag: Bool) -> Bool
}

extension BonsplitDelegate {
    func splitTabBar(_ controller: BonsplitController, shouldCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool { true }
    func splitTabBar(_ controller: BonsplitController, shouldCloseTab tab: Bonsplit.Tab, inPane pane: PaneID) -> Bool { true }
    func splitTabBar(_ controller: BonsplitController, didCreateTab tab: Bonsplit.Tab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didCloseTab tabId: TabID, fromPane pane: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didSelectTab tab: Bonsplit.Tab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didMoveTab tab: Bonsplit.Tab, fromPane source: PaneID, toPane destination: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, shouldSplitPane pane: PaneID, orientation: SplitOrientation) -> Bool { true }
    func splitTabBar(_ controller: BonsplitController, shouldClosePane pane: PaneID) -> Bool { true }
    func splitTabBar(_ controller: BonsplitController, didSplitPane originalPane: PaneID, newPane: PaneID, orientation: SplitOrientation) {}
    func splitTabBar(_ controller: BonsplitController, didClosePane paneId: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didFocusPane pane: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didRequestNewTab kind: String, inPane pane: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didRequestTabContextAction action: TabContextAction, for tab: Bonsplit.Tab, inPane pane: PaneID) {}
    func splitTabBar(_ controller: BonsplitController, didChangeGeometry snapshot: LayoutSnapshot) {}
    func splitTabBar(_ controller: BonsplitController, shouldNotifyDuringDrag: Bool) -> Bool { false }
}


extension WorkspaceTabID {
    init(id: UUID) {
        self.rawValue = id
    }

    var id: UUID {
        rawValue
    }
}

extension WorkspaceDropZone {
    var insertsFirst: Bool {
        insertFirst
    }
}

extension Bonsplit.Tab {
    init(from tabItem: TabItem) {
        self.init(
            id: TabID(id: tabItem.id),
            title: tabItem.title,
            hasCustomTitle: tabItem.hasCustomTitle,
            icon: tabItem.icon,
            iconImageData: tabItem.iconImageData,
            kind: tabItem.kind,
            isDirty: tabItem.isDirty,
            showsNotificationBadge: tabItem.showsNotificationBadge,
            isLoading: tabItem.isLoading,
            isPinned: tabItem.isPinned
        )
    }
}

#if DEBUG
enum BonsplitDebugCounters {
    private(set) static var arrangedSubviewUnderflowCount: Int = 0

    static func reset() {
        arrangedSubviewUnderflowCount = 0
    }

    static func recordArrangedSubviewUnderflow() {
        arrangedSubviewUnderflowCount += 1
    }
}
#else
enum BonsplitDebugCounters {
    static let arrangedSubviewUnderflowCount: Int = 0

    static func reset() {}
    static func recordArrangedSubviewUnderflow() {}
}
#endif

func dlog(_ message: String) {
    NSLog("%@", message)
}
import AppKit
import SwiftUI

private struct SafeTooltipModifier: ViewModifier {
    let text: String?

    func body(content: Content) -> some View {
        content.background {
            SafeTooltipViewRepresentable(text: text)
                .allowsHitTesting(false)
        }
    }
}

private struct SafeTooltipViewRepresentable: NSViewRepresentable {
    let text: String?

    func makeNSView(context: Context) -> SafeTooltipView {
        let view = SafeTooltipView()
        view.updateTooltip(text)
        return view
    }

    func updateNSView(_ nsView: SafeTooltipView, context: Context) {
        nsView.updateTooltip(text)
    }

    static func dismantleNSView(_ nsView: SafeTooltipView, coordinator: ()) {
        nsView.invalidateTooltip()
    }
}

private final class SafeTooltipView: NSView {
    private var tooltipTag: NSView.ToolTipTag?
    private var registeredBounds: NSRect = .zero
    private var registeredText: String?
    private var tooltipText: String?

    override var isOpaque: Bool { false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        nil
    }

    override func layout() {
        super.layout()
        refreshTooltipRegistration()
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshTooltipRegistration()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil {
            invalidateTooltip()
        } else {
            refreshTooltipRegistration()
        }
    }

    override func viewDidMoveToSuperview() {
        super.viewDidMoveToSuperview()
        if superview == nil {
            invalidateTooltip()
        } else {
            refreshTooltipRegistration()
        }
    }

    func updateTooltip(_ text: String?) {
        let normalized = text?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        tooltipText = normalized?.isEmpty == false ? normalized : nil
        refreshTooltipRegistration()
    }

    func invalidateTooltip() {
        if let tooltipTag {
            removeToolTip(tooltipTag)
            self.tooltipTag = nil
        }
        registeredBounds = .zero
        registeredText = nil
    }

    private func refreshTooltipRegistration() {
        guard let tooltipText,
              window != nil,
              superview != nil else {
            invalidateTooltip()
            return
        }

        let nextBounds = bounds.standardized.integral
        guard nextBounds.width > 0, nextBounds.height > 0 else {
            invalidateTooltip()
            return
        }

        if tooltipTag != nil,
           nextBounds == registeredBounds,
           tooltipText == registeredText {
            return
        }

        invalidateTooltip()
        tooltipTag = addToolTip(nextBounds, owner: self, userData: nil)
        registeredBounds = nextBounds
        registeredText = tooltipText
    }

    @objc
    func view(
        _ view: NSView,
        stringForToolTip tag: NSView.ToolTipTag,
        point: NSPoint,
        userData data: UnsafeMutableRawPointer?
    ) -> String {
        tooltipText ?? ""
    }

    deinit {
        invalidateTooltip()
    }
}

extension View {
    /// Uses an AppKit-backed tooltip host that explicitly unregisters its tooltip
    /// before the view is detached or deallocated.
    func safeHelp(_ text: String?) -> some View {
        modifier(SafeTooltipModifier(text: text))
    }
}

import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Custom UTTypes for tab drag and drop
extension UTType {
    static var tabItem: UTType {
        UTType(exportedAs: "com.splittabbar.tabitem")
    }

    static var tabTransfer: UTType {
        UTType(exportedAs: "com.splittabbar.tabtransfer", conformingTo: .data)
    }
}

/// Represents a single tab in a pane's tab bar (internal representation)
struct TabItem: Identifiable, Hashable, Codable {
    let id: UUID
    var title: String
    var hasCustomTitle: Bool
    var icon: String?
    var iconImageData: Data?
    var kind: String?
    var isDirty: Bool
    var showsNotificationBadge: Bool
    var isLoading: Bool
    var isPinned: Bool

    init(
        id: UUID = UUID(),
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false
    ) {
        self.id = id
        self.title = title
        self.hasCustomTitle = hasCustomTitle
        self.icon = icon
        self.iconImageData = iconImageData
        self.kind = kind
        self.isDirty = isDirty
        self.showsNotificationBadge = showsNotificationBadge
        self.isLoading = isLoading
        self.isPinned = isPinned
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: TabItem, rhs: TabItem) -> Bool {
        lhs.id == rhs.id
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case title
        case hasCustomTitle
        case icon
        case iconImageData
        case kind
        case isDirty
        case showsNotificationBadge
        case isLoading
        case isPinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try c.decode(UUID.self, forKey: .id)
        self.title = try c.decode(String.self, forKey: .title)
        self.hasCustomTitle = try c.decodeIfPresent(Bool.self, forKey: .hasCustomTitle) ?? false
        self.icon = try c.decodeIfPresent(String.self, forKey: .icon)
        self.iconImageData = try c.decodeIfPresent(Data.self, forKey: .iconImageData)
        self.kind = try c.decodeIfPresent(String.self, forKey: .kind)
        self.isDirty = try c.decodeIfPresent(Bool.self, forKey: .isDirty) ?? false
        self.showsNotificationBadge = try c.decodeIfPresent(Bool.self, forKey: .showsNotificationBadge) ?? false
        self.isLoading = try c.decodeIfPresent(Bool.self, forKey: .isLoading) ?? false
        self.isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(title, forKey: .title)
        try c.encode(hasCustomTitle, forKey: .hasCustomTitle)
        try c.encodeIfPresent(icon, forKey: .icon)
        try c.encodeIfPresent(iconImageData, forKey: .iconImageData)
        try c.encodeIfPresent(kind, forKey: .kind)
        try c.encode(isDirty, forKey: .isDirty)
        try c.encode(showsNotificationBadge, forKey: .showsNotificationBadge)
        try c.encode(isLoading, forKey: .isLoading)
        try c.encode(isPinned, forKey: .isPinned)
    }
}

// MARK: - Transferable for Drag & Drop

extension TabItem: Transferable {
    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabItem)
    }
}

/// Transfer data that includes source pane information for cross-pane moves
struct TabTransferData: Codable, Transferable {
    let tab: TabItem
    let sourcePaneId: UUID
    let sourceProcessId: Int32

    init(tab: TabItem, sourcePaneId: UUID, sourceProcessId: Int32 = Int32(ProcessInfo.processInfo.processIdentifier)) {
        self.tab = tab
        self.sourcePaneId = sourcePaneId
        self.sourceProcessId = sourceProcessId
    }

    var isFromCurrentProcess: Bool {
        sourceProcessId == Int32(ProcessInfo.processInfo.processIdentifier)
    }

    private enum CodingKeys: String, CodingKey {
        case tab
        case sourcePaneId
        case sourceProcessId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.tab = try container.decode(TabItem.self, forKey: .tab)
        self.sourcePaneId = try container.decode(UUID.self, forKey: .sourcePaneId)
        // Legacy payloads won't include this field. Treat as foreign process to reject cross-instance drops.
        self.sourceProcessId = try container.decodeIfPresent(Int32.self, forKey: .sourceProcessId) ?? -1
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(tab, forKey: .tab)
        try container.encode(sourcePaneId, forKey: .sourcePaneId)
        try container.encode(sourceProcessId, forKey: .sourceProcessId)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .tabTransfer)
    }
}

import Foundation
import SwiftUI

/// State for a single pane (leaf node in the split tree)
@Observable
final class PaneState: Identifiable {
    let id: PaneID
    var tabs: [TabItem]
    var selectedTabId: UUID?

    init(
        id: PaneID = PaneID(),
        tabs: [TabItem] = [],
        selectedTabId: UUID? = nil
    ) {
        self.id = id
        self.tabs = tabs
        self.selectedTabId = selectedTabId ?? tabs.first?.id
    }

    /// Currently selected tab
    var selectedTab: TabItem? {
        tabs.first { $0.id == selectedTabId }
    }

    /// Select a tab by ID
    func selectTab(_ tabId: UUID) {
        guard tabs.contains(where: { $0.id == tabId }) else { return }
        selectedTabId = tabId
    }

    /// Add a new tab
    func addTab(_ tab: TabItem, select: Bool = true) {
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let insertIndex = tab.isPinned ? pinnedCount : tabs.count
        tabs.insert(tab, at: insertIndex)
        if select {
            selectedTabId = tab.id
        }
    }

    /// Insert a tab at a specific index
    func insertTab(_ tab: TabItem, at index: Int, select: Bool = true) {
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let requested = min(max(0, index), tabs.count)
        let safeIndex: Int
        if tab.isPinned {
            safeIndex = min(requested, pinnedCount)
        } else {
            safeIndex = max(requested, pinnedCount)
        }
        tabs.insert(tab, at: safeIndex)
        if select {
            selectedTabId = tab.id
        }
    }

    /// Remove a tab and return it
    @discardableResult
    func removeTab(_ tabId: UUID) -> TabItem? {
        guard let index = tabs.firstIndex(where: { $0.id == tabId }) else { return nil }
        let tab = tabs.remove(at: index)

        // If we removed the selected tab, keep the index stable when possible:
        // prefer selecting the tab that moved into the removed tab's slot (the "next" tab),
        // and only fall back to selecting the previous tab when we removed the last tab.
        if selectedTabId == tabId {
            if !tabs.isEmpty {
                let newIndex = min(index, max(0, tabs.count - 1))
                selectedTabId = tabs[newIndex].id
            } else {
                selectedTabId = nil
            }
        }

        return tab
    }

    /// Move a tab within this pane
    func moveTab(from sourceIndex: Int, to destinationIndex: Int) {
        guard tabs.indices.contains(sourceIndex),
              destinationIndex >= 0, destinationIndex <= tabs.count else { return }

        // Treat dropping "on itself" or "after itself" as a no-op.
        // This avoids remove/insert churn that can cause brief visual artifacts during drag/drop.
        if destinationIndex == sourceIndex || destinationIndex == sourceIndex + 1 {
            return
        }

        let tab = tabs.remove(at: sourceIndex)
        let requestedIndex = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
        let pinnedCount = tabs.filter { $0.isPinned }.count
        let adjustedIndex: Int
        if tab.isPinned {
            adjustedIndex = min(requestedIndex, pinnedCount)
        } else {
            adjustedIndex = max(requestedIndex, pinnedCount)
        }
        let safeIndex = min(max(0, adjustedIndex), tabs.count)
        tabs.insert(tab, at: safeIndex)
    }
}

extension PaneState: Equatable {
    static func == (lhs: PaneState, rhs: PaneState) -> Bool {
        lhs.id == rhs.id
    }
}

import Foundation

/// Represents a pane with its computed bounds in normalized coordinates (0-1)
struct PaneBounds {
    let paneId: PaneID
    let bounds: CGRect
}

/// Recursive structure representing the split tree
/// - pane: A leaf node containing a single pane with tabs
/// - split: A branch node containing two children with a divider
indirect enum SplitNode: Identifiable, Equatable {
    case pane(PaneState)
    case split(SplitState)

    var id: UUID {
        switch self {
        case .pane(let state):
            return state.id.id
        case .split(let state):
            return state.id
        }
    }

    /// Find a pane by its ID
    func findPane(_ paneId: PaneID) -> PaneState? {
        switch self {
        case .pane(let state):
            return state.id == paneId ? state : nil
        case .split(let state):
            return state.first.findPane(paneId) ?? state.second.findPane(paneId)
        }
    }

    /// Find the leaf node for a pane by ID.
    func findNode(containing paneId: PaneID) -> SplitNode? {
        switch self {
        case .pane(let state):
            return state.id == paneId ? self : nil
        case .split(let state):
            return state.first.findNode(containing: paneId) ?? state.second.findNode(containing: paneId)
        }
    }

    /// Get all pane IDs in the tree
    var allPaneIds: [PaneID] {
        switch self {
        case .pane(let state):
            return [state.id]
        case .split(let state):
            return state.first.allPaneIds + state.second.allPaneIds
        }
    }

    /// Get all panes in the tree
    var allPanes: [PaneState] {
        switch self {
        case .pane(let state):
            return [state]
        case .split(let state):
            return state.first.allPanes + state.second.allPanes
        }
    }

    /// Discriminator for detecting structural changes in the tree
    enum NodeType: Equatable {
        case pane
        case split
    }

    var nodeType: NodeType {
        switch self {
        case .pane: return .pane
        case .split: return .split
        }
    }

    static func == (lhs: SplitNode, rhs: SplitNode) -> Bool {
        lhs.id == rhs.id
    }

    /// Compute normalized bounds (0-1) for all panes in the tree
    /// - Parameter availableRect: The rect available for this subtree (starts as unit rect)
    /// - Returns: Array of pane IDs with their computed bounds
    func computePaneBounds(in availableRect: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> [PaneBounds] {
        switch self {
        case .pane(let paneState):
            return [PaneBounds(paneId: paneState.id, bounds: availableRect)]

        case .split(let splitState):
            let dividerPos = splitState.dividerPosition
            let firstRect: CGRect
            let secondRect: CGRect

            switch splitState.orientation {
            case .horizontal:  // Side-by-side: first=LEFT, second=RIGHT
                firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                                   width: availableRect.width * dividerPos, height: availableRect.height)
                secondRect = CGRect(x: availableRect.minX + availableRect.width * dividerPos, y: availableRect.minY,
                                    width: availableRect.width * (1 - dividerPos), height: availableRect.height)
            case .vertical:  // Stacked: first=TOP, second=BOTTOM
                firstRect = CGRect(x: availableRect.minX, y: availableRect.minY,
                                   width: availableRect.width, height: availableRect.height * dividerPos)
                secondRect = CGRect(x: availableRect.minX, y: availableRect.minY + availableRect.height * dividerPos,
                                    width: availableRect.width, height: availableRect.height * (1 - dividerPos))
            }

            return splitState.first.computePaneBounds(in: firstRect)
                 + splitState.second.computePaneBounds(in: secondRect)
        }
    }
}

import Foundation
import SwiftUI

/// Direction from which a new split animates in
enum SplitAnimationOrigin {
    case fromFirst   // New pane slides in from start (left/top)
    case fromSecond  // New pane slides in from end (right/bottom)
}

/// State for a split node (branch in the split tree)
@Observable
final class SplitState: Identifiable {
    let id: UUID
    var orientation: SplitOrientation
    var first: SplitNode
    var second: SplitNode
    var dividerPosition: CGFloat  // 0.0 to 1.0

    /// Animation origin for entry animation (nil = no animation needed)
    var animationOrigin: SplitAnimationOrigin?

    init(
        id: UUID = UUID(),
        orientation: SplitOrientation,
        first: SplitNode,
        second: SplitNode,
        dividerPosition: CGFloat = 0.5,
        animationOrigin: SplitAnimationOrigin? = nil
    ) {
        self.id = id
        self.orientation = orientation
        self.first = first
        self.second = second
        self.dividerPosition = dividerPosition
        self.animationOrigin = animationOrigin
    }
}

extension SplitState: Equatable {
    static func == (lhs: SplitState, rhs: SplitState) -> Bool {
        lhs.id == rhs.id
    }
}

import Foundation
import SwiftUI

/// Central controller managing the entire split view state (internal implementation)
@Observable
@MainActor
final class SplitViewController {
    /// The root node of the split tree
    var rootNode: SplitNode

    /// Currently zoomed pane. When set, rendering should only show this pane.
    var zoomedPaneId: PaneID?

    /// Currently focused pane ID
    var focusedPaneId: PaneID?

    /// Tab currently being dragged (for visual feedback and hit-testing).
    /// This is @Observable so SwiftUI views react (e.g. allowsHitTesting).
    var draggingTab: TabItem?

    /// Monotonic counter incremented on each drag start. Used to invalidate stale
    /// timeout timers that would otherwise cancel a new drag of the same tab.
    var dragGeneration: Int = 0

    /// Source pane of the dragging tab
    var dragSourcePaneId: PaneID?

    /// Non-observable drag session state. Drop delegates read these instead of the
    /// @Observable properties above, because SwiftUI batches observable updates and
    /// createItemProvider's writes may not be visible to validateDrop/performDrop yet.
    @ObservationIgnored var activeDragTab: TabItem?
    @ObservationIgnored var activeDragSourcePaneId: PaneID?

    /// When false, drop delegates reject all drags and NSViews are hidden.
    /// Mirrors BonsplitController.isInteractive. Must be observable so
    /// updateNSView is called to toggle isHidden on the AppKit containers.
    var isInteractive: Bool = true

    /// Handler for file/URL drops from external apps (e.g. Finder).
    /// Receives the dropped URLs and the pane ID where the drop occurred.
    @ObservationIgnored var onFileDrop: ((_ urls: [URL], _ paneId: PaneID) -> Bool)?

    /// During drop, SwiftUI may keep the source tab view alive briefly (default removal animation)
    /// even after we've updated the model. Hide it explicitly so it disappears immediately.
    var dragHiddenSourceTabId: UUID?
    var dragHiddenSourcePaneId: PaneID?

    /// Current frame of the entire split view container
    var containerFrame: CGRect = .zero

    /// Flag to prevent notification loops during external updates
    var isExternalUpdateInProgress: Bool = false

    /// Timestamp of last geometry notification for debouncing
    var lastGeometryNotificationTime: TimeInterval = 0

    /// Callback for geometry changes
    var onGeometryChange: (() -> Void)?

    init(rootNode: SplitNode? = nil) {
        if let rootNode {
            self.rootNode = rootNode
        } else {
            // Initialize with a single pane containing a welcome tab
            let welcomeTab = TabItem(title: "Welcome", icon: "star")
            let initialPane = PaneState(tabs: [welcomeTab])
            self.rootNode = .pane(initialPane)
            self.focusedPaneId = initialPane.id
        }
    }

    // MARK: - Focus Management

    /// Set focus to a specific pane
    func focusPane(_ paneId: PaneID) {
        guard rootNode.findPane(paneId) != nil else { return }
#if DEBUG
        dlog("focus.bonsplit pane=\(paneId.id.uuidString.prefix(5))")
#endif
        focusedPaneId = paneId
    }

    /// Get the currently focused pane state
    var focusedPane: PaneState? {
        guard let focusedPaneId else { return nil }
        return rootNode.findPane(focusedPaneId)
    }

    var zoomedNode: SplitNode? {
        guard let zoomedPaneId else { return nil }
        return rootNode.findNode(containing: zoomedPaneId)
    }

    @discardableResult
    func clearPaneZoom() -> Bool {
        guard zoomedPaneId != nil else { return false }
        zoomedPaneId = nil
        return true
    }

    @discardableResult
    func togglePaneZoom(_ paneId: PaneID) -> Bool {
        guard rootNode.findPane(paneId) != nil else { return false }

        if zoomedPaneId == paneId {
            zoomedPaneId = nil
            return true
        }

        // Match Ghostty behavior: a single-pane layout can't be zoomed.
        guard rootNode.allPaneIds.count > 1 else { return false }
        zoomedPaneId = paneId
        focusedPaneId = paneId
        return true
    }

    // MARK: - Split Operations

    /// Split the specified pane in the given orientation
    func splitPane(_ paneId: PaneID, orientation: SplitOrientation, with newTab: TabItem? = nil) {
        clearPaneZoom()
        rootNode = splitNodeRecursively(
            node: rootNode,
            targetPaneId: paneId,
            orientation: orientation,
            newTab: newTab
        )
    }

    private func splitNodeRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        newTab: TabItem?
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                // Create new pane - empty if no tab provided (gives developer full control)
                let newPane: PaneState
                if let tab = newTab {
                    newPane = PaneState(tabs: [tab])
                } else {
                    newPane = PaneState(tabs: [])
                }

                // Start with divider at the edge so there's no flash before animation
                let splitState = SplitState(
                    orientation: orientation,
                    first: .pane(paneState),
                    second: .pane(newPane),
                    // Keep the model at its steady-state ratio. The view layer can still animate
                    // from an edge via animationOrigin, but the model should never represent a
                    // fully-collapsed pane (which can get stuck under view reparenting timing).
                    dividerPosition: 0.5,
                    animationOrigin: .fromSecond  // New pane slides in from right/bottom
                )

                // Focus the new pane
                focusedPaneId = newPane.id

                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTab: newTab
            )
            splitState.second = splitNodeRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                newTab: newTab
            )
            return .split(splitState)
        }
    }

    /// Split a pane with a specific tab, optionally inserting the new pane first
    func splitPaneWithTab(_ paneId: PaneID, orientation: SplitOrientation, tab: TabItem, insertFirst: Bool) {
        clearPaneZoom()
        rootNode = splitNodeWithTabRecursively(
            node: rootNode,
            targetPaneId: paneId,
            orientation: orientation,
            tab: tab,
            insertFirst: insertFirst
        )
    }

    private func splitNodeWithTabRecursively(
        node: SplitNode,
        targetPaneId: PaneID,
        orientation: SplitOrientation,
        tab: TabItem,
        insertFirst: Bool
    ) -> SplitNode {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                // Create new pane with the tab
                let newPane = PaneState(tabs: [tab])

                // Start with divider at the edge so there's no flash before animation
                let splitState: SplitState
                if insertFirst {
                    // New pane goes first (left or top).
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(newPane),
                        second: .pane(paneState),
                        dividerPosition: 0.5,
                        animationOrigin: .fromFirst
                    )
                } else {
                    // New pane goes second (right or bottom).
                    splitState = SplitState(
                        orientation: orientation,
                        first: .pane(paneState),
                        second: .pane(newPane),
                        dividerPosition: 0.5,
                        animationOrigin: .fromSecond
                    )
                }

                // Focus the new pane
                focusedPaneId = newPane.id

                return .split(splitState)
            }
            return node

        case .split(let splitState):
            splitState.first = splitNodeWithTabRecursively(
                node: splitState.first,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
            splitState.second = splitNodeWithTabRecursively(
                node: splitState.second,
                targetPaneId: targetPaneId,
                orientation: orientation,
                tab: tab,
                insertFirst: insertFirst
            )
            return .split(splitState)
        }
    }

    /// Close a pane and collapse the split
    func closePane(_ paneId: PaneID) {
        // Don't close the last pane
        guard rootNode.allPaneIds.count > 1 else { return }

        let (newRoot, siblingPaneId) = closePaneRecursively(node: rootNode, targetPaneId: paneId)

        if let newRoot {
            rootNode = newRoot
        }

        // Focus the sibling or first available pane
        if let siblingPaneId {
            focusedPaneId = siblingPaneId
        } else if let firstPane = rootNode.allPaneIds.first {
            focusedPaneId = firstPane
        }

        if let zoomedPaneId, rootNode.findPane(zoomedPaneId) == nil {
            self.zoomedPaneId = nil
        }
    }

    private func closePaneRecursively(
        node: SplitNode,
        targetPaneId: PaneID
    ) -> (SplitNode?, PaneID?) {
        switch node {
        case .pane(let paneState):
            if paneState.id == targetPaneId {
                return (nil, nil)
            }
            return (node, nil)

        case .split(let splitState):
            // Check if either direct child is the target
            if case .pane(let firstPane) = splitState.first, firstPane.id == targetPaneId {
                let focusTarget = splitState.second.allPaneIds.first
                return (splitState.second, focusTarget)
            }

            if case .pane(let secondPane) = splitState.second, secondPane.id == targetPaneId {
                let focusTarget = splitState.first.allPaneIds.first
                return (splitState.first, focusTarget)
            }

            // Recursively check children
            let (newFirst, focusFromFirst) = closePaneRecursively(node: splitState.first, targetPaneId: targetPaneId)
            if newFirst == nil {
                return (splitState.second, splitState.second.allPaneIds.first)
            }

            let (newSecond, focusFromSecond) = closePaneRecursively(node: splitState.second, targetPaneId: targetPaneId)
            if newSecond == nil {
                return (splitState.first, splitState.first.allPaneIds.first)
            }

            if let newFirst { splitState.first = newFirst }
            if let newSecond { splitState.second = newSecond }

            return (.split(splitState), focusFromFirst ?? focusFromSecond)
        }
    }

    // MARK: - Tab Operations

    /// Add a tab to the focused pane (or specified pane)
    func addTab(_ tab: TabItem, toPane paneId: PaneID? = nil, atIndex index: Int? = nil) {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId,
              let pane = rootNode.findPane(targetPaneId) else { return }

        if let index {
            pane.insertTab(tab, at: index)
        } else {
            pane.addTab(tab)
        }
    }

    /// Move a tab from one pane to another
    func moveTab(_ tab: TabItem, from sourcePaneId: PaneID, to targetPaneId: PaneID, atIndex index: Int? = nil) {
        guard let sourcePane = rootNode.findPane(sourcePaneId),
              let targetPane = rootNode.findPane(targetPaneId) else { return }

        // Remove from source
        sourcePane.removeTab(tab.id)

        // Add to target
        if let index {
            targetPane.insertTab(tab, at: index)
        } else {
            targetPane.addTab(tab)
        }

        // Focus target pane
        focusPane(targetPaneId)

        // If source pane is now empty and not the only pane, close it
        if sourcePane.tabs.isEmpty && rootNode.allPaneIds.count > 1 {
            closePane(sourcePaneId)
        }
    }

    /// Close a tab in a specific pane
    func closeTab(_ tabId: UUID, inPane paneId: PaneID) {
        guard let pane = rootNode.findPane(paneId) else { return }

        pane.removeTab(tabId)

        // If pane is now empty and not the only pane, close it
        if pane.tabs.isEmpty && rootNode.allPaneIds.count > 1 {
            closePane(paneId)
        }
    }

    // MARK: - Keyboard Navigation

    /// Navigate focus to an adjacent pane based on spatial position
    func navigateFocus(direction: NavigationDirection) {
        guard let currentPaneId = focusedPaneId else { return }

        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == currentPaneId })?.bounds else { return }

        if let targetPaneId = findBestNeighbor(from: currentBounds, currentPaneId: currentPaneId,
                                               direction: direction, allPaneBounds: allPaneBounds) {
            focusPane(targetPaneId)
        }
        // No neighbor found = at edge, do nothing
    }

    /// Find the closest pane in the requested direction from the given pane.
    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        let allPaneBounds = rootNode.computePaneBounds()
        guard let currentBounds = allPaneBounds.first(where: { $0.paneId == paneId })?.bounds else {
            return nil
        }
        return findBestNeighbor(
            from: currentBounds,
            currentPaneId: paneId,
            direction: direction,
            allPaneBounds: allPaneBounds
        )
    }

    private func findBestNeighbor(from currentBounds: CGRect, currentPaneId: PaneID,
                                  direction: NavigationDirection, allPaneBounds: [PaneBounds]) -> PaneID? {
        let epsilon: CGFloat = 0.001

        // Filter to panes in the target direction
        let candidates = allPaneBounds.filter { paneBounds in
            guard paneBounds.paneId != currentPaneId else { return false }
            let b = paneBounds.bounds
            switch direction {
            case .left:  return b.maxX <= currentBounds.minX + epsilon
            case .right: return b.minX >= currentBounds.maxX - epsilon
            case .up:    return b.maxY <= currentBounds.minY + epsilon
            case .down:  return b.minY >= currentBounds.maxY - epsilon
            }
        }

        guard !candidates.isEmpty else { return nil }

        // Score by overlap (perpendicular axis) and distance
        let scored: [(PaneID, CGFloat, CGFloat)] = candidates.map { c in
            let overlap: CGFloat
            let distance: CGFloat

            switch direction {
            case .left, .right:
                // Vertical overlap for horizontal movement
                overlap = max(0, min(currentBounds.maxY, c.bounds.maxY) - max(currentBounds.minY, c.bounds.minY))
                distance = direction == .left ? (currentBounds.minX - c.bounds.maxX) : (c.bounds.minX - currentBounds.maxX)
            case .up, .down:
                // Horizontal overlap for vertical movement
                overlap = max(0, min(currentBounds.maxX, c.bounds.maxX) - max(currentBounds.minX, c.bounds.minX))
                distance = direction == .up ? (currentBounds.minY - c.bounds.maxY) : (c.bounds.minY - currentBounds.maxY)
            }

            return (c.paneId, overlap, distance)
        }

        // Sort: prefer more overlap, then closer distance
        let sorted = scored.sorted { a, b in
            if abs(a.1 - b.1) > epsilon { return a.1 > b.1 }
            return a.2 < b.2
        }

        return sorted.first?.0
    }

    /// Create a new tab in the focused pane
    func createNewTab() {
        guard let pane = focusedPane else { return }
        let count = pane.tabs.count + 1
        let newTab = TabItem(title: "Untitled \(count)", icon: "doc")
        pane.addTab(newTab)
    }

    /// Close the currently selected tab in the focused pane
    func closeSelectedTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId else { return }
        closeTab(selectedTabId, inPane: pane.id)
    }

    /// Select the previous tab in the focused pane
    func selectPreviousTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }

        let newIndex = currentIndex > 0 ? currentIndex - 1 : pane.tabs.count - 1
        pane.selectTab(pane.tabs[newIndex].id)
    }

    /// Select the next tab in the focused pane
    func selectNextTab() {
        guard let pane = focusedPane,
              let selectedTabId = pane.selectedTabId,
              let currentIndex = pane.tabs.firstIndex(where: { $0.id == selectedTabId }),
              !pane.tabs.isEmpty else { return }

        let newIndex = currentIndex < pane.tabs.count - 1 ? currentIndex + 1 : 0
        pane.selectTab(pane.tabs[newIndex].id)
    }

    // MARK: - Split State Access

    /// Find a split state by its UUID
    func findSplit(_ splitId: UUID) -> SplitState? {
        return findSplitRecursively(in: rootNode, id: splitId)
    }

    private func findSplitRecursively(in node: SplitNode, id: UUID) -> SplitState? {
        switch node {
        case .pane:
            return nil
        case .split(let splitState):
            if splitState.id == id {
                return splitState
            }
            if let found = findSplitRecursively(in: splitState.first, id: id) {
                return found
            }
            return findSplitRecursively(in: splitState.second, id: id)
        }
    }

    /// Get all split states in the tree
    var allSplits: [SplitState] {
        return collectSplits(from: rootNode)
    }

    private func collectSplits(from node: SplitNode) -> [SplitState] {
        switch node {
        case .pane:
            return []
        case .split(let splitState):
            return [splitState] + collectSplits(from: splitState.first) + collectSplits(from: splitState.second)
        }
    }
}

import Foundation

/// Sizing and spacing constants for the tab bar (following macOS HIG)
enum TabBarMetrics {
    // MARK: - Tab Bar

    static let barHeight: CGFloat = 30
    static let barPadding: CGFloat = 0

    // MARK: - Individual Tabs

    static let tabHeight: CGFloat = 30
    static let tabMinWidth: CGFloat = 48
    static let tabMaxWidth: CGFloat = 220
    static let tabCornerRadius: CGFloat = 0
    static let tabHorizontalPadding: CGFloat = 6
    static let tabSpacing: CGFloat = 0
    static let activeIndicatorHeight: CGFloat = 2

    // MARK: - Tab Content

    static let iconSize: CGFloat = 14
    static let titleFontSize: CGFloat = 11
    static let closeButtonSize: CGFloat = 16
    static let closeIconSize: CGFloat = 9
    static let dirtyIndicatorSize: CGFloat = 8
    static let notificationBadgeSize: CGFloat = 6
    static let contentSpacing: CGFloat = 6

    // MARK: - Drop Indicator

    static let dropIndicatorWidth: CGFloat = 2
    static let dropIndicatorHeight: CGFloat = 20

    // MARK: - Split View

    static let minimumPaneWidth: CGFloat = 100
    static let minimumPaneHeight: CGFloat = 100
    static let dividerThickness: CGFloat = 1

    // MARK: - Animations

    static let selectionDuration: Double = 0.15
    static let closeDuration: Double = 0.2
    static let reorderDuration: Double = 0.3
    static let reorderBounce: Double = 0.15
    static let hoverDuration: Double = 0.1

    // MARK: - Split Animations (120fps via CADisplayLink)

    /// Duration for split entry animation (fast and snappy like Hyprland)
    static let splitAnimationDuration: Double = 0.15
}

import SwiftUI
import AppKit

/// Native macOS colors for the tab bar
enum TabBarColors {
    private enum Constants {
        static let darkTextAlpha: CGFloat = 0.82
        static let darkSecondaryTextAlpha: CGFloat = 0.62
        static let lightTextAlpha: CGFloat = 0.82
        static let lightSecondaryTextAlpha: CGFloat = 0.68
    }

    private static func chromeBackgroundColor(
        for appearance: BonsplitConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.backgroundHex else { return nil }
        return NSColor(bonsplitHex: value)
    }

    private static func chromeBorderColor(
        for appearance: BonsplitConfiguration.Appearance
    ) -> NSColor? {
        guard let value = appearance.chromeColors.borderHex else { return nil }
        return NSColor(bonsplitHex: value)
    }

    private static func effectiveBackgroundColor(
        for appearance: BonsplitConfiguration.Appearance,
        fallback fallbackColor: NSColor
    ) -> NSColor {
        chromeBackgroundColor(for: appearance) ?? fallbackColor
    }

    private static func effectiveTextColor(
        for appearance: BonsplitConfiguration.Appearance,
        secondary: Bool
    ) -> NSColor {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return secondary ? .secondaryLabelColor : .labelColor
        }

        if custom.isBonsplitLightColor {
            let alpha = secondary ? Constants.darkSecondaryTextAlpha : Constants.darkTextAlpha
            return NSColor.black.withAlphaComponent(alpha)
        }

        let alpha = secondary ? Constants.lightSecondaryTextAlpha : Constants.lightTextAlpha
        return NSColor.white.withAlphaComponent(alpha)
    }

    static func paneBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveBackgroundColor(for: appearance, fallback: .textBackgroundColor))
    }

    static func nsColorPaneBackground(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        effectiveBackgroundColor(for: appearance, fallback: .textBackgroundColor)
    }

    // MARK: - Tab Bar Background

    static var barBackground: Color {
        Color(nsColor: .windowBackgroundColor)
    }

    static func barBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveBackgroundColor(for: appearance, fallback: .windowBackgroundColor))
    }

    static var barMaterial: Material {
        .bar
    }

    // MARK: - Tab States

    static var activeTabBackground: Color {
        Color(nsColor: .controlBackgroundColor)
    }

    static func activeTabBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return activeTabBackground
        }
        let adjusted = custom.isBonsplitLightColor
            ? custom.bonsplitDarken(by: 0.065)
            : custom.bonsplitLighten(by: 0.12)
        return Color(nsColor: adjusted)
    }

    static var hoveredTabBackground: Color {
        Color(nsColor: .controlBackgroundColor).opacity(0.5)
    }

    static func hoveredTabBackground(for appearance: BonsplitConfiguration.Appearance) -> Color {
        guard let custom = chromeBackgroundColor(for: appearance) else {
            return hoveredTabBackground
        }
        let adjusted = custom.isBonsplitLightColor
            ? custom.bonsplitDarken(by: 0.03)
            : custom.bonsplitLighten(by: 0.07)
        return Color(nsColor: adjusted.withAlphaComponent(0.78))
    }

    static var inactiveTabBackground: Color {
        .clear
    }

    // MARK: - Text Colors

    static var activeText: Color {
        Color(nsColor: .labelColor)
    }

    static func activeText(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveTextColor(for: appearance, secondary: false))
    }

    static func nsColorActiveText(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        effectiveTextColor(for: appearance, secondary: false)
    }

    static var inactiveText: Color {
        Color(nsColor: .secondaryLabelColor)
    }

    static func inactiveText(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: effectiveTextColor(for: appearance, secondary: true))
    }

    static func nsColorInactiveText(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        effectiveTextColor(for: appearance, secondary: true)
    }

    static func splitActionIcon(for appearance: BonsplitConfiguration.Appearance, isPressed: Bool) -> Color {
        Color(nsColor: nsColorSplitActionIcon(for: appearance, isPressed: isPressed))
    }

    static func nsColorSplitActionIcon(
        for appearance: BonsplitConfiguration.Appearance,
        isPressed: Bool
    ) -> NSColor {
        isPressed ? nsColorActiveText(for: appearance) : nsColorInactiveText(for: appearance)
    }

    // MARK: - Borders & Indicators

    static var separator: Color {
        Color(nsColor: .separatorColor)
    }

    static func separator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        Color(nsColor: nsColorSeparator(for: appearance))
    }

    static func nsColorSeparator(for appearance: BonsplitConfiguration.Appearance) -> NSColor {
        if let explicit = chromeBorderColor(for: appearance) {
            return explicit
        }

        guard let custom = chromeBackgroundColor(for: appearance) else {
            return .separatorColor
        }
        let alpha: CGFloat = custom.isBonsplitLightColor ? 0.26 : 0.36
        let tone = custom.isBonsplitLightColor
            ? custom.bonsplitDarken(by: 0.12)
            : custom.bonsplitLighten(by: 0.16)
        return tone.withAlphaComponent(alpha)
    }

    static var dropIndicator: Color {
        Color.accentColor
    }

    static func dropIndicator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        _ = appearance
        return dropIndicator
    }

    static var focusRing: Color {
        Color.accentColor.opacity(0.5)
    }

    static var dirtyIndicator: Color {
        Color(nsColor: .labelColor).opacity(0.6)
    }

    static func dirtyIndicator(for appearance: BonsplitConfiguration.Appearance) -> Color {
        guard chromeBackgroundColor(for: appearance) != nil else { return dirtyIndicator }
        return activeText(for: appearance).opacity(0.72)
    }

    static var notificationBadge: Color {
        Color(nsColor: .systemBlue)
    }

    static func notificationBadge(for appearance: BonsplitConfiguration.Appearance) -> Color {
        _ = appearance
        return notificationBadge
    }

    // MARK: - Shadows

    static var tabShadow: Color {
        Color.black.opacity(0.08)
    }
}

private extension NSColor {
    private static let bonsplitHexDigits = CharacterSet(charactersIn: "0123456789abcdefABCDEF")

    convenience init?(bonsplitHex value: String) {
        var hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if hex.hasPrefix("#") {
            hex.removeFirst()
        }
        guard hex.count == 6 || hex.count == 8 else { return nil }
        guard hex.unicodeScalars.allSatisfy({ Self.bonsplitHexDigits.contains($0) }) else { return nil }
        guard let rgba = UInt64(hex, radix: 16) else { return nil }
        let red: CGFloat
        let green: CGFloat
        let blue: CGFloat
        let alpha: CGFloat
        if hex.count == 8 {
            red = CGFloat((rgba & 0xFF000000) >> 24) / 255.0
            green = CGFloat((rgba & 0x00FF0000) >> 16) / 255.0
            blue = CGFloat((rgba & 0x0000FF00) >> 8) / 255.0
            alpha = CGFloat(rgba & 0x000000FF) / 255.0
        } else {
            red = CGFloat((rgba & 0xFF0000) >> 16) / 255.0
            green = CGFloat((rgba & 0x00FF00) >> 8) / 255.0
            blue = CGFloat(rgba & 0x0000FF) / 255.0
            alpha = 1.0
        }
        self.init(red: red, green: green, blue: blue, alpha: alpha)
    }

    var isBonsplitLightColor: Bool {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        let luminance = (0.299 * red) + (0.587 * green) + (0.114 * blue)
        return luminance > 0.5
    }

    func bonsplitLighten(by amount: CGFloat) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(
            red: min(1.0, red + amount),
            green: min(1.0, green + amount),
            blue: min(1.0, blue + amount),
            alpha: alpha
        )
    }

    func bonsplitDarken(by amount: CGFloat) -> NSColor {
        var red: CGFloat = 0
        var green: CGFloat = 0
        var blue: CGFloat = 0
        var alpha: CGFloat = 0
        let color = usingColorSpace(.sRGB) ?? self
        color.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        return NSColor(
            red: max(0.0, red - amount),
            green: max(0.0, green - amount),
            blue: max(0.0, blue - amount),
            alpha: alpha
        )
    }
}

import Foundation
import AppKit
import QuartzCore
import CoreVideo

/// Animates split view divider positions with display-synced updates and pixel-perfect positioning
@MainActor
final class SplitAnimator {

    // MARK: - Types

    private struct Animation {
        weak var splitView: NSSplitView?
        let startPosition: CGFloat
        let endPosition: CGFloat
        let startTime: CFTimeInterval
        let duration: CFTimeInterval
        var onComplete: (() -> Void)?
    }

    // MARK: - Properties

    private var displayLink: CVDisplayLink?
    private var animations: [UUID: Animation] = [:]

    /// Shared animator instance
    static let shared = SplitAnimator()

    /// Default animation duration in seconds
    nonisolated static let defaultAnimationDuration: CFTimeInterval = 0.16
    // MARK: - Initialization

    private init() {
        setupDisplayLink()
    }

    deinit {
        if let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }

    // MARK: - Display Link

    private func setupDisplayLink() {
        var link: CVDisplayLink?
        CVDisplayLinkCreateWithActiveCGDisplays(&link)
        guard let link else { return }

        let callback: CVDisplayLinkOutputCallback = { _, _, _, _, _, context in
            let animator = Unmanaged<SplitAnimator>.fromOpaque(context!).takeUnretainedValue()
            DispatchQueue.main.async {
                Task { @MainActor in
                    animator.tick()
                }
            }
            return kCVReturnSuccess
        }

        CVDisplayLinkSetOutputCallback(link, callback, Unmanaged.passUnretained(self).toOpaque())
        displayLink = link
    }

    // MARK: - Animation Control

    @discardableResult
    func animate(
        splitView: NSSplitView,
        from startPosition: CGFloat,
        to endPosition: CGFloat,
        duration: CFTimeInterval = SplitAnimator.defaultAnimationDuration,
        onComplete: (() -> Void)? = nil
    ) -> UUID {
        let id = UUID()

        splitView.layoutSubtreeIfNeeded()
        splitView.setPosition(round(startPosition), ofDividerAt: 0)
        splitView.layoutSubtreeIfNeeded()

        animations[id] = Animation(
            splitView: splitView,
            startPosition: startPosition,
            endPosition: endPosition,
            startTime: CACurrentMediaTime(),
            duration: duration,
            onComplete: onComplete
        )

        if let displayLink, !CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStart(displayLink)
        }

        return id
    }

    func cancel(_ id: UUID) {
        animations.removeValue(forKey: id)
        stopIfNeeded()
    }

    // MARK: - Frame Update

    private func tick() {
        let currentTime = CACurrentMediaTime()
        var completedIds: [UUID] = []

        for (id, animation) in animations {
            guard let splitView = animation.splitView else {
                completedIds.append(id)
                continue
            }

            let elapsed = currentTime - animation.startTime
            let progress = min(elapsed / animation.duration, 1.0)
            let eased = progress == 1.0 ? 1.0 : 1.0 - pow(2.0, -10.0 * progress)

            let position = animation.startPosition + (animation.endPosition - animation.startPosition) * eased

            // Round to whole pixels to prevent artifacts
            splitView.setPosition(round(position), ofDividerAt: 0)

            if progress >= 1.0 {
                completedIds.append(id)
                animation.onComplete?()
            }
        }

        for id in completedIds {
            animations.removeValue(forKey: id)
        }

        stopIfNeeded()
    }

    private func stopIfNeeded() {
        if animations.isEmpty, let displayLink, CVDisplayLinkIsRunning(displayLink) {
            CVDisplayLinkStop(displayLink)
        }
    }
}

import SwiftUI

/// Preview shown during tab drag operations
struct TabDragPreview: View {
    let tab: TabItem
    let appearance: BonsplitConfiguration.Appearance

    var body: some View {
        HStack(spacing: TabBarMetrics.contentSpacing) {
            if let iconName = tab.icon {
                Image(systemName: iconName)
                    .font(.system(size: TabBarMetrics.iconSize))
                    .foregroundStyle(TabBarColors.activeText(for: appearance))
            }

            Text(tab.title)
                .font(.system(size: TabBarMetrics.titleFontSize))
                .lineLimit(1)
                .foregroundStyle(TabBarColors.activeText(for: appearance))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: TabBarMetrics.tabCornerRadius, style: .continuous)
                .fill(TabBarColors.activeTabBackground(for: appearance))
                .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        )
        .opacity(0.9)
    }
}

import SwiftUI
import AppKit

private enum TabControlShortcutHintDebugSettings {
    static let xKey = "shortcutHintPaneTabXOffset"
    static let yKey = "shortcutHintPaneTabYOffset"
    static let alwaysShowKey = "shortcutHintAlwaysShow"
    static let defaultX = 0.0
    static let defaultY = 0.0
    static let defaultAlwaysShow = false
    static let range: ClosedRange<Double> = -20...20

    static func clamped(_ value: Double) -> Double {
        min(max(value, range.lowerBound), range.upperBound)
    }
}

enum TabItemStyling {
    static func iconSaturation(hasRasterIcon: Bool, tabSaturation: Double) -> Double {
        hasRasterIcon ? 1.0 : tabSaturation
    }

    static func shouldShowHoverBackground(isHovered: Bool, isSelected: Bool) -> Bool {
        isHovered && !isSelected
    }

    static func resolvedFaviconImage(existing: NSImage?, incomingData: Data?) -> NSImage? {
        guard let incomingData else { return nil }
        if let decoded = NSImage(data: incomingData) {
            // Favicon bitmaps must never be treated as template/tintable symbols.
            decoded.isTemplate = false
            return decoded
        }
        return existing
    }
}

/// Individual tab view with icon, title, close button, and dirty indicator
struct BonsplitTabItemView: View {
    let tab: TabItem
    let isSelected: Bool
    let showsZoomIndicator: Bool
    let appearance: BonsplitConfiguration.Appearance
    let saturation: Double
    let controlShortcutDigit: Int?
    let showsControlShortcutHint: Bool
    let shortcutModifierSymbol: String
    let contextMenuState: TabContextMenuState
    let onSelect: () -> Void
    let onClose: () -> Void
    let onZoomToggle: () -> Void
    let onContextAction: (TabContextAction) -> Void

    @State private var isHovered = false
    @State private var isCloseHovered = false
    @State private var isZoomHovered = false
    @State private var showGlobeFallback = true
    @State private var globeFallbackWorkItem: DispatchWorkItem?
    @State private var lastIsLoadingObserved = false
    @State private var lastLoadingStoppedAt: Date?
    @State private var renderedFaviconData: Data?
    @State private var renderedFaviconImage: NSImage?
    @AppStorage(TabControlShortcutHintDebugSettings.xKey) private var controlShortcutHintXOffset = TabControlShortcutHintDebugSettings.defaultX
    @AppStorage(TabControlShortcutHintDebugSettings.yKey) private var controlShortcutHintYOffset = TabControlShortcutHintDebugSettings.defaultY
    @AppStorage(TabControlShortcutHintDebugSettings.alwaysShowKey) private var alwaysShowShortcutHints = TabControlShortcutHintDebugSettings.defaultAlwaysShow

    var body: some View {
        HStack(spacing: 0) {
            // Icon + title block uses the standard spacing, but keep the close affordance tight.
            HStack(spacing: TabBarMetrics.contentSpacing) {
                let iconSlotSize = TabBarMetrics.iconSize
                let iconTint = isSelected
                    ? TabBarColors.activeText(for: appearance)
                    : TabBarColors.inactiveText(for: appearance)
                let faviconImage = renderedFaviconImage ?? tab.iconImageData.flatMap { NSImage(data: $0) }

                Group {
                    if tab.isLoading {
                        // Slightly smaller than the icon slot so it reads cleaner at tab scale.
                        TabLoadingSpinner(size: iconSlotSize * 0.86, color: iconTint)
                    } else if let image = faviconImage {
                        FaviconIconView(image: image)
                            .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                            .clipped()
                    } else if let iconName = tab.icon {
                        if iconName == "globe", !showGlobeFallback {
                            // Avoid a distracting "globe -> favicon" flash: show a neutral placeholder
                            // briefly while the favicon fetch finishes. If no favicon arrives, we
                            // reveal the globe after a short delay.
                            RoundedRectangle(cornerRadius: 3)
                                .stroke(iconTint.opacity(0.25), lineWidth: 1)
                        } else {
                            Image(systemName: iconName)
                                .font(.system(size: glyphSize(for: iconName)))
                                .foregroundStyle(iconTint)
                        }
                    }
                }
                // Keep downloaded favicon bitmaps in full color even for inactive tab bars.
                .saturation(TabItemStyling.iconSaturation(hasRasterIcon: faviconImage != nil, tabSaturation: saturation))
                .transaction { tx in
                    // Prevent incidental parent animations from briefly fading icon content.
                    tx.animation = nil
                }
                .frame(width: iconSlotSize, height: iconSlotSize, alignment: .center)
                .onAppear {
                    updateRenderedFaviconImage()
                    updateGlobeFallback()
                }
                .onDisappear {
                    globeFallbackWorkItem?.cancel()
                    globeFallbackWorkItem = nil
                }
                .onChange(of: tab.isLoading) { _ in updateGlobeFallback() }
                .onChange(of: tab.iconImageData) { _ in
                    updateRenderedFaviconImage()
                    updateGlobeFallback()
                }
                .onChange(of: tab.icon) { _ in updateGlobeFallback() }

                Text(tab.title)
                    .font(.system(size: TabBarMetrics.titleFontSize))
                    .lineLimit(1)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .saturation(saturation)

                if showsZoomIndicator {
                    Button {
                        onZoomToggle()
                    } label: {
                        Image(systemName: "arrow.up.left.and.arrow.down.right")
                            .font(.system(size: max(8, TabBarMetrics.titleFontSize - 2), weight: .semibold))
                            .foregroundStyle(
                                isZoomHovered
                                    ? TabBarColors.activeText(for: appearance)
                                    : TabBarColors.inactiveText(for: appearance)
                            )
                            .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                            .background(
                                Circle()
                                    .fill(
                                        isZoomHovered
                                            ? TabBarColors.hoveredTabBackground(for: appearance)
                                            : .clear
                                    )
                            )
                    }
                    .buttonStyle(.plain)
                    .onHover { hovering in
                        isZoomHovered = hovering
                    }
                    .saturation(saturation)
                    .accessibilityLabel("Exit zoom")
                }
            }

            Spacer(minLength: 0)

            // Close button / dirty indicator / shortcut hint share the same trailing slot.
            trailingAccessory
        }
        .padding(.horizontal, TabBarMetrics.tabHorizontalPadding)
        .offset(y: isSelected ? 0.5 : 0)
        .frame(
            minWidth: TabBarMetrics.tabMinWidth,
            maxWidth: TabBarMetrics.tabMaxWidth,
            minHeight: TabBarMetrics.tabHeight,
            maxHeight: TabBarMetrics.tabHeight
        )
        .padding(.bottom, isSelected ? 1 : 0)
        .background(tabBackground.saturation(saturation))
        .animation(.easeInOut(duration: 0.14), value: showsShortcutHint)
        .contentShape(Rectangle())
        // Middle click to close (macOS convention).
        // Uses an AppKit event monitor so it doesn't interfere with left click selection or drag/reorder.
        .background(MiddleClickMonitorView(onMiddleClick: {
            guard !tab.isPinned else { return }
            onClose()
        }))
        .onTapGesture {
            onSelect()
        }
        .onHover { hovering in
            // Keep icon rendering stable while hovering; only accessory/background elements animate.
            isHovered = hovering
        }
        .contextMenu {
            contextMenuContent
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(tab.title)
        .accessibilityValue(accessibilityValue)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    private func glyphSize(for iconName: String) -> CGFloat {
        // `terminal.fill` reads visually heavier than most symbols at the same point size.
        // Hardcode sizes to avoid cross-glyph layout shifts.
        if iconName == "terminal.fill" || iconName == "terminal" || iconName == "globe" {
            return max(10, TabBarMetrics.iconSize - 2.5)
        }
        return TabBarMetrics.iconSize
    }

    private var shortcutHintLabel: String? {
        guard let controlShortcutDigit else { return nil }
        return "\(shortcutModifierSymbol)\(controlShortcutDigit)"
    }

    private var showsShortcutHint: Bool {
        (showsControlShortcutHint || alwaysShowShortcutHints) && shortcutHintLabel != nil
    }

    private var shortcutHintSlotWidth: CGFloat {
        guard let label = shortcutHintLabel else {
            return TabBarMetrics.closeButtonSize
        }
        let positiveDebugInset = max(0, CGFloat(TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset))) + 2
        return max(TabBarMetrics.closeButtonSize, shortcutHintWidth(for: label) + positiveDebugInset)
    }

    private func shortcutHintWidth(for label: String) -> CGFloat {
        let font = NSFont.systemFont(ofSize: max(8, TabBarMetrics.titleFontSize - 2), weight: .semibold)
        let textWidth = (label as NSString).size(withAttributes: [.font: font]).width
        return ceil(textWidth) + 8
    }

    @ViewBuilder
    private var trailingAccessory: some View {
        ZStack(alignment: .center) {
            if let shortcutHintLabel {
                Text(shortcutHintLabel)
                    .font(.system(size: max(8, TabBarMetrics.titleFontSize - 2), weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                    .foregroundStyle(
                        isSelected
                            ? TabBarColors.activeText(for: appearance)
                            : TabBarColors.inactiveText(for: appearance)
                    )
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(
                        Capsule(style: .continuous)
                            .fill(.regularMaterial)
                            .overlay(
                                Capsule(style: .continuous)
                                    .stroke(Color.white.opacity(0.30), lineWidth: 0.8)
                            )
                            .shadow(color: Color.black.opacity(0.22), radius: 2, x: 0, y: 1)
                    )
                    .offset(
                        x: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintXOffset),
                        y: TabControlShortcutHintDebugSettings.clamped(controlShortcutHintYOffset)
                    )
                    .opacity(showsShortcutHint ? 1 : 0)
                    .allowsHitTesting(false)
            }

            closeOrDirtyIndicator
                .opacity(showsShortcutHint ? 0 : 1)
                .allowsHitTesting(!showsShortcutHint)
        }
        .frame(width: shortcutHintSlotWidth, height: TabBarMetrics.closeButtonSize, alignment: .center)
        .animation(.easeInOut(duration: 0.14), value: showsShortcutHint)
    }

    private func updateGlobeFallback() {
        // Track load transitions so we can avoid an "empty placeholder -> globe" flash on brand-new tabs.
        if lastIsLoadingObserved && !tab.isLoading {
            lastLoadingStoppedAt = Date()
        }
        lastIsLoadingObserved = tab.isLoading

        globeFallbackWorkItem?.cancel()
        globeFallbackWorkItem = nil

        // Only delay the globe fallback right after a navigation completes, when a favicon is likely to
        // arrive soon. Otherwise (e.g. a brand-new tab), show the globe immediately.
        let recentlyStoppedLoading: Bool = {
            guard let t = lastLoadingStoppedAt else { return false }
            return Date().timeIntervalSince(t) < 1.5
        }()
        let shouldDelayGlobe = (tab.icon == "globe") && (tab.iconImageData == nil) && !tab.isLoading && recentlyStoppedLoading
        if !shouldDelayGlobe {
            showGlobeFallback = true
            return
        }

        showGlobeFallback = false
        let work = DispatchWorkItem {
            showGlobeFallback = true
        }
        globeFallbackWorkItem = work
        // Give favicon fetches a little longer before showing the globe fallback to reduce brief flashes.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.90, execute: work)
    }

    private func updateRenderedFaviconImage() {
        guard renderedFaviconData != tab.iconImageData ||
                (renderedFaviconImage == nil && tab.iconImageData != nil) else { return }
        renderedFaviconData = tab.iconImageData
        renderedFaviconImage = TabItemStyling.resolvedFaviconImage(
            existing: renderedFaviconImage,
            incomingData: tab.iconImageData
        )
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if tab.isLoading { parts.append("Loading") }
        if tab.isPinned { parts.append("Pinned") }
        if tab.showsNotificationBadge { parts.append("Unread") }
        if tab.isDirty { parts.append("Modified") }
        if showsZoomIndicator { parts.append("Zoomed") }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var contextMenuContent: some View {
        contextButton("Rename Tab…", action: .rename)

        if contextMenuState.hasCustomTitle {
            contextButton("Remove Custom Tab Name", action: .clearName)
        }

        Divider()

        contextButton("Close Tabs to Left", action: .closeToLeft)
            .disabled(!contextMenuState.canCloseToLeft)

        contextButton("Close Tabs to Right", action: .closeToRight)
            .disabled(!contextMenuState.canCloseToRight)

        contextButton("Close Other Tabs", action: .closeOthers)
            .disabled(!contextMenuState.canCloseOthers)

        contextButton("Move Tab…", action: .move)

        if contextMenuState.isTerminal {
            localizedContextButton(
                "command.moveTabToLeftPane.title",
                defaultValue: "Move to Left Pane",
                action: .moveToLeftPane
            )
                .disabled(!contextMenuState.canMoveToLeftPane)

            localizedContextButton(
                "command.moveTabToRightPane.title",
                defaultValue: "Move to Right Pane",
                action: .moveToRightPane
            )
                .disabled(!contextMenuState.canMoveToRightPane)
        }

        Divider()

        contextButton("New Terminal Tab to Right", action: .newTerminalToRight)

        contextButton("New Browser Tab to Right", action: .newBrowserToRight)

        if contextMenuState.isBrowser {
            Divider()

            contextButton("Reload Tab", action: .reload)

            contextButton("Duplicate Tab", action: .duplicate)
        }

        Divider()

        if contextMenuState.hasSplits {
            contextButton(
                contextMenuState.isZoomed ? "Exit Zoom" : "Zoom Pane",
                action: .toggleZoom
            )
        }

        contextButton(
            contextMenuState.isPinned ? "Unpin Tab" : "Pin Tab",
            action: .togglePin
        )

        if contextMenuState.isUnread {
            contextButton("Mark Tab as Read", action: .markAsRead)
                .disabled(!contextMenuState.canMarkAsRead)
        } else {
            contextButton("Mark Tab as Unread", action: .markAsUnread)
                .disabled(!contextMenuState.canMarkAsUnread)
        }
    }

    @ViewBuilder
    private func contextButton(_ title: String, action: TabContextAction) -> some View {
        if let shortcut = contextMenuState.shortcuts[action] {
            Button(title) {
                onContextAction(action)
            }
            .keyboardShortcut(shortcut)
        } else {
            Button(title) {
                onContextAction(action)
            }
        }
    }

    @ViewBuilder
    private func localizedContextButton(
        _ titleKey: String,
        defaultValue: String,
        action: TabContextAction
    ) -> some View {
        contextButton(
            NSLocalizedString(titleKey, tableName: nil, bundle: .main, value: defaultValue, comment: ""),
            action: action
        )
    }

    // MARK: - Tab Background

    @ViewBuilder
    private var tabBackground: some View {
        ZStack(alignment: .top) {
            // Background fill (hover)
            if TabItemStyling.shouldShowHoverBackground(isHovered: isHovered, isSelected: isSelected) {
                Rectangle()
                    .fill(TabBarColors.hoveredTabBackground(for: appearance))
            } else {
                Color.clear
            }

            // Top accent indicator for selected tab
            if isSelected {
                Rectangle()
                    .fill(Color.accentColor)
                    .frame(height: TabBarMetrics.activeIndicatorHeight)
            }

            // Right border separator
            HStack {
                Spacer()
                Rectangle()
                    .fill(TabBarColors.separator(for: appearance))
                    .frame(width: 1)
            }
        }
    }

    // MARK: - Close Button / Dirty Indicator

    @ViewBuilder
    private var closeOrDirtyIndicator: some View {
        ZStack {
            // Dirty indicator (shown when dirty and not hovering, hidden for selected tab)
            if (!isSelected && !isHovered && !isCloseHovered) && (tab.isDirty || tab.showsNotificationBadge) {
                HStack(spacing: 2) {
                    if tab.showsNotificationBadge {
                        Circle()
                            .fill(TabBarColors.notificationBadge(for: appearance))
                            .frame(width: TabBarMetrics.notificationBadgeSize, height: TabBarMetrics.notificationBadgeSize)
                    }
                    if tab.isDirty {
                        Circle()
                            .fill(TabBarColors.dirtyIndicator(for: appearance))
                            .frame(width: TabBarMetrics.dirtyIndicatorSize, height: TabBarMetrics.dirtyIndicatorSize)
                            .saturation(saturation)
                    }
                }
            }

            if tab.isPinned {
                if isSelected || isHovered || isCloseHovered || (!tab.isDirty && !tab.showsNotificationBadge) {
                    Image(systemName: "pin.fill")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(TabBarColors.inactiveText(for: appearance))
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .saturation(saturation)
                }
            } else if isSelected || isHovered || isCloseHovered {
                // Close button (always visible on active tab, shown on hover for others)
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: TabBarMetrics.closeIconSize, weight: .semibold))
                        .foregroundStyle(
                            isCloseHovered
                                ? TabBarColors.activeText(for: appearance)
                                : TabBarColors.inactiveText(for: appearance)
                        )
                        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
                        .background(
                            Circle()
                                .fill(
                                    isCloseHovered
                                        ? TabBarColors.hoveredTabBackground(for: appearance)
                                        : .clear
                                )
                        )
                }
                .buttonStyle(.plain)
                .onHover { hovering in
                    isCloseHovered = hovering
                }
                .saturation(saturation)
            }
        }
        .frame(width: TabBarMetrics.closeButtonSize, height: TabBarMetrics.closeButtonSize)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isHovered)
        .animation(.easeInOut(duration: TabBarMetrics.hoverDuration), value: isCloseHovered)
    }
}

private struct TabLoadingSpinner: View {
    let size: CGFloat
    let color: Color

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            // 0.9s per revolution feels a bit snappier at tab-icon scale.
            let angle = (t.truncatingRemainder(dividingBy: 0.9) / 0.9) * 360.0

            ZStack {
                Circle()
                    .stroke(color.opacity(0.20), lineWidth: ringWidth)
                Circle()
                    .trim(from: 0.0, to: 0.28)
                    .stroke(color, style: StrokeStyle(lineWidth: ringWidth, lineCap: .round))
                    .rotationEffect(.degrees(angle))
            }
            .frame(width: size, height: size)
        }
    }

    private var ringWidth: CGFloat {
        max(1.6, size * 0.14)
    }
}

private struct FaviconIconView: NSViewRepresentable {
    let image: NSImage

    final class ContainerView: NSView {
        let imageView = NSImageView(frame: .zero)

        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            wantsLayer = true
            layer?.masksToBounds = true
            imageView.imageScaling = .scaleProportionallyDown
            imageView.imageAlignment = .alignCenter
            imageView.animates = false
            imageView.contentTintColor = nil
            imageView.autoresizingMask = [.width, .height]
            addSubview(imageView)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        override var intrinsicContentSize: NSSize {
            .zero
        }

        override func layout() {
            super.layout()
            imageView.frame = bounds.integral
        }
    }

    func makeNSView(context: Context) -> ContainerView {
        ContainerView(frame: .zero)
    }

    func updateNSView(_ nsView: ContainerView, context: Context) {
        image.isTemplate = false
        if nsView.imageView.image !== image {
            nsView.imageView.image = image
        }
        nsView.imageView.contentTintColor = nil
    }
}

private struct MiddleClickMonitorView: NSViewRepresentable {
    let onMiddleClick: () -> Void

    final class Coordinator {
        var onMiddleClick: (() -> Void)?
        weak var view: NSView?
        var monitor: Any?

        deinit {
            if let monitor {
                NSEvent.removeMonitor(monitor)
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor

        context.coordinator.view = view
        context.coordinator.onMiddleClick = onMiddleClick

        // Monitor only middle clicks so we don't break drag/reorder or normal selection.
        let coordinator = context.coordinator
        coordinator.monitor = NSEvent.addLocalMonitorForEvents(matching: [.otherMouseUp]) { [weak coordinator] event in
            guard event.buttonNumber == 2 else { return event }
            guard let coordinator, let v = coordinator.view, let w = v.window else { return event }
            guard event.window === w else { return event }

            let p = v.convert(event.locationInWindow, from: nil)
            guard v.bounds.contains(p) else { return event }

            coordinator.onMiddleClick?()
            return nil // swallow so it doesn't also select the tab
        }

        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.view = nsView
        context.coordinator.onMiddleClick = onMiddleClick
    }
}

import SwiftUI
import AppKit
import UniformTypeIdentifiers

private struct SelectedTabFramePreferenceKey: PreferenceKey {
    static let defaultValue: CGRect? = nil

    static func reduce(value: inout CGRect?, nextValue: () -> CGRect?) {
        if let next = nextValue() {
            value = next
        }
    }
}

enum TabBarStyling {
    static func separatorSegments(
        totalWidth: CGFloat,
        gap: ClosedRange<CGFloat>?
    ) -> (left: CGFloat, right: CGFloat) {
        let clampedTotal = max(0, totalWidth)
        guard let gap else {
            return (left: clampedTotal, right: 0)
        }

        let start = min(max(gap.lowerBound, 0), clampedTotal)
        let end = min(max(gap.upperBound, 0), clampedTotal)
        let normalizedStart = min(start, end)
        let normalizedEnd = max(start, end)
        let left = max(0, normalizedStart)
        let right = max(0, clampedTotal - normalizedEnd)
        return (left: left, right: right)
    }
}

struct TabContextMenuState {
    let isPinned: Bool
    let isUnread: Bool
    let isBrowser: Bool
    let isTerminal: Bool
    let hasCustomTitle: Bool
    let canCloseToLeft: Bool
    let canCloseToRight: Bool
    let canCloseOthers: Bool
    let canMoveToLeftPane: Bool
    let canMoveToRightPane: Bool
    let isZoomed: Bool
    let hasSplits: Bool
    let shortcuts: [TabContextAction: KeyboardShortcut]

    var canMarkAsUnread: Bool {
        !isUnread
    }

    var canMarkAsRead: Bool {
        isUnread
    }
}

/// Tab bar view with scrollable tabs, drag/drop support, and split buttons
struct TabBarView: View {
    @Environment(BonsplitController.self) private var controller
    @Environment(SplitViewController.self) private var splitViewController
    
    @Bindable var pane: PaneState
    let isFocused: Bool
    var showSplitButtons: Bool = true

    @AppStorage("workspacePresentationMode") private var presentationMode = "standard"
    @State private var isHoveringTabBar = false
    @State private var dropTargetIndex: Int?
    @State private var dropLifecycle: TabDropLifecycle = .idle
    @State private var scrollOffset: CGFloat = 0
    @State private var contentWidth: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @State private var selectedTabFrameInBar: CGRect?
    @StateObject private var controlKeyMonitor = TabControlShortcutKeyMonitor()

    private var canScrollLeft: Bool {
        scrollOffset > 1
    }

    private var canScrollRight: Bool {
        contentWidth > containerWidth && scrollOffset < contentWidth - containerWidth - 1
    }

    /// Whether this tab bar should show full saturation (focused or drag source)
    private var shouldShowFullSaturation: Bool {
        isFocused || splitViewController.dragSourcePaneId == pane.id
    }

    private var tabBarSaturation: Double {
        shouldShowFullSaturation ? 1.0 : 0.0
    }

    private var appearance: BonsplitConfiguration.Appearance {
        controller.configuration.appearance
    }

    private var showsControlShortcutHints: Bool {
        isFocused && controlKeyMonitor.isShortcutHintVisible
    }


    var body: some View {
        HStack(spacing: 0) {
            if appearance.tabBarLeadingInset > 0 && controller.internalController.rootNode.allPaneIds.first == pane.id {
                TabBarDragZoneView { return false }
                    .frame(width: appearance.tabBarLeadingInset)
            }
            // Scrollable tabs with fade overlays
            GeometryReader { containerGeo in
                ScrollViewReader { proxy in
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: TabBarMetrics.tabSpacing) {
                            ForEach(Array(pane.tabs.enumerated()), id: \.element.id) { index, tab in
                                tabItem(for: tab, at: index)
                                    .id(tab.id)
                            }

                            // Unified drop zone after the last tab. This is at least a small hit
                            // target (so the user can always drop "after the last tab") and it
                            // supports dropping after the last tab.
                            dropZoneAfterTabs
                        }
                        .padding(.horizontal, TabBarMetrics.barPadding)
                        // Keep tab insert/remove/reorder instant without suppressing unrelated
                        // subtree animations (for example, shortcut-hint fades).
                        .animation(nil, value: pane.tabs.map(\.id))
                        .background(
                            GeometryReader { contentGeo in
                                Color.clear
                                    .onChange(of: contentGeo.frame(in: .named("tabScroll"))) { _, newFrame in
                                        scrollOffset = -newFrame.minX
                                        contentWidth = newFrame.width
                                    }
                                    .onAppear {
                                        let frame = contentGeo.frame(in: .named("tabScroll"))
                                        scrollOffset = -frame.minX
                                        contentWidth = frame.width
                                    }
                            }
                        )
                    }
                    // When the tab strip is shorter than the visible area, allow dropping in the
                    // empty trailing space without forcing tabs to stretch.
                    .overlay(alignment: .trailing) {
                        let trailing = max(0, containerGeo.size.width - contentWidth)
                        if trailing >= 1 {
                            TabBarDragZoneView {
                                guard splitViewController.isInteractive else { return false }
                                controller.requestNewTab(kind: "terminal", inPane: pane.id)
                                return true
                            }
                            .frame(width: trailing, height: TabBarMetrics.tabHeight)
                            .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
                                targetIndex: pane.tabs.count,
                                pane: pane,
                                bonsplitController: controller,
                                controller: splitViewController,
                                dropTargetIndex: $dropTargetIndex,
                                dropLifecycle: $dropLifecycle
                            ))
                        }
                    }
                    .coordinateSpace(name: "tabScroll")
                    .onAppear {
                        containerWidth = containerGeo.size.width
                        if let tabId = pane.selectedTabId {
                            proxy.scrollTo(tabId, anchor: .center)
                        }
                    }
                    .onChange(of: containerGeo.size.width) { _, newWidth in
                        containerWidth = newWidth
                    }
                    .onChange(of: pane.selectedTabId) { _, newTabId in
                        if let tabId = newTabId {
                            // Keep tab selection changes instant; scrolling to the focused tab should
                            // not animate (avoids feeling like tabs "linger" during drag/drop).
                            withTransaction(Transaction(animation: nil)) {
                                proxy.scrollTo(tabId, anchor: .center)
                            }
                        }
                    }
                }
                .frame(height: TabBarMetrics.barHeight)
                .overlay(fadeOverlays)
            }

            // Split buttons
            if showSplitButtons {
                let shouldShow = presentationMode != "minimal" || isHoveringTabBar
                splitButtons
                    .saturation(tabBarSaturation)
                    .opacity(shouldShow ? 1 : 0)
                    .allowsHitTesting(shouldShow)
                    .animation(.easeInOut(duration: 0.14), value: shouldShow)
            }
        }
        .frame(height: TabBarMetrics.barHeight)
        .coordinateSpace(name: "tabBar")
        .background(tabBarBackground)
        .background(TabBarDragAndHoverView(
            isMinimalMode: presentationMode == "minimal",
            onHoverChanged: { isHoveringTabBar = $0 }
        ))
        .background(
            TabBarHostWindowReader { window in
                controlKeyMonitor.setHostWindow(window)
            }
            .frame(width: 0, height: 0)
        )
        // Clear drop state when drag ends elsewhere (cancelled, dropped in another pane, etc.)
        .onChange(of: splitViewController.draggingTab) { _, newValue in
#if DEBUG
            dlog(
                "tab.dragState pane=\(pane.id.id.uuidString.prefix(5)) " +
                "draggingTab=\(newValue != nil ? 1 : 0) " +
                "activeDragTab=\(splitViewController.activeDragTab != nil ? 1 : 0)"
            )
#endif
            if newValue == nil {
                dropTargetIndex = nil
                dropLifecycle = .idle
            }
        }
        .onAppear {
            controlKeyMonitor.start()
        }
        .onPreferenceChange(SelectedTabFramePreferenceKey.self) { frame in
            selectedTabFrameInBar = frame
        }
        .onDisappear {
            controlKeyMonitor.stop()
        }
    }

    // MARK: - Tab Item

    @ViewBuilder
    private func tabItem(for tab: TabItem, at index: Int) -> some View {
        let contextMenuState = contextMenuState(for: tab, at: index)
        let showsZoomIndicator = splitViewController.zoomedPaneId == pane.id && pane.selectedTabId == tab.id
        BonsplitTabItemView(
            tab: tab,
            isSelected: pane.selectedTabId == tab.id,
            showsZoomIndicator: showsZoomIndicator,
            appearance: appearance,
            saturation: tabBarSaturation,
            controlShortcutDigit: tabControlShortcutDigit(for: index, tabCount: pane.tabs.count),
            showsControlShortcutHint: showsControlShortcutHints,
            shortcutModifierSymbol: controlKeyMonitor.shortcutModifierSymbol,
            contextMenuState: contextMenuState,
            onSelect: {
                // Tab selection must be instant. Animating this transaction causes the pane
                // content (often swapped via opacity) to crossfade, which is undesirable for
                // terminal/browser surfaces.
#if DEBUG
                dlog("tab.select pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
                withTransaction(Transaction(animation: nil)) {
                    pane.selectTab(tab.id)
                    controller.focusPane(pane.id)
                }
            },
            onClose: {
                guard !tab.isPinned else { return }
                // Close should be instant (no fade-out/removal animation).
#if DEBUG
                dlog("tab.close pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
                withTransaction(Transaction(animation: nil)) {
                    controller.onTabCloseRequest?(TabID(id: tab.id), pane.id)
                    _ = controller.closeTab(TabID(id: tab.id), inPane: pane.id)
                }
            },
            onZoomToggle: {
                _ = splitViewController.togglePaneZoom(pane.id)
            },
            onContextAction: { action in
                controller.requestTabContextAction(action, for: TabID(id: tab.id), inPane: pane.id)
            }
        )
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: SelectedTabFramePreferenceKey.self,
                    value: pane.selectedTabId == tab.id
                        ? geometry.frame(in: .named("tabBar"))
                        : nil
                )
            }
        )
        .onDrag {
            createItemProvider(for: tab)
        } preview: {
            TabDragPreview(tab: tab, appearance: appearance)
        }
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            targetIndex: index,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == index {
                dropIndicator
                    .saturation(tabBarSaturation)
            }
        }
    }

    private func contextMenuState(for tab: TabItem, at index: Int) -> TabContextMenuState {
        let leftTabs = pane.tabs.prefix(index)
        let canCloseToLeft = leftTabs.contains(where: { !$0.isPinned })
        let canCloseToRight: Bool
        if (index + 1) < pane.tabs.count {
            canCloseToRight = pane.tabs.suffix(from: index + 1).contains(where: { !$0.isPinned })
        } else {
            canCloseToRight = false
        }
        let canCloseOthers = pane.tabs.enumerated().contains { itemIndex, item in
            itemIndex != index && !item.isPinned
        }
        return TabContextMenuState(
            isPinned: tab.isPinned,
            isUnread: tab.showsNotificationBadge,
            isBrowser: tab.kind == "browser",
            isTerminal: tab.kind == "terminal",
            hasCustomTitle: tab.hasCustomTitle,
            canCloseToLeft: canCloseToLeft,
            canCloseToRight: canCloseToRight,
            canCloseOthers: canCloseOthers,
            canMoveToLeftPane: controller.adjacentPane(to: pane.id, direction: .left) != nil,
            canMoveToRightPane: controller.adjacentPane(to: pane.id, direction: .right) != nil,
            isZoomed: splitViewController.zoomedPaneId == pane.id,
            hasSplits: splitViewController.rootNode.allPaneIds.count > 1,
            shortcuts: controller.contextMenuShortcuts
        )
    }

    // MARK: - Item Provider

    private func createItemProvider(for tab: TabItem) -> NSItemProvider {
        #if DEBUG
        NSLog("[Bonsplit Drag] createItemProvider for tab: \(tab.title)")
        #endif
#if DEBUG
        dlog("tab.dragStart pane=\(pane.id.id.uuidString.prefix(5)) tab=\(tab.id.uuidString.prefix(5)) title=\"\(tab.title)\"")
#endif
        // Clear any stale drop indicator from previous incomplete drag
        dropTargetIndex = nil
        dropLifecycle = .idle

        // Set drag source for visual feedback (observable) and drop delegates (non-observable).
        splitViewController.dragGeneration += 1
        splitViewController.draggingTab = tab
        splitViewController.dragSourcePaneId = pane.id
        splitViewController.activeDragTab = tab
        splitViewController.activeDragSourcePaneId = pane.id

        // Install a one-shot mouse-up monitor to clear stale drag state if the drag is
        // cancelled (dropped outside any valid target). SwiftUI's onDrag doesn't provide
        // a drag-cancelled callback, so performDrop never fires and draggingTab stays set,
        // which disables hit testing on all content views.
        let controller = splitViewController
        let dragGen = controller.dragGeneration
        var monitorRef: Any?
        monitorRef = NSEvent.addLocalMonitorForEvents(matching: .leftMouseUp) { event in
            // One-shot: remove ourselves, then clean up stale drag state.
            if let m = monitorRef {
                NSEvent.removeMonitor(m)
                monitorRef = nil
            }
            // Use async to avoid mutating @Observable state during event dispatch.
            DispatchQueue.main.async {
                guard controller.dragGeneration == dragGen else { return }
                if controller.draggingTab != nil || controller.activeDragTab != nil {
#if DEBUG
                    dlog("tab.dragCancel (stale draggingTab cleared)")
#endif
                    controller.draggingTab = nil
                    controller.dragSourcePaneId = nil
                    controller.activeDragTab = nil
                    controller.activeDragSourcePaneId = nil
                }
            }
            return event
        }

        let transfer = TabTransferData(tab: tab, sourcePaneId: pane.id.id)
        if let data = try? JSONEncoder().encode(transfer) {
            let provider = NSItemProvider()
            provider.registerDataRepresentation(
                forTypeIdentifier: UTType.tabTransfer.identifier,
                visibility: .ownProcess
            ) { completion in
                completion(data, nil)
                return nil
            }
#if DEBUG
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                let types = NSPasteboard(name: .drag).types?.map(\.rawValue).joined(separator: ",") ?? "-"
                dlog("tab.dragPasteboard types=\(types)")
            }
#endif
            return provider
        }
        return NSItemProvider()
    }

    private func tabControlShortcutDigit(for index: Int, tabCount: Int) -> Int? {
        for digit in 1...9 {
            if tabIndexForControlShortcutDigit(digit, tabCount: tabCount) == index {
                return digit
            }
        }
        return nil
    }

    private func tabIndexForControlShortcutDigit(_ digit: Int, tabCount: Int) -> Int? {
        guard tabCount > 0, digit >= 1, digit <= 9 else { return nil }
        if digit == 9 {
            return tabCount - 1
        }
        let index = digit - 1
        return index < tabCount ? index : nil
    }

    // MARK: - Drop Zone at End

    @ViewBuilder
    private var dropZoneAfterTabs: some View {
        TabBarDragZoneView {
            guard splitViewController.isInteractive else { return false }
            controller.requestNewTab(kind: "terminal", inPane: pane.id)
            return true
        }
        .frame(width: 30, height: TabBarMetrics.tabHeight)
        .onDrop(of: [.tabTransfer], delegate: TabDropDelegate(
            targetIndex: pane.tabs.count,
            pane: pane,
            bonsplitController: controller,
            controller: splitViewController,
            dropTargetIndex: $dropTargetIndex,
            dropLifecycle: $dropLifecycle
        ))
        .overlay(alignment: .leading) {
            if dropTargetIndex == pane.tabs.count {
                dropIndicator
                    .saturation(tabBarSaturation)
            }
        }
    }

    // MARK: - Drop Indicator

    @ViewBuilder
    private var dropIndicator: some View {
        Capsule()
            .fill(TabBarColors.dropIndicator(for: appearance))
            .frame(width: TabBarMetrics.dropIndicatorWidth, height: TabBarMetrics.dropIndicatorHeight)
            .offset(x: -1)
    }

    // MARK: - Split Buttons

    @ViewBuilder
    private var splitButtons: some View {
        let tooltips = controller.configuration.appearance.splitButtonTooltips
        HStack(spacing: 4) {
            Button {
                controller.requestNewTab(kind: "terminal", inPane: pane.id)
            } label: {
                Image(systemName: "terminal")
                    .font(.system(size: 12))
            }
            .buttonStyle(SplitActionButtonStyle(appearance: appearance))
            .safeHelp(tooltips.newTerminal)

            Button {
                controller.requestNewTab(kind: "browser", inPane: pane.id)
            } label: {
                Image(systemName: "globe")
                    .font(.system(size: 12))
            }
            .buttonStyle(SplitActionButtonStyle(appearance: appearance))
            .safeHelp(tooltips.newBrowser)

            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .horizontal)
            } label: {
                Image(systemName: "square.split.2x1")
                    .font(.system(size: 12))
            }
            .buttonStyle(SplitActionButtonStyle(appearance: appearance))
            .safeHelp(tooltips.splitRight)

            Button {
                // 120fps animation handled by SplitAnimator
                controller.splitPane(pane.id, orientation: .vertical)
            } label: {
                Image(systemName: "square.split.1x2")
                    .font(.system(size: 12))
            }
            .buttonStyle(SplitActionButtonStyle(appearance: appearance))
            .safeHelp(tooltips.splitDown)
        }
        .padding(.trailing, 8)
    }

    // MARK: - Fade Overlays

    @ViewBuilder
    private var fadeOverlays: some View {
        let fadeWidth: CGFloat = 24

        HStack(spacing: 0) {
            // Left fade
            LinearGradient(
                colors: [
                    TabBarColors.barBackground(for: appearance),
                    TabBarColors.barBackground(for: appearance).opacity(0),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .opacity(canScrollLeft ? 1 : 0)
            .allowsHitTesting(false)

            Spacer()

            // Right fade
            LinearGradient(
                colors: [
                    TabBarColors.barBackground(for: appearance).opacity(0),
                    TabBarColors.barBackground(for: appearance),
                ],
                startPoint: .leading,
                endPoint: .trailing
            )
            .frame(width: fadeWidth)
            .opacity(canScrollRight ? 1 : 0)
            .allowsHitTesting(false)
        }
    }

    // MARK: - Background

    @ViewBuilder
    private var tabBarBackground: some View {
        let barFill = isFocused
            ? TabBarColors.barBackground(for: appearance)
            : TabBarColors.barBackground(for: appearance).opacity(0.95)

        Rectangle()
            .fill(barFill)
            .overlay(alignment: .bottom) {
                GeometryReader { geometry in
                    let separator = TabBarColors.separator(for: appearance)
                    let gapRange: ClosedRange<CGFloat>? = selectedTabFrameInBar.map { frame in
                        frame.minX...frame.maxX
                    }
                    let segments = TabBarStyling.separatorSegments(
                        totalWidth: geometry.size.width,
                        gap: gapRange
                    )

                    HStack(spacing: 0) {
                        Rectangle()
                            .fill(separator)
                            .frame(width: segments.left, height: 1)
                        Spacer(minLength: 0)
                        Rectangle()
                            .fill(separator)
                            .frame(width: segments.right, height: 1)
                    }
                }
                .frame(height: 1)
            }
    }
}

private struct SplitActionButtonStyle: ButtonStyle {
    let appearance: BonsplitConfiguration.Appearance

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(TabBarColors.splitActionIcon(for: appearance, isPressed: configuration.isPressed))
    }
}

/// Background view that provides window-drag-from-empty-space in minimal mode
/// and hover tracking via NSTrackingArea (replacing .contentShape + .onHover).
/// As a .background(), AppKit routes clicks to tabs/buttons in front first;
/// this view only receives hits in truly empty space.
private struct TabBarDragAndHoverView: NSViewRepresentable {
    let isMinimalMode: Bool
    let onHoverChanged: (Bool) -> Void

    func makeNSView(context: Context) -> TabBarBackgroundNSView {
        let view = TabBarBackgroundNSView()
        view.isMinimalMode = isMinimalMode
        view.onHoverChanged = onHoverChanged
        return view
    }

    func updateNSView(_ nsView: TabBarBackgroundNSView, context: Context) {
        nsView.isMinimalMode = isMinimalMode
        nsView.onHoverChanged = onHoverChanged
    }

    final class TabBarBackgroundNSView: NSView {
        var isMinimalMode = false
        var onHoverChanged: ((Bool) -> Void)?
        private var hoverTrackingArea: NSTrackingArea?

        override var mouseDownCanMoveWindow: Bool { false }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let existing = hoverTrackingArea {
                removeTrackingArea(existing)
            }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.mouseEnteredAndExited, .activeInActiveApp],
                owner: self
            )
            addTrackingArea(area)
            hoverTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            onHoverChanged?(true)
        }

        override func mouseExited(with event: NSEvent) {
            onHoverChanged?(false)
        }

        override func mouseDown(with event: NSEvent) {
            guard isMinimalMode, let window else {
                super.mouseDown(with: event)
                return
            }
            if event.clickCount >= 2 {
                let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
                switch action {
                case "Minimize": window.miniaturize(nil)
                default: window.zoom(nil)
                }
                return
            }
            let wasMovable = window.isMovable
            window.isMovable = true
            window.performDrag(with: event)
            window.isMovable = wasMovable
        }
    }
}

private struct TabBarDragZoneView: NSViewRepresentable {
    let onDoubleClick: () -> Bool

    func makeNSView(context: Context) -> DragNSView {
        let view = DragNSView()
        view.onDoubleClick = onDoubleClick
        view.wantsLayer = true
        view.layer?.backgroundColor = NSColor.clear.cgColor
        return view
    }

    func updateNSView(_ nsView: DragNSView, context: Context) {
        nsView.onDoubleClick = onDoubleClick
    }

    final class DragNSView: NSView {
        var onDoubleClick: (() -> Bool)?

        override var mouseDownCanMoveWindow: Bool {
            return UserDefaults.standard.string(forKey: "workspacePresentationMode") == "minimal"
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            return bounds.contains(point) ? self : nil
        }

        override func mouseDown(with event: NSEvent) {
            guard let window = self.window else {
                super.mouseDown(with: event)
                return
            }

            if event.clickCount >= 2 {
                if UserDefaults.standard.string(forKey: "workspacePresentationMode") == "minimal" {
                    let action = UserDefaults.standard.persistentDomain(forName: UserDefaults.globalDomain)?["AppleActionOnDoubleClick"] as? String
                    switch action {
                    case "Minimize": window.miniaturize(nil)
                    default: window.zoom(nil)
                    }
                    return
                } else {
                    if onDoubleClick?() == true {
                        return
                    }
                }
            }

            if UserDefaults.standard.string(forKey: "workspacePresentationMode") == "minimal" {
                let wasMovable = window.isMovable
                window.isMovable = true
                window.performDrag(with: event)
                window.isMovable = wasMovable
            } else {
                super.mouseDown(with: event)
            }
        }
    }
}

private struct TabControlShortcutStoredShortcut: Decodable {
    let key: String
    let command: Bool
    let shift: Bool
    let option: Bool
    let control: Bool

    init(
        key: String,
        command: Bool,
        shift: Bool,
        option: Bool,
        control: Bool
    ) {
        self.key = key
        self.command = command
        self.shift = shift
        self.option = option
        self.control = control
    }

    var modifierFlags: NSEvent.ModifierFlags {
        var flags: NSEvent.ModifierFlags = []
        if command { flags.insert(.command) }
        if shift { flags.insert(.shift) }
        if option { flags.insert(.option) }
        if control { flags.insert(.control) }
        return flags
    }

    var modifierSymbol: String {
        var parts: [String] = []
        if control { parts.append("⌃") }
        if option { parts.append("⌥") }
        if shift { parts.append("⇧") }
        if command { parts.append("⌘") }
        return parts.joined()
    }
}

private enum TabControlShortcutSettings {
    static let surfaceByNumberKey = "shortcut.selectSurfaceByNumber"
    static let defaultShortcut = TabControlShortcutStoredShortcut(
        key: "1",
        command: false,
        shift: false,
        option: false,
        control: true
    )

    static func surfaceByNumberShortcut(defaults: UserDefaults = .standard) -> TabControlShortcutStoredShortcut {
        guard let data = defaults.data(forKey: surfaceByNumberKey),
              let shortcut = try? JSONDecoder().decode(TabControlShortcutStoredShortcut.self, from: data) else {
            return defaultShortcut
        }
        return shortcut
    }
}

struct TabControlShortcutModifier: Equatable {
    let modifierFlags: NSEvent.ModifierFlags
    let symbol: String
}

enum TabControlShortcutHintPolicy {
    static let intentionalHoldDelay: TimeInterval = 0.30
    static let showHintsOnCommandHoldKey = "shortcutHintShowOnCommandHold"
    static let defaultShowHintsOnCommandHold = true

    static func showHintsOnCommandHoldEnabled(defaults: UserDefaults = .standard) -> Bool {
        guard defaults.object(forKey: showHintsOnCommandHoldKey) != nil else {
            return defaultShowHintsOnCommandHold
        }
        return defaults.bool(forKey: showHintsOnCommandHoldKey)
    }

    static func hintModifier(
        for modifierFlags: NSEvent.ModifierFlags,
        defaults: UserDefaults = .standard
    ) -> TabControlShortcutModifier? {
        guard showHintsOnCommandHoldEnabled(defaults: defaults) else { return nil }
        let flags = modifierFlags.intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])
        let shortcut = TabControlShortcutSettings.surfaceByNumberShortcut(defaults: defaults)
        guard flags == shortcut.modifierFlags else { return nil }
        return TabControlShortcutModifier(
            modifierFlags: shortcut.modifierFlags,
            symbol: shortcut.modifierSymbol
        )
    }

    static func isCurrentWindow(
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?
    ) -> Bool {
        guard let hostWindowNumber, hostWindowIsKey else { return false }
        if let eventWindowNumber {
            return eventWindowNumber == hostWindowNumber
        }
        return keyWindowNumber == hostWindowNumber
    }

    static func shouldShowHints(
        for modifierFlags: NSEvent.ModifierFlags,
        hostWindowNumber: Int?,
        hostWindowIsKey: Bool,
        eventWindowNumber: Int?,
        keyWindowNumber: Int?,
        defaults: UserDefaults = .standard
    ) -> Bool {
        hintModifier(for: modifierFlags, defaults: defaults) != nil &&
            isCurrentWindow(
                hostWindowNumber: hostWindowNumber,
                hostWindowIsKey: hostWindowIsKey,
                eventWindowNumber: eventWindowNumber,
                keyWindowNumber: keyWindowNumber
            )
    }
}

private struct TabBarHostWindowReader: NSViewRepresentable {
    let onResolve: (NSWindow?) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in
            onResolve(view?.window)
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        DispatchQueue.main.async { [weak nsView] in
            onResolve(nsView?.window)
        }
    }
}

@MainActor
private final class TabControlShortcutKeyMonitor: ObservableObject {
    @Published private(set) var isShortcutHintVisible = false
    @Published private(set) var shortcutModifierSymbol = "⌃"

    private weak var hostWindow: NSWindow?
    private var hostWindowDidBecomeKeyObserver: NSObjectProtocol?
    private var hostWindowDidResignKeyObserver: NSObjectProtocol?
    private var flagsMonitor: Any?
    private var keyDownMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var pendingShowWorkItem: DispatchWorkItem?
    private var pendingModifier: TabControlShortcutModifier?

    func setHostWindow(_ window: NSWindow?) {
        guard hostWindow !== window else { return }
        removeHostWindowObservers()
        hostWindow = window
        guard let window else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        hostWindowDidBecomeKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.update(from: NSEvent.modifierFlags, eventWindow: nil)
            }
        }

        hostWindowDidResignKeyObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification,
            object: window,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func start() {
        guard flagsMonitor == nil else {
            update(from: NSEvent.modifierFlags, eventWindow: nil)
            return
        }

        flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { [weak self] event in
            self?.update(from: event.modifierFlags, eventWindow: event.window)
            return event
        }

        keyDownMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard self?.isCurrentWindow(eventWindow: event.window) == true else { return event }
            self?.cancelPendingHintShow(resetVisible: true)
            return event
        }

        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.cancelPendingHintShow(resetVisible: true)
            }
        }

        update(from: NSEvent.modifierFlags, eventWindow: nil)
    }

    func stop() {
        if let flagsMonitor {
            NSEvent.removeMonitor(flagsMonitor)
            self.flagsMonitor = nil
        }
        if let keyDownMonitor {
            NSEvent.removeMonitor(keyDownMonitor)
            self.keyDownMonitor = nil
        }
        if let resignObserver {
            NotificationCenter.default.removeObserver(resignObserver)
            self.resignObserver = nil
        }
        removeHostWindowObservers()
        cancelPendingHintShow(resetVisible: true)
    }

    private func isCurrentWindow(eventWindow: NSWindow?) -> Bool {
        TabControlShortcutHintPolicy.isCurrentWindow(
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        )
    }

    private func update(from modifierFlags: NSEvent.ModifierFlags, eventWindow: NSWindow?) {
        guard TabControlShortcutHintPolicy.shouldShowHints(
            for: modifierFlags,
            hostWindowNumber: hostWindow?.windowNumber,
            hostWindowIsKey: hostWindow?.isKeyWindow ?? false,
            eventWindowNumber: eventWindow?.windowNumber,
            keyWindowNumber: NSApp.keyWindow?.windowNumber
        ) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        guard let modifier = TabControlShortcutHintPolicy.hintModifier(for: modifierFlags) else {
            cancelPendingHintShow(resetVisible: true)
            return
        }

        if isShortcutHintVisible {
            shortcutModifierSymbol = modifier.symbol
            return
        }

        queueHintShow(for: modifier)
    }

    private func queueHintShow(for modifier: TabControlShortcutModifier) {
        if pendingModifier == modifier, pendingShowWorkItem != nil {
            return
        }

        pendingShowWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.pendingShowWorkItem = nil
            self.pendingModifier = nil
            guard TabControlShortcutHintPolicy.shouldShowHints(
                for: NSEvent.modifierFlags,
                hostWindowNumber: self.hostWindow?.windowNumber,
                hostWindowIsKey: self.hostWindow?.isKeyWindow ?? false,
                eventWindowNumber: nil,
                keyWindowNumber: NSApp.keyWindow?.windowNumber
            ) else { return }
            guard let currentModifier = TabControlShortcutHintPolicy.hintModifier(for: NSEvent.modifierFlags) else { return }
            self.shortcutModifierSymbol = currentModifier.symbol
            withAnimation(.easeInOut(duration: 0.14)) {
                self.isShortcutHintVisible = true
            }
        }

        pendingModifier = modifier
        pendingShowWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + TabControlShortcutHintPolicy.intentionalHoldDelay, execute: workItem)
    }

    private func cancelPendingHintShow(resetVisible: Bool) {
        pendingShowWorkItem?.cancel()
        pendingShowWorkItem = nil
        pendingModifier = nil
        if resetVisible {
            withAnimation(.easeInOut(duration: 0.14)) {
                isShortcutHintVisible = false
            }
        }
    }

    private func removeHostWindowObservers() {
        if let hostWindowDidBecomeKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidBecomeKeyObserver)
            self.hostWindowDidBecomeKeyObserver = nil
        }
        if let hostWindowDidResignKeyObserver {
            NotificationCenter.default.removeObserver(hostWindowDidResignKeyObserver)
            self.hostWindowDidResignKeyObserver = nil
        }
    }
}


/// Drop lifecycle state to prevent dropUpdated from re-setting state after performDrop
enum TabDropLifecycle {
    case idle
    case hovering
}

// MARK: - Tab Drop Delegate

struct TabDropDelegate: DropDelegate {
    let targetIndex: Int
    let pane: PaneState
    let bonsplitController: BonsplitController
    let controller: SplitViewController
    @Binding var dropTargetIndex: Int?
    @Binding var dropLifecycle: TabDropLifecycle

    func performDrop(info: DropInfo) -> Bool {
        #if DEBUG
        NSLog("[Bonsplit Drag] performDrop called, targetIndex: \(targetIndex)")
        #endif
#if DEBUG
        dlog("tab.drop pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex)")
#endif

        // Ensure all drag/drop side-effects run on the main actor. SwiftUI can call these
        // callbacks off-main, and SplitViewController is @MainActor.
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                performDrop(info: info)
            }
        }

        // Read from non-observable drag state — @Observable writes from createItemProvider
        // may not have propagated yet when performDrop runs.
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            guard let transfer = decodeTransfer(from: info),
                  transfer.isFromCurrentProcess else {
                return false
            }
            let request = BonsplitController.ExternalTabDropRequest(
                tabId: TabID(id: transfer.tab.id),
                sourcePaneId: PaneID(id: transfer.sourcePaneId),
                destination: .insert(targetPane: pane.id, targetIndex: targetIndex)
            )
            let handled = bonsplitController.onExternalTabDrop?(request) ?? false
            if handled {
                dropLifecycle = .idle
                dropTargetIndex = nil
            }
            return handled
        }

        // Execute synchronously when possible so the dragged tab disappears immediately.
        let applyMove = {
            // Ensure the move itself doesn't animate.
            withTransaction(Transaction(animation: nil)) {
                if sourcePaneId == pane.id {
                    guard let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else { return }
                    // Same-pane no-op: don't mutate the model (and don't show an indicator).
                    if targetIndex == sourceIndex || targetIndex == sourceIndex + 1 {
                        return
                    }
                    pane.moveTab(from: sourceIndex, to: targetIndex)
                } else {
                    _ = bonsplitController.moveTab(
                        TabID(id: draggedTab.id),
                        toPane: pane.id,
                        atIndex: targetIndex
                    )
                }
            }
        }

        applyMove()

        // Clear visual state immediately to prevent lingering indicators.
        // Must happen synchronously before returning, not in async callback.
        // Setting dropLifecycle to idle prevents dropUpdated from re-setting dropTargetIndex.
        dropLifecycle = .idle
        dropTargetIndex = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil

        return true
    }

    func dropEntered(info: DropInfo) {
        #if DEBUG
        NSLog("[Bonsplit Drag] dropEntered at index: \(targetIndex)")
        dlog(
            "tab.dropEntered pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) " +
            "hasDrag=\(controller.draggingTab != nil ? 1 : 0) " +
            "hasActive=\(controller.activeDragTab != nil ? 1 : 0)"
        )
        #endif
        dropLifecycle = .hovering
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            dropTargetIndex = nil
        } else {
            dropTargetIndex = targetIndex
        }
    }

    func dropExited(info: DropInfo) {
        #if DEBUG
        NSLog("[Bonsplit Drag] dropExited from index: \(targetIndex)")
        dlog("tab.dropExited pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex)")
        #endif
        dropLifecycle = .idle
        if dropTargetIndex == targetIndex {
            dropTargetIndex = nil
        }
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Guard against dropUpdated firing after performDrop/dropExited
        // This is the key fix for the lingering indicator bug
        guard dropLifecycle == .hovering else {
#if DEBUG
            dlog("tab.dropUpdated.skip pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) reason=lifecycle_idle")
#endif
            return DropProposal(operation: .move)
        }
        // Only update if this is the active target, and suppress same-pane no-op indicators.
        if shouldSuppressIndicatorForNoopSamePaneDrop() {
            if dropTargetIndex == targetIndex {
                dropTargetIndex = nil
            }
        } else if dropTargetIndex != targetIndex {
            dropTargetIndex = targetIndex
        }
#if DEBUG
        dlog(
            "tab.dropUpdated pane=\(pane.id.id.uuidString.prefix(5)) targetIndex=\(targetIndex) " +
            "dropTarget=\(dropTargetIndex.map(String.init) ?? "nil")"
        )
#endif
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Reject drops on inactive workspaces whose views are kept alive in a ZStack.
        guard controller.isInteractive else {
#if DEBUG
            dlog("tab.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) allowed=0 reason=inactive")
#endif
            return false
        }
        // The custom UTType alone is sufficient — only Bonsplit tab drags produce it.
        // Do NOT gate on draggingTab != nil: @Observable changes from createItemProvider
        // may not have propagated to the drop delegate yet, causing false rejections.
        let hasType = info.hasItemsConforming(to: [.tabTransfer])
        guard hasType else { return false }

        // Local drags use in-memory state and are always same-process.
        if controller.activeDragTab != nil || controller.draggingTab != nil {
            return true
        }

        // External drags (another Bonsplit controller) must include a payload from this process.
        guard let transfer = decodeTransfer(from: info),
              transfer.isFromCurrentProcess else {
            return false
        }
#if DEBUG
        let hasDrag = controller.draggingTab != nil
        let hasActive = controller.activeDragTab != nil
        dlog(
            "tab.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) " +
            "allowed=\(hasType ? 1 : 0) hasDrag=\(hasDrag ? 1 : 0) hasActive=\(hasActive ? 1 : 0)"
        )
#endif
        return true
    }

    private func shouldSuppressIndicatorForNoopSamePaneDrop() -> Bool {
        guard let draggedTab = controller.draggingTab,
              controller.dragSourcePaneId == pane.id,
              let sourceIndex = pane.tabs.firstIndex(where: { $0.id == draggedTab.id }) else {
            return false
        }
        // Insertion indices are expressed in "original array" coordinates; after removal,
        // inserting at `sourceIndex` or `sourceIndex + 1` results in no change.
        return targetIndex == sourceIndex || targetIndex == sourceIndex + 1
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }

    private func decodeTransfer(from info: DropInfo) -> TabTransferData? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)
        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        if let raw = pasteboard.string(forType: type) {
            return decodeTransfer(from: raw)
        }
        return nil
    }
}

import SwiftUI
import AppKit

/// Recursively renders a split node (pane or split)
struct SplitNodeView<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let node: SplitNode
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: BonsplitConfiguration.Appearance
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    var body: some View {
        switch node {
        case .pane(let paneState):
            // Wrap in NSHostingController for proper layout constraints
            SinglePaneWrapper(
                pane: paneState,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )

        case .split(let splitState):
            SplitContainerView(
                splitState: splitState,
                controller: controller,
                appearance: appearance,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                enableAnimations: enableAnimations,
                animationDuration: animationDuration
            )
        }
    }
}

/// Container NSView for a pane inside SinglePaneWrapper.
class PaneDragContainerView: NSView {
    override var isOpaque: Bool { false }
}

/// Wrapper that uses NSHostingController for proper AppKit layout constraints
struct SinglePaneWrapper<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Environment(SplitViewController.self) private var controller
    
    let pane: PaneState
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    func makeNSView(context: Context) -> NSView {
        let paneView = PaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle
        )
        let hostingController = NSHostingController(rootView: paneView)
        hostingController.view.translatesAutoresizingMaskIntoConstraints = false

        let containerView = PaneDragContainerView()
        containerView.wantsLayer = true
        containerView.layer?.backgroundColor = NSColor.clear.cgColor
        containerView.layer?.isOpaque = false
        containerView.layer?.masksToBounds = true
        containerView.addSubview(hostingController.view)

        NSLayoutConstraint.activate([
            hostingController.view.topAnchor.constraint(equalTo: containerView.topAnchor),
            hostingController.view.leadingAnchor.constraint(equalTo: containerView.leadingAnchor),
            hostingController.view.trailingAnchor.constraint(equalTo: containerView.trailingAnchor),
            hostingController.view.bottomAnchor.constraint(equalTo: containerView.bottomAnchor)
        ])

        // Store hosting controller to keep it alive
        context.coordinator.hostingController = hostingController

        return containerView
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        // Hide the container when inactive so AppKit's drag routing doesn't deliver
        // drag sessions to views belonging to background workspaces.
        nsView.isHidden = !controller.isInteractive
        nsView.wantsLayer = true
        nsView.layer?.backgroundColor = NSColor.clear.cgColor
        nsView.layer?.isOpaque = false
        nsView.layer?.masksToBounds = true

        let paneView = PaneContainerView(
            pane: pane,
            controller: controller,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle
        )
        context.coordinator.hostingController?.rootView = paneView
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    class Coordinator {
        var hostingController: NSHostingController<PaneContainerView<Content, EmptyContent>>?
    }
}

import SwiftUI
import AppKit

private var splitContainerProgrammaticSyncDepth = 0

private class ThemedSplitView: NSSplitView {
    var customDividerColor: NSColor?

    override var dividerColor: NSColor {
        customDividerColor ?? super.dividerColor
    }

    override var isOpaque: Bool { false }
}

#if DEBUG
private func debugPointString(_ point: NSPoint) -> String {
    let x = Int(point.x.rounded())
    let y = Int(point.y.rounded())
    return "\(x)x\(y)"
}

private func debugRectString(_ rect: NSRect) -> String {
    let x = Int(rect.origin.x.rounded())
    let y = Int(rect.origin.y.rounded())
    let w = Int(rect.size.width.rounded())
    let h = Int(rect.size.height.rounded())
    return "\(x):\(y)+\(w)x\(h)"
}

private final class DebugSplitView: ThemedSplitView {
    var debugSplitToken: String = "none"
    private var lastLoggedEventTimestampMs: Int = -1

    override func hitTest(_ point: NSPoint) -> NSView? {
        let result = super.hitTest(point)
        guard let event = NSApp.currentEvent else { return result }
        guard event.type == .leftMouseDown else { return result }
        guard event.window == window else { return result }
        let eventTimestampMs = Int((event.timestamp * 1000).rounded())
        guard eventTimestampMs != lastLoggedEventTimestampMs else { return result }
        lastLoggedEventTimestampMs = eventTimestampMs

        let dividerRect = debugDividerRect()
        let hitRect = dividerRect?.insetBy(dx: -4, dy: -4)
        let onDivider = dividerRect?.contains(point) == true
        let nearDivider = hitRect?.contains(point) == true
        let targetClass = result.map { NSStringFromClass(type(of: $0)) } ?? "nil"

        dlog(
            "divider.hitTest split=\(debugSplitToken) point=\(debugPointString(point)) target=\(targetClass) onDivider=\(onDivider ? 1 : 0) nearDivider=\(nearDivider ? 1 : 0)"
        )

        return result
    }

    private func debugDividerRect() -> NSRect? {
        guard arrangedSubviews.count >= 2 else { return nil }

        let a = arrangedSubviews[0].frame
        let b = arrangedSubviews[1].frame
        let thickness = dividerThickness

        if isVertical {
            guard a.width > 1, b.width > 1 else { return nil }
            let x = max(0, a.maxX)
            return NSRect(x: x, y: 0, width: thickness, height: bounds.height)
        }

        guard a.height > 1, b.height > 1 else { return nil }
        let y = max(0, a.maxY)
        return NSRect(x: 0, y: y, width: bounds.width, height: thickness)
    }
}
#endif

/// SwiftUI wrapper around NSSplitView for native split behavior
struct SplitContainerView<Content: View, EmptyContent: View>: NSViewRepresentable {
    @Bindable var splitState: SplitState
    let controller: SplitViewController
    let appearance: BonsplitConfiguration.Appearance
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    /// Callback when geometry changes. Bool indicates if change is during active divider drag.
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    /// Animation configuration
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    func makeCoordinator() -> Coordinator {
        Coordinator(
            splitState: splitState,
            minimumPaneWidth: appearance.minimumPaneWidth,
            minimumPaneHeight: appearance.minimumPaneHeight,
            onGeometryChange: onGeometryChange
        )
    }

    func makeNSView(context: Context) -> NSSplitView {
#if DEBUG
        let splitView: ThemedSplitView = {
            let debugSplitView = DebugSplitView()
            debugSplitView.debugSplitToken = String(splitState.id.uuidString.prefix(5))
            return debugSplitView
        }()
#else
        let splitView = ThemedSplitView()
#endif
        splitView.customDividerColor = TabBarColors.nsColorSeparator(for: appearance)
        splitView.isVertical = splitState.orientation == .horizontal
        splitView.dividerStyle = .thin
        splitView.delegate = context.coordinator
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.layer?.isOpaque = false

        // Keep arranged subviews stable (always 2) to avoid transient "collapse" flashes when
        // replacing pane<->split content. We swap the hosted content within these containers.
        let firstContainer = NSView()
        firstContainer.wantsLayer = true
        firstContainer.layer?.backgroundColor = NSColor.clear.cgColor
        firstContainer.layer?.isOpaque = false
        firstContainer.layer?.masksToBounds = true
        let firstController = makeHostingController(for: splitState.first)
        installHostingController(firstController, into: firstContainer)
        splitView.addArrangedSubview(firstContainer)
        context.coordinator.firstHostingController = firstController

        let secondContainer = NSView()
        secondContainer.wantsLayer = true
        secondContainer.layer?.backgroundColor = NSColor.clear.cgColor
        secondContainer.layer?.isOpaque = false
        secondContainer.layer?.masksToBounds = true
        let secondController = makeHostingController(for: splitState.second)
        installHostingController(secondController, into: secondContainer)
        splitView.addArrangedSubview(secondContainer)
        context.coordinator.secondHostingController = secondController

        context.coordinator.splitView = splitView

        // Capture animation origin before it gets cleared
        let animationOrigin = splitState.animationOrigin
#if DEBUG
        let splitDebugToken = String(splitState.id.uuidString.prefix(5))
        let orientationToken = splitState.orientation == .horizontal ? "horizontal" : "vertical"
        let animationOriginToken: String = {
            guard let animationOrigin else { return "none" }
            switch animationOrigin {
            case .fromFirst: return "fromFirst"
            case .fromSecond: return "fromSecond"
            }
        }()
#endif

        // Determine which pane is new (will be hidden initially)
        let newPaneIndex = animationOrigin == .fromFirst ? 0 : 1

        // Capture animation settings for async block
        let shouldAnimate = enableAnimations && animationOrigin != nil
        let duration = animationDuration

        if animationOrigin != nil {
            // Clear immediately so we don't re-animate on updates
            splitState.animationOrigin = nil

            if shouldAnimate {
                // Hide the NEW pane immediately to prevent flash
                splitView.arrangedSubviews[newPaneIndex].isHidden = true

                // Track that we're animating (skip delegate position updates)
                context.coordinator.isAnimating = true
            }
        }

        // Apply the initial divider position once after initial layout scheduling.
        func applyInitialDividerPosition() {
            if context.coordinator.didApplyInitialDividerPosition {
                return
            }

            let totalSize = splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
            let availableSize = max(totalSize - splitView.dividerThickness, 0)

            guard availableSize > 0 else {
                // makeNSView can run before NSSplitView has a real frame; retry on the
                // next runloop so we still get the intended entry animation.
                context.coordinator.initialDividerApplyAttempts += 1
#if DEBUG
                let attempt = context.coordinator.initialDividerApplyAttempts
                if attempt == 1 || attempt == 4 || attempt == 8 || attempt == 12 {
                    dlog(
                        "split.entry.wait split=\(splitDebugToken) orientation=\(orientationToken) " +
                        "origin=\(animationOriginToken) animate=\(shouldAnimate ? 1 : 0) " +
                        "attempt=\(attempt) total=\(Int(totalSize.rounded())) available=\(Int(availableSize.rounded()))"
                    )
                }
#endif
                if context.coordinator.initialDividerApplyAttempts < 12 {
                    DispatchQueue.main.async {
                        applyInitialDividerPosition()
                    }
                    return
                }

                // Safety fallback: don't leave the new pane hidden forever.
                context.coordinator.didApplyInitialDividerPosition = true
                if animationOrigin != nil, shouldAnimate {
                    splitView.arrangedSubviews[newPaneIndex].isHidden = false
                    context.coordinator.isAnimating = false
                }
#if DEBUG
                dlog(
                    "split.entry.fallback split=\(splitDebugToken) orientation=\(orientationToken) " +
                    "origin=\(animationOriginToken) animate=\(shouldAnimate ? 1 : 0) attempts=\(context.coordinator.initialDividerApplyAttempts)"
                )
#endif
                return
            }

            context.coordinator.didApplyInitialDividerPosition = true
            context.coordinator.initialDividerApplyAttempts = 0

            if animationOrigin != nil {
                let targetPosition = availableSize * 0.5
                splitState.dividerPosition = 0.5

                if shouldAnimate {
                    // Position at edge while new pane is hidden
                    let startPosition: CGFloat = animationOrigin == .fromFirst ? 0 : availableSize
#if DEBUG
                    dlog(
                        "split.entry.start split=\(splitDebugToken) orientation=\(orientationToken) " +
                        "origin=\(animationOriginToken) newPaneIndex=\(newPaneIndex) " +
                        "startPx=\(Int(startPosition.rounded())) targetPx=\(Int(targetPosition.rounded())) " +
                        "available=\(Int(availableSize.rounded()))"
                    )
#endif
                    context.coordinator.setPositionSafely(startPosition, in: splitView, layout: true)

                    // Wait for layout
                    DispatchQueue.main.async {
                        // Show the new pane and animate
                        splitView.arrangedSubviews[newPaneIndex].isHidden = false

                        SplitAnimator.shared.animate(
                            splitView: splitView,
                            from: startPosition,
                            to: targetPosition,
                            duration: duration
                        ) {
                            context.coordinator.isAnimating = false
                            // Re-assert exact 0.5 ratio to prevent pixel-rounding drift
                            splitState.dividerPosition = 0.5
                            context.coordinator.lastAppliedPosition = 0.5
#if DEBUG
                            dlog(
                                "split.entry.complete split=\(splitDebugToken) orientation=\(orientationToken) " +
                                "origin=\(animationOriginToken) finalRatio=\(String(format: "%.3f", splitState.dividerPosition))"
                            )
#endif
                        }
                    }
                } else {
                    // No animation - just set the position immediately
                    context.coordinator.setPositionSafely(targetPosition, in: splitView, layout: false)
#if DEBUG
                    dlog(
                        "split.entry.noAnimation split=\(splitDebugToken) orientation=\(orientationToken) " +
                        "origin=\(animationOriginToken) targetPx=\(Int(targetPosition.rounded())) " +
                        "enableAnimations=\(enableAnimations ? 1 : 0)"
                    )
#endif
                }
            } else {
                // No animation - just set the position
                let position = availableSize * splitState.dividerPosition
                context.coordinator.setPositionSafely(position, in: splitView, layout: false)
            }
        }

        DispatchQueue.main.async {
            applyInitialDividerPosition()
        }

        return splitView
    }

    func updateNSView(_ splitView: NSSplitView, context: Context) {
        // SwiftUI may reuse the same NSSplitView/Coordinator instance while the underlying SplitState
        // object changes (e.g., during split tree restructuring). Keep the coordinator pointed at
        // the latest state to avoid syncing geometry against a stale model.
        context.coordinator.update(
            splitState: splitState,
            minimumPaneWidth: appearance.minimumPaneWidth,
            minimumPaneHeight: appearance.minimumPaneHeight,
            onGeometryChange: onGeometryChange
        )

        // Hide the NSSplitView when inactive so AppKit's drag routing doesn't deliver
        // drag sessions to views belonging to background workspaces. SwiftUI's
        // .allowsHitTesting(false) only affects gesture recognizers, not AppKit's
        // view-hierarchy-based NSDraggingDestination routing.
        splitView.isHidden = !controller.isInteractive
        splitView.wantsLayer = true
        splitView.layer?.backgroundColor = NSColor.clear.cgColor
        splitView.layer?.isOpaque = false
        (splitView as? ThemedSplitView)?.customDividerColor = TabBarColors.nsColorSeparator(for: appearance)

        // Update orientation if changed
        splitView.isVertical = splitState.orientation == .horizontal

        // Update children. When a child's node type changes (split→pane or pane→split),
        // replace the hosted content (not the arranged subview) to ensure native NSViews
        // (e.g., Metal-backed terminals) are properly moved through the AppKit hierarchy
        // without briefly dropping arrangedSubviews to 1.
        let arranged = splitView.arrangedSubviews
        if arranged.count >= 2 {
            let firstType = splitState.first.nodeType
            let secondType = splitState.second.nodeType

            let firstContainer = arranged[0]
            let secondContainer = arranged[1]
            firstContainer.wantsLayer = true
            firstContainer.layer?.backgroundColor = NSColor.clear.cgColor
            firstContainer.layer?.isOpaque = false
            secondContainer.wantsLayer = true
            secondContainer.layer?.backgroundColor = NSColor.clear.cgColor
            secondContainer.layer?.isOpaque = false

            updateHostedContent(
                in: firstContainer,
                node: splitState.first,
                nodeTypeChanged: firstType != context.coordinator.firstNodeType,
                controller: &context.coordinator.firstHostingController
            )
            context.coordinator.firstNodeType = firstType

            updateHostedContent(
                in: secondContainer,
                node: splitState.second,
                nodeTypeChanged: secondType != context.coordinator.secondNodeType,
                controller: &context.coordinator.secondHostingController
            )
            context.coordinator.secondNodeType = secondType
        }

        // Access dividerPosition to ensure SwiftUI tracks this dependency
        // Then sync if the position changed externally
        let currentPosition = splitState.dividerPosition
        context.coordinator.syncPosition(currentPosition, in: splitView)
    }

    // MARK: - Helpers

    private func makeHostingController(for node: SplitNode) -> NSHostingController<AnyView> {
        let hostingController = NSHostingController(rootView: AnyView(makeView(for: node)))
        if #available(macOS 13.0, *) {
            // NSSplitView owns pane geometry. Keep NSHostingController from publishing
            // intrinsic-size constraints that force a minimum pane width.
            hostingController.sizingOptions = []
        }

        let hostedView = hostingController.view
        // NSSplitView lays out arranged subviews by setting frames. Leaving Auto Layout
        // enabled on these NSHostingViews can allow them to compress to 0 during
        // structural updates, collapsing panes.
        hostedView.translatesAutoresizingMaskIntoConstraints = true
        hostedView.autoresizingMask = [.width, .height]
        // Do not let SwiftUI intrinsic size push split panes wider than the model frame.
        let relaxed = NSLayoutConstraint.Priority(1)
        hostedView.setContentHuggingPriority(relaxed, for: .horizontal)
        hostedView.setContentCompressionResistancePriority(relaxed, for: .horizontal)
        hostedView.setContentHuggingPriority(relaxed, for: .vertical)
        hostedView.setContentCompressionResistancePriority(relaxed, for: .vertical)
        return hostingController
    }

    private func installHostingController(_ hostingController: NSHostingController<AnyView>, into container: NSView) {
        let hostedView = hostingController.view
        hostedView.frame = container.bounds
        hostedView.autoresizingMask = [.width, .height]
        if hostedView.superview !== container {
            container.addSubview(hostedView)
        }
    }

    private func updateHostedContent(
        in container: NSView,
        node: SplitNode,
        nodeTypeChanged: Bool,
        controller: inout NSHostingController<AnyView>?
    ) {
        // Historically we recreated the NSHostingController when the child node type changed
        // (pane <-> split) to force a full detach/reattach of native AppKit subviews.
        //
        // In practice, that can introduce a single-frame "blank flash" for Metal/IOSurface-backed
        // content during split collapse (SwiftUI tears down the old subtree before the new subtree
        // has produced its native backing views).
        //
        // Keeping the hosting controller stable and just swapping its rootView makes the update
        // atomic from AppKit's perspective and avoids the transient blank frame.
        _ = nodeTypeChanged // keep signature; behavior is intentionally identical either way.

        if let current = controller {
            current.rootView = AnyView(makeView(for: node))
            // Ensure fill if container bounds changed without a layout pass yet.
            current.view.frame = container.bounds
            return
        }

        let newController = makeHostingController(for: node)
        installHostingController(newController, into: container)
        controller = newController
    }

    @ViewBuilder
    private func makeView(for node: SplitNode) -> some View {
        switch node {
        case .pane(let paneState):
            PaneContainerView(
                pane: paneState,
                controller: controller,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle
            )
        case .split(let nestedSplitState):
            SplitContainerView(
                splitState: nestedSplitState,
                controller: controller,
                appearance: appearance,
                contentBuilder: contentBuilder,
                emptyPaneBuilder: emptyPaneBuilder,
                showSplitButtons: showSplitButtons,
                contentViewLifecycle: contentViewLifecycle,
                onGeometryChange: onGeometryChange,
                enableAnimations: enableAnimations,
                animationDuration: animationDuration
            )
        }
    }

    // MARK: - Coordinator

    class Coordinator: NSObject, NSSplitViewDelegate {
        var splitState: SplitState
        private var splitStateId: UUID
        private var minimumPaneWidth: CGFloat
        private var minimumPaneHeight: CGFloat
        weak var splitView: NSSplitView?
        var isAnimating = false
        var didApplyInitialDividerPosition = false
        /// Initial divider placement can run before NSSplitView has a real size.
        /// Retry a few turns so entry animations are not dropped on first layout.
        var initialDividerApplyAttempts = 0
        var onGeometryChange: ((_ isDragging: Bool) -> Void)?
        /// Track last applied position to detect external changes
        var lastAppliedPosition: CGFloat = 0.5
        // Guard programmatic `setPosition` re-entrancy from resize callbacks.
        var isSyncingProgrammatically = false
        /// Track if user is actively dragging the divider
        var isDragging = false
        /// Track child node types to detect structural changes
        var firstNodeType: SplitNode.NodeType
        var secondNodeType: SplitNode.NodeType
        /// Retain hosting controllers so SwiftUI content stays alive
        var firstHostingController: NSHostingController<AnyView>?
        var secondHostingController: NSHostingController<AnyView>?

        init(
            splitState: SplitState,
            minimumPaneWidth: CGFloat,
            minimumPaneHeight: CGFloat,
            onGeometryChange: ((_ isDragging: Bool) -> Void)?
        ) {
            self.splitState = splitState
            self.splitStateId = splitState.id
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight
            self.onGeometryChange = onGeometryChange
            self.lastAppliedPosition = splitState.dividerPosition
            self.firstNodeType = splitState.first.nodeType
            self.secondNodeType = splitState.second.nodeType
        }

        func update(
            splitState newState: SplitState,
            minimumPaneWidth: CGFloat,
            minimumPaneHeight: CGFloat,
            onGeometryChange: ((_ isDragging: Bool) -> Void)?
        ) {
            self.onGeometryChange = onGeometryChange
            self.minimumPaneWidth = minimumPaneWidth
            self.minimumPaneHeight = minimumPaneHeight

            // If SwiftUI reused this representable for a different split node,
            // reset our cached sync state so we don't "pin" the divider to an edge.
            if newState.id != splitStateId {
                splitStateId = newState.id
                splitState = newState
                lastAppliedPosition = newState.dividerPosition
                didApplyInitialDividerPosition = false
                initialDividerApplyAttempts = 0
                isAnimating = false
                isDragging = false
                firstNodeType = newState.first.nodeType
                secondNodeType = newState.second.nodeType
                return
            }

            // Same split node; keep reference updated anyway.
            splitState = newState
        }

        private func splitTotalSize(in splitView: NSSplitView) -> CGFloat {
            splitState.orientation == .horizontal
                ? splitView.bounds.width
                : splitView.bounds.height
        }

        private func splitAvailableSize(in splitView: NSSplitView) -> CGFloat {
            max(splitTotalSize(in: splitView) - splitView.dividerThickness, 0)
        }

        private func requestedMinimumPaneSize() -> CGFloat {
            max(
                splitState.orientation == .horizontal ? minimumPaneWidth : minimumPaneHeight,
                1
            )
        }

        private func effectiveMinimumPaneSize(in splitView: NSSplitView) -> CGFloat {
            let available = splitAvailableSize(in: splitView)
            guard available > 0 else { return 0 }
            // When the container is too small for both configured minimums, keep both panes
            // visible by evenly splitting the available space rather than forcing invalid bounds.
            return min(requestedMinimumPaneSize(), available / 2)
        }

        private func normalizedDividerBounds(in splitView: NSSplitView) -> ClosedRange<CGFloat> {
            let available = splitAvailableSize(in: splitView)
            guard available > 0 else { return 0...1 }
            let minNormalized = min(0.5, effectiveMinimumPaneSize(in: splitView) / available)
            return minNormalized...(1 - minNormalized)
        }

        private func clampedDividerPosition(_ position: CGFloat, in splitView: NSSplitView) -> CGFloat {
            let available = splitAvailableSize(in: splitView)
            guard available > 0 else { return 0 }
            let minPaneSize = effectiveMinimumPaneSize(in: splitView)
            let maxPosition = max(minPaneSize, available - minPaneSize)
            return min(max(position, minPaneSize), maxPosition)
        }
#if DEBUG
        private func debugLogDividerDragSkip(
            _ reason: String,
            splitView: NSSplitView,
            event: NSEvent? = nil,
            location: NSPoint? = nil,
            dividerRect: NSRect? = nil,
            hitRect: NSRect? = nil
        ) {
            var message = "divider.dragCheck.skip split=\(splitState.id.uuidString.prefix(5)) reason=\(reason)"
            if let event {
                let ageMs = Int(((ProcessInfo.processInfo.systemUptime - event.timestamp) * 1000).rounded())
                message += " eventType=\(event.type.rawValue) ageMs=\(ageMs)"
            } else {
                message += " event=nil"
            }
            message += " splitWin=\(splitView.window?.windowNumber ?? -1)"
            if let location {
                message += " loc=\(debugPointString(location))"
            }
            if let dividerRect {
                message += " divider=\(debugRectString(dividerRect))"
            }
            if let hitRect {
                message += " hit=\(debugRectString(hitRect))"
            }
            dlog(message)
        }
#endif
        /// Apply external position changes to the NSSplitView
        func setPositionSafely(_ position: CGFloat, in splitView: NSSplitView, layout: Bool = true) {
            isSyncingProgrammatically = true
            splitContainerProgrammaticSyncDepth += 1
            defer {
                isSyncingProgrammatically = false
                splitContainerProgrammaticSyncDepth = max(0, splitContainerProgrammaticSyncDepth - 1)
            }
            let clampedPosition = clampedDividerPosition(position, in: splitView)
            splitView.setPosition(clampedPosition, ofDividerAt: 0)
            if layout {
                splitView.layoutSubtreeIfNeeded()
            }
        }

        func syncPosition(_ statePosition: CGFloat, in splitView: NSSplitView) {
            guard !isAnimating else { return }
            guard !isSyncingProgrammatically else { return }
            guard splitContainerProgrammaticSyncDepth == 0 else { return }

            guard splitView.arrangedSubviews.count >= 2 else {
                // Structural updates can temporarily remove an arranged subview.
                // A subsequent update/layout pass will re-apply the model position.
#if DEBUG
                BonsplitDebugCounters.recordArrangedSubviewUnderflow()
#endif
                return
            }

            let availableSize = splitAvailableSize(in: splitView)

            // During view reparenting, NSSplitView can briefly report 0-sized bounds.
            // A later layout pass with real bounds will apply the model ratio.
            guard availableSize > 0 else { return }
            let stateBounds = normalizedDividerBounds(in: splitView)
            let clampedStatePosition = max(
                stateBounds.lowerBound,
                min(stateBounds.upperBound, statePosition)
            )

            // Keep the view in sync even if the model hasn't changed. Structural updates (pane↔split)
            // can temporarily reset divider positions; lastAppliedPosition alone isn't enough.
            let currentDividerPixels: CGFloat = {
                let firstSubview = splitView.arrangedSubviews[0]
                return splitState.orientation == .horizontal ? firstSubview.frame.width : firstSubview.frame.height
            }()
            let currentNormalized = max(
                stateBounds.lowerBound,
                min(stateBounds.upperBound, currentDividerPixels / availableSize)
            )

            if abs(clampedStatePosition - lastAppliedPosition) <= 0.01 &&
                abs(currentNormalized - clampedStatePosition) <= 0.01 {
                return
            }

            let pixelPosition = availableSize * clampedStatePosition
            setPositionSafely(pixelPosition, in: splitView, layout: true)
            lastAppliedPosition = clampedStatePosition
        }

        func splitViewWillResizeSubviews(_ notification: Notification) {
            guard let splitView = notification.object as? NSSplitView else { return }
            // If the left mouse button isn't down, this can't be an interactive divider drag.
            // (`splitViewWillResizeSubviews` can fire for programmatic/layout-driven resizes too.)
            guard (NSEvent.pressedMouseButtons & 1) != 0 else {
#if DEBUG
                if let event = NSApp.currentEvent,
                   event.type == .leftMouseDown || event.type == .leftMouseDragged {
                    debugLogDividerDragSkip("leftMouseNotPressed", splitView: splitView, event: event)
                }
#endif
                isDragging = false
                return
            }

            // If we're already tracking an active drag, keep the flag until mouse-up.
            if isDragging {
                return
            }

            guard let event = NSApp.currentEvent else {
#if DEBUG
                debugLogDividerDragSkip("noCurrentEvent", splitView: splitView, event: nil)
#endif
                return
            }

            // Only treat this as a divider drag if the pointer is actually on the divider.
            // This delegate callback can also fire during window resizes or structural updates,
            // and persisting divider ratios in those cases can permanently collapse a pane.
            let now = ProcessInfo.processInfo.systemUptime
            // `NSApp.currentEvent` can be stale when called from async UI work (e.g. socket commands).
            // Only trust very recent events.
            guard (now - event.timestamp) < 0.1 else {
#if DEBUG
                debugLogDividerDragSkip("staleCurrentEvent", splitView: splitView, event: event)
#endif
                return
            }
            guard event.type == .leftMouseDown || event.type == .leftMouseDragged else {
#if DEBUG
                debugLogDividerDragSkip("wrongEventType", splitView: splitView, event: event)
#endif
                return
            }
            guard event.window == splitView.window else {
#if DEBUG
                debugLogDividerDragSkip("windowMismatch", splitView: splitView, event: event)
#endif
                return
            }
            guard splitView.arrangedSubviews.count >= 2 else {
#if DEBUG
                debugLogDividerDragSkip("arrangedUnderflow", splitView: splitView, event: event)
#endif
                return
            }

            let location = splitView.convert(event.locationInWindow, from: nil)
            let a = splitView.arrangedSubviews[0].frame
            let b = splitView.arrangedSubviews[1].frame
            let thickness = splitView.dividerThickness
            let dividerRect: NSRect
            if splitView.isVertical {
                // If we don't have real frames yet (during structural updates), don't infer dragging.
                guard a.width > 1, b.width > 1 else {
#if DEBUG
                    debugLogDividerDragSkip("invalidSubviewWidths", splitView: splitView, event: event, location: location)
#endif
                    return
                }
                // Vertical divider between left/right arranged subviews.
                let x = max(0, a.maxX)
                dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
            } else {
                guard a.height > 1, b.height > 1 else {
#if DEBUG
                    debugLogDividerDragSkip("invalidSubviewHeights", splitView: splitView, event: event, location: location)
#endif
                    return
                }
                // Horizontal divider between top/bottom arranged subviews.
                let y = max(0, a.maxY)
                dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
            }
            let hitRect = dividerRect.insetBy(dx: -4, dy: -4)
            if hitRect.contains(location) {
                isDragging = true
#if DEBUG
                dlog(
                    "divider.dragStart split=\(splitState.id.uuidString.prefix(5)) loc=\(debugPointString(location)) divider=\(debugRectString(dividerRect)) hit=\(debugRectString(hitRect))"
                )
#endif
            } else {
#if DEBUG
                debugLogDividerDragSkip(
                    "hitRectMiss",
                    splitView: splitView,
                    event: event,
                    location: location,
                    dividerRect: dividerRect,
                    hitRect: hitRect
                )
#endif
            }
        }

        func splitViewDidResizeSubviews(_ notification: Notification) {
            // Skip position updates during animation
            guard !isAnimating else { return }
            guard let splitView = notification.object as? NSSplitView else { return }
#if DEBUG
            let subframes = splitView.arrangedSubviews.enumerated().map { (i, v) in
                "\(i)=\(Int(v.frame.width))x\(Int(v.frame.height))"
            }.joined(separator: " ")
            dlog("split.didResize split=\(splitState.id.uuidString.prefix(5)) orient=\(splitState.orientation == .horizontal ? "H" : "V") container=\(Int(splitView.frame.width))x\(Int(splitView.frame.height)) subs=[\(subframes)] anim=\(isAnimating ? 1 : 0) sync=\(isSyncingProgrammatically ? 1 : 0)")
#endif
            if isSyncingProgrammatically || splitContainerProgrammaticSyncDepth > 0 {
                return
            }
            // Prevent stale drag state from persisting through programmatic/async resizes.
            let leftDown = (NSEvent.pressedMouseButtons & 1) != 0
            if !leftDown {
#if DEBUG
                if isDragging {
                    dlog("divider.dragStateReset split=\(splitState.id.uuidString.prefix(5)) reason=leftMouseReleased")
                }
#endif
                isDragging = false
            }
            // During structural updates (pane↔split), arranged subviews can be temporarily removed.
            // Avoid persisting a dividerPosition derived from a transient 1-subview layout.
            guard splitView.arrangedSubviews.count >= 2 else {
#if DEBUG
                BonsplitDebugCounters.recordArrangedSubviewUnderflow()
#endif
                return
            }

            let availableSize = splitAvailableSize(in: splitView)

            guard availableSize > 0 else { return }

            if let firstSubview = splitView.arrangedSubviews.first {
                let dividerPosition = splitState.orientation == .horizontal
                    ? firstSubview.frame.width
                    : firstSubview.frame.height

                var normalizedPosition = dividerPosition / availableSize

                // Never persist a fully-collapsed pane ratio. (This can happen if we ever
                // see a transient 0-sized layout during a drag or structural update.)
                let normalizedBounds = normalizedDividerBounds(in: splitView)
                normalizedPosition = max(
                    normalizedBounds.lowerBound,
                    min(normalizedBounds.upperBound, normalizedPosition)
                )

                // Snap to 0.5 if very close (prevents pixel-rounding drift)
                if abs(normalizedPosition - 0.5) < 0.01 {
                    normalizedPosition = 0.5
                }

                // Check if drag ended (mouse up)
                let wasDragging = isDragging && leftDown
                if let event = NSApp.currentEvent, event.type == .leftMouseUp {
#if DEBUG
                    dlog("divider.dragEnd split=\(splitState.id.uuidString.prefix(5))")
#endif
                    isDragging = false
                }

                // Only update the model when the user is actively dragging. For other resizes
                // (window resizes, view reparenting, pane↔split structural updates), the model's
                // dividerPosition should remain stable; syncPosition() will keep the view aligned.
                guard wasDragging else {
#if DEBUG
                    let eventType = NSApp.currentEvent.map { String(describing: $0.type) } ?? "none"
                    dlog(
                        "divider.resizeIgnored split=\(splitState.id.uuidString.prefix(5)) eventType=\(eventType) leftDown=\(leftDown ? 1 : 0) isDragging=\(isDragging ? 1 : 0) normalized=\(String(format: "%.3f", normalizedPosition)) model=\(String(format: "%.3f", self.splitState.dividerPosition))"
                    )
#endif
                    let statePosition = self.splitState.dividerPosition
                    // Re-assert synchronously. setPositionSafely sets isSyncingProgrammatically=true,
                    // so the recursive splitViewDidResizeSubviews call is caught by the guard above.
                    // Deferring to the next runloop turn would allow the transient frame to propagate
                    // through SwiftUI layout → ghostty terminal resize → reflow, causing content shifts.
                    self.syncPosition(statePosition, in: splitView)
                    self.onGeometryChange?(false)
                    return
                }

                Task { @MainActor in
#if DEBUG
                    dlog(
                        "divider.dragUpdate split=\(splitState.id.uuidString.prefix(5)) normalized=\(String(format: "%.3f", normalizedPosition)) px=\(Int(dividerPosition.rounded())) available=\(Int(availableSize.rounded()))"
                    )
#endif
                    self.splitState.dividerPosition = normalizedPosition
                    self.lastAppliedPosition = normalizedPosition
                    // Notify geometry change with drag state
                    self.onGeometryChange?(wasDragging)
                }
            }
        }

        func splitView(_ splitView: NSSplitView, effectiveRect proposedEffectiveRect: NSRect, forDrawnRect drawnRect: NSRect, ofDividerAt dividerIndex: Int) -> NSRect {
            let expanded = drawnRect.insetBy(dx: -5, dy: -5)
            return proposedEffectiveRect.union(expanded)
        }

        func splitView(_ splitView: NSSplitView, additionalEffectiveRectOfDividerAt dividerIndex: Int) -> NSRect {
            guard splitView.arrangedSubviews.count >= dividerIndex + 2 else { return .zero }

            let first = splitView.arrangedSubviews[dividerIndex].frame
            let second = splitView.arrangedSubviews[dividerIndex + 1].frame
            let thickness = splitView.dividerThickness

            let dividerRect: NSRect
            if splitView.isVertical {
                guard first.width > 1, second.width > 1 else { return .zero }
                let x = max(0, first.maxX)
                dividerRect = NSRect(x: x, y: 0, width: thickness, height: splitView.bounds.height)
            } else {
                guard first.height > 1, second.height > 1 else { return .zero }
                let y = max(0, first.maxY)
                dividerRect = NSRect(x: 0, y: y, width: splitView.bounds.width, height: thickness)
            }

            return dividerRect.insetBy(dx: -5, dy: -5)
        }

        func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            // Allow edge positions during animation
            guard !isAnimating else { return proposedMinimumPosition }
            return max(proposedMinimumPosition, effectiveMinimumPaneSize(in: splitView))
        }

        func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat, ofSubviewAt dividerIndex: Int) -> CGFloat {
            // Allow edge positions during animation
            guard !isAnimating else { return proposedMaximumPosition }
            let availableSize = splitAvailableSize(in: splitView)
            let minimumPaneSize = effectiveMinimumPaneSize(in: splitView)
            let maxCoordinate = max(minimumPaneSize, availableSize - minimumPaneSize)
            return min(proposedMaximumPosition, maxCoordinate)
        }
    }
}

import SwiftUI

/// Main container view that renders the entire split tree (internal implementation)
struct SplitViewContainer<Content: View, EmptyContent: View>: View {
    @Environment(SplitViewController.self) private var controller

    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    let appearance: BonsplitConfiguration.Appearance
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch
    var onGeometryChange: ((_ isDragging: Bool) -> Void)?
    var enableAnimations: Bool = true
    var animationDuration: Double = 0.15

    var body: some View {
        GeometryReader { geometry in
            splitNodeContent
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(TabBarColors.paneBackground(for: appearance))
                .focusable()
                .focusEffectDisabled()
                .onChange(of: geometry.size) { _, newSize in
                    updateContainerFrame(geometry: geometry)
                }
                .onAppear {
                    updateContainerFrame(geometry: geometry)
                }
        }
    }

    private func updateContainerFrame(geometry: GeometryProxy) {
        // Get frame in global coordinate space
        let frame = geometry.frame(in: .global)
        controller.containerFrame = frame
        onGeometryChange?(false)  // Container resize is not a drag
    }

    @ViewBuilder
    private var splitNodeContent: some View {
        let nodeToRender = controller.zoomedNode ?? controller.rootNode
        SplitNodeView(
            node: nodeToRender,
            contentBuilder: contentBuilder,
            emptyPaneBuilder: emptyPaneBuilder,
            appearance: appearance,
            showSplitButtons: showSplitButtons,
            contentViewLifecycle: contentViewLifecycle,
            onGeometryChange: onGeometryChange,
            enableAnimations: enableAnimations,
            animationDuration: animationDuration
        )
    }
}

enum PaneDropLifecycle {
    case idle
    case hovering
}

private struct PaneDropPlaceholderOverlay: View {
    let zone: DropZone?
    let size: CGSize

    private let placeholderColor = Color.accentColor.opacity(0.25)
    private let borderColor = Color.accentColor
    private let padding: CGFloat = 4

    var body: some View {
        let frame = overlayFrame(for: zone, in: size)

        RoundedRectangle(cornerRadius: 8)
            .fill(placeholderColor)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(borderColor, lineWidth: 2)
            )
            .frame(width: frame.width, height: frame.height)
            .offset(x: frame.minX, y: frame.minY)
            .opacity(zone != nil ? 1 : 0)
            .animation(.spring(duration: 0.25, bounce: 0.15), value: zone)
    }

    private func overlayFrame(for zone: DropZone?, in size: CGSize) -> CGRect {
        switch zone {
        case .center, .none:
            return CGRect(
                x: padding,
                y: padding,
                width: size.width - padding * 2,
                height: size.height - padding * 2
            )
        case .left:
            return CGRect(
                x: padding,
                y: padding,
                width: size.width / 2 - padding,
                height: size.height - padding * 2
            )
        case .right:
            return CGRect(
                x: size.width / 2,
                y: padding,
                width: size.width / 2 - padding,
                height: size.height - padding * 2
            )
        case .top:
            return CGRect(
                x: padding,
                y: padding,
                width: size.width - padding * 2,
                height: size.height / 2 - padding
            )
        case .bottom:
            return CGRect(
                x: padding,
                y: size.height / 2,
                width: size.width - padding * 2,
                height: size.height / 2 - padding
            )
        }
    }
}

struct PaneDropInteractionContainer<Content: View, DropLayer: View>: View {
    let activeDropZone: DropZone?
    let content: Content
    let dropLayer: (CGSize) -> DropLayer

    init(
        activeDropZone: DropZone?,
        @ViewBuilder content: () -> Content,
        @ViewBuilder dropLayer: @escaping (CGSize) -> DropLayer
    ) {
        self.activeDropZone = activeDropZone
        self.content = content()
        self.dropLayer = dropLayer
    }

    var body: some View {
        GeometryReader { geometry in
            let size = geometry.size

            content
                .frame(width: size.width, height: size.height)
                .overlay {
                    dropLayer(size)
                }
                .overlay(alignment: .topLeading) {
                    PaneDropPlaceholderOverlay(zone: activeDropZone, size: size)
                        .allowsHitTesting(false)
                }
        }
        .clipped()
    }
}

/// Container for a single pane with its tab bar and content area
struct PaneContainerView<Content: View, EmptyContent: View>: View {
    @Environment(BonsplitController.self) private var bonsplitController

    @Bindable var pane: PaneState
    @Bindable var controller: SplitViewController
    let contentBuilder: (TabItem, PaneID) -> Content
    let emptyPaneBuilder: (PaneID) -> EmptyContent
    var showSplitButtons: Bool = true
    var contentViewLifecycle: ContentViewLifecycle = .recreateOnSwitch

    @State private var activeDropZone: DropZone?
    @State private var dropLifecycle: PaneDropLifecycle = .idle

    private var isFocused: Bool {
        controller.focusedPaneId == pane.id
    }

    private var isTabDragActive: Bool {
        controller.draggingTab != nil || controller.activeDragTab != nil
    }

    var body: some View {
        VStack(spacing: 0) {
            // Tab bar
            TabBarView(
                pane: pane,
                isFocused: isFocused,
                showSplitButtons: showSplitButtons
            )

            // Content area with drop zones
            contentAreaWithDropZones
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // Clear drop state when drag ends elsewhere (cancelled, dropped in another pane, etc.)
        .onChange(of: controller.draggingTab) { _, newValue in
#if DEBUG
            dlog(
                "pane.dragState pane=\(pane.id.id.uuidString.prefix(5)) " +
                "draggingTab=\(newValue != nil ? 1 : 0) " +
                "activeDragTab=\(controller.activeDragTab != nil ? 1 : 0) " +
                "dropHit=\(isTabDragActive ? 1 : 0)"
            )
#endif
            if newValue == nil {
                activeDropZone = nil
                dropLifecycle = .idle
            }
        }
        .onChange(of: activeDropZone) { oldValue, newValue in
#if DEBUG
            let oldZone = oldValue.map { String(describing: $0) } ?? "none"
            let newZone = newValue.map { String(describing: $0) } ?? "none"
            let selected = pane.selectedTab ?? pane.tabs.first
            let icon = selected?.icon ?? "nil"
            dlog(
                "pane.overlayZone pane=\(pane.id.id.uuidString.prefix(5)) " +
                "old=\(oldZone) new=\(newZone) selectedIcon=\(icon)"
            )
#endif
        }
    }

    // MARK: - Content Area with Drop Zones

    @ViewBuilder
    private var contentAreaWithDropZones: some View {
        PaneDropInteractionContainer(activeDropZone: activeDropZone) {
            contentArea
        } dropLayer: { size in
            // Drop zones layer (above content, receives drops and taps)
            dropZonesLayer(size: size)
        }
    }

    // MARK: - Content Area

    @ViewBuilder
    private var contentArea: some View {
        Group {
            if pane.tabs.isEmpty {
                emptyPaneView
            } else {
                switch contentViewLifecycle {
                case .recreateOnSwitch:
                    // Original behavior: only render selected tab
                    //
                    // `selectedTabId` can be transiently nil (or point at a tab that is being moved/closed)
                    // during rapid split/tab mutations. Rendering nothing for a single SwiftUI update causes
                    // a visible blank flash. If we have tabs, always render a stable fallback.
                    if let selectedTab = pane.selectedTab ?? pane.tabs.first {
                        contentBuilder(selectedTab, pane.id)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            // When the content is an NSViewRepresentable (e.g. WKWebView), it can
                            // sit above SwiftUI overlays and swallow drop events. During tab drags,
                            // disable hit testing for the content so our dropZonesLayer reliably
                            // receives the drag/drop interaction.
                            .allowsHitTesting(!isTabDragActive)
                            // Tab selection is often driven by `withAnimation` in the tab bar;
                            // don't crossfade the content when switching tabs.
                            .transition(.identity)
                            .transaction { tx in
                                tx.animation = nil
                            }
                    }

                case .keepAllAlive:
                    // macOS-like behavior: keep all tab views in hierarchy
                    let effectiveSelectedTabId = pane.selectedTabId ?? pane.tabs.first?.id
                    ZStack {
                        ForEach(pane.tabs) { tab in
                            contentBuilder(tab, pane.id)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .opacity(tab.id == effectiveSelectedTabId ? 1 : 0)
                                .allowsHitTesting(!isTabDragActive && tab.id == effectiveSelectedTabId)
                        }
                    }
                    // Prevent SwiftUI from animating Metal-backed views during tab moves.
                    // This avoids blank content when GhosttyKit terminals are snapshotted.
                    .transaction { tx in
                        tx.disablesAnimations = true
                    }
                }
            }
        }
        // Ensure a tab switch doesn't implicitly animate other animatable properties in this subtree.
        .animation(nil, value: pane.selectedTabId)
        // Expose the active drop zone to portal-hosted content so it can render
        // its own overlay above the AppKit surface.
        .environment(\.paneDropZone, activeDropZone)
    }

    // MARK: - Drop Zones Layer

    @ViewBuilder
    private func dropZonesLayer(size: CGSize) -> some View {
        // Keep tap-to-focus and drag-drop routing as separate layers.
        //
        // Why: SwiftUI state propagation for `isTabDragActive` can lag behind the
        // actual AppKit drag lifecycle (especially over portal-hosted terminals),
        // causing a drag to start while this view is still non-hit-testable.
        // The drop layer therefore stays always available for `.tabTransfer`.
        ZStack {
            Color.clear
                .onTapGesture {
#if DEBUG
                    dlog("pane.focus pane=\(pane.id.id.uuidString.prefix(5))")
#endif
                    controller.focusPane(pane.id)
                }
                .allowsHitTesting(!isTabDragActive)

            Color.clear
                .onDrop(of: [.tabTransfer], delegate: UnifiedPaneDropDelegate(
                    size: size,
                    pane: pane,
                    controller: controller,
                    bonsplitController: bonsplitController,
                    activeDropZone: $activeDropZone,
                    dropLifecycle: $dropLifecycle
                ))
        }
    }

    // MARK: - Empty Pane View

    @ViewBuilder
    private var emptyPaneView: some View {
        emptyPaneBuilder(pane.id)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Unified Pane Drop Delegate

struct UnifiedPaneDropDelegate: DropDelegate {
    let size: CGSize
    let pane: PaneState
    let controller: SplitViewController
    let bonsplitController: BonsplitController
    @Binding var activeDropZone: DropZone?
    @Binding var dropLifecycle: PaneDropLifecycle

    // Calculate zone based on position within the view
    private func zoneForLocation(_ location: CGPoint) -> DropZone {
        let edgeRatio: CGFloat = 0.25
        let horizontalEdge = max(80, size.width * edgeRatio)
        let verticalEdge = max(80, size.height * edgeRatio)

        // Check edges first (left/right take priority at corners)
        if location.x < horizontalEdge {
            return .left
        } else if location.x > size.width - horizontalEdge {
            return .right
        } else if location.y < verticalEdge {
            return .top
        } else if location.y > size.height - verticalEdge {
            return .bottom
        } else {
            return .center
        }
    }

    private func effectiveZone(for info: DropInfo) -> DropZone {
        let defaultZone = zoneForLocation(info.location)
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            return defaultZone
        }
        guard let adjacentPaneMoveZone = adjacentPaneMoveZone(
            for: draggedTab,
            sourcePaneId: sourcePaneId,
            defaultZone: defaultZone
        ) else {
            return defaultZone
        }
        return adjacentPaneMoveZone
    }

    private func adjacentPaneMoveZone(
        for draggedTab: TabItem,
        sourcePaneId: PaneID,
        defaultZone: DropZone
    ) -> DropZone? {
        guard draggedTab.kind == "terminal",
              sourcePaneId != pane.id else {
            return nil
        }
        if defaultZone == .left,
           bonsplitController.adjacentPane(to: sourcePaneId, direction: .right) == pane.id {
            // Preserve the outer edge as a split affordance while treating the shared edge
            // between adjacent panes as "drop into this pane".
            return .center
        }
        if defaultZone == .right,
           bonsplitController.adjacentPane(to: sourcePaneId, direction: .left) == pane.id {
            return .center
        }
        return nil
    }

    func performDrop(info: DropInfo) -> Bool {
        if !Thread.isMainThread {
            return DispatchQueue.main.sync {
                performDrop(info: info)
            }
        }

        let zone = effectiveZone(for: info)
#if DEBUG
        dlog(
            "pane.drop pane=\(pane.id.id.uuidString.prefix(5)) zone=\(zone) " +
            "source=\(controller.dragSourcePaneId?.id.uuidString.prefix(5) ?? "nil") " +
            "hasDrag=\(controller.draggingTab != nil ? 1 : 0) " +
            "hasActive=\(controller.activeDragTab != nil ? 1 : 0)"
        )
#endif

        // Read from non-observable drag state — @Observable writes from createItemProvider
        // may not have propagated yet when performDrop runs.
        guard let draggedTab = controller.activeDragTab ?? controller.draggingTab,
              let sourcePaneId = controller.activeDragSourcePaneId ?? controller.dragSourcePaneId else {
            guard let transfer = decodeTransfer(from: info),
                  transfer.isFromCurrentProcess else {
                return false
            }
            let destination: BonsplitController.ExternalTabDropRequest.Destination
            if zone == .center {
                destination = .insert(targetPane: pane.id, targetIndex: nil)
            } else if let orientation = zone.orientation {
                destination = .split(
                    targetPane: pane.id,
                    orientation: orientation,
                    insertFirst: zone.insertsFirst
                )
            } else {
                return false
            }

            let request = BonsplitController.ExternalTabDropRequest(
                tabId: TabID(id: transfer.tab.id),
                sourcePaneId: PaneID(id: transfer.sourcePaneId),
                destination: destination
            )
            let handled = bonsplitController.onExternalTabDrop?(request) ?? false
            if handled {
                dropLifecycle = .idle
                activeDropZone = nil
            }
            return handled
        }

        // Clear both observable and non-observable drag state.
        dropLifecycle = .idle
        activeDropZone = nil
        controller.draggingTab = nil
        controller.dragSourcePaneId = nil
        controller.activeDragTab = nil
        controller.activeDragSourcePaneId = nil

        if zone == .center {
            if sourcePaneId != pane.id {
                withTransaction(Transaction(animation: nil)) {
                    _ = bonsplitController.moveTab(
                        TabID(id: draggedTab.id),
                        toPane: pane.id,
                        atIndex: nil
                    )
                }
            }
        } else if let orientation = zone.orientation {
#if DEBUG
            dlog(
                "pane.drop.splitRequest targetPane=\(pane.id.id.uuidString.prefix(5)) " +
                "sourcePane=\(sourcePaneId.id.uuidString.prefix(5)) zone=\(zone) " +
                "orientation=\(orientation) insertFirst=\(zone.insertsFirst ? 1 : 0) " +
                "draggedTab=\(draggedTab.id.uuidString.prefix(5))"
            )
#endif
            let newPaneId = bonsplitController.splitPane(
                pane.id,
                orientation: orientation,
                movingTab: TabID(id: draggedTab.id),
                insertFirst: zone.insertsFirst
            )
#if DEBUG
            dlog(
                "pane.drop.splitResult targetPane=\(pane.id.id.uuidString.prefix(5)) " +
                "newPane=\(newPaneId?.id.uuidString.prefix(5) ?? "nil")"
            )
#endif
        }

        return true
    }

    func dropEntered(info: DropInfo) {
        dropLifecycle = .hovering
        let zone = effectiveZone(for: info)
        activeDropZone = zone
#if DEBUG
        dlog(
            "pane.dropEntered pane=\(pane.id.id.uuidString.prefix(5)) zone=\(zone) " +
            "hasDrag=\(controller.draggingTab != nil ? 1 : 0) " +
            "hasActive=\(controller.activeDragTab != nil ? 1 : 0)"
        )
#endif
    }

    func dropExited(info: DropInfo) {
        dropLifecycle = .idle
        activeDropZone = nil
#if DEBUG
        dlog("pane.dropExited pane=\(pane.id.id.uuidString.prefix(5))")
#endif
    }

    func dropUpdated(info: DropInfo) -> DropProposal? {
        // Guard against dropUpdated firing after performDrop/dropExited
        guard dropLifecycle == .hovering else {
#if DEBUG
            dlog("pane.dropUpdated.skip pane=\(pane.id.id.uuidString.prefix(5)) reason=lifecycle_idle")
#endif
            return DropProposal(operation: .move)
        }
        let zone = effectiveZone(for: info)
        activeDropZone = zone
#if DEBUG
        dlog("pane.dropUpdated pane=\(pane.id.id.uuidString.prefix(5)) zone=\(zone)")
#endif
        return DropProposal(operation: .move)
    }

    func validateDrop(info: DropInfo) -> Bool {
        // Reject drops on inactive workspaces whose views are kept alive in a ZStack.
        guard controller.isInteractive else {
#if DEBUG
            dlog("pane.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) allowed=0 reason=inactive")
#endif
            return false
        }
        // The custom UTType alone is sufficient — only Bonsplit tab drags produce it.
        // Do NOT gate on draggingTab != nil: @Observable changes from createItemProvider
        // may not have propagated to the drop delegate yet, causing false rejections.
        let hasType = info.hasItemsConforming(to: [.tabTransfer])
        guard hasType else { return false }

        // Local drags use in-memory state and are always same-process.
        if controller.activeDragTab != nil || controller.draggingTab != nil {
            return true
        }

        // External drags (another Bonsplit controller) must include a payload from this process.
        guard let transfer = decodeTransfer(from: info),
              transfer.isFromCurrentProcess else {
            return false
        }
#if DEBUG
        let hasDrag = controller.draggingTab != nil
        let hasActive = controller.activeDragTab != nil
        dlog(
            "pane.validateDrop pane=\(pane.id.id.uuidString.prefix(5)) " +
            "allowed=\(hasType ? 1 : 0) hasDrag=\(hasDrag ? 1 : 0) hasActive=\(hasActive ? 1 : 0)"
        )
#endif
        return true
    }

    private func decodeTransfer(from string: String) -> TabTransferData? {
        guard let data = string.data(using: .utf8),
              let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) else {
            return nil
        }
        return transfer
    }

    private func decodeTransfer(from info: DropInfo) -> TabTransferData? {
        let pasteboard = NSPasteboard(name: .drag)
        let type = NSPasteboard.PasteboardType(UTType.tabTransfer.identifier)
        if let data = pasteboard.data(forType: type),
           let transfer = try? JSONDecoder().decode(TabTransferData.self, from: data) {
            return transfer
        }
        if let raw = pasteboard.string(forType: type) {
            return decodeTransfer(from: raw)
        }
        return nil
    }
}

import Foundation
import SwiftUI

/// Main controller for the split tab bar system
@MainActor
@Observable
final class BonsplitController {

    struct ExternalTabDropRequest {
        enum Destination {
            case insert(targetPane: PaneID, targetIndex: Int?)
            case split(targetPane: PaneID, orientation: SplitOrientation, insertFirst: Bool)
        }

        let tabId: TabID
        let sourcePaneId: PaneID
        let destination: Destination

        init(tabId: TabID, sourcePaneId: PaneID, destination: Destination) {
            self.tabId = tabId
            self.sourcePaneId = sourcePaneId
            self.destination = destination
        }
    }

    // MARK: - Delegate

    /// Delegate for receiving callbacks about tab bar events
    weak var delegate: BonsplitDelegate?

    // MARK: - Configuration

    /// Configuration for behavior and appearance
    var configuration: BonsplitConfiguration

    /// When false, drop delegates reject all drags. Set to false for inactive workspaces
    /// so their views (kept alive in a ZStack for state preservation) don't intercept drags
    /// meant for the active workspace.
    @ObservationIgnored var isInteractive: Bool = true {
        didSet { internalController.isInteractive = isInteractive }
    }

    /// Handler for file/URL drops from external apps (e.g., Finder).
    /// Called when files are dropped onto a pane's content area.
    /// Return `true` if the drop was handled.
    @ObservationIgnored var onFileDrop: ((_ urls: [URL], _ paneId: PaneID) -> Bool)? {
        didSet { internalController.onFileDrop = onFileDrop }
    }

    /// Handler for tab drops originating from another Bonsplit controller (e.g. another workspace/window).
    /// Return `true` when the drop has been handled by the host application.
    @ObservationIgnored var onExternalTabDrop: ((ExternalTabDropRequest) -> Bool)?

    /// Called when the user explicitly requests to close a tab from the tab strip UI.
    /// Internal host-driven closes should not use this hook.
    @ObservationIgnored var onTabCloseRequest: ((_ tabId: TabID, _ paneId: PaneID) -> Void)?

    // MARK: - Internal State

    internal var internalController: SplitViewController

    // MARK: - Initialization

    /// Create a new controller with the specified configuration
    init(configuration: BonsplitConfiguration = .default) {
        self.configuration = configuration
        self.internalController = SplitViewController()
    }

    // MARK: - Bonsplit.Tab Operations

    /// Create a new tab in the focused pane (or specified pane)
    /// - Parameters:
    ///   - title: The tab title
    ///   - icon: Optional SF Symbol name for the tab icon
    ///   - iconImageData: Optional image data (PNG recommended) for the tab icon. When present, takes precedence over `icon`.
    ///   - kind: Consumer-defined tab kind identifier (e.g. "terminal", "browser")
    ///   - hasCustomTitle: Whether the tab title came from a custom user override
    ///   - isDirty: Whether the tab shows a dirty indicator
    ///   - showsNotificationBadge: Whether the tab shows an "unread/activity" badge
    ///   - isLoading: Whether the tab shows an activity/loading indicator (e.g. spinning icon)
    ///   - isPinned: Whether the tab should be treated as pinned
    ///   - pane: Optional pane to add the tab to (defaults to focused pane)
    /// - Returns: The TabID of the created tab, or nil if creation was vetoed by delegate
    @discardableResult
    func createTab(
        title: String,
        hasCustomTitle: Bool = false,
        icon: String? = "doc.text",
        iconImageData: Data? = nil,
        kind: String? = nil,
        isDirty: Bool = false,
        showsNotificationBadge: Bool = false,
        isLoading: Bool = false,
        isPinned: Bool = false,
        inPane pane: PaneID? = nil
    ) -> TabID? {
        let tabId = TabID()
        let tab = Bonsplit.Tab(
            id: tabId,
            title: title,
            hasCustomTitle: hasCustomTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isDirty: isDirty,
            showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading,
            isPinned: isPinned
        )
        let targetPane = pane ?? focusedPaneId ?? PaneID(id: internalController.rootNode.allPaneIds.first!.id)

        // Check with delegate
        if delegate?.splitTabBar(self, shouldCreateTab: tab, inPane: targetPane) == false {
            return nil
        }

        // Calculate insertion index based on configuration
        let insertIndex: Int?
        switch configuration.newTabPosition {
        case .current:
            // Insert after the currently selected tab
            if let paneState = internalController.rootNode.findPane(PaneID(id: targetPane.id)),
               let selectedTabId = paneState.selectedTabId,
               let currentIndex = paneState.tabs.firstIndex(where: { $0.id == selectedTabId }) {
                insertIndex = currentIndex + 1
            } else {
                // No selected tab, append to end
                insertIndex = nil
            }
        case .end:
            insertIndex = nil
        }

        // Create internal TabItem
        let tabItem = TabItem(
            id: tabId.id,
            title: title,
            hasCustomTitle: hasCustomTitle,
            icon: icon,
            iconImageData: iconImageData,
            kind: kind,
            isDirty: isDirty,
            showsNotificationBadge: showsNotificationBadge,
            isLoading: isLoading,
            isPinned: isPinned
        )
        internalController.addTab(tabItem, toPane: PaneID(id: targetPane.id), atIndex: insertIndex)

        // Notify delegate
        delegate?.splitTabBar(self, didCreateTab: tab, inPane: targetPane)

        return tabId
    }

    /// Request the delegate to create a new tab of the given kind in a pane.
    /// The delegate is responsible for the actual creation logic.
    func requestNewTab(kind: String, inPane pane: PaneID) {
        delegate?.splitTabBar(self, didRequestNewTab: kind, inPane: pane)
    }

    /// Request the delegate to handle a tab context-menu action.
    func requestTabContextAction(_ action: TabContextAction, for tabId: TabID, inPane pane: PaneID) {
        guard let tab = tab(tabId) else { return }
        delegate?.splitTabBar(self, didRequestTabContextAction: action, for: tab, inPane: pane)
    }

    /// Update an existing tab's metadata
    /// - Parameters:
    ///   - tabId: The tab to update
    ///   - title: New title (pass nil to keep current)
    ///   - icon: New icon (pass nil to keep current, pass .some(nil) to remove icon)
    ///   - iconImageData: New icon image data (pass nil to keep current, pass .some(nil) to remove)
    ///   - kind: New tab kind (pass nil to keep current, pass .some(nil) to clear)
    ///   - hasCustomTitle: New custom-title state (pass nil to keep current)
    ///   - isDirty: New dirty state (pass nil to keep current)
    ///   - showsNotificationBadge: New badge state (pass nil to keep current)
    ///   - isLoading: New loading/busy state (pass nil to keep current)
    ///   - isPinned: New pinned state (pass nil to keep current)
    func updateTab(
        _ tabId: TabID,
        title: String? = nil,
        icon: String?? = nil,
        iconImageData: Data?? = nil,
        kind: String?? = nil,
        hasCustomTitle: Bool? = nil,
        isDirty: Bool? = nil,
        showsNotificationBadge: Bool? = nil,
        isLoading: Bool? = nil,
        isPinned: Bool? = nil
    ) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        if let title = title {
            pane.tabs[tabIndex].title = title
        }
        if let icon = icon {
            pane.tabs[tabIndex].icon = icon
        }
        if let iconImageData = iconImageData {
            pane.tabs[tabIndex].iconImageData = iconImageData
        }
        if let kind = kind {
            pane.tabs[tabIndex].kind = kind
        }
        if let hasCustomTitle = hasCustomTitle {
            pane.tabs[tabIndex].hasCustomTitle = hasCustomTitle
        }
        if let isDirty = isDirty {
            pane.tabs[tabIndex].isDirty = isDirty
        }
        if let showsNotificationBadge = showsNotificationBadge {
            pane.tabs[tabIndex].showsNotificationBadge = showsNotificationBadge
        }
        if let isLoading = isLoading {
            pane.tabs[tabIndex].isLoading = isLoading
        }
        if let isPinned = isPinned {
            pane.tabs[tabIndex].isPinned = isPinned
        }
    }

    /// Close a tab by ID
    /// - Parameter tabId: The tab to close
    /// - Returns: true if the tab was closed, false if vetoed by delegate
    @discardableResult
    func closeTab(_ tabId: TabID) -> Bool {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return false }
        return closeTab(tabId, with: tabIndex, in: pane)
    }
    
    /// Close a tab by ID in a specific pane.
    /// - Parameter tabId: The tab to close
    /// - Parameter paneId: The pane in which to close the tab
    func closeTab(_ tabId: TabID, inPane paneId: PaneID) -> Bool {
        guard let pane = internalController.rootNode.findPane(paneId),
              let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) else {
            return false
        }
        
        return closeTab(tabId, with: tabIndex, in: pane)
    }
    
    /// Internal helper to close a tab given its index in a pane
    /// - Parameter tabId: The tab to close
    /// - Parameter tabIndex: The position of the tab within the pane
    /// - Parameter pane: The pane in which to close the tab
    private func closeTab(_ tabId: TabID, with tabIndex: Int, in pane: PaneState) -> Bool {
        let tabItem = pane.tabs[tabIndex]
        let tab = Bonsplit.Tab(from: tabItem)
        let paneId = pane.id

        // Check with delegate
        if delegate?.splitTabBar(self, shouldCloseTab: tab, inPane: paneId) == false {
            return false
        }

        internalController.closeTab(tabId.id, inPane: pane.id)

        // Notify delegate
        delegate?.splitTabBar(self, didCloseTab: tabId, fromPane: paneId)
        notifyGeometryChange()

        return true
    }

    /// Select a tab by ID
    /// - Parameter tabId: The tab to select
    func selectTab(_ tabId: TabID) {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return }

        pane.selectTab(tabId.id)
        internalController.focusPane(pane.id)

        // Notify delegate
        let tab = Bonsplit.Tab(from: pane.tabs[tabIndex])
        delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
    }

    /// Move a tab to a specific pane (and optional index) inside this controller.
    /// - Parameters:
    ///   - tabId: The tab to move.
    ///   - targetPaneId: Destination pane.
    ///   - index: Optional destination index. When nil, appends at the end.
    /// - Returns: true if moved.
    @discardableResult
    func moveTab(_ tabId: TabID, toPane targetPaneId: PaneID, atIndex index: Int? = nil) -> Bool {
        guard let (sourcePane, sourceIndex) = findTabInternal(tabId) else { return false }
        guard let targetPane = internalController.rootNode.findPane(PaneID(id: targetPaneId.id)) else { return false }

        let tabItem = sourcePane.tabs[sourceIndex]
        let movedTab = Bonsplit.Tab(from: tabItem)
        let sourcePaneId = sourcePane.id

        if sourcePaneId == targetPane.id {
            // Reorder within same pane.
            let destinationIndex: Int = {
                if let index { return max(0, min(index, sourcePane.tabs.count)) }
                return sourcePane.tabs.count
            }()
            sourcePane.moveTab(from: sourceIndex, to: destinationIndex)
            sourcePane.selectTab(tabItem.id)
            internalController.focusPane(sourcePane.id)
            delegate?.splitTabBar(self, didSelectTab: movedTab, inPane: sourcePane.id)
            notifyGeometryChange()
            return true
        }

        internalController.moveTab(tabItem, from: sourcePaneId, to: targetPane.id, atIndex: index)
        delegate?.splitTabBar(self, didMoveTab: movedTab, fromPane: sourcePaneId, toPane: targetPane.id)
        notifyGeometryChange()
        return true
    }

    /// Reorder a tab within its pane.
    /// - Parameters:
    ///   - tabId: The tab to reorder.
    ///   - toIndex: Destination index.
    /// - Returns: true if reordered.
    @discardableResult
    func reorderTab(_ tabId: TabID, toIndex: Int) -> Bool {
        guard let (pane, sourceIndex) = findTabInternal(tabId) else { return false }
        let destinationIndex = max(0, min(toIndex, pane.tabs.count))
        pane.moveTab(from: sourceIndex, to: destinationIndex)
        pane.selectTab(tabId.id)
        internalController.focusPane(pane.id)
        if let tabIndex = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
            let tab = Bonsplit.Tab(from: pane.tabs[tabIndex])
            delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
        }
        notifyGeometryChange()
        return true
    }

    /// Move to previous tab in focused pane
    func selectPreviousTab() {
        internalController.selectPreviousTab()
        notifyTabSelection()
    }

    /// Move to next tab in focused pane
    func selectNextTab() {
        internalController.selectNextTab()
        notifyTabSelection()
    }

    // MARK: - Split Operations

    /// Split the focused pane (or specified pane)
    /// - Parameters:
    ///   - paneId: Optional pane to split (defaults to focused pane)
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked)
    ///   - tab: Optional tab to add to the new pane
    /// - Returns: The new pane ID, or nil if vetoed by delegate
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTab tab: Bonsplit.Tab? = nil
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        // Check with delegate
        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        let internalTab: TabItem?
        if let tab {
            internalTab = TabItem(
                id: tab.id.id,
                title: tab.title,
                hasCustomTitle: tab.hasCustomTitle,
                icon: tab.icon,
                iconImageData: tab.iconImageData,
                kind: tab.kind,
                isDirty: tab.isDirty,
                showsNotificationBadge: tab.showsNotificationBadge,
                isLoading: tab.isLoading,
                isPinned: tab.isPinned
            )
        } else {
            internalTab = nil
        }

        // Perform split
        internalController.splitPane(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            with: internalTab
        )

        // Find new pane (will be focused after split)
        let newPaneId = focusedPaneId!

        // Notify delegate
        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Split a pane and place a specific tab in the newly created pane, choosing which side to insert on.
    ///
    /// This is like `splitPane(_:orientation:withTab:)`, but allows choosing left/top vs right/bottom insertion
    /// without needing to create then move a tab.
    ///
    /// - Parameters:
    ///   - paneId: Optional pane to split (defaults to focused pane).
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked).
    ///   - tab: The tab to add to the new pane.
    ///   - insertFirst: If true, insert the new pane first (left/top). Otherwise insert second (right/bottom).
    /// - Returns: The new pane ID, or nil if vetoed by delegate.
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        withTab tab: Bonsplit.Tab,
        insertFirst: Bool
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return nil }

        // Check with delegate
        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        let internalTab = TabItem(
            id: tab.id.id,
            title: tab.title,
            hasCustomTitle: tab.hasCustomTitle,
            icon: tab.icon,
            iconImageData: tab.iconImageData,
            kind: tab.kind,
            isDirty: tab.isDirty,
            showsNotificationBadge: tab.showsNotificationBadge,
            isLoading: tab.isLoading,
            isPinned: tab.isPinned
        )

        // Perform split with insertion side.
        internalController.splitPaneWithTab(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            tab: internalTab,
            insertFirst: insertFirst
        )

        let newPaneId = focusedPaneId!

        // Notify delegate
        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Split a pane by moving an existing tab into the new pane.
    ///
    /// This mirrors the "drag a tab to a pane edge to create a split" interaction:
    /// the tab is removed from its source pane first, then inserted into the newly
    /// created pane on the chosen edge.
    ///
    /// - Parameters:
    ///   - paneId: Optional target pane to split (defaults to the tab's current pane).
    ///   - orientation: Direction to split (horizontal = side-by-side, vertical = stacked).
    ///   - tabId: The existing tab to move into the new pane.
    ///   - insertFirst: If true, the new pane is inserted first (left/top). Otherwise it is inserted second (right/bottom).
    /// - Returns: The new pane ID, or nil if the tab couldn't be found or the split was vetoed.
    @discardableResult
    func splitPane(
        _ paneId: PaneID? = nil,
        orientation: SplitOrientation,
        movingTab tabId: TabID,
        insertFirst: Bool
    ) -> PaneID? {
        guard configuration.allowSplits else { return nil }

        // Find the existing tab and its source pane.
        guard let (sourcePane, tabIndex) = findTabInternal(tabId) else { return nil }
        let tabItem = sourcePane.tabs[tabIndex]

        // Default target to the tab's current pane to match edge-drop behavior on the source pane.
        let targetPaneId = paneId ?? sourcePane.id

        // Check with delegate
        if delegate?.splitTabBar(self, shouldSplitPane: targetPaneId, orientation: orientation) == false {
            return nil
        }

        // Remove from source first.
        sourcePane.removeTab(tabItem.id)

        if sourcePane.tabs.isEmpty {
            if sourcePane.id == targetPaneId {
                // Keep a placeholder tab so the original pane isn't left "tabless".
                // This makes the empty side closable via tab close, and avoids apps
                // needing to special-case empty panes.
                sourcePane.addTab(TabItem(title: "Empty", icon: nil), select: true)
            } else if internalController.rootNode.allPaneIds.count > 1 {
                // If the source pane is now empty, close it (unless it's also the split target).
                internalController.closePane(sourcePane.id)
            }
        }

        // Perform split with the moved tab.
        internalController.splitPaneWithTab(
            PaneID(id: targetPaneId.id),
            orientation: orientation,
            tab: tabItem,
            insertFirst: insertFirst
        )

        let newPaneId = focusedPaneId!

        // Notify delegate
        delegate?.splitTabBar(self, didSplitPane: targetPaneId, newPane: newPaneId, orientation: orientation)

        notifyGeometryChange()

        return newPaneId
    }

    /// Close a specific pane
    /// - Parameter paneId: The pane to close
    /// - Returns: true if the pane was closed, false if vetoed by delegate
    @discardableResult
    func closePane(_ paneId: PaneID) -> Bool {
        // Don't close if it's the last pane and not allowed
        if !configuration.allowCloseLastPane && internalController.rootNode.allPaneIds.count <= 1 {
            return false
        }

        // Check with delegate
        if delegate?.splitTabBar(self, shouldClosePane: paneId) == false {
            return false
        }

        internalController.closePane(PaneID(id: paneId.id))

        // Notify delegate
        delegate?.splitTabBar(self, didClosePane: paneId)

        notifyGeometryChange()

        return true
    }

    // MARK: - Focus Management

    /// Currently focused pane ID
    var focusedPaneId: PaneID? {
        guard let internalId = internalController.focusedPaneId else { return nil }
        return internalId
    }

    /// Focus a specific pane
    func focusPane(_ paneId: PaneID) {
        internalController.focusPane(PaneID(id: paneId.id))
        delegate?.splitTabBar(self, didFocusPane: paneId)
    }

    /// Navigate focus in a direction
    func navigateFocus(direction: NavigationDirection) {
        internalController.navigateFocus(direction: direction)
        if let focusedPaneId {
            delegate?.splitTabBar(self, didFocusPane: focusedPaneId)
        }
    }

    /// Find the closest pane in the requested direction from the given pane.
    func adjacentPane(to paneId: PaneID, direction: NavigationDirection) -> PaneID? {
        internalController.adjacentPane(to: paneId, direction: direction)
    }

    // MARK: - Split Zoom

    /// Currently zoomed pane ID, if any.
    var zoomedPaneId: PaneID? {
        internalController.zoomedPaneId
    }

    var isSplitZoomed: Bool {
        internalController.zoomedPaneId != nil
    }

    @discardableResult
    func clearPaneZoom() -> Bool {
        internalController.clearPaneZoom()
    }

    /// Toggle zoom for a pane. When zoomed, only that pane is rendered in the split area.
    /// Passing nil toggles the currently focused pane.
    @discardableResult
    func togglePaneZoom(inPane paneId: PaneID? = nil) -> Bool {
        let targetPaneId = paneId ?? focusedPaneId
        guard let targetPaneId else { return false }
        return internalController.togglePaneZoom(targetPaneId)
    }

    // MARK: - Context Menu Shortcut Hints

    /// Keyboard shortcuts to display in tab context menus, keyed by context action.
    /// Set by the host app to sync with its customizable keyboard shortcut settings.
    var contextMenuShortcuts: [TabContextAction: KeyboardShortcut] = [:]

    // MARK: - Query Methods

    /// Get all tab IDs
    var allTabIds: [TabID] {
        internalController.rootNode.allPanes.flatMap { pane in
            pane.tabs.map { TabID(id: $0.id) }
        }
    }

    /// Get all pane IDs
    var allPaneIds: [PaneID] {
        internalController.rootNode.allPaneIds
    }

    /// Get tab metadata by ID
    func tab(_ tabId: TabID) -> Bonsplit.Tab? {
        guard let (pane, tabIndex) = findTabInternal(tabId) else { return nil }
        return Bonsplit.Tab(from: pane.tabs[tabIndex])
    }

    /// Get tabs in a specific pane
    func tabs(inPane paneId: PaneID) -> [Bonsplit.Tab] {
        guard let pane = internalController.rootNode.findPane(PaneID(id: paneId.id)) else {
            return []
        }
        return pane.tabs.map { Bonsplit.Tab(from: $0) }
    }

    /// Get selected tab in a pane
    func selectedTab(inPane paneId: PaneID) -> Bonsplit.Tab? {
        guard let pane = internalController.rootNode.findPane(PaneID(id: paneId.id)),
              let selected = pane.selectedTab else {
            return nil
        }
        return Bonsplit.Tab(from: selected)
    }

    // MARK: - Geometry Query API

    /// Get current layout snapshot with pixel coordinates
    func layoutSnapshot() -> LayoutSnapshot {
        let containerFrame = internalController.containerFrame
        let paneBounds = internalController.rootNode.computePaneBounds()

        let paneGeometries = paneBounds.map { bounds -> PaneGeometry in
            let pane = internalController.rootNode.findPane(bounds.paneId)
            let pixelFrame = PixelRect(
                x: Double(bounds.bounds.minX * containerFrame.width + containerFrame.origin.x),
                y: Double(bounds.bounds.minY * containerFrame.height + containerFrame.origin.y),
                width: Double(bounds.bounds.width * containerFrame.width),
                height: Double(bounds.bounds.height * containerFrame.height)
            )
            return PaneGeometry(
                paneId: bounds.paneId.id.uuidString,
                frame: pixelFrame,
                selectedTabId: pane?.selectedTabId?.uuidString,
                tabIds: pane?.tabs.map { $0.id.uuidString } ?? []
            )
        }

        return LayoutSnapshot(
            containerFrame: PixelRect(from: containerFrame),
            panes: paneGeometries,
            focusedPaneId: focusedPaneId?.id.uuidString,
            timestamp: Date().timeIntervalSince1970
        )
    }

    /// Get full tree structure for external consumption
    func treeSnapshot() -> ExternalTreeNode {
        let containerFrame = internalController.containerFrame
        return buildExternalTree(from: internalController.rootNode, containerFrame: containerFrame)
    }

    private func buildExternalTree(from node: SplitNode, containerFrame: CGRect, bounds: CGRect = CGRect(x: 0, y: 0, width: 1, height: 1)) -> ExternalTreeNode {
        switch node {
        case .pane(let paneState):
            let pixelFrame = PixelRect(
                x: Double(bounds.minX * containerFrame.width + containerFrame.origin.x),
                y: Double(bounds.minY * containerFrame.height + containerFrame.origin.y),
                width: Double(bounds.width * containerFrame.width),
                height: Double(bounds.height * containerFrame.height)
            )
            let tabs = paneState.tabs.map { ExternalTab(id: $0.id.uuidString, title: $0.title) }
            let paneNode = ExternalPaneNode(
                id: paneState.id.id.uuidString,
                frame: pixelFrame,
                tabs: tabs,
                selectedTabId: paneState.selectedTabId?.uuidString
            )
            return .pane(paneNode)

        case .split(let splitState):
            let dividerPos = splitState.dividerPosition
            let firstBounds: CGRect
            let secondBounds: CGRect

            switch splitState.orientation {
            case .horizontal:
                firstBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width * dividerPos, height: bounds.height)
                secondBounds = CGRect(x: bounds.minX + bounds.width * dividerPos, y: bounds.minY,
                                      width: bounds.width * (1 - dividerPos), height: bounds.height)
            case .vertical:
                firstBounds = CGRect(x: bounds.minX, y: bounds.minY,
                                     width: bounds.width, height: bounds.height * dividerPos)
                secondBounds = CGRect(x: bounds.minX, y: bounds.minY + bounds.height * dividerPos,
                                      width: bounds.width, height: bounds.height * (1 - dividerPos))
            }

            let splitNode = ExternalSplitNode(
                id: splitState.id.uuidString,
                orientation: splitState.orientation == .horizontal ? "horizontal" : "vertical",
                dividerPosition: Double(splitState.dividerPosition),
                first: buildExternalTree(from: splitState.first, containerFrame: containerFrame, bounds: firstBounds),
                second: buildExternalTree(from: splitState.second, containerFrame: containerFrame, bounds: secondBounds)
            )
            return .split(splitNode)
        }
    }

    /// Check if a split exists by ID
    func findSplit(_ splitId: UUID) -> Bool {
        return internalController.findSplit(splitId) != nil
    }

    // MARK: - Geometry Update API

    /// Set divider position for a split node (0.0-1.0)
    /// - Parameters:
    ///   - position: The new divider position (clamped to 0.1-0.9)
    ///   - splitId: The UUID of the split to update
    ///   - fromExternal: Set to true to suppress outgoing notifications (prevents loops)
    /// - Returns: true if the split was found and updated
    @discardableResult
    func setDividerPosition(_ position: CGFloat, forSplit splitId: UUID, fromExternal: Bool = false) -> Bool {
        guard let split = internalController.findSplit(splitId) else { return false }

        if fromExternal {
            internalController.isExternalUpdateInProgress = true
        }

        // Clamp position to valid range
        let clampedPosition = min(max(position, 0.1), 0.9)
        split.dividerPosition = clampedPosition

        if fromExternal {
            // Use a slight delay to allow the UI to update before re-enabling notifications
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
                self?.internalController.isExternalUpdateInProgress = false
            }
        }

        return true
    }

    /// Update container frame (called when window moves/resizes)
    func setContainerFrame(_ frame: CGRect) {
        internalController.containerFrame = frame
    }

    /// Notify geometry change to delegate (internal use)
    /// - Parameter isDragging: Whether the change is due to active divider dragging
    internal func notifyGeometryChange(isDragging: Bool = false) {
        guard !internalController.isExternalUpdateInProgress else { return }

        // If dragging, check if delegate wants notifications during drag
        if isDragging {
            let shouldNotify = delegate?.splitTabBar(self, shouldNotifyDuringDrag: true) ?? false
            guard shouldNotify else { return }
        }

        if isDragging {
            // Debounce drag updates to avoid flooding delegates during divider moves.
            let now = Date().timeIntervalSince1970
            let debounceInterval: TimeInterval = 0.05
            guard now - internalController.lastGeometryNotificationTime >= debounceInterval else { return }
            internalController.lastGeometryNotificationTime = now
        }

        let snapshot = layoutSnapshot()
        delegate?.splitTabBar(self, didChangeGeometry: snapshot)
    }

    // MARK: - Private Helpers

    private func findTabInternal(_ tabId: TabID) -> (PaneState, Int)? {
        for pane in internalController.rootNode.allPanes {
            if let index = pane.tabs.firstIndex(where: { $0.id == tabId.id }) {
                return (pane, index)
            }
        }
        return nil
    }

    private func notifyTabSelection() {
        guard let pane = internalController.focusedPane,
              let tabItem = pane.selectedTab else { return }
        let tab = Bonsplit.Tab(from: tabItem)
        delegate?.splitTabBar(self, didSelectTab: tab, inPane: pane.id)
    }
}

import SwiftUI

/// Main entry point for the Bonsplit library
///
/// Usage:
/// ```swift
/// struct MyApp: View {
///     @State private var controller = BonsplitController()
///
///     var body: some View {
///         BonsplitView(controller: controller) { tab, paneId in
///             MyContentView(for: tab)
///                 .onTapGesture { controller.focusPane(paneId) }
///         } emptyPane: { paneId in
///             Text("Empty pane")
///         }
///     }
/// }
/// ```
struct BonsplitView<Content: View, EmptyContent: View>: View {
    @Bindable private var controller: BonsplitController
    private let contentBuilder: (Bonsplit.Tab, PaneID) -> Content
    private let emptyPaneBuilder: (PaneID) -> EmptyContent

    /// Initialize with a controller, content builder, and empty pane builder
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    ///   - emptyPane: A ViewBuilder closure that provides content for empty panes
    init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Bonsplit.Tab, PaneID) -> Content,
        @ViewBuilder emptyPane: @escaping (PaneID) -> EmptyContent
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = emptyPane
    }

    var body: some View {
        SplitViewContainer(
            contentBuilder: { tabItem, paneId in
                contentBuilder(Bonsplit.Tab(from: tabItem), PaneID(id: paneId.id))
            },
            emptyPaneBuilder: { internalPaneId in
                emptyPaneBuilder(PaneID(id: internalPaneId.id))
            },
            appearance: controller.configuration.appearance,
            showSplitButtons: controller.configuration.allowSplits && controller.configuration.appearance.showSplitButtons,
            contentViewLifecycle: controller.configuration.contentViewLifecycle,
            onGeometryChange: { [weak controller] isDragging in
                controller?.notifyGeometryChange(isDragging: isDragging)
            },
            enableAnimations: controller.configuration.appearance.enableAnimations,
            animationDuration: controller.configuration.appearance.animationDuration
        )
        .environment(controller)
        .environment(controller.internalController)
    }
}

// MARK: - Convenience initializer with default empty view

extension BonsplitView where EmptyContent == DefaultEmptyPaneView {
    /// Initialize with a controller and content builder, using the default empty pane view
    /// - Parameters:
    ///   - controller: The BonsplitController managing the tab state
    ///   - content: A ViewBuilder closure that provides content for each tab. Receives the tab and pane ID.
    init(
        controller: BonsplitController,
        @ViewBuilder content: @escaping (Bonsplit.Tab, PaneID) -> Content
    ) {
        self.controller = controller
        self.contentBuilder = content
        self.emptyPaneBuilder = { _ in DefaultEmptyPaneView() }
    }
}

/// Default view shown when a pane has no tabs
struct DefaultEmptyPaneView: View {
    init() {}

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "doc.text")
                .font(.system(size: 48))
                .foregroundStyle(.tertiary)

            Text("No Open Tabs")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
