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
