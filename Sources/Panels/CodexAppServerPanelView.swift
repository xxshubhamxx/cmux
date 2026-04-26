import SwiftUI

struct CodexAppServerPanelView: View {
    @ObservedObject var panel: CodexAppServerPanel
    let isFocused: Bool

    @FocusState private var promptFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            transcript
            Divider()
            composer
        }
        .background(Color(nsColor: .textBackgroundColor))
        .onAppear {
            if isFocused {
                promptFocused = true
            }
        }
        .task {
            await panel.start()
        }
        .onChange(of: isFocused) { _, focused in
            if focused {
                promptFocused = true
            }
        }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusForeground)
                .frame(width: 7, height: 7)

            Text(panel.status.localizedTitle)
                .font(.caption2)
                .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            Label(
                String(localized: "codexAppServer.cwd.label", defaultValue: "Working directory"),
                systemImage: "folder"
            )
            .labelStyle(.iconOnly)
            .foregroundStyle(.secondary)

            TextField(
                String(localized: "codexAppServer.cwd.placeholder", defaultValue: "Working directory"),
                text: $panel.cwd
            )
            .textFieldStyle(.plain)
            .font(.system(size: 13, design: .monospaced))
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 7))
            .frame(minWidth: 220, maxWidth: 360)

            Button {
                if showsStartButton {
                    if !isStopped {
                        panel.stop()
                    }
                    Task { await panel.start() }
                } else {
                    panel.stop()
                }
            } label: {
                Image(systemName: showsStartButton ? "play.fill" : "stop.fill")
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .frame(width: 26, height: 26)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.38), in: RoundedRectangle(cornerRadius: 7))
            .accessibilityLabel(showsStartButton
                ? String(localized: "codexAppServer.button.start", defaultValue: "Start")
                : String(localized: "codexAppServer.button.stop", defaultValue: "Stop")
            )
            .disabled(panel.status == .starting)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 5)
    }

    private var transcript: some View {
        VStack(spacing: 0) {
            ZStack {
                CodexTrajectoryTranscriptView(items: panel.transcriptItems)
                    .opacity(panel.transcriptItems.isEmpty ? 0 : 1)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                if panel.transcriptItems.isEmpty && panel.pendingRequests.isEmpty {
                    emptyState
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            if !panel.pendingRequests.isEmpty {
                Divider()
                pendingRequests
            }
        }
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
        .background(Color(nsColor: .textBackgroundColor))
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

    private var composer: some View {
        HStack(alignment: .center, spacing: 8) {
            TextField(
                String(localized: "codexAppServer.prompt.placeholder", defaultValue: "Ask Codex about this workspace"),
                text: $panel.promptText,
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .font(.system(size: 16))
            .lineLimit(1...5)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minHeight: 28, alignment: .center)
            .focused($promptFocused)
            .onSubmit {
                Task { await panel.sendPrompt() }
            }

            Button {
                Task { await panel.sendPrompt() }
            } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 14, weight: .semibold))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(!panel.canSendPrompt)
            .foregroundStyle(panel.canSendPrompt ? .primary : .secondary)
            .frame(width: 28, height: 28)
            .background(Color(nsColor: .controlBackgroundColor).opacity(panel.canSendPrompt ? 0.75 : 0.35), in: Circle())
            .accessibilityLabel(String(localized: "codexAppServer.button.send", defaultValue: "Send"))
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.88), in: RoundedRectangle(cornerRadius: 12))
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color(nsColor: .separatorColor).opacity(0.62), lineWidth: 1)
        )
        .frame(maxWidth: 1_180)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, 24)
        .padding(.top, 8)
        .padding(.bottom, 12)
    }

    private var isStopped: Bool {
        if case .stopped = panel.status {
            return true
        }
        return false
    }

    private var showsStartButton: Bool {
        switch panel.status {
        case .stopped, .failed:
            return true
        case .starting, .ready, .running:
            return false
        }
    }

    private var statusForeground: Color {
        switch panel.status {
        case .ready:
            return .green
        case .running, .starting:
            return .blue
        case .failed:
            return .red
        case .stopped:
            return .secondary
        }
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
