import AppKit
import SwiftUI

struct CodexAppServerPanelView: View {
    @ObservedObject var panel: CodexAppServerPanel
    let isFocused: Bool

    @State private var promptFocused: Bool = false
    @State private var promptInputHeight = CodexComposerMetrics.micro.promptMinHeight
    @State private var themeBackground = GhosttyBackgroundTheme.currentColor()
#if DEBUG
    @AppStorage(CodexComposerDebugSettings.layoutLabVisibleKey)
    private var showComposerLayoutLab = CodexComposerDebugSettings.defaultShowLayoutLab
    @AppStorage(CodexComposerDebugSettings.queueLabVisibleKey)
    private var showQueueLayoutLab = CodexComposerDebugSettings.defaultShowQueueLab
#endif

    var body: some View {
        ZStack(alignment: .bottom) {
            transcript
            VStack(spacing: 7) {
#if DEBUG
                if showComposerLayoutLab {
                    CodexComposerLayoutLabView(themeBackground: themeBackground)
                }
#endif
#if DEBUG
                if showQueueLayoutLab {
                    CodexQueuedPromptDebugLabView(prompts: panel.queuedPrompts)
                }
#endif
                composerCluster
            }
            .padding(.bottom, CodexComposerMetrics.micro.bottomFloat)
        }
        .background(Color(nsColor: themeBackground).ignoresSafeArea())
        .onAppear {
            if isFocused {
                promptFocused = true
            }
        }
        .task {
            guard panel.shouldAutoStart else { return }
            await panel.start()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                promptFocused = true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyDefaultBackgroundDidChange)) { notification in
            themeBackground = GhosttyBackgroundTheme.color(from: notification)
        }
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ZStack {
                CodexTrajectoryTranscriptView(
                    items: panel.transcriptItems,
                    bottomSpacerHeight: transcriptBottomSpacerHeight
                )
                    .opacity(panel.transcriptContentState == .content ? 1 : 0)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                switch panel.transcriptContentState {
                case .loading(let phase):
                    loadingState(phase)
                case .empty:
                    emptyState
                case .content:
                    EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !panel.pendingRequests.isEmpty {
                Divider()
                pendingRequests
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var pendingRequests: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 10) {
                ForEach(panel.pendingRequests) { request in
                    CodexAppServerPendingRequestView(
                        request: request,
                        onAccept: {
                            panel.resolvePendingRequest(request, decision: .accept)
                        },
                        onDecline: {
                            panel.resolvePendingRequest(request, decision: .decline)
                        },
                        onCancel: {
                            panel.resolvePendingRequest(request, decision: .cancel)
                        }
                    )
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxHeight: 240)
        .background(Color(nsColor: themeBackground))
    }

    private func loadingState(_ phase: CodexAppServerTranscriptLoadingPhase) -> some View {
        VStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            Text(phase.localizedTitle)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "sparkles")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text(String(localized: "codexAppServer.emptyTranscript", defaultValue: "No messages yet"))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 180)
    }

    @ViewBuilder
    private var queuedPromptStrip: some View {
        if !panel.queuedPrompts.isEmpty {
            CodexQueuedPromptIntegratedView(prompts: panel.queuedPrompts, variant: .solidShelf)
                .frame(maxWidth: CodexComposerMetrics.queuedPromptWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }

    private var composer: some View {
        composerView(metrics: .micro)
    }

    private var composerCluster: some View {
        VStack(spacing: 0) {
            queuedPromptStrip
            composer
        }
    }

    private func composerView(metrics: CodexComposerMetrics) -> some View {
        CodexComposerSurfaceChrome(metrics: metrics, themeBackground: themeBackground) {
            composerSurface(metrics: metrics)
        }
        .frame(maxWidth: CodexComposerMetrics.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .animation(.easeInOut(duration: 0.16), value: promptInputHeight)
    }

    private func composerSurface(metrics: CodexComposerMetrics) -> some View {
        CodexComposerSurfaceContent(
            placeholder: String(localized: "codexAppServer.prompt.placeholder", defaultValue: "Ask anything"),
            text: $panel.promptText,
            selectionRanges: panel.promptSelectionRanges,
            isFocused: $promptFocused,
            measuredHeight: $promptInputHeight,
            metrics: metrics,
            modelDisplayName: panel.selectedModelDisplayName,
            metadataText: composerMetadataText,
            models: panel.availableModels,
            selectedModelId: panel.selectedModel?.id,
            fastModeEnabled: panel.fastModeEnabled,
            canEnableFastMode: panel.selectedModel?.supportsFastMode == true,
            canSend: panel.canSendPrompt,
            layoutMode: .pinnedControls,
            onSelectModel: { modelId in
                panel.selectModel(modelId)
            },
            onSetFastMode: { enabled in
                panel.setFastModeEnabled(enabled)
            },
            onSubmit: {
                Task { await panel.sendPrompt() }
            },
            onQueueFollowUp: {
                panel.queuePromptForNextTurn()
            },
            onInterrupt: {
                guard panel.canInterruptPendingPrompts else { return false }
                Task { await panel.interruptForPendingPrompts() }
                return true
            },
            onSelectionRangesChange: { ranges in
                panel.updatePromptSelectionRanges(ranges)
            },
            onSend: {
                Task { await panel.sendPrompt() }
            }
        )
    }

    private var composerMetadataText: String {
        var segments: [String] = []
        if panel.status.isBusy {
            segments.append(String(localized: "codexAppServer.composer.status.thinking", defaultValue: "Thinking"))
        }
        if let contextSummary = panel.contextSummary {
            let format = String(localized: "codexAppServer.composer.contextRemaining", defaultValue: "Context %ld%% left")
            segments.append(String(format: format, locale: Locale.current, contextSummary.remainingPercent))
        }
        segments.append(
            panel.fastModeEnabled
                ? String(localized: "codexAppServer.composer.fastOn", defaultValue: "Fast on")
                : String(localized: "codexAppServer.composer.fastOff", defaultValue: "Fast off")
        )
        if let rateLimitText {
            segments.append(rateLimitText)
        }
        return segments.joined(separator: "  ")
    }

    private var rateLimitText: String? {
        guard let summary = panel.rateLimitSummary else { return nil }
        let parts = summary.windows.map { window in
            "\(rateLimitName(window.name)) \(window.displayPercent)"
        }
        return parts.isEmpty ? nil : parts.joined(separator: "  ")
    }

    private func rateLimitName(_ name: String) -> String {
        switch name {
        case "primary":
            return String(localized: "codexAppServer.rateLimits.primary", defaultValue: "Primary")
        case "secondary":
            return String(localized: "codexAppServer.rateLimits.secondary", defaultValue: "Secondary")
        default:
            return name.capitalized
        }
    }

    private var transcriptBottomSpacerHeight: CGFloat {
        CodexComposerMetrics.micro.transcriptSpacerHeight(forPromptHeight: promptInputHeight)
            + CodexQueuedPromptIntegratedView.estimatedHeight(for: panel.queuedPrompts.count)
    }

    @ViewBuilder
    private var rateLimitFooter: some View {
        if let summary = panel.rateLimitSummary {
            CodexRateLimitFooterView(summary: summary)
                .frame(maxWidth: CodexComposerMetrics.maxWidth)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 24)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
        }
    }
}

#if DEBUG
enum CodexComposerDebugSettings {
    static let layoutLabVisibleKey = "codexComposerLayoutLabVisible"
    static let queueLabVisibleKey = "codexComposerQueueLabVisible"
    static let defaultShowLayoutLab = false
    static let defaultShowQueueLab = false
}
#endif

private enum CodexComposerLayoutMode {
    case legacyTopAligned
    case bottomAnchored
    case pinnedControls

    var contentAlignment: Alignment {
        switch self {
        case .legacyTopAligned:
            return .top
        case .bottomAnchored, .pinnedControls:
            return .bottom
        }
    }
}

private struct CodexComposerSurfaceChrome<Content: View>: View {
    let metrics: CodexComposerMetrics
    let themeBackground: NSColor
    @ViewBuilder let content: () -> Content

    var body: some View {
        Group {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                glassComposerChrome
            } else {
                fallbackComposerChrome
            }
            #else
            fallbackComposerChrome
            #endif
        }
    }

    #if compiler(>=6.2)
    @available(macOS 26.0, *)
    private var glassComposerChrome: some View {
        GlassEffectContainer(spacing: 0) {
            content()
                .glassEffect(
                    .regular
                        .tint(Color(nsColor: themeBackground).opacity(0.56))
                        .interactive(),
                    in: .rect(cornerRadius: metrics.cornerRadius)
                )
                .overlay(composerStroke)
                .shadow(color: Color.black.opacity(metrics.shadowOpacity), radius: metrics.shadowRadius, x: 0, y: metrics.shadowY)
        }
    }
    #endif

    private var fallbackComposerChrome: some View {
        content()
            .background {
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor).opacity(0.62))
            }
            .overlay(composerStroke)
            .shadow(color: Color.black.opacity(metrics.shadowOpacity - 0.04), radius: metrics.shadowRadius - 2, x: 0, y: metrics.shadowY - 1)
    }

    private var composerStroke: some View {
        RoundedRectangle(cornerRadius: metrics.cornerRadius, style: .continuous)
            .strokeBorder(Color(nsColor: .separatorColor).opacity(0.58), lineWidth: 1)
            .allowsHitTesting(false)
    }
}

private struct CodexComposerSurfaceContent: View {
    let placeholder: String
    @Binding var text: String
    let selectionRanges: [CodexPromptSelectionRange]
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let metrics: CodexComposerMetrics
    let modelDisplayName: String
    let metadataText: String
    let models: [CodexAppServerModelInfo]
    let selectedModelId: String?
    let fastModeEnabled: Bool
    let canEnableFastMode: Bool
    let canSend: Bool
    let layoutMode: CodexComposerLayoutMode
    let onSelectModel: (String) -> Void
    let onSetFastMode: (Bool) -> Void
    let onSubmit: () -> Void
    let onQueueFollowUp: () -> Void
    let onInterrupt: () -> Bool
    let onSelectionRangesChange: ([CodexPromptSelectionRange]) -> Void
    let onSend: () -> Void

    var body: some View {
        Group {
            switch layoutMode {
            case .legacyTopAligned, .bottomAnchored:
                stackedContent
            case .pinnedControls:
                pinnedControlContent
            }
        }
        .padding(.leading, metrics.leadingPadding)
        .padding(.trailing, metrics.trailingPadding)
        .padding(.top, metrics.topPadding)
        .padding(.bottom, metrics.bottomPadding)
        .frame(minHeight: metrics.minHeight, alignment: layoutMode.contentAlignment)
    }

    private var stackedContent: some View {
        VStack(alignment: .leading, spacing: metrics.rowSpacing) {
            promptEditor
            controlRow
        }
    }

    private var pinnedControlContent: some View {
        ZStack(alignment: .bottomLeading) {
            promptEditor
                .padding(.bottom, metrics.controlRowHeight + metrics.rowSpacing)
            controlRow
        }
        .frame(maxWidth: .infinity, alignment: .bottomLeading)
    }

    private var promptEditor: some View {
        CodexPromptTextEditor(
            placeholder: placeholder,
            text: $text,
            selectionRanges: selectionRanges,
            isFocused: $isFocused,
            measuredHeight: $measuredHeight,
            fontSize: metrics.promptFont,
            minimumHeight: metrics.promptMinHeight,
            maximumHeight: metrics.promptMaxHeight,
            onSubmit: onSubmit,
            onQueueFollowUp: onQueueFollowUp,
            onInterrupt: onInterrupt,
            onSelectionRangesChange: onSelectionRangesChange
        )
        .frame(height: measuredHeight)
        .accessibilityLabel(placeholder)
    }

    private var controlRow: some View {
        HStack(alignment: .center, spacing: metrics.iconSpacing) {
            composerIcon("plus")
            composerIcon("globe")
            composerIcon("cursorarrow.rays")
            composerIcon("hammer")

            CodexModelPickerButton(
                modelDisplayName: modelDisplayName,
                metadataText: metadataText,
                models: models,
                selectedModelId: selectedModelId,
                fastModeEnabled: fastModeEnabled,
                canEnableFastMode: canEnableFastMode,
                metrics: metrics,
                onSelectModel: onSelectModel,
                onSetFastMode: onSetFastMode
            )

            Spacer(minLength: 12)

            composerIcon("circle")
            composerIcon("mic")

            CodexComposerSendButton(
                metrics: metrics,
                canSend: canSend,
                onSend: onSend
            )
        }
        .frame(height: metrics.controlRowHeight)
    }

    private func composerIcon(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: metrics.iconFont, weight: .medium))
            .foregroundStyle(.secondary)
            .frame(width: metrics.iconFrame, height: metrics.iconFrame)
            .accessibilityHidden(true)
    }
}

private struct CodexModelPickerButton: View {
    let modelDisplayName: String
    let metadataText: String
    let models: [CodexAppServerModelInfo]
    let selectedModelId: String?
    let fastModeEnabled: Bool
    let canEnableFastMode: Bool
    let metrics: CodexComposerMetrics
    let onSelectModel: (String) -> Void
    let onSetFastMode: (Bool) -> Void

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 5) {
                Text(modelDisplayName)
                    .font(.system(size: metrics.statusFont, weight: .semibold))
                    .foregroundStyle(.primary.opacity(0.76))
                    .lineLimit(1)

                if !metadataText.isEmpty {
                    Text(metadataText)
                        .font(.system(size: max(9.5, metrics.statusFont - 0.5), weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Image(systemName: "chevron.down")
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            popoverContent
        }
        .accessibilityLabel(String(localized: "codexAppServer.modelPicker.title", defaultValue: "Model"))
    }

    private var popoverContent: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(String(localized: "codexAppServer.modelPicker.title", defaultValue: "Model"))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)

            if models.isEmpty {
                Text(String(localized: "codexAppServer.modelPicker.empty", defaultValue: "Models unavailable"))
                    .font(.system(size: 12, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(models) { model in
                            modelRow(model)
                        }
                    }
                }
                .frame(maxHeight: 280)
            }

            Divider()

            Toggle(
                String(localized: "codexAppServer.modelPicker.fastMode", defaultValue: "Fast mode"),
                isOn: Binding(
                    get: { fastModeEnabled },
                    set: { onSetFastMode($0) }
                )
            )
            .disabled(!canEnableFastMode)
            .toggleStyle(.switch)
            .font(.system(size: 12, weight: .medium))
        }
        .padding(12)
        .frame(width: 340)
    }

    private func modelRow(_ model: CodexAppServerModelInfo) -> some View {
        Button {
            onSelectModel(model.id)
            isPresented = false
        } label: {
            HStack(alignment: .top, spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(model.pickerTitle)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.primary)
                    if !model.description.isEmpty {
                        Text(model.description)
                            .font(.system(size: 11, weight: .regular))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                if selectedModelId == model.id || selectedModelId == model.model {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }
}

private struct CodexComposerSendButton: View {
    let metrics: CodexComposerMetrics
    let canSend: Bool
    let onSend: () -> Void

    @State private var isHovered = false

    var body: some View {
        Button {
            onSend()
        } label: {
            Image(systemName: "arrow.up")
                .font(.system(size: metrics.sendFont, weight: .semibold))
                .frame(width: metrics.sendButtonSize, height: metrics.sendButtonSize)
                .contentShape(Circle())
        }
        .buttonStyle(CodexComposerSendButtonStyle(canSend: canSend, isHovered: isHovered))
        .disabled(!canSend)
        .onHover { hovering in
            isHovered = hovering
        }
        .accessibilityLabel(String(localized: "codexAppServer.button.send", defaultValue: "Send"))
    }
}

private struct CodexComposerSendButtonStyle: ButtonStyle {
    let canSend: Bool
    let isHovered: Bool

    func makeBody(configuration: Configuration) -> some View {
        let active = canSend && configuration.isPressed
        let hovered = canSend && isHovered
        let fillOpacity: Double = {
            if !canSend { return 0.18 }
            if active { return 0.74 }
            if hovered { return 0.96 }
            return 0.90
        }()
        let strokeOpacity: Double = hovered || active ? 0.18 : 0
        let iconOpacity: Double = canSend ? (active ? 0.96 : 0.88) : 0.58

        configuration.label
            .foregroundStyle(
                canSend
                    ? Color(nsColor: .windowBackgroundColor).opacity(iconOpacity)
                    : Color(nsColor: .secondaryLabelColor)
            )
            .background {
                Circle()
                    .fill(Color(nsColor: .labelColor).opacity(fillOpacity))
            }
            .overlay {
                Circle()
                    .strokeBorder(Color(nsColor: .labelColor).opacity(strokeOpacity), lineWidth: 1)
            }
            .animation(.easeInOut(duration: 0.12), value: isHovered)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}

private struct CodexRateLimitFooterView: View {
    static let height: CGFloat = 28

    let summary: CodexAppServerRateLimitSummary

    var body: some View {
        HStack(spacing: 10) {
            Text(String(localized: "codexAppServer.rateLimits.title", defaultValue: "Rate limits"))
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)

            ForEach(summary.windows, id: \.name) { window in
                CodexRateLimitChip(window: window)
            }

            Spacer(minLength: 4)
        }
        .padding(.horizontal, 11)
        .frame(height: Self.height)
        .background {
            RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous)
                .fill(Color(nsColor: .controlBackgroundColor).opacity(0.36))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Self.height / 2, style: .continuous)
                .strokeBorder(Color(nsColor: .separatorColor).opacity(0.36), lineWidth: 1)
        }
    }
}

private struct CodexRateLimitChip: View {
    let window: CodexAppServerRateLimitWindow

    var body: some View {
        HStack(spacing: 5) {
            Text(localizedName)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.primary.opacity(0.78))

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color(nsColor: .separatorColor).opacity(0.38))
                    Capsule()
                        .fill(barColor.opacity(0.82))
                        .frame(width: max(3, proxy.size.width * window.clampedUsedFraction))
                }
            }
            .frame(width: 34, height: 4)

            Text(window.displayPercent)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(.secondary)

            if let resetText {
                Text(resetText)
                    .font(.system(size: 10.5, weight: .regular))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
        }
    }

    private var localizedName: String {
        switch window.name {
        case "primary":
            return String(localized: "codexAppServer.rateLimits.primary", defaultValue: "Primary")
        case "secondary":
            return String(localized: "codexAppServer.rateLimits.secondary", defaultValue: "Secondary")
        default:
            return window.name.capitalized
        }
    }

    private var barColor: Color {
        guard let used = window.usedPercent else { return Color(nsColor: .secondaryLabelColor) }
        if used >= 85 {
            return Color(nsColor: .systemRed)
        }
        if used >= 65 {
            return Color(nsColor: .systemOrange)
        }
        return Color(nsColor: .systemGreen)
    }

    private var resetText: String? {
        guard let resetsAt = window.resetsAt else { return nil }
        let formatted = Self.resetFormatter.string(from: resetsAt)
        let format = String(localized: "codexAppServer.rateLimits.resets", defaultValue: "resets %@")
        return String(format: format, locale: Locale.current, formatted)
    }

    private static let resetFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        formatter.doesRelativeDateFormatting = true
        return formatter
    }()
}

private enum CodexQueuedPromptIntegratedVariant: CaseIterable, Identifiable {
    case solidShelf
    case glassShelf
    case compactShelf

    var id: Self { self }

    var localizedTitle: String {
        switch self {
        case .solidShelf:
            return String(localized: "codexAppServer.queueDebug.variant.solidShelf", defaultValue: "Solid shelf")
        case .glassShelf:
            return String(localized: "codexAppServer.queueDebug.variant.glassShelf", defaultValue: "Glass shelf")
        case .compactShelf:
            return String(localized: "codexAppServer.queueDebug.variant.compactShelf", defaultValue: "Compact shelf")
        }
    }

    var topCornerRadius: CGFloat {
        switch self {
        case .solidShelf, .glassShelf:
            return 15
        case .compactShelf:
            return 12
        }
    }

    var rowSpacing: CGFloat {
        switch self {
        case .solidShelf, .glassShelf:
            return 5
        case .compactShelf:
            return 3
        }
    }

    var horizontalPadding: CGFloat {
        switch self {
        case .solidShelf, .glassShelf:
            return 11
        case .compactShelf:
            return 9
        }
    }

    var verticalPadding: CGFloat {
        switch self {
        case .solidShelf, .glassShelf:
            return 8
        case .compactShelf:
            return 6
        }
    }

    var fillOpacity: Double {
        switch self {
        case .solidShelf:
            return 0.58
        case .glassShelf:
            return 0.30
        case .compactShelf:
            return 0.48
        }
    }

    var borderOpacity: Double {
        switch self {
        case .solidShelf:
            return 0.38
        case .glassShelf:
            return 0.48
        case .compactShelf:
            return 0.30
        }
    }

    var maxVisibleRows: Int {
        switch self {
        case .solidShelf, .glassShelf:
            return 4
        case .compactShelf:
            return 3
        }
    }
}

private struct CodexQueuedPromptIntegratedView: View {
    let prompts: [CodexAppServerQueuedPrompt]
    let variant: CodexQueuedPromptIntegratedVariant

    var body: some View {
        VStack(alignment: .leading, spacing: variant.rowSpacing) {
            ForEach(Array(prompts.prefix(variant.maxVisibleRows))) { prompt in
                CodexQueuedPromptIntegratedRow(prompt: prompt)
            }
            if prompts.count > variant.maxVisibleRows {
                let format = String(localized: "codexAppServer.queue.more", defaultValue: "+%ld more")
                Text(String(format: format, locale: Locale.current, prompts.count - variant.maxVisibleRows))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, variant.horizontalPadding)
        .padding(.vertical, variant.verticalPadding)
        .background {
            UnevenRoundedRectangle(
                topLeadingRadius: variant.topCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: variant.topCornerRadius,
                style: .continuous
            )
            .fill(Color(nsColor: .controlBackgroundColor).opacity(variant.fillOpacity))
        }
        .overlay {
            UnevenRoundedRectangle(
                topLeadingRadius: variant.topCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: variant.topCornerRadius,
                style: .continuous
            )
            .strokeBorder(Color(nsColor: .separatorColor).opacity(variant.borderOpacity), lineWidth: 1)
        }
        .clipShape(
            UnevenRoundedRectangle(
                topLeadingRadius: variant.topCornerRadius,
                bottomLeadingRadius: 0,
                bottomTrailingRadius: 0,
                topTrailingRadius: variant.topCornerRadius,
                style: .continuous
            )
        )
    }

    static func estimatedHeight(for promptCount: Int) -> CGFloat {
        guard promptCount > 0 else { return 0 }
        let visibleRows = min(promptCount, CodexQueuedPromptIntegratedVariant.solidShelf.maxVisibleRows)
        let hiddenRow = promptCount > visibleRows ? 17 : 0
        return CGFloat(visibleRows * 22) + CGFloat(max(0, visibleRows - 1) * 5) + 16 + CGFloat(hiddenRow)
    }
}

private struct CodexQueuedPromptIntegratedRow: View {
    let prompt: CodexAppServerQueuedPrompt

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Text(prompt.kind.localizedLabel)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
                .frame(width: 58, alignment: .leading)
            Text(prompt.text)
                .font(.system(size: 11, weight: .regular))
                .foregroundStyle(.primary.opacity(0.86))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 0)
        }
        .frame(height: 22)
    }
}

#if DEBUG
private struct CodexComposerLayoutLabView: View {
    let themeBackground: NSColor

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(String(localized: "codexAppServer.composerDebug.title", defaultValue: "Composer layout lab"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            VStack(spacing: 8) {
                CodexComposerDebugVariantView(
                    title: String(localized: "codexAppServer.composerDebug.legacyTopAligned", defaultValue: "Legacy top aligned"),
                    layoutMode: .legacyTopAligned,
                    themeBackground: themeBackground
                )
                CodexComposerDebugVariantView(
                    title: String(localized: "codexAppServer.composerDebug.bottomAnchored", defaultValue: "Bottom anchored"),
                    layoutMode: .bottomAnchored,
                    themeBackground: themeBackground
                )
                CodexComposerDebugVariantView(
                    title: String(localized: "codexAppServer.composerDebug.pinnedControls", defaultValue: "Pinned controls"),
                    layoutMode: .pinnedControls,
                    themeBackground: themeBackground
                )
            }
        }
        .frame(maxWidth: CodexComposerMetrics.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}

private struct CodexComposerDebugVariantView: View {
    let title: String
    let layoutMode: CodexComposerLayoutMode
    let themeBackground: NSColor

    @State private var text = ""
    @State private var focused = false
    @State private var measuredHeight = CodexComposerMetrics.micro.promptMinHeight

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)

            CodexComposerSurfaceChrome(metrics: .micro, themeBackground: themeBackground) {
                CodexComposerSurfaceContent(
                    placeholder: String(localized: "codexAppServer.composerDebug.placeholder", defaultValue: "Type, then press Shift+Enter"),
                    text: $text,
                    selectionRanges: [CodexPromptSelectionRange.caret(at: (text as NSString).length)],
                    isFocused: $focused,
                    measuredHeight: $measuredHeight,
                    metrics: .micro,
                    modelDisplayName: "GPT-5.5 Codex",
                    metadataText: String(localized: "codexAppServer.composer.status.thinking", defaultValue: "Thinking"),
                    models: [],
                    selectedModelId: nil,
                    fastModeEnabled: false,
                    canEnableFastMode: false,
                    canSend: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
                    layoutMode: layoutMode,
                    onSelectModel: { _ in },
                    onSetFastMode: { _ in },
                    onSubmit: {},
                    onQueueFollowUp: {},
                    onInterrupt: { false },
                    onSelectionRangesChange: { _ in },
                    onSend: {}
                )
            }
        }
    }
}

private struct CodexQueuedPromptDebugLabView: View {
    let prompts: [CodexAppServerQueuedPrompt]

    private var previewPrompts: [CodexAppServerQueuedPrompt] {
        if !prompts.isEmpty { return prompts }
        return [
            CodexAppServerQueuedPrompt(text: "Use this as steer input", kind: .steer),
            CodexAppServerQueuedPrompt(text: "Run after the current turn finishes", kind: .followUp),
        ]
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(String(localized: "codexAppServer.queueDebug.title", defaultValue: "Queued message lab"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(CodexQueuedPromptIntegratedVariant.allCases) { variant in
                VStack(alignment: .leading, spacing: 3) {
                    Text(variant.localizedTitle)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                    CodexQueuedPromptIntegratedView(prompts: previewPrompts, variant: variant)
                        .frame(maxWidth: CodexComposerMetrics.queuedPromptWidth)
                        .frame(maxWidth: .infinity, alignment: .center)
                }
            }
        }
        .frame(maxWidth: CodexComposerMetrics.maxWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
    }
}
#endif

private struct CodexComposerMetrics {
    static let maxWidth: CGFloat = 740
    static let queuedPromptWidth = maxWidth - 44
    static let micro = CodexComposerMetrics(
        minHeight: 76,
        cornerRadius: 22,
        promptFont: 13,
        promptMinHeight: 17,
        promptMaxHeight: 260,
        statusFont: 11,
        iconFont: 14,
        iconFrame: 18,
        iconSpacing: 8,
        rowSpacing: 6,
        sendButtonSize: 30,
        sendFont: 14,
        leadingPadding: 15,
        trailingPadding: 8,
        topPadding: 12,
        bottomPadding: 7,
        bottomFloat: 8,
        transcriptBottomCushion: 26,
        shadowRadius: 16,
        shadowY: 8,
        shadowOpacity: 0.24
    )

    var minHeight: CGFloat
    var cornerRadius: CGFloat
    var promptFont: CGFloat
    var promptMinHeight: CGFloat
    var promptMaxHeight: CGFloat
    var statusFont: CGFloat
    var iconFont: CGFloat
    var iconFrame: CGFloat
    var iconSpacing: CGFloat
    var rowSpacing: CGFloat
    var sendButtonSize: CGFloat
    var sendFont: CGFloat
    var leadingPadding: CGFloat
    var trailingPadding: CGFloat
    var topPadding: CGFloat
    var bottomPadding: CGFloat
    var bottomFloat: CGFloat
    var transcriptBottomCushion: CGFloat
    var shadowRadius: CGFloat
    var shadowY: CGFloat
    var shadowOpacity: Double

    var controlRowHeight: CGFloat {
        max(iconFrame, sendButtonSize)
    }

    func surfaceHeight(forPromptHeight promptHeight: CGFloat) -> CGFloat {
        max(
            minHeight,
            topPadding + promptHeight + rowSpacing + controlRowHeight + bottomPadding
        )
    }

    func transcriptSpacerHeight(forPromptHeight promptHeight: CGFloat) -> CGFloat {
        max(
            112,
            surfaceHeight(forPromptHeight: promptHeight) + bottomFloat + transcriptBottomCushion
        )
    }
}

enum CodexPromptTextViewKeyAction: Equatable {
    case submit
    case queueFollowUp
    case interrupt
    case insertNewline
    case passThrough

    static func action(
        keyCode: UInt16,
        modifierFlags: NSEvent.ModifierFlags,
        hasMarkedText: Bool
    ) -> Self {
        guard !hasMarkedText else { return .passThrough }

        let normalizedFlags = modifierFlags
            .intersection(.deviceIndependentFlagsMask)
            .subtracting([.numericPad, .function, .capsLock])

        if keyCode == 48, normalizedFlags.isEmpty {
            return .queueFollowUp
        }

        if keyCode == 53, normalizedFlags.isEmpty {
            return .interrupt
        }

        guard keyCode == 36 || keyCode == 76 else { return .passThrough }

        if normalizedFlags.isEmpty {
            return .submit
        }
        if normalizedFlags == [.shift] {
            return .insertNewline
        }
        return .passThrough
    }
}

private final class CodexPromptPassthroughLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

private final class CodexPromptTextView: NSTextView {
    var onHandleKeyEvent: ((NSEvent, CodexPromptTextView) -> Bool)?
    var onDidBecomeFirstResponder: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let didBecomeFirstResponder = super.becomeFirstResponder()
        if didBecomeFirstResponder {
            onDidBecomeFirstResponder?()
        }
        return didBecomeFirstResponder
    }

    override func keyDown(with event: NSEvent) {
        if onHandleKeyEvent?(event, self) == true {
            return
        }
        super.keyDown(with: event)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if onHandleKeyEvent?(event, self) == true {
            return true
        }
        return super.performKeyEquivalent(with: event)
    }
}

private final class CodexPromptTextEditorView: NSView {
    private let scrollView = NSScrollView(frame: .zero)
    let textView = CodexPromptTextView(frame: .zero)
    private let placeholderField = CodexPromptPassthroughLabel(labelWithString: "")

    var onMeasuredHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat?

    var fontSize: CGFloat = 13 {
        didSet { updateFont() }
    }

    var minimumHeight: CGFloat = 17 {
        didSet { refreshMetrics() }
    }

    var maximumHeight: CGFloat = 96 {
        didSet { refreshMetrics() }
    }

    var placeholder: String = "" {
        didSet {
            placeholderField.stringValue = placeholder
            updatePlaceholderVisibility()
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        addSubview(scrollView)

        textView.translatesAutoresizingMaskIntoConstraints = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textColor = .labelColor
        textView.insertionPointColor = .labelColor
        textView.textContainerInset = .zero
        textView.textContainer?.lineFragmentPadding = 0
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.heightTracksTextView = false
        textView.minSize = NSSize(width: 0, height: minimumHeight)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        scrollView.documentView = textView

        placeholderField.translatesAutoresizingMaskIntoConstraints = false
        placeholderField.textColor = .secondaryLabelColor
        placeholderField.lineBreakMode = .byTruncatingTail
        placeholderField.maximumNumberOfLines = 1
        addSubview(placeholderField)

        NotificationCenter.default.addObserver(
            self,
            selector: #selector(textDidChange(_:)),
            name: NSText.didChangeNotification,
            object: textView
        )

        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor),

            placeholderField.leadingAnchor.constraint(equalTo: leadingAnchor),
            placeholderField.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor),
            placeholderField.centerYAnchor.constraint(equalTo: topAnchor, constant: minimumHeight / 2),
        ])

        updateFont()
        updatePlaceholderVisibility()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        NotificationCenter.default.removeObserver(self)
    }

    override func layout() {
        super.layout()
        updateTextViewLayout()
        reportMeasuredHeightIfNeeded()
    }

    func refreshMetrics() {
        textView.minSize = NSSize(width: 0, height: minimumHeight)
        updatePlaceholderVisibility()
        needsLayout = true
        layoutSubtreeIfNeeded()
        reportMeasuredHeightIfNeeded()
    }

    func focusIfNeeded(restoring selectionRanges: [CodexPromptSelectionRange]) {
        guard let window, window.firstResponder !== textView else { return }
        guard window.makeFirstResponder(textView) else { return }
        applySelectionRanges(selectionRanges)
    }

    func applySelectionRanges(_ selectionRanges: [CodexPromptSelectionRange]) {
        let length = (textView.string as NSString).length
        textView.selectedRanges = CodexPromptSelectionRange.nsValues(
            from: selectionRanges,
            textLength: length
        )
        if let firstRange = textView.selectedRanges.first?.rangeValue {
            textView.scrollRangeToVisible(firstRange)
        }
    }

    func currentSelectionRanges() -> [CodexPromptSelectionRange] {
        let length = (textView.string as NSString).length
        return CodexPromptSelectionRange.normalized(
            nsRanges: textView.selectedRanges,
            textLength: length
        )
    }

    private func updateFont() {
        let font = NSFont.systemFont(ofSize: fontSize, weight: .regular)
        textView.font = font
        placeholderField.font = font
        refreshMetrics()
    }

    private func lineHeight() -> CGFloat {
        let font = textView.font ?? NSFont.systemFont(ofSize: fontSize, weight: .regular)
        return ceil(font.ascender - font.descender + font.leading)
    }

    private func cappedMaximumHeight() -> CGFloat {
        max(minimumHeight, maximumHeight)
    }

    private func naturalHeight(for width: CGFloat) -> CGFloat {
        guard let layoutManager = textView.layoutManager,
              let textContainer = textView.textContainer else {
            return minimumHeight
        }

        textContainer.containerSize = NSSize(
            width: width,
            height: CGFloat.greatestFiniteMagnitude
        )
        layoutManager.ensureLayout(for: textContainer)
        let usedRect = layoutManager.usedRect(for: textContainer)
        let contentHeight = max(lineHeight(), ceil(usedRect.height))
        return max(minimumHeight, contentHeight)
    }

    private func updateTextViewLayout() {
        let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
        let naturalHeight = naturalHeight(for: availableWidth)
        let measuredHeight = min(cappedMaximumHeight(), naturalHeight)
        let documentHeight = max(naturalHeight, measuredHeight)
        textView.frame = NSRect(x: 0, y: 0, width: availableWidth, height: documentHeight)
    }

    private func fittingHeight() -> CGFloat {
        let availableWidth = max(scrollView.contentSize.width, bounds.width, 1)
        return min(cappedMaximumHeight(), naturalHeight(for: availableWidth))
    }

    private func reportMeasuredHeightIfNeeded() {
        let height = fittingHeight()
        guard lastReportedHeight == nil || abs((lastReportedHeight ?? height) - height) > 0.5 else { return }
        lastReportedHeight = height
        onMeasuredHeightChange?(height)
    }

    @objc
    private func textDidChange(_ notification: Notification) {
        updatePlaceholderVisibility()
        refreshMetrics()
    }

    private func updatePlaceholderVisibility() {
        placeholderField.isHidden = textView.string.isEmpty == false
    }
}

private struct CodexPromptTextEditor: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let selectionRanges: [CodexPromptSelectionRange]
    @Binding var isFocused: Bool
    @Binding var measuredHeight: CGFloat
    let fontSize: CGFloat
    let minimumHeight: CGFloat
    let maximumHeight: CGFloat
    let onSubmit: () -> Void
    let onQueueFollowUp: () -> Void
    let onInterrupt: () -> Bool
    let onSelectionRangesChange: ([CodexPromptSelectionRange]) -> Void

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodexPromptTextEditor
        var isProgrammaticMutation = false
        var isProgrammaticSelectionMutation = false
        var pendingFocusRequest = false
        var lastKnownSelectionRanges: [CodexPromptSelectionRange]

        init(parent: CodexPromptTextEditor) {
            self.parent = parent
            lastKnownSelectionRanges = parent.selectionRanges
        }

        func textDidBeginEditing(_ notification: Notification) {
            parent.isFocused = true
        }

        func textDidEndEditing(_ notification: Notification) {
            if let textView = notification.object as? NSTextView {
                storeSelection(from: textView)
            }
            parent.isFocused = false
        }

        func textDidChange(_ notification: Notification) {
            guard !isProgrammaticMutation,
                  let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !isProgrammaticSelectionMutation,
                  let textView = notification.object as? NSTextView else { return }
            storeSelection(from: textView)
        }

        func handleDidBecomeFirstResponder() {
            parent.isFocused = true
        }

        func handleMeasuredHeight(_ height: CGFloat) {
            guard abs(parent.measuredHeight - height) > 0.5 else { return }
            Task { @MainActor in
                self.parent.measuredHeight = height
            }
        }

        func handleKeyEvent(_ event: NSEvent, editor: CodexPromptTextView) -> Bool {
            switch CodexPromptTextViewKeyAction.action(
                keyCode: event.keyCode,
                modifierFlags: event.modifierFlags,
                hasMarkedText: editor.hasMarkedText()
            ) {
            case .submit:
                let currentText = editor.string
                if parent.text != currentText {
                    parent.text = currentText
                }
                parent.onSubmit()
                return true
            case .queueFollowUp:
                let currentText = editor.string
                if parent.text != currentText {
                    parent.text = currentText
                }
                parent.onQueueFollowUp()
                return true
            case .interrupt:
                return parent.onInterrupt()
            case .insertNewline, .passThrough:
                return false
            }
        }

        func storeSelection(from textView: NSTextView) {
            let length = (textView.string as NSString).length
            let ranges = CodexPromptSelectionRange.normalized(
                nsRanges: textView.selectedRanges,
                textLength: length
            )
            guard ranges != lastKnownSelectionRanges else { return }
            lastKnownSelectionRanges = ranges
            parent.onSelectionRangesChange(ranges)
        }

        func applySelection(
            _ ranges: [CodexPromptSelectionRange],
            to view: CodexPromptTextEditorView
        ) {
            let length = (view.textView.string as NSString).length
            let normalizedRanges = CodexPromptSelectionRange.normalized(
                ranges,
                textLength: length
            )
            isProgrammaticSelectionMutation = true
            view.applySelectionRanges(normalizedRanges)
            isProgrammaticSelectionMutation = false
            lastKnownSelectionRanges = normalizedRanges
            parent.onSelectionRangesChange(normalizedRanges)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> CodexPromptTextEditorView {
        let view = CodexPromptTextEditorView(frame: .zero)
        view.placeholder = placeholder
        view.fontSize = fontSize
        view.minimumHeight = minimumHeight
        view.maximumHeight = maximumHeight
        view.textView.string = text
        view.textView.delegate = context.coordinator
        context.coordinator.applySelection(selectionRanges, to: view)
        view.textView.setAccessibilityLabel(placeholder)
        view.textView.setAccessibilityIdentifier("codex-app-server-prompt-input")
        view.setAccessibilityIdentifier("codex-app-server-prompt-input")
        view.textView.onHandleKeyEvent = { [weak coordinator = context.coordinator] event, editor in
            coordinator?.handleKeyEvent(event, editor: editor) ?? false
        }
        view.textView.onDidBecomeFirstResponder = { [weak coordinator = context.coordinator] in
            coordinator?.handleDidBecomeFirstResponder()
        }
        view.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.handleMeasuredHeight(height)
        }
        view.refreshMetrics()
        return view
    }

    func updateNSView(_ nsView: CodexPromptTextEditorView, context: Context) {
        context.coordinator.parent = self
        nsView.placeholder = placeholder
        nsView.fontSize = fontSize
        nsView.minimumHeight = minimumHeight
        nsView.maximumHeight = maximumHeight
        nsView.textView.setAccessibilityLabel(placeholder)

        if nsView.textView.string != text {
            context.coordinator.isProgrammaticMutation = true
            nsView.textView.string = text
            context.coordinator.isProgrammaticMutation = false
            context.coordinator.applySelection(context.coordinator.lastKnownSelectionRanges, to: nsView)
        } else if context.coordinator.lastKnownSelectionRanges.isEmpty {
            context.coordinator.applySelection(selectionRanges, to: nsView)
        }

        nsView.onMeasuredHeightChange = { [weak coordinator = context.coordinator] height in
            coordinator?.handleMeasuredHeight(height)
        }
        nsView.refreshMetrics()

        guard nsView.window != nil else { return }
        let isFirstResponder = nsView.window?.firstResponder === nsView.textView
        if isFocused, !isFirstResponder, !context.coordinator.pendingFocusRequest {
            context.coordinator.pendingFocusRequest = true
            Task { [weak nsView, weak coordinator = context.coordinator] in
                await MainActor.run {
                    guard let coordinator else { return }
                    coordinator.pendingFocusRequest = false
                    guard coordinator.parent.isFocused, let nsView else { return }
                    nsView.focusIfNeeded(restoring: coordinator.lastKnownSelectionRanges)
                }
            }
        }
    }

    static func dismantleNSView(_ nsView: CodexPromptTextEditorView, coordinator: Coordinator) {
        coordinator.storeSelection(from: nsView.textView)
        nsView.textView.delegate = nil
        nsView.textView.onHandleKeyEvent = nil
        nsView.textView.onDidBecomeFirstResponder = nil
        nsView.onMeasuredHeightChange = nil
    }
}

private struct CodexAppServerPendingRequestView: View {
    let request: CodexAppServerPendingRequest
    let onAccept: () -> Void
    let onDecline: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(
                String(localized: "codexAppServer.request.title", defaultValue: "Approval requested"),
                systemImage: "hand.raised.fill"
            )
            .font(.caption.weight(.semibold))
            .foregroundStyle(.orange)

            Text(request.method)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            Text(request.summary)
                .font(.system(.body, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 8) {
                if request.supportsDecisionResponse {
                    Button {
                        onAccept()
                    } label: {
                        Label(
                            String(localized: "codexAppServer.button.approve", defaultValue: "Approve"),
                            systemImage: "checkmark"
                        )
                    }
                    .buttonStyle(.borderedProminent)

                    Button {
                        onDecline()
                    } label: {
                        Label(
                            String(localized: "codexAppServer.button.deny", defaultValue: "Deny"),
                            systemImage: "xmark"
                        )
                    }
                }

                Button {
                    onCancel()
                } label: {
                    Label(
                        String(localized: "codexAppServer.button.cancel", defaultValue: "Cancel"),
                        systemImage: "slash.circle"
                    )
                }
            }
        }
        .padding(10)
        .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.orange.opacity(0.4), lineWidth: 1)
        )
    }
}
