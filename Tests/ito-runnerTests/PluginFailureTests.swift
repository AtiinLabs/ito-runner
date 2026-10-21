import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

@Suite("Plugin failures")
struct PluginFailureTests {
    private static let homeFailure = "Error in get_home: Host error: Add your server URL"
    private static let imageFailure = "Error in handle_image: Host error: Refused path"

    /// A plugin shaped like the SDK's exports: failures print "Error in <export>: <reason>" and
    /// return 0; "nothing" (no settings, unsupported image or URL) returns 0 without printing.
    private static let pluginWAT = """
        (module
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            (data (i32.const 16) "\(homeFailure)")
            (data (i32.const 256) "\(imageFailure)")
            (data (i32.const 512) "\\00\\00")
            (global $next (mut i32) (i32.const 1024))
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
            (func (export "get_home") (result i64)
                i32.const 16
                i32.const \(homeFailure.utf8.count)
                call $print
                i64.const 0)
            (func (export "get_manga_list") (param i32 i32 i32) (result i64)
                i64.const 0)
            (func (export "get_search_manga_list") (param i32 i32 i32 i32 i32) (result i64)
                ;; (512 << 32) | 2: an empty PageResult (no entries, no next page)
                i64.const 2199023255554)
            (func (export "get_settings") (result i64)
                i64.const 0)
            (func (export "handle_url") (param i32 i32) (result i64)
                i64.const 0)
            (func (export "handle_image") (param i32 i32) (result i64)
                i32.const 256
                i32.const \(imageFailure.utf8.count)
                call $print
                i64.const 0)
        )
        """

    private func loadRunner(withStd: Bool = true) async throws -> ItoRunner {
        let runner = ItoRunner()
        if withStd {
            await runner.setStdModule(DefaultStdModule())
        }
        try await runner.loadPlugin(fromBytes: try wat2wasm(Self.pluginWAT))
        return runner
    }

    @Test func aFailedExportReportsThePluginsReason() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(function: "get_home", reason: "Host error: Add your server URL")) {
            try await runner.getHome()
        }
    }

    @Test func aFailureWithoutAReasonIsStillAFailure() async throws {
        let runner = try await loadRunner()
        let listing = Listing(id: "all", name: "All", kind: 0)

        await #expect(throws: ItoError.pluginFailed(function: "get_manga_list", reason: nil)) {
            try await runner.getMangaList(listing: listing, page: 1)
        }
    }

    @Test func aReasonDoesNotLeakIntoTheNextCall() async throws {
        let runner = try await loadRunner()
        _ = try? await runner.getHome()

        await #expect(throws: ItoError.pluginFailed(function: "get_manga_list", reason: nil)) {
            try await runner.getMangaList(listing: Listing(id: "all", name: "All", kind: 0), page: 1)
        }
    }

    @Test func nothingToReturnIsNotAFailure() async throws {
        let runner = try await loadRunner()

        #expect(try await runner.getSettings() == nil)
        #expect(try await runner.handleUrl("https://example.com") == nil)
    }

    @Test func aRefusedImageIsAFailureNotAFallback() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(function: "handle_image", reason: "Host error: Refused path")) {
            try await runner.handleImage("../../etc")
        }
    }

    @Test func aSuccessfulExportDecodesItsResult() async throws {
        let runner = try await loadRunner()

        let result = try await runner.getSearchMangaList(query: "query", page: 1, filters: nil)

        #expect(result.entries.isEmpty)
        #expect(result.hasNextPage == false)
    }

    @Test func hostModuleErrorsReachTheCallerTyped() async throws {
        let runner = try await loadRunner(withStd: false)

        await #expect(throws: ItoError.hostModuleError(domain: "std", message: "StdModule not provided")) {
            try await runner.getHome()
        }
    }
}

@Suite("Postcard values out of range")
struct PostcardRangeTests {
    private struct Int32Holder: Decodable { let value: Int32 }
    private struct UInt16Holder: Decodable { let value: UInt16 }

    @Test func anInt32OutOfRangeThrowsInsteadOfTrapping() {
        // zig-zag 2^31, one past Int32.max
        #expect(throws: ItoError.self) {
            try ItoPostcardDecoder().decode(Int32Holder.self, from: [0x80, 0x80, 0x80, 0x80, 0x10])
        }
    }

    @Test func aUInt16OutOfRangeThrowsInsteadOfTrapping() {
        // 70_000
        #expect(throws: ItoError.self) {
            try ItoPostcardDecoder().decode(UInt16Holder.self, from: [0xF0, 0xA2, 0x04])
        }
    }

    @Test func aSequenceLengthBeyondIntThrowsInsteadOfTrapping() {
        // UInt64.max as a varint
        let length: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]
        #expect(throws: ItoError.self) {
            try ItoPostcardDecoder().decode([String].self, from: length)
        }
    }
}
