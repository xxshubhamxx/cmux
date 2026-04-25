// Generated from Mojo/OwlFresh.mojom by OwlMojoBindingsGenerator.
// Do not edit by hand.
import Foundation

public struct MojoPendingRemote<Interface>: Equatable, Codable {
    public let handle: UInt64

    public init(handle: UInt64) {
        self.handle = handle
    }
}

public struct OwlFreshMojoTransportCall: Equatable, Codable {
    public let interface: String
    public let method: String
    public let payloadType: String
    public let payloadSummary: String

    public init(interface: String, method: String, payloadType: String, payloadSummary: String) {
        self.interface = interface
        self.method = method
        self.payloadType = payloadType
        self.payloadSummary = payloadSummary
    }
}

public enum OwlFreshGeneratedMojoTransport {
    public static let name = "GeneratedOwlFreshMojoTransport"
}

public enum OwlFreshMouseKind: UInt32, Codable, CaseIterable {
    case down = 0
    case up = 1
    case move = 2
    case wheel = 3
}

public struct OwlFreshMouseEvent: Equatable, Codable {
    public let kind: OwlFreshMouseKind
    public let x: Float
    public let y: Float
    public let button: UInt32
    public let clickCount: UInt32
    public let deltaX: Float
    public let deltaY: Float
    public let modifiers: UInt32

    public init(kind: OwlFreshMouseKind, x: Float, y: Float, button: UInt32, clickCount: UInt32, deltaX: Float, deltaY: Float, modifiers: UInt32) {
        self.kind = kind
        self.x = x
        self.y = y
        self.button = button
        self.clickCount = clickCount
        self.deltaX = deltaX
        self.deltaY = deltaY
        self.modifiers = modifiers
    }
}

public struct OwlFreshKeyEvent: Equatable, Codable {
    public let keyDown: Bool
    public let keyCode: UInt32
    public let text: String
    public let modifiers: UInt32

    public init(keyDown: Bool, keyCode: UInt32, text: String, modifiers: UInt32) {
        self.keyDown = keyDown
        self.keyCode = keyCode
        self.text = text
        self.modifiers = modifiers
    }
}

public struct OwlFreshCompositorInfo: Equatable, Codable {
    public let contextId: UInt32

    public init(contextId: UInt32) {
        self.contextId = contextId
    }
}

public struct OwlFreshCaptureResult: Equatable, Codable {
    public let png: [UInt8]
    public let width: UInt32
    public let height: UInt32
    public let captureMode: String
    public let error: String

    public init(png: [UInt8], width: UInt32, height: UInt32, captureMode: String, error: String) {
        self.png = png
        self.width = width
        self.height = height
        self.captureMode = captureMode
        self.error = error
    }
}

public enum OwlFreshClientMojoInterfaceMarker {}
public typealias OwlFreshClientRemote = MojoPendingRemote<OwlFreshClientMojoInterfaceMarker>

public protocol OwlFreshClientMojoInterface {
    func onReady(_ request: OwlFreshClientOnReadyRequest)
    func onCompositorChanged(_ compositor: OwlFreshCompositorInfo)
    func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest)
    func onHostLog(_ message: String)
}

public struct OwlFreshClientOnReadyRequest: Equatable, Codable {
    public let hostPid: Int32
    public let compositor: OwlFreshCompositorInfo

    public init(hostPid: Int32, compositor: OwlFreshCompositorInfo) {
        self.hostPid = hostPid
        self.compositor = compositor
    }
}

public struct OwlFreshClientOnNavigationChangedRequest: Equatable, Codable {
    public let url: String
    public let title: String
    public let loading: Bool

    public init(url: String, title: String, loading: Bool) {
        self.url = url
        self.title = title
        self.loading = loading
    }
}

public protocol OwlFreshClientMojoSink: AnyObject {
    func onReady(_ request: OwlFreshClientOnReadyRequest)
    func onCompositorChanged(_ compositor: OwlFreshCompositorInfo)
    func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest)
    func onHostLog(_ message: String)
}

public final class GeneratedOwlFreshClientMojoTransport: OwlFreshClientMojoInterface {
    public private(set) var recordedCalls: [OwlFreshMojoTransportCall] = []
    private let sink: OwlFreshClientMojoSink

    public init(sink: OwlFreshClientMojoSink) {
        self.sink = sink
    }

    public func resetRecordedCalls() {
        recordedCalls.removeAll()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recordedCalls.append(OwlFreshMojoTransportCall(
            interface: "OwlFreshClient",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        ))
    }

    public func onReady(_ request: OwlFreshClientOnReadyRequest) {
        record(method: "onReady", payloadType: "OwlFreshClientOnReadyRequest", payloadSummary: String(describing: request))
        sink.onReady(request)
    }

    public func onCompositorChanged(_ compositor: OwlFreshCompositorInfo) {
        record(method: "onCompositorChanged", payloadType: "OwlFreshCompositorInfo", payloadSummary: String(describing: compositor))
        sink.onCompositorChanged(compositor)
    }

    public func onNavigationChanged(_ request: OwlFreshClientOnNavigationChangedRequest) {
        record(method: "onNavigationChanged", payloadType: "OwlFreshClientOnNavigationChangedRequest", payloadSummary: String(describing: request))
        sink.onNavigationChanged(request)
    }

    public func onHostLog(_ message: String) {
        record(method: "onHostLog", payloadType: "String", payloadSummary: String(describing: message))
        sink.onHostLog(message)
    }
}

public enum OwlFreshHostMojoInterfaceMarker {}
public typealias OwlFreshHostRemote = MojoPendingRemote<OwlFreshHostMojoInterfaceMarker>

public protocol OwlFreshHostMojoInterface {
    func setClient(_ client: OwlFreshClientRemote)
    func navigate(_ url: String)
    func resize(_ request: OwlFreshHostResizeRequest)
    func setFocus(_ focused: Bool)
    func sendMouse(_ event: OwlFreshMouseEvent)
    func sendKey(_ event: OwlFreshKeyEvent)
    func flush() async throws -> Bool
    func captureSurface() async throws -> OwlFreshCaptureResult
}

public struct OwlFreshHostResizeRequest: Equatable, Codable {
    public let width: UInt32
    public let height: UInt32
    public let scale: Float

    public init(width: UInt32, height: UInt32, scale: Float) {
        self.width = width
        self.height = height
        self.scale = scale
    }
}

public protocol OwlFreshHostMojoSink: AnyObject {
    func setClient(_ client: OwlFreshClientRemote)
    func navigate(_ url: String)
    func resize(_ request: OwlFreshHostResizeRequest)
    func setFocus(_ focused: Bool)
    func sendMouse(_ event: OwlFreshMouseEvent)
    func sendKey(_ event: OwlFreshKeyEvent)
    func flush() async throws -> Bool
    func captureSurface() async throws -> OwlFreshCaptureResult
}

public final class GeneratedOwlFreshHostMojoTransport: OwlFreshHostMojoInterface {
    public private(set) var recordedCalls: [OwlFreshMojoTransportCall] = []
    private let sink: OwlFreshHostMojoSink

    public init(sink: OwlFreshHostMojoSink) {
        self.sink = sink
    }

    public func resetRecordedCalls() {
        recordedCalls.removeAll()
    }

    private func record(method: String, payloadType: String, payloadSummary: String) {
        recordedCalls.append(OwlFreshMojoTransportCall(
            interface: "OwlFreshHost",
            method: method,
            payloadType: payloadType,
            payloadSummary: payloadSummary
        ))
    }

    public func setClient(_ client: OwlFreshClientRemote) {
        record(method: "setClient", payloadType: "OwlFreshClientRemote", payloadSummary: String(describing: client))
        sink.setClient(client)
    }

    public func navigate(_ url: String) {
        record(method: "navigate", payloadType: "String", payloadSummary: String(describing: url))
        sink.navigate(url)
    }

    public func resize(_ request: OwlFreshHostResizeRequest) {
        record(method: "resize", payloadType: "OwlFreshHostResizeRequest", payloadSummary: String(describing: request))
        sink.resize(request)
    }

    public func setFocus(_ focused: Bool) {
        record(method: "setFocus", payloadType: "Bool", payloadSummary: String(describing: focused))
        sink.setFocus(focused)
    }

    public func sendMouse(_ event: OwlFreshMouseEvent) {
        record(method: "sendMouse", payloadType: "OwlFreshMouseEvent", payloadSummary: String(describing: event))
        sink.sendMouse(event)
    }

    public func sendKey(_ event: OwlFreshKeyEvent) {
        record(method: "sendKey", payloadType: "OwlFreshKeyEvent", payloadSummary: String(describing: event))
        sink.sendKey(event)
    }

    public func flush() async throws -> Bool {
        record(method: "flush", payloadType: "Void", payloadSummary: "")
        return try await sink.flush()
    }

    public func captureSurface() async throws -> OwlFreshCaptureResult {
        record(method: "captureSurface", payloadType: "Void", payloadSummary: "")
        return try await sink.captureSurface()
    }
}

public struct MojoSchemaDeclaration: Equatable, Codable {
    public let kind: String
    public let name: String
}

public enum OwlFreshMojoSchema {
    public static let module = "content.mojom"
    public static let sourceChecksum = "fnv1a64:f1267ac781dd95f0"
    public static let declarations: [MojoSchemaDeclaration] = [
        MojoSchemaDeclaration(kind: "enum", name: "OwlFreshMouseKind"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshMouseEvent"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshKeyEvent"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshCompositorInfo"),
        MojoSchemaDeclaration(kind: "struct", name: "OwlFreshCaptureResult"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshClient"),
        MojoSchemaDeclaration(kind: "interface", name: "OwlFreshHost")
    ]
}
