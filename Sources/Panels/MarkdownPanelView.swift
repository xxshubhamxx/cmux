import AppKit
import CMUXMarkdown
import SwiftUI

/// SwiftUI view that renders a MarkdownPanel's content using the local markdown renderer.
struct MarkdownPanelView: View {
    @ObservedObject var panel: MarkdownPanel
    let isFocused: Bool
    let isVisibleInUI: Bool
    let portalPriority: Int
    let onRequestPanelFocus: () -> Void

    @State private var focusFlashOpacity: Double = 0.0
    @State private var focusFlashAnimationGeneration: Int = 0
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Group {
            if panel.isFileUnavailable {
                fileUnavailableView
            } else {
                markdownContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(backgroundColor)
        .overlay {
            RoundedRectangle(cornerRadius: FocusFlashPattern.ringCornerRadius)
                .stroke(cmuxAccentColor().opacity(focusFlashOpacity), lineWidth: 3)
                .shadow(color: cmuxAccentColor().opacity(focusFlashOpacity * 0.35), radius: 10)
                .padding(FocusFlashPattern.ringInset)
                .allowsHitTesting(false)
        }
        .overlay {
            if isVisibleInUI {
                // Observe left-clicks without intercepting them so markdown text
                // selection and link activation continue to use the native path.
                MarkdownPointerObserver(onPointerDown: onRequestPanelFocus)
            }
        }
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var markdownContentView: some View {
        VStack(alignment: .leading, spacing: 0) {
            filePathHeader
                .padding(.horizontal, 16)
                .padding(.top, 10)
                .padding(.bottom, 6)

            Divider()
                .padding(.horizontal, 12)

            CMUXMarkdownTextView(
                markdown: panel.content,
                isDark: colorScheme == .dark
            )
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.richtext")
                .foregroundColor(.secondary)
                .font(.system(size: 12))
            Text(panel.filePath)
                .font(.system(size: 11, design: .monospaced))
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
        }
    }

    private var fileUnavailableView: some View {
        VStack(spacing: 12) {
            Image(systemName: "doc.questionmark")
                .font(.system(size: 40))
                .foregroundColor(.secondary)
            Text(String(localized: "markdown.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "markdown.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
                .font(.caption)
                .foregroundColor(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Theme

    private var backgroundColor: Color {
        colorScheme == .dark
            ? Color(nsColor: NSColor(white: 0.12, alpha: 1.0))
            : Color(nsColor: NSColor(white: 0.98, alpha: 1.0))
    }

    // MARK: - Focus Flash

    private func triggerFocusFlashAnimation() {
        focusFlashAnimationGeneration &+= 1
        let generation = focusFlashAnimationGeneration
        focusFlashOpacity = FocusFlashPattern.values.first ?? 0

        for segment in FocusFlashPattern.segments {
            DispatchQueue.main.asyncAfter(deadline: .now() + segment.delay) {
                guard focusFlashAnimationGeneration == generation else { return }
                withAnimation(focusFlashAnimation(for: segment.curve, duration: segment.duration)) {
                    focusFlashOpacity = segment.targetOpacity
                }
            }
        }
    }

    private func focusFlashAnimation(for curve: FocusFlashCurve, duration: TimeInterval) -> Animation {
        switch curve {
        case .easeIn:
            return .easeIn(duration: duration)
        case .easeOut:
            return .easeOut(duration: duration)
        }
    }
}

private struct CMUXMarkdownTextView: NSViewRepresentable {
    let markdown: String
    let isDark: Bool

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true

        let textView = CMUXMarkdownNSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 16, height: 10)
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width]
        textView.allowsUndo = false
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? CMUXMarkdownNSTextView else { return }
        updateTextViewWidth(textView, in: scrollView)
        guard context.coordinator.needsRender(markdown: markdown, isDark: isDark) else { return }

        let previousSelection = textView.selectedRange()
        textView.textStorage?.setAttributedString(renderedMarkdown())
        context.coordinator.didRender(markdown: markdown, isDark: isDark)
        textView.refreshMarkdownOverlays()

        let renderedLength = (textView.string as NSString).length
        let selectionLocation = min(previousSelection.location, renderedLength)
        textView.setSelectedRange(NSRange(location: selectionLocation, length: 0))
    }

    private func updateTextViewWidth(_ textView: NSTextView, in scrollView: NSScrollView) {
        let contentWidth = max(1, scrollView.contentSize.width)
        let textWidth = max(1, contentWidth - textView.textContainerInset.width * 2)
        textView.textContainer?.containerSize = NSSize(
            width: textWidth,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        if abs(textView.frame.width - contentWidth) > 0.5 {
            textView.setFrameSize(
                NSSize(
                    width: contentWidth,
                    height: max(textView.frame.height, scrollView.contentSize.height)
                )
            )
        }
    }

    private func renderedMarkdown() -> NSAttributedString {
        let theme = CMUXMarkdownAppKitTheme(
            baseFont: .systemFont(ofSize: 14),
            monospacedFont: .monospacedSystemFont(ofSize: 13, weight: .regular),
            foregroundColor: isDark
                ? NSColor(srgbRed: 0.90, green: 0.91, blue: 0.88, alpha: 1)
                : .labelColor,
            mutedColor: isDark
                ? NSColor(srgbRed: 0.58, green: 0.59, blue: 0.55, alpha: 1)
                : .secondaryLabelColor,
            linkColor: .linkColor,
            codeColor: isDark
                ? NSColor(srgbRed: 0.88, green: 0.72, blue: 0.48, alpha: 1)
                : .secondaryLabelColor,
            codeBlockForegroundColor: isDark
                ? NSColor(srgbRed: 0.91, green: 0.92, blue: 0.88, alpha: 1)
                : NSColor(srgbRed: 0.14, green: 0.15, blue: 0.13, alpha: 1),
            codeBlockBackgroundColor: isDark
                ? NSColor(srgbRed: 0.21, green: 0.22, blue: 0.20, alpha: 1)
                : NSColor(srgbRed: 0.94, green: 0.95, blue: 0.92, alpha: 1),
            codeBlockBorderColor: isDark
                ? NSColor(srgbRed: 0.27, green: 0.285, blue: 0.25, alpha: 1)
                : NSColor(srgbRed: 0.82, green: 0.84, blue: 0.78, alpha: 1),
            codeBlockLanguageColor: isDark
                ? NSColor(srgbRed: 0.66, green: 0.67, blue: 0.62, alpha: 1)
                : NSColor(srgbRed: 0.38, green: 0.40, blue: 0.36, alpha: 1),
            codeBlockKeywordColor: isDark
                ? NSColor(srgbRed: 0.22, green: 0.64, blue: 0.95, alpha: 1)
                : NSColor(srgbRed: 0.05, green: 0.38, blue: 0.68, alpha: 1),
            codeBlockTypeColor: isDark
                ? NSColor(srgbRed: 1.00, green: 0.25, blue: 0.34, alpha: 1)
                : NSColor(srgbRed: 0.70, green: 0.14, blue: 0.22, alpha: 1),
            codeBlockCommentColor: isDark
                ? NSColor(srgbRed: 0.60, green: 0.61, blue: 0.57, alpha: 1)
                : NSColor(srgbRed: 0.46, green: 0.48, blue: 0.43, alpha: 1),
            codeBlockStringColor: isDark
                ? NSColor(srgbRed: 0.65, green: 0.82, blue: 0.45, alpha: 1)
                : NSColor(srgbRed: 0.30, green: 0.50, blue: 0.20, alpha: 1),
            tableHeaderBackgroundColor: isDark
                ? NSColor(srgbRed: 0.18, green: 0.205, blue: 0.18, alpha: 1)
                : NSColor(srgbRed: 0.92, green: 0.94, blue: 0.90, alpha: 1),
            tableRowBackgroundColor: isDark
                ? NSColor(srgbRed: 0.135, green: 0.145, blue: 0.125, alpha: 1)
                : NSColor(srgbRed: 0.985, green: 0.985, blue: 0.965, alpha: 1),
            tableAlternateRowBackgroundColor: isDark
                ? NSColor(srgbRed: 0.115, green: 0.125, blue: 0.108, alpha: 1)
                : NSColor(srgbRed: 0.955, green: 0.965, blue: 0.94, alpha: 1),
            tableBorderColor: isDark
                ? NSColor(srgbRed: 0.30, green: 0.315, blue: 0.28, alpha: 1)
                : NSColor(srgbRed: 0.80, green: 0.82, blue: 0.76, alpha: 1)
        )
        return CMUXMarkdownAppKitRenderer(theme: theme).render(markdown)
    }

    final class Coordinator {
        private var renderedMarkdown: String?
        private var renderedIsDark: Bool?

        func needsRender(markdown: String, isDark: Bool) -> Bool {
            renderedMarkdown != markdown || renderedIsDark != isDark
        }

        func didRender(markdown: String, isDark: Bool) {
            renderedMarkdown = markdown
            renderedIsDark = isDark
        }
    }
}

private final class CMUXMarkdownNSTextView: NSTextView {
    private var copyButtonsByBlockID: [Int: MarkdownCodeBlockCopyButton] = [:]
    private var isUpdatingCodeBlockButtons = false

    override func draw(_ dirtyRect: NSRect) {
        drawCodeBlockBackgrounds(in: dirtyRect)
        super.draw(dirtyRect)
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        refreshMarkdownOverlays()
    }

    override func layout() {
        super.layout()
        refreshMarkdownOverlays()
    }

    func refreshMarkdownOverlays() {
        updateCodeBlockCopyButtons()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        invalidateVisibleMarkdownSelectionDisplay()
    }

    override func mouseDragged(with event: NSEvent) {
        super.mouseDragged(with: event)
        invalidateVisibleMarkdownSelectionDisplay()
    }

    override func setSelectedRange(_ charRange: NSRange) {
        super.setSelectedRange(charRange)
        invalidateVisibleMarkdownSelectionDisplay()
    }

    override func setSelectedRanges(
        _ ranges: [NSValue],
        affinity: NSSelectionAffinity,
        stillSelecting stillSelectingFlag: Bool
    ) {
        super.setSelectedRanges(ranges, affinity: affinity, stillSelecting: stillSelectingFlag)
        if !stillSelectingFlag {
            invalidateVisibleMarkdownSelectionDisplay()
        }
    }

    private func drawCodeBlockBackgrounds(in dirtyRect: NSRect) {
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0 else { return }

        layoutManager.ensureLayout(for: textContainer)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var drawnBlockIDs = Set<Int>()

        textStorage.enumerateAttribute(
            .cmuxMarkdownCodeBlockID,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard let blockID = value as? Int,
                  !drawnBlockIDs.contains(blockID),
                  range.length > 0 else { return }
            drawnBlockIDs.insert(blockID)

            let glyphRange = layoutManager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { return }

            var textRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !textRect.isEmpty else { return }

            let textOrigin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
            let containerWidth = max(1, min(textContainer.containerSize.width, bounds.width - textContainerInset.width * 2))
            textRect.origin.x = textOrigin.x
            textRect.origin.y += textOrigin.y
            textRect.size.width = containerWidth
            textRect = textRect.insetBy(dx: 0, dy: -8)

            guard textRect.intersects(dirtyRect) else { return }

            let background = (textStorage.attribute(
                .cmuxMarkdownCodeBlockBackgroundColor,
                at: range.location,
                effectiveRange: nil
            ) as? NSColor) ?? NSColor.controlBackgroundColor
            let border = (textStorage.attribute(
                .cmuxMarkdownCodeBlockBorderColor,
                at: range.location,
                effectiveRange: nil
            ) as? NSColor) ?? NSColor.separatorColor

            background.setFill()
            let path = NSBezierPath(roundedRect: textRect, xRadius: 8, yRadius: 8)
            path.fill()
            border.setStroke()
            path.lineWidth = 1
            path.stroke()
        }
    }

    private func updateCodeBlockCopyButtons() {
        guard !isUpdatingCodeBlockButtons else { return }
        guard let layoutManager,
              let textContainer,
              let textStorage,
              textStorage.length > 0 else {
            removeAllCodeBlockCopyButtons()
            return
        }

        isUpdatingCodeBlockButtons = true
        defer { isUpdatingCodeBlockButtons = false }

        layoutManager.ensureLayout(for: textContainer)
        let fullRange = NSRange(location: 0, length: textStorage.length)
        var blockRanges: [Int: NSRange] = [:]
        var copyTexts: [Int: String] = [:]
        var orderedBlockIDs: [Int] = []

        textStorage.enumerateAttribute(
            .cmuxMarkdownCodeBlockID,
            in: fullRange,
            options: []
        ) { value, range, _ in
            guard let blockID = value as? Int else { return }
            if blockRanges[blockID] == nil {
                orderedBlockIDs.append(blockID)
                blockRanges[blockID] = range
            } else if let currentRange = blockRanges[blockID] {
                blockRanges[blockID] = NSUnionRange(currentRange, range)
            }

            if copyTexts[blockID] == nil,
               let copyText = textStorage.attribute(
                   .cmuxMarkdownCodeBlockCopyText,
                   at: range.location,
                   effectiveRange: nil
               ) as? String {
                copyTexts[blockID] = copyText
            }
        }

        let activeBlockIDs = Set(orderedBlockIDs)
        for (blockID, button) in copyButtonsByBlockID where !activeBlockIDs.contains(blockID) {
            button.removeFromSuperview()
        }
        copyButtonsByBlockID = copyButtonsByBlockID.filter { activeBlockIDs.contains($0.key) }

        for blockID in orderedBlockIDs {
            guard let blockRange = blockRanges[blockID],
                  blockRange.length > 0,
                  let copyText = copyTexts[blockID] else { continue }

            let glyphRange = layoutManager.glyphRange(forCharacterRange: blockRange, actualCharacterRange: nil)
            guard glyphRange.length > 0 else { continue }

            var blockRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            guard !blockRect.isEmpty else { continue }

            let textOrigin = NSPoint(x: textContainerInset.width, y: textContainerInset.height)
            let containerWidth = max(1, min(textContainer.containerSize.width, bounds.width - textContainerInset.width * 2))
            blockRect.origin.x = textOrigin.x
            blockRect.origin.y += textOrigin.y
            blockRect.size.width = containerWidth
            blockRect = blockRect.insetBy(dx: 0, dy: -8)

            let button = copyButtonsByBlockID[blockID] ?? MarkdownCodeBlockCopyButton()
            button.copyText = copyText
            button.frame = NSRect(
                x: blockRect.maxX - 34,
                y: blockRect.minY + 6,
                width: 24,
                height: 24
            )
            if button.superview !== self {
                addSubview(button)
            }
            copyButtonsByBlockID[blockID] = button
        }
    }

    private func removeAllCodeBlockCopyButtons() {
        for button in copyButtonsByBlockID.values {
            button.removeFromSuperview()
        }
        copyButtonsByBlockID.removeAll()
    }

    private func invalidateVisibleMarkdownSelectionDisplay() {
        guard let layoutManager, let textContainer else {
            setNeedsDisplay(visibleRect)
            return
        }
        let glyphRange = layoutManager.glyphRange(forBoundingRect: visibleRect, in: textContainer)
        let characterRange = layoutManager.characterRange(forGlyphRange: glyphRange, actualGlyphRange: nil)
        if characterRange.length > 0 {
            layoutManager.invalidateDisplay(forCharacterRange: characterRange)
        }
        setNeedsDisplay(visibleRect)
        enclosingScrollView?.contentView.setNeedsDisplay(enclosingScrollView?.contentView.bounds ?? visibleRect)
    }
}

private final class MarkdownCodeBlockCopyButton: NSButton {
    private static let iconConfiguration = NSImage.SymbolConfiguration(pointSize: 11, weight: .regular)
    private static let copiedIconDuration: TimeInterval = 1.2

    var copyText: String = ""
    private var hoverTrackingArea: NSTrackingArea?
    private let copyLabel = String(localized: "markdown.copyCode", defaultValue: "Copy code")
    private let copiedLabel = String(localized: "markdown.copiedCode", defaultValue: "Copied")
    private var copiedIconResetTimer: Timer?
    private var isShowingCopiedIcon = false {
        didSet {
            guard oldValue != isShowingCopiedIcon else { return }
            updateIcon()
            updateAppearance()
            setAccessibilityLabel(isShowingCopiedIcon ? copiedLabel : copyLabel)
        }
    }
    private var isHovering = false {
        didSet {
            guard oldValue != isHovering else { return }
            updateAppearance()
        }
    }

    override var isHighlighted: Bool {
        didSet {
            updateAppearance()
        }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 24, height: 24))
        title = ""
        imageScaling = .scaleNone
        imagePosition = .imageOnly
        alignment = .center
        isBordered = false
        bezelStyle = .regularSquare
        setButtonType(.momentaryChange)
        focusRingType = .none
        contentTintColor = .secondaryLabelColor
        setAccessibilityLabel(copyLabel)
        target = self
        action = #selector(copyCode)
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        updateIcon()
        updateAppearance()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        copiedIconResetTimer?.invalidate()
    }

    override func updateTrackingAreas() {
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        isHovering = true
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        isHovering = false
    }

    @objc private func copyCode() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(copyText, forType: .string)
        showCopiedIcon()
    }

    private func updateAppearance() {
        let isActive = isHovering || isHighlighted
        if isShowingCopiedIcon {
            contentTintColor = .systemGreen
        } else if isActive {
            contentTintColor = .labelColor
        } else {
            contentTintColor = .secondaryLabelColor
        }
        layer?.backgroundColor = isActive
            ? NSColor.controlBackgroundColor.withAlphaComponent(0.55).cgColor
            : NSColor.clear.cgColor
    }

    private func showCopiedIcon() {
        copiedIconResetTimer?.invalidate()
        isShowingCopiedIcon = true

        let timer = Timer(timeInterval: Self.copiedIconDuration, repeats: false) { [weak self] _ in
            guard let self else { return }
            isShowingCopiedIcon = false
            copiedIconResetTimer = nil
        }
        copiedIconResetTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func updateIcon() {
        let symbolName = isShowingCopiedIcon ? "checkmark" : "doc.on.doc"
        let accessibilityDescription = isShowingCopiedIcon ? copiedLabel : copyLabel
        image = NSImage(systemSymbolName: symbolName, accessibilityDescription: accessibilityDescription)?
            .withSymbolConfiguration(Self.iconConfiguration)
        image?.isTemplate = true
    }
}

private struct MarkdownPointerObserver: NSViewRepresentable {
    let onPointerDown: () -> Void

    func makeNSView(context: Context) -> MarkdownPanelPointerObserverView {
        let view = MarkdownPanelPointerObserverView()
        view.onPointerDown = onPointerDown
        return view
    }

    func updateNSView(_ nsView: MarkdownPanelPointerObserverView, context: Context) {
        nsView.onPointerDown = onPointerDown
    }
}

final class MarkdownPanelPointerObserverView: NSView {
    var onPointerDown: (() -> Void)?
    private var eventMonitor: Any?
    private weak var forwardedMouseTarget: NSView?

    override var mouseDownCanMoveWindow: Bool { false }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        installEventMonitorIfNeeded()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let eventMonitor {
            NSEvent.removeMonitor(eventMonitor)
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard PaneFirstClickFocusSettings.isEnabled(),
              window?.isKeyWindow != true,
              bounds.contains(point) else { return nil }
        return self
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        PaneFirstClickFocusSettings.isEnabled()
    }

    override func mouseDown(with event: NSEvent) {
        onPointerDown?()
        forwardedMouseTarget = forwardedTarget(for: event)
        forwardedMouseTarget?.mouseDown(with: event)
    }

    override func mouseDragged(with event: NSEvent) {
        forwardedMouseTarget?.mouseDragged(with: event)
    }

    override func mouseUp(with event: NSEvent) {
        forwardedMouseTarget?.mouseUp(with: event)
        forwardedMouseTarget = nil
    }

    func shouldHandle(_ event: NSEvent) -> Bool {
        guard event.type == .leftMouseDown,
              let window,
              event.window === window,
              !isHiddenOrHasHiddenAncestor else { return false }
        if PaneFirstClickFocusSettings.isEnabled(), window.isKeyWindow != true {
            return false
        }
        let point = convert(event.locationInWindow, from: nil)
        return bounds.contains(point)
    }

    func handleEventIfNeeded(_ event: NSEvent) -> NSEvent {
        guard shouldHandle(event) else { return event }
        DispatchQueue.main.async { [weak self] in
            self?.onPointerDown?()
        }
        return event
    }

    private func installEventMonitorIfNeeded() {
        guard eventMonitor == nil else { return }
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] event in
            self?.handleEventIfNeeded(event) ?? event
        }
    }

    private func forwardedTarget(for event: NSEvent) -> NSView? {
        guard let window else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=0 contentView=0")
#endif
            return nil
        }
        guard let contentView = window.contentView else {
#if DEBUG
            NSLog("MarkdownPanelPointerObserverView.forwardedTarget skipped, window=1 contentView=0")
#endif
            return nil
        }
        isHidden = true
        defer { isHidden = false }
        let point = contentView.convert(event.locationInWindow, from: nil)
        let target = contentView.hitTest(point)
        return target === self ? nil : target
    }
}
