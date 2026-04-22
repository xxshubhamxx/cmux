import XCTest

#if canImport(cmux_DEV)
@testable import cmux_DEV
#elseif canImport(cmux)
@testable import cmux
#endif

final class CodexAppServerRequestFactoryTests: XCTestCase {
    func testInitializeRequestUsesCodexAppServerHandshakeShape() throws {
        let request = CodexAppServerRequestFactory.initializeRequest(id: 42)

        XCTAssertEqual(request["id"] as? Int, 42)
        XCTAssertEqual(request["method"] as? String, "initialize")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        let clientInfo = try XCTUnwrap(params["clientInfo"] as? [String: Any])
        XCTAssertEqual(clientInfo["name"] as? String, "cmux")
        XCTAssertEqual(clientInfo["title"] as? String, "cmux")
        XCTAssertNotNil(clientInfo["version"] as? String)

        let capabilities = try XCTUnwrap(params["capabilities"] as? [String: Any])
        XCTAssertEqual(capabilities["experimentalApi"] as? Bool, true)
    }

    func testInitializedNotificationHasNoRequestId() {
        let notification = CodexAppServerRequestFactory.initializedNotification()

        XCTAssertNil(notification["id"])
        XCTAssertEqual(notification["method"] as? String, "initialized")
    }

    func testThreadStartRequestCarriesCwdAndEphemeralSession() throws {
        let request = CodexAppServerRequestFactory.threadStartRequest(
            id: 7,
            cwd: "/Users/cmux/project"
        )

        XCTAssertEqual(request["id"] as? Int, 7)
        XCTAssertEqual(request["method"] as? String, "thread/start")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["cwd"] as? String, "/Users/cmux/project")
        XCTAssertEqual(params["serviceName"] as? String, "cmux")
        XCTAssertEqual(params["ephemeral"] as? Bool, true)
    }

    func testTurnStartRequestUsesTextInputItemShape() throws {
        let request = CodexAppServerRequestFactory.turnStartRequest(
            id: 9,
            threadId: "thr_123",
            text: "Summarize this repo",
            cwd: "/Users/cmux/project"
        )

        XCTAssertEqual(request["id"] as? Int, 9)
        XCTAssertEqual(request["method"] as? String, "turn/start")

        let params = try XCTUnwrap(request["params"] as? [String: Any])
        XCTAssertEqual(params["threadId"] as? String, "thr_123")
        XCTAssertEqual(params["cwd"] as? String, "/Users/cmux/project")

        let input = try XCTUnwrap(params["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 1)
        XCTAssertEqual(input[0]["type"] as? String, "text")
        XCTAssertEqual(input[0]["text"] as? String, "Summarize this repo")
        XCTAssertNotNil(input[0]["textElements"] as? [Any])
    }

    func testResponseObjectUsesJsonRpcResponseShapeWithoutMethod() throws {
        let response = CodexAppServerRequestFactory.response(
            id: 12,
            result: ["decision": "accept"]
        )

        XCTAssertEqual(response["id"] as? Int, 12)
        XCTAssertNil(response["method"])
        let result = try XCTUnwrap(response["result"] as? [String: Any])
        XCTAssertEqual(result["decision"] as? String, "accept")
    }

    func testErrorResponseCarriesMessage() throws {
        let response = CodexAppServerRequestFactory.errorResponse(
            id: 13,
            message: "unsupported"
        )

        XCTAssertEqual(response["id"] as? Int, 13)
        let error = try XCTUnwrap(response["error"] as? [String: Any])
        XCTAssertEqual(error["message"] as? String, "unsupported")
        XCTAssertNotNil(error["code"] as? Int)
    }

    func testAppServerEnvironmentIncludesNodeVersionManagerPaths() throws {
        let tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmux-codex-app-server-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: tempDirectory) }

        let nvmNodeBin = tempDirectory
            .appendingPathComponent(".nvm/versions/node/v25.8.1/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: nvmNodeBin, withIntermediateDirectories: true)

        let environment = CodexAppServerClient.appServerEnvironment(
            baseEnvironment: [
                "HOME": tempDirectory.path,
                "PATH": "/usr/bin:/bin",
            ]
        )

        let pathComponents = try XCTUnwrap(environment["PATH"]).split(separator: ":").map(String.init)
        XCTAssertTrue(pathComponents.contains(nvmNodeBin.path))
    }

    func testLaunchConfigurationRunsNodeBackedCodexScriptWithResolvedNode() throws {
        let fileManager = FileManager.default
        let tempDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("cmux-codex-launch-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: tempDirectory) }

        let codexBin = tempDirectory.appendingPathComponent("codex-bin", isDirectory: true)
        let nodeBin = tempDirectory.appendingPathComponent(".nvm/versions/node/v25.8.1/bin", isDirectory: true)
        try fileManager.createDirectory(at: codexBin, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: nodeBin, withIntermediateDirectories: true)

        let codexPath = codexBin.appendingPathComponent("codex")
        let nodePath = nodeBin.appendingPathComponent("node")
        try "#!/usr/bin/env node\n".write(to: codexPath, atomically: true, encoding: .utf8)
        try "#!/bin/sh\n".write(to: nodePath, atomically: true, encoding: .utf8)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: codexPath.path)
        try fileManager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: nodePath.path)

        let configuration = CodexAppServerClient.appServerLaunchConfiguration(
            baseEnvironment: [
                "HOME": tempDirectory.path,
                "PATH": codexBin.path,
            ]
        )

        XCTAssertEqual(configuration.executablePath, nodePath.path)
        XCTAssertEqual(configuration.arguments, [
            codexPath.path,
            "app-server",
            "--listen",
            "stdio://",
        ])
    }
}
