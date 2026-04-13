import AppKit
import SwiftUI

/// SwiftUI view that hosts an NSTextView-based text editor for an EditorPanel.
struct EditorPanelView: View {
    @ObservedObject var panel: EditorPanel
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
                editorContentView
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
        .onChange(of: panel.focusFlashToken) { _ in
            triggerFocusFlashAnimation()
        }
    }

    // MARK: - Content

    private var editorContentView: some View {
        VStack(spacing: 0) {
            filePathHeader
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .padding(.bottom, 6)
            Divider()
                .padding(.horizontal, 8)
            EditorTextViewRepresentable(
                panel: panel,
                isFocused: isFocused,
                onRequestPanelFocus: onRequestPanelFocus
            )
        }
    }

    private var filePathHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "doc.text")
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
            Text(String(localized: "editor.fileUnavailable.title", defaultValue: "File unavailable"))
                .font(.headline)
                .foregroundColor(.primary)
            Text(panel.filePath)
                .font(.system(size: 12, design: .monospaced))
                .foregroundColor(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 24)
            Text(String(localized: "editor.fileUnavailable.message", defaultValue: "The file may have been moved or deleted."))
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

// MARK: - NSTextView Bridge

private struct EditorTextViewRepresentable: NSViewRepresentable {
    let panel: EditorPanel
    let isFocused: Bool
    let onRequestPanelFocus: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(panel: panel, onRequestPanelFocus: onRequestPanelFocus)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false

        let textView = EditorNSTextView()
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticTextCompletionEnabled = false
        textView.smartInsertDeleteEnabled = false

        textView.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)
        textView.textContainerInset = NSSize(width: 16, height: 12)
        textView.autoresizingMask = [.width]
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )

        applyThemeColors(to: textView)

        textView.string = panel.content
        textView.delegate = context.coordinator
        textView.editorPanel = panel
        textView.onRequestPanelFocus = onRequestPanelFocus

        scrollView.documentView = textView
        context.coordinator.textView = textView
        panel.textView = textView

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? EditorNSTextView else { return }

        context.coordinator.panel = panel
        context.coordinator.onRequestPanelFocus = onRequestPanelFocus
        textView.editorPanel = panel
        textView.onRequestPanelFocus = onRequestPanelFocus
        panel.textView = textView

        // Only update text if it differs and we're not mid-edit
        if !context.coordinator.isEditing && textView.string != panel.content {
            let savedRanges = textView.selectedRanges
            textView.string = panel.content
            // Clamp ranges to new content length. Without this, AppKit throws
            // NSRangeException when an external change shrinks the file.
            let newLength = (textView.string as NSString).length
            let clamped = savedRanges.compactMap { value -> NSValue? in
                let range = value.rangeValue
                let loc = min(range.location, newLength)
                let remaining = newLength - loc
                let len = min(range.length, remaining)
                return NSValue(range: NSRange(location: loc, length: len))
            }
            if !clamped.isEmpty {
                textView.selectedRanges = clamped
            }
        }

        applyThemeColors(to: textView)
    }

    private func applyThemeColors(to textView: NSTextView) {
        let isDark = NSApp.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        textView.backgroundColor = isDark
            ? NSColor(white: 0.12, alpha: 1.0)
            : NSColor(white: 0.98, alpha: 1.0)
        textView.textColor = isDark
            ? NSColor(white: 0.9, alpha: 1.0)
            : NSColor(white: 0.1, alpha: 1.0)
        textView.insertionPointColor = isDark
            ? .white
            : .black
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var panel: EditorPanel
        var onRequestPanelFocus: () -> Void
        weak var textView: NSTextView?
        var isEditing: Bool = false

        init(panel: EditorPanel, onRequestPanelFocus: @escaping () -> Void) {
            self.panel = panel
            self.onRequestPanelFocus = onRequestPanelFocus
        }

        func textDidBeginEditing(_ notification: Notification) {
            isEditing = true
        }

        func textDidEndEditing(_ notification: Notification) {
            isEditing = false
            panel.content = textView?.string ?? panel.content
            panel.markDirty()
        }

        func textDidChange(_ notification: Notification) {
            panel.content = textView?.string ?? panel.content
            panel.markDirty()
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            // Tab-to-2-spaces
            if let replacement = replacementString, replacement == "\t" {
                textView.insertText("  ", replacementRange: affectedCharRange)
                return false
            }
            return true
        }
    }
}

// MARK: - Custom NSTextView subclass for Cmd+S

private final class EditorNSTextView: NSTextView {
    weak var editorPanel: EditorPanel?
    var onRequestPanelFocus: (() -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+S to save
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "s" {
            editorPanel?.save()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func mouseDown(with event: NSEvent) {
        onRequestPanelFocus?()
        super.mouseDown(with: event)
    }
}
