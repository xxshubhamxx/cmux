import AppKit
import Combine
import Foundation

/// A panel that provides a simple text editor for a file.
/// Tracks dirty state, supports save, and watches for external file changes.
@MainActor
final class EditorPanel: Panel, ObservableObject {
    let id: UUID
    let panelType: PanelType = .editor

    /// Absolute path to the file being edited.
    let filePath: String

    /// The workspace this panel belongs to.
    private(set) var workspaceId: UUID

    /// Current text content of the editor.
    @Published var content: String = ""

    /// Title shown in the tab bar (filename).
    @Published private(set) var displayTitle: String = ""

    /// SF Symbol icon for the tab bar.
    var displayIcon: String? { "doc.text" }

    /// Whether the file has unsaved changes.
    @Published private(set) var isDirty: Bool = false

    /// Whether the file has been deleted or is unreadable.
    @Published private(set) var isFileUnavailable: Bool = false

    /// Token incremented to trigger focus flash animation.
    @Published private(set) var focusFlashToken: Int = 0

    /// Weak reference to the AppKit text view so focus() can make it first responder.
    weak var textView: NSTextView?

    /// Encoding detected when the file was loaded. Preserved on save so legacy-encoded
    /// files are not silently re-encoded to UTF-8.
    private var originalEncoding: String.Encoding = .utf8

    /// The saved content, used to detect dirty state.
    private var savedContent: String = ""

    // MARK: - File watching

    private nonisolated(unsafe) var fileWatchSource: DispatchSourceFileSystemObject?
    private var fileDescriptor: Int32 = -1
    private var isClosed: Bool = false
    private let watchQueue = DispatchQueue(label: "com.cmux.editor-file-watch", qos: .utility)
    /// Suppresses file-watcher reloads immediately after a save.
    private var suppressNextReload: Bool = false

    private static let reattachDelay: TimeInterval = 0.5

    // MARK: - Init

    init(workspaceId: UUID, filePath: String) {
        self.id = UUID()
        self.workspaceId = workspaceId
        self.filePath = filePath
        self.displayTitle = (filePath as NSString).lastPathComponent

        loadFileContent()
        startFileWatcher()
        if isFileUnavailable && fileWatchSource == nil {
            scheduleReattach()
        }
    }

    // MARK: - Panel protocol

    func focus() {
        guard let textView else { return }
        textView.window?.makeFirstResponder(textView)
    }

    func unfocus() {
        // NSTextView resigns naturally when another panel takes first responder.
    }

    func close() {
        if isDirty {
            // If save fails, keep the panel alive and preserve the dirty buffer.
            guard save() else { return }
        }
        isClosed = true
        stopFileWatcher()
    }

    func triggerFlash(reason: WorkspaceAttentionFlashReason) {
        _ = reason
        guard NotificationPaneFlashSettings.isEnabled() else { return }
        focusFlashToken += 1
    }

    // MARK: - Dirty tracking

    func markDirty() {
        let dirty = content != savedContent
        if isDirty != dirty {
            isDirty = dirty
            updateDisplayTitle()
        }
    }

    // MARK: - Save

    /// Saves the current content to disk using the file's original encoding.
    /// Returns `true` on success. On failure, the dirty state is preserved.
    @discardableResult
    func save() -> Bool {
        guard isDirty else { return true }
        do {
            suppressNextReload = true
            try content.write(toFile: filePath, atomically: true, encoding: originalEncoding)
            savedContent = content
            isDirty = false
            updateDisplayTitle()
            return true
        } catch {
            suppressNextReload = false
            #if DEBUG
            NSLog("editor.save failed path=%@ error=%@", filePath, "\(error)")
            #endif
            return false
        }
    }

    // MARK: - File I/O

    private func loadFileContent() {
        do {
            let newContent = try String(contentsOfFile: filePath, encoding: .utf8)
            originalEncoding = .utf8
            content = newContent
            savedContent = newContent
            isDirty = false
            isFileUnavailable = false
        } catch {
            // Fallback: ISO Latin-1 accepts all 256 byte values, covering legacy encodings.
            if let data = FileManager.default.contents(atPath: filePath),
               let decoded = String(data: data, encoding: .isoLatin1) {
                originalEncoding = .isoLatin1
                content = decoded
                savedContent = decoded
                isDirty = false
                isFileUnavailable = false
            } else {
                isFileUnavailable = true
            }
        }
        updateDisplayTitle()
    }

    private func updateDisplayTitle() {
        let filename = (filePath as NSString).lastPathComponent
        displayTitle = isDirty ? "\(filename) *" : filename
    }

    // MARK: - File watcher via DispatchSource

    private func startFileWatcher() {
        let fd = open(filePath, O_EVTONLY)
        guard fd >= 0 else { return }
        fileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename, .extend],
            queue: watchQueue
        )

        source.setEventHandler { [weak self] in
            guard let self else { return }
            let flags = source.data
            if flags.contains(.delete) || flags.contains(.rename) {
                DispatchQueue.main.async {
                    self.stopFileWatcher()
                    if self.suppressNextReload {
                        self.suppressNextReload = false
                        self.startFileWatcher()
                    } else if self.isDirty {
                        // Preserve the dirty buffer; just re-attach the watcher to the new inode.
                        if FileManager.default.fileExists(atPath: self.filePath) {
                            self.startFileWatcher()
                        } else {
                            self.scheduleReattach()
                        }
                    } else {
                        self.loadFileContent()
                        if self.isFileUnavailable {
                            self.scheduleReattach()
                        } else {
                            self.startFileWatcher()
                        }
                    }
                }
            } else {
                DispatchQueue.main.async {
                    if self.suppressNextReload {
                        self.suppressNextReload = false
                    } else if !self.isDirty {
                        self.loadFileContent()
                    }
                }
            }
        }

        source.setCancelHandler {
            Darwin.close(fd)
        }

        source.resume()
        fileWatchSource = source
    }

    /// Keep retrying until the file reappears or the panel is closed. Atomic saves by
    /// external editors may take longer than a fixed window, so there is no attempt cap.
    private func scheduleReattach() {
        watchQueue.asyncAfter(deadline: .now() + Self.reattachDelay) { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async {
                guard !self.isClosed else { return }
                if FileManager.default.fileExists(atPath: self.filePath) {
                    self.isFileUnavailable = false
                    if !self.isDirty {
                        self.loadFileContent()
                    }
                    self.startFileWatcher()
                } else {
                    self.scheduleReattach()
                }
            }
        }
    }

    private func stopFileWatcher() {
        if let source = fileWatchSource {
            source.cancel()
            fileWatchSource = nil
        }
        fileDescriptor = -1
    }

    deinit {
        fileWatchSource?.cancel()
    }
}
