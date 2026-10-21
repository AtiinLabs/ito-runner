import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

/// A net module whose requests hang until they are cancelled, reporting when a request starts and
/// when it is cancelled.
private final class HangingNetModule: NetModule, @unchecked Sendable {
    private let started = AsyncStream<Void>.makeStream()
    private let cancelled = AsyncStream<Void>.makeStream()

    func fetch(request: NetRequest) async throws -> NetResponse {
        started.continuation.yield()
        do {
            try await Task.sleep(nanoseconds: 3_600_000_000_000)
        } catch {
            cancelled.continuation.yield()
            throw error
        }
        return NetResponse(status: 200, headers: [:], body: [])
    }

    func requestStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }

    func requestCancelled() async {
        var iterator = cancelled.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

// A broken call would leave these tests awaiting a request that never ends; fail instead.
@Suite("Plugin call cancellation and deadlines", .timeLimit(.minutes(1)))
struct CallCancellationTests {
    /// `get_home` makes one network request (GET http://x) and returns 0; `get_manga_list` counts
    /// how often it ran.
    private static let pluginWAT = """
        (module
            (import "ito:core/net" "fetch" (func $fetch (param i32 i32) (result i32)))
            (memory (export "memory") 1)
            (data (i32.const 64) "\\08http://x\\03GET\\00\\00")
            (global $next (mut i32) (i32.const 1024))
            (global $listCalls (mut i32) (i32.const 0))
            (func (export "alloc") (param $size i32) (result i32)
                (local $pointer i32)
                global.get $next
                local.set $pointer
                global.get $next
                local.get $size
                i32.add
                global.set $next
                local.get $pointer)
            (func (export "dealloc") (param i32 i32))
            (func (export "list_calls") (result i32)
                global.get $listCalls)
            (func (export "get_home") (result i64)
                i32.const 64
                i32.const 15
                call $fetch
                drop
                i64.const 0)
            (func (export "get_manga_list") (param i32 i32 i32) (result i64)
                global.get $listCalls
                i32.const 1
                i32.add
                global.set $listCalls
                i64.const 0)
        )
        """

    private func loadRunner(net: HangingNetModule, timeouts: HostCallTimeouts = HostCallTimeouts()) async throws
        -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(net)
        await runner.setHostCallTimeouts(timeouts)
        try await runner.loadPlugin(fromBytes: try wat2wasm(Self.pluginWAT))
        return runner
    }

    @Test func cancellingACallStopsWaitingOnItsRequest() async throws {
        let net = HangingNetModule()
        let runner = try await loadRunner(net: net)

        let call = Task { try await runner.getHome() }
        await net.requestStarted()
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        await net.requestCancelled()
    }

    @Test func aRequestPastTheDeadlineReachesThePluginAsAFailedResponse() async throws {
        let net = HangingNetModule()
        let runner = try await loadRunner(net: net, timeouts: HostCallTimeouts(net: 0.05, webview: 0.05))

        // The plugin gets a 500 response, fails, and the call reports that failure.
        await #expect(throws: ItoError.pluginFailed(function: "get_home", reason: nil)) {
            try await runner.getHome()
        }
        await net.requestCancelled()
    }

    @Test func aCallCancelledBeforeItStartsNeverRuns() async throws {
        let net = HangingNetModule()
        let runner = try await loadRunner(net: net)
        let listing = Listing(id: "all", name: "All", kind: 0)

        let first = Task { try await runner.getHome() }
        await net.requestStarted()
        let second = Task { try await runner.getMangaList(listing: listing, page: 1) }
        second.cancel()
        first.cancel()

        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        guard case .i32(let listCalls) = try await runner.executeExport("list_calls").first else {
            Issue.record("list_calls returned no i32")
            return
        }
        #expect(listCalls == 0)
    }
}

/// A web view module whose loads hang until they are cancelled, reporting when one starts.
private final class HangingWebviewModule: WebviewModule, @unchecked Sendable {
    private let started = AsyncStream<Void>.makeStream()

    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        started.continuation.yield()
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return WebviewResponse(url: request.url, html: "")
    }

    func executeJs(script: String) async throws -> String { "" }

    func loadStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

/// Runs blocking bridge work on a dispatch queue, as the runner does, off the cooperative pool.
private func onRunnerQueue<T: Sendable>(_ work: @escaping @Sendable () throws -> T) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
        DispatchQueue.global().async { continuation.resume(with: Result { try work() }) }
    }
}

@Suite("Host work a plugin call waits on", .timeLimit(.minutes(1)))
struct HostWorkWaitTests {
    private let request = NetRequest(url: "http://x", method: "GET", headers: [:], body: nil)

    @Test func aRequestPastTheDeadlineReachesThePluginAsA500() async throws {
        let net = HangingNetModule()
        // Configured before it reaches the queue, then used only there, as in the runner.
        nonisolated(unsafe) let bridge = WasmBridge(runner: ItoRunner())
        bridge.netModule = net
        bridge.timeouts = HostCallTimeouts(net: 0.05, webview: 0.05)

        let response = try await onRunnerQueue { [request] in
            bridge.fetchForPlugin(request, options: nil, label: "net_fetch")
        }

        #expect(response.status == 500)
        #expect(String(decoding: response.body, as: UTF8.self) == "FFI Error in net_fetch: The request timed out.")
        #expect(response.headers[WasmBridge.transportErrorHeader] == "The request timed out.")
        await net.requestCancelled()
    }

    @Test func aCancelledCallsRequestReachesThePluginAsA500() async throws {
        let net = HangingNetModule()
        // Configured before it reaches the queue, then used only there, as in the runner.
        nonisolated(unsafe) let bridge = WasmBridge(runner: ItoRunner())
        bridge.netModule = net
        let token = CallToken()
        bridge.activeCallToken = token

        let response = Task { [request] in
            try await onRunnerQueue { bridge.fetchForPlugin(request, options: nil, label: "net_fetch_v2") }
        }
        await net.requestStarted()
        token.cancel()

        let body = String(decoding: try await response.value.body, as: UTF8.self)
        #expect(body == "FFI Error in net_fetch_v2: The request was cancelled.")
        await net.requestCancelled()
    }

    @Test func aCancelledWebviewLoadGivesThePluginNoResult() async throws {
        let webview = HangingWebviewModule()
        // Configured before it reaches the queue, then used only there, as in the runner.
        nonisolated(unsafe) let bridge = WasmBridge(runner: ItoRunner())
        bridge.webviewModule = webview
        let token = CallToken()
        bridge.activeCallToken = token

        let result = Task {
            try await onRunnerQueue {
                try bridge.webviewForPlugin { try await $0.loadUrl(request: WebviewRequest(url: "http://x", script: nil)) }
            }
        }
        await webview.loadStarted()
        token.cancel()

        #expect(try await result.value == nil)
    }

    @Test func aWebviewLoadPastTheDeadlineThrows() async throws {
        // Configured before it reaches the queue, then used only there, as in the runner.
        nonisolated(unsafe) let bridge = WasmBridge(runner: ItoRunner())
        bridge.webviewModule = HangingWebviewModule()
        bridge.timeouts = HostCallTimeouts(net: 0.05, webview: 0.05)

        await #expect(throws: ItoError.hostModuleError(domain: "webview", message: "The page took too long to respond.")) {
            try await onRunnerQueue {
                try bridge.webviewForPlugin { try await $0.loadUrl(request: WebviewRequest(url: "http://x", script: nil)) }
            }
        }
    }
}
