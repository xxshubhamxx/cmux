import Foundation

/// Developer-only toggle that swaps the editor panel view between the native
/// `NSTextView` backend (default) and the Monaco (`WKWebView`) backend.
///
/// This is intentionally not a user-facing setting: Monaco is still being
/// validated. The toggle lives under the Debug menu and reads a plain
/// `UserDefaults` key so changes are effective the next time an editor tab is
/// mounted. Existing tabs do not hot-swap backends — close and reopen the file
/// to flip it.
enum EditorBackendSettings {
    static let defaultsKey = "editor.backend.monaco"
    static let didChangeNotification = Notification.Name("cmux.editorBackendSettingsDidChange")

    static func useMonaco(defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    static func setUseMonaco(_ enabled: Bool, defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
        NotificationCenter.default.post(name: didChangeNotification, object: nil)
    }
}
