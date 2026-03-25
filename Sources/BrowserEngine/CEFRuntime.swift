import Foundation

/// Manages the CEF runtime lifecycle: initialization, message loop
/// pumping, and shutdown.
///
/// CEF must be initialized exactly once per app launch. After
/// initialization, the message loop must be pumped periodically
/// from the main thread. Shutdown happens at app termination.
final class CEFRuntime {

    static let shared = CEFRuntime()

    private var messageLoopTimer: Timer?
    private(set) var isInitialized = false

    private init() {}

    // MARK: - Initialization

    /// Initialize CEF using the bridge layer. Must be called from
    /// the main thread after CEFFrameworkManager reports .ready.
    ///
    /// Returns true on success. Once initialized, call
    /// startMessageLoop() to begin pumping.
    @discardableResult
    func initialize() -> Bool {
        guard !isInitialized else { return true }
        guard CEFFrameworkManager.shared.isAvailable else { return false }

        let frameworkPath = CEFFrameworkManager.shared.frameworksDir.path
        let helperPath = Bundle.main.privateFrameworksPath
            .map { ($0 as NSString).appendingPathComponent("cmux Helper.app/Contents/MacOS/cmux Helper") }
            ?? ""

        let cacheRoot: String = {
            let appSupport = FileManager.default.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first!
            let bundleID = Bundle.main.bundleIdentifier ?? "com.manaflow.cmux"
            return appSupport
                .appendingPathComponent(bundleID)
                .appendingPathComponent("CEFCache")
                .path
        }()

        // Ensure cache directory exists
        try? FileManager.default.createDirectory(
            atPath: cacheRoot,
            withIntermediateDirectories: true
        )

        let result = cef_bridge_initialize(frameworkPath, helperPath, cacheRoot)
        if result == CEF_BRIDGE_OK {
            isInitialized = true
            startMessageLoop()
            return true
        }
        return false
    }

    // MARK: - Message Loop

    /// Start pumping the CEF message loop from the main thread.
    /// Uses a repeating timer at ~60Hz.
    func startMessageLoop() {
        guard isInitialized, messageLoopTimer == nil else { return }
        messageLoopTimer = Timer.scheduledTimer(
            withTimeInterval: 1.0 / 60.0,
            repeats: true
        ) { _ in
            cef_bridge_do_message_loop_work()
        }
    }

    /// Stop the message loop timer.
    func stopMessageLoop() {
        messageLoopTimer?.invalidate()
        messageLoopTimer = nil
    }

    // MARK: - Shutdown

    /// Shut down CEF. Call at app termination.
    func shutdown() {
        stopMessageLoop()
        if isInitialized {
            cef_bridge_shutdown()
            isInitialized = false
        }
    }

    // MARK: - Version

    /// Get the CEF version string.
    var version: String {
        guard let cstr = cef_bridge_get_version() else { return "unknown" }
        let str = String(cString: cstr)
        cef_bridge_free_string(cstr)
        return str
    }
}
