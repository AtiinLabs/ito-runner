import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

/// Script results come from `scripts`, in order; with none left, the script hangs until cancelled.
private final class ScriptedWebviewModule: WebviewModule, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [String]
    private let started = AsyncStream<Void>.makeStream()

    init(results: [String]) {
        scripts = results
    }

    func loadUrl(request: WebviewRequest) async throws -> WebviewResponse {
        throw ItoError.hostModuleError(domain: "webview", message: "unused")
    }

    func executeJs(script: String) async throws -> String {
        let next = lock.withLock { scripts.isEmpty ? nil : scripts.removeFirst() }
        if let next { return next }
        started.continuation.yield()
        try await Task.sleep(nanoseconds: 3_600_000_000_000)
        return "late"
    }

    func scriptStarted() async {
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
    }
}

@Suite("Web view script results", .timeLimit(.minutes(1)))
struct WebviewResultTests {
    /// `run_js` returns the length `webview_execute_js` reports; `get_home` stores it for `last`.
    private static let wat = """
        (module
            (import "ito:core/webview" "webview_execute_js" (func $js (param i32 i32) (result i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "go()")
            (global $last (mut i32) (i32.const 7))
            (func (export "alloc") (param i32) (result i32) (i32.const 1024))
            (func (export "dealloc") (param i32 i32))
            (func (export "run_js") (result i32) (call $js (i32.const 16) (i32.const 4)))
            (func (export "get_home") (result i64)
                (global.set $last (call $js (i32.const 16) (i32.const 4)))
                (i64.const 0))
            (func (export "last") (result i32) (global.get $last))
        )
        """

    private func loadRunner(_ webview: ScriptedWebviewModule) async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setWebviewModule(webview)
        try await runner.loadPlugin(fromBytes: try wat2wasm(Self.wat))
        return runner
    }

    private func length(_ runner: ItoRunner, _ export: String) async throws -> Int32 {
        guard case .i32(let raw) = try await runner.executeExport(export).first else {
            Issue.record("\(export) returned no i32")
            return .min
        }
        return Int32(bitPattern: raw)
    }

    @Test func anEmptyScriptResultIsALengthOfZeroNotAFailure() async throws {
        let runner = try await loadRunner(ScriptedWebviewModule(results: ["", "42"]))

        #expect(try await length(runner, "run_js") == 0)
        #expect(try await length(runner, "run_js") == 2)
    }

    @Test func aCancelledScriptGivesThePluginANegativeLength() async throws {
        let webview = ScriptedWebviewModule(results: [])
        let runner = try await loadRunner(webview)

        let call = Task { try await runner.getHome() }
        await webview.scriptStarted()
        call.cancel()

        await #expect(throws: CancellationError.self) { try await call.value }
        #expect(try await length(runner, "last") < 0)
    }
}
