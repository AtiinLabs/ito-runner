import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

@Suite("Plugin error categories")
struct PluginErrorCategoryTests {
    /// A plugin with an `ito_last_error` export like the SDK's: a failing export leaves a postcard
    /// `{category, message}` for it to hand over once, then returns 0.
    private static let pluginWAT = """
        (module
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "Error in get_home: Add your server URL")
            (data (i32.const 128) "Error in get_manga_list: Plain reason")
            ;; {category: needsSetup (zigzag 0), message: "Add your server URL"}
            (data (i32.const 2048) "\\00\\13Add your server URL")
            ;; {category: other (zigzag 10), message: "Unsupported operation"}
            (data (i32.const 2100) "\\0a\\15Unsupported operation")
            ;; {category: needsLogin (zigzag 14), message: "Sign in!"}
            (data (i32.const 2200) "\\0e\\08Sign in!")
            (global $next (mut i32) (i32.const 4096))
            (global $deallocs (mut i32) (i32.const 0))
            (global $lastError (mut i64) (i64.const 0))
            (func (export "alloc") (param $size i32) (result i32)
                (local $pointer i32)
                global.get $next
                local.set $pointer
                global.get $next
                local.get $size
                i32.add
                global.set $next
                local.get $pointer)
            (func (export "dealloc") (param i32 i32)
                global.get $deallocs
                i32.const 1
                i32.add
                global.set $deallocs)
            (func (export "dealloc_count") (result i32)
                global.get $deallocs)
            (func (export "ito_last_error") (result i64)
                (local $packed i64)
                global.get $lastError
                local.set $packed
                i64.const 0
                global.set $lastError
                local.get $packed)
            (func (export "get_home") (result i64)
                ;; (2048 << 32) | 21
                i64.const 8796093022229
                global.set $lastError
                i32.const 16
                i32.const 38
                call $print
                i64.const 0)
            (func (export "handle_image") (param i32 i32) (result i64)
                ;; (2100 << 32) | 23
                i64.const 9019431321623
                global.set $lastError
                i64.const 0)
            (func (export "get_manga_list") (param i32 i32 i32) (result i64)
                i32.const 128
                i32.const 37
                call $print
                i64.const 0)
            (func (export "get_anime_list") (param i32 i32 i32) (result i64)
                ;; (2200 << 32) | 10
                i64.const 9448928051210
                global.set $lastError
                i64.const 0)
        )
        """

    private func loadRunner() async throws -> ItoRunner {
        let runner = ItoRunner()
        await runner.setStdModule(DefaultStdModule())
        try await runner.loadPlugin(fromBytes: try wat2wasm(Self.pluginWAT))
        return runner
    }

    private func deallocations(_ runner: ItoRunner) async throws -> UInt32 {
        guard case .i32(let count)? = try await runner.executeExport("dealloc_count").first else {
            Issue.record("dealloc_count returned no i32")
            return 0
        }
        return count
    }

    @Test func aTypedFailureArrivesWithItsCategoryAndItsBufferIsFreed() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(
            function: "get_home", reason: "Add your server URL", category: .needsSetup
        )) {
            try await runner.getHome()
        }
        #expect(try await deallocations(runner) == 1)
    }

    @Test func aTypedUnsupportedFromAnOptionalExportMeansNotHandled() async throws {
        let runner = try await loadRunner()
        #expect(try await runner.handleImage("https://example.com/a.png") == nil)
    }

    @Test func withoutATypedFailureThePrintedReasonIsUsed() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(
            function: "get_manga_list", reason: "Plain reason", category: .other
        )) {
            try await runner.getMangaList(listing: Listing(id: "all", name: "All", kind: 0), page: 1)
        }
    }

    @Test func aSignInRequestArrivesAsNeedsLogin() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(
            function: "get_anime_list", reason: "Sign in!", category: .needsLogin
        )) {
            try await runner.getAnimeList(listing: Listing(id: "all", name: "All", kind: 0), page: 1)
        }
    }

    @Test func reportsDecodeFromTheBytesTheSDKWrites() throws {
        // ito-rs encodes ErrorCategory as a zigzag i32 (NeedsSetup0 … NeedsLogin7), then the message.
        let categories: [PluginErrorCategory] = [
            .needsSetup, .unauthorized, .network, .server, .notFound, .other, .unsupported, .needsLogin
        ]
        for (index, category) in categories.enumerated() {
            let payload = try ItoPostcardDecoder().decode(PluginErrorPayload.self, from: [UInt8(index * 2), 1, 0x78])
            #expect(payload.category == category)
            #expect(payload.message == "x")
        }
    }
}
