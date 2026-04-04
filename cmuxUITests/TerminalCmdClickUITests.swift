import XCTest
import Foundation

final class TerminalCmdClickUITests: XCTestCase {
    private enum DisplayMode: String {
        case escaped
        case raw
    }

    private struct SetupData {
        let expectedPath: String
    }

    private var hoverDiagnosticsPath = ""
    private var openCapturePath = ""
    private var setupDataPath = ""
    private var commandPath = ""
    private var fixtureDirectoryURL: URL!

    override func setUp() {
        super.setUp()
        continueAfterFailure = false

        fixtureDirectoryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-ui-test-terminal-cmd-click-\(UUID().uuidString)", isDirectory: true)
        hoverDiagnosticsPath = fixtureDirectoryURL.appendingPathComponent("hover.json").path
        openCapturePath = fixtureDirectoryURL.appendingPathComponent("open.log").path
        setupDataPath = fixtureDirectoryURL.appendingPathComponent("setup.json").path
        commandPath = fixtureDirectoryURL.appendingPathComponent("command.json").path

        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(atPath: setupDataPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.createDirectory(at: fixtureDirectoryURL, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(atPath: hoverDiagnosticsPath)
        try? FileManager.default.removeItem(atPath: openCapturePath)
        try? FileManager.default.removeItem(atPath: setupDataPath)
        try? FileManager.default.removeItem(atPath: commandPath)
        try? FileManager.default.removeItem(at: fixtureDirectoryURL)
        super.tearDown()
    }

    func testHoldingCommandAfterSelectionSuppresssCommandHoverDispatch() throws {
        let app = launchApp(captureOpenPaths: false, captureHoverDiagnostics: true)
        defer { app.terminate() }

        _ = try waitForReadySetup()
        let result = try runCommand(action: "select_token_and_hold_command")

        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected setup harness to create a selection and suppress cmd-hover. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandSelectionActive"] as? String,
            "1",
            "Expected a real Ghostty selection before holding Command. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandHoverSuppressed"] as? String,
            "1",
            "Expected cmd-hover suppression to trigger while selection stayed active. result=\(result)"
        )

        guard let diagnostics = waitForHoverDiagnostics(timeout: 5.0) else {
            XCTFail("Expected hover diagnostics after holding Command with an active selection. result=\(result)")
            return
        }

        let suppressedCount = diagnostics["suppressed_command_hover_count"] as? Int ?? 0
        let forwardedCount = diagnostics["forwarded_command_hover_count"] as? Int ?? 0
        XCTAssertGreaterThanOrEqual(
            suppressedCount,
            1,
            "Expected holding Command after selecting text to suppress command hover dispatch. diagnostics=\(diagnostics)"
        )
        XCTAssertEqual(
            forwardedCount,
            0,
            "Expected no command-modified hover dispatch to reach Ghostty while selection is active. diagnostics=\(diagnostics)"
        )
    }

    func testCmdClickEscapedPathWithSpacesOpensResolvedFile() throws {
        let app = launchApp(
            displayMode: .escaped,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let fileName = "Cmd Click Fixture.txt"
        let setup = try waitForReadySetup()
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path

        XCTAssertEqual(setup.expectedPath, expectedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click harness to open the escaped-space path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedPath,
            "Expected cmd-click to resolve the escaped-space path to the real file. result=\(result)"
        )

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
            XCTFail("Expected cmd-click capture log after running the command harness. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to resolve the escaped-space path to the real file. opened=\(openedPaths) expected=\(expectedPath)"
        )
    }

    func testCmdClickRawLsStylePathWithSpacesOpensResolvedFile() throws {
        let app = launchApp(
            displayMode: .raw,
            captureOpenPaths: true,
            captureHoverDiagnostics: false
        )
        defer { app.terminate() }

        let fileName = "Cmd Click Fixture.txt"
        let setup = try waitForReadySetup()
        let expectedPath = fixtureDirectoryURL.appendingPathComponent(fileName).path

        XCTAssertEqual(setup.expectedPath, expectedPath)

        let result = try runCommand(action: "cmd_click_token")
        XCTAssertEqual(
            result["lastCommandSucceeded"] as? String,
            "1",
            "Expected cmd-click harness to open the raw-space path. result=\(result)"
        )
        XCTAssertEqual(
            result["lastCommandOpenedPath"] as? String,
            expectedPath,
            "Expected cmd-click to resolve the raw-space path to the real file. result=\(result)"
        )

        guard let openedPaths = waitForCapturedOpenPaths(timeout: 5.0) else {
            XCTFail("Expected cmd-click capture log after running the raw-space command harness. result=\(result)")
            return
        }

        XCTAssertTrue(
            openedPaths.contains(expectedPath),
            "Expected cmd-click to resolve the raw-space path to the real file. opened=\(openedPaths) expected=\(expectedPath)"
        )
    }

    private func launchApp(
        displayMode: DisplayMode = .escaped,
        captureOpenPaths: Bool,
        captureHoverDiagnostics: Bool
    ) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["CMUX_TAG"] = "ui-test-terminal-cmd-click"
        app.launchEnvironment["CMUX_UI_TEST_MODE"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_SETUP"] = "1"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_PATH"] = setupDataPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_COMMAND_PATH"] = commandPath
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FIXTURE_DIR"] = fixtureDirectoryURL.path
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_FILE_NAME"] = "Cmd Click Fixture.txt"
        app.launchEnvironment["CMUX_UI_TEST_TERMINAL_CMD_CLICK_DISPLAY_MODE"] = displayMode.rawValue
        if captureOpenPaths {
            app.launchEnvironment["CMUX_UI_TEST_CAPTURE_OPEN_PATH"] = openCapturePath
        }
        if captureHoverDiagnostics {
            app.launchEnvironment["CMUX_UI_TEST_CMD_HOVER_DIAGNOSTICS_PATH"] = hoverDiagnosticsPath
        }
        launchAndEnsureForeground(app)
        return app
    }

    private func waitForCapturedOpenPaths(timeout: TimeInterval) -> [String]? {
        var openedPaths: [String]?
        let matched = waitForCondition(timeout: timeout) {
            guard let contents = try? String(contentsOfFile: self.openCapturePath, encoding: .utf8) else {
                return false
            }
            let lines = contents
                .split(separator: "\n")
                .map(String.init)
                .filter { !$0.isEmpty }
            guard !lines.isEmpty else { return false }
            openedPaths = lines
            return true
        }
        return matched ? openedPaths : nil
    }

    private func waitForHoverDiagnostics(timeout: TimeInterval) -> [String: Any]? {
        var diagnostics: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let data = try? Data(contentsOf: URL(fileURLWithPath: self.hoverDiagnosticsPath)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  (object["suppressed_command_hover_count"] as? Int ?? 0) > 0 else {
                return false
            }
            diagnostics = object
            return true
        }
        return matched ? diagnostics : nil
    }

    private func waitForReadySetup(timeout: TimeInterval = 15.0) throws -> SetupData {
        var setup: SetupData?
        let matched = waitForCondition(timeout: timeout) {
            guard let payload = self.loadSetupData(),
                  payload["ready"] as? String == "1",
                  let expectedPath = payload["expectedPath"] as? String else {
                return false
            }
            setup = SetupData(expectedPath: expectedPath)
            return true
        }

        guard matched, let setup else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "Expected terminal cmd-click setup data. payload=\(loadSetupData() ?? [:])"
            ])
        }
        return setup
    }

    private func runCommand(
        action: String,
        timeout: TimeInterval = 10.0
    ) throws -> [String: Any] {
        let commandID = UUID().uuidString
        let request: [String: Any] = [
            "id": commandID,
            "action": action,
        ]
        let data = try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
        try data.write(to: URL(fileURLWithPath: commandPath), options: .atomic)

        var result: [String: Any]?
        let matched = waitForCondition(timeout: timeout) {
            guard let payload = self.loadSetupData(),
                  payload["lastCommandId"] as? String == commandID else {
                return false
            }
            result = payload
            return true
        }

        guard matched, let result else {
            throw NSError(domain: "TerminalCmdClickUITests", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "Expected command result for \(action). payload=\(loadSetupData() ?? [:])"
            ])
        }
        return result
    }

    private func loadSetupData() -> [String: Any]? {
        guard let data = try? Data(contentsOf: URL(fileURLWithPath: setupDataPath)),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    private func launchAndEnsureForeground(_ app: XCUIApplication, timeout: TimeInterval = 12.0) {
        let options = XCTExpectedFailure.Options()
        options.isStrict = false
        XCTExpectFailure("App activation may fail on headless GUI runners", options: options) {
            app.launch()
        }

        guard app.state == .runningForeground || app.state == .runningBackground else {
            XCTFail("App failed to start. state=\(app.state.rawValue)")
            return
        }

        app.activate()
        let foregrounded = waitForCondition(timeout: timeout) {
            app.state == .runningForeground || app.windows.firstMatch.exists
        }
        XCTAssertTrue(
            foregrounded,
            "Expected app activation before driving cmd-key harness. state=\(app.state.rawValue)"
        )
    }

    private func waitForCondition(
        timeout: TimeInterval,
        pollInterval: TimeInterval = 0.05,
        predicate: @escaping () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() {
                return true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(pollInterval))
        }
        return predicate()
    }
}
