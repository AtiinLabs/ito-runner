import Foundation
import Testing
import WAT
import WasmKit
@testable import ito_runner

private final class ControlsWaitingNet: NetModule, Sendable {
    private let started = AsyncStream<Void>.makeStream()
    func fetch(request: NetRequest) async throws -> NetResponse {
        let wait = AsyncStream<Void>.makeStream()
        started.continuation.yield()
        // AsyncStream terminates its suspended iterator on cancellation; no timing-based gate.
        for await _ in wait.stream {}
        throw CancellationError()
    }
    func nextRequest() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Suite("Rich controls cancellation", .timeLimit(.minutes(1)))
struct ControlsCancellationTests {
    private func runner(_ net: ControlsWaitingNet) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setNetModule(net)
        try await runner.loadPlugin(fromBytes: wat2wasm("""
            (module
                (import "ito:core/net" "fetch" (func $fetch (param i32 i32) (result i32)))
                (memory (export "memory") 1)
                (func (export "ito_abi_version") (result i32) i32.const 2)
                (func (export "ito_supported_kinds") (result i32) i32.const 1)
                (data (i32.const 64) "\\08http://x\\03GET\\00\\00")
                (data (i32.const 128) "\\00\\00\\00")
                (data (i32.const 256) "\\00\\00\\00\\00")
                (global $pages (mut i32) (i32.const 0))
                (global $caps (mut i32) (i32.const 0))
                (func (export "alloc") (param i32) (result i32) i32.const 1024)
                (func (export "dealloc") (param i32 i32))
                (func $wait i32.const 64 i32.const 15 call $fetch drop)
                (func (export "get_home") (result i64) call $wait i64.const 0)
                (func (export "get_search_capabilities") (param i32) (result i64)
                    global.get $caps i32.const 1 i32.add global.set $caps
                    call $wait i64.const 549755813891)
                (func (export "get_option_page") (param i32 i32) (result i64)
                    global.get $pages i32.const 1 i32.add global.set $pages
                    call $wait i64.const 1099511627780)
                (func (export "page_calls") (result i32) global.get $pages)
                (func (export "cap_calls") (result i32) global.get $caps)
            )
            """))
        return runner
    }
    @Test func cancelledBeforeStartNeverCallsOptionExport() async throws {
        let net = ControlsWaitingNet(), request = OptionRequest(catalog: "tags", query: .search(text: "", offset: 0), limit: 50)
        let runner = try await runner(net)
        let first = Task { try await runner.getHome() }
        await net.nextRequest()
        let second = Task { try await runner.getOptionPage(request) }
        second.cancel()
        first.cancel()
        await #expect(throws: CancellationError.self) { try await first.value }
        await #expect(throws: CancellationError.self) { try await second.value }
        #expect(try await runner.executeExport("page_calls") == [.i32(0)])
    }
    @Test func cancelledDuringOptionHostWorkNeverReturnsLateSuccess() async throws {
        let net = ControlsWaitingNet(), request = OptionRequest(catalog: "tags", query: .search(text: "", offset: 0), limit: 50)
        let runner = try await runner(net)
        let call = Task { try await runner.getOptionPage(request) }
        await net.nextRequest()
        call.cancel()
        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(try await runner.executeExport("page_calls") == [.i32(1)])
    }
    @Test func cancelledCapabilitiesAreNeverCached() async throws {
        let net = ControlsWaitingNet()
        let runner = try await runner(net)
        for _ in 0..<2 {
            let call = Task { try await runner.getSearchCapabilities(kind: .manga) }
            await net.nextRequest()
            call.cancel()
            await #expect(throws: CancellationError.self) { try await call.value }
        }
        #expect(try await runner.executeExport("cap_calls") == [.i32(2)])
    }
}
