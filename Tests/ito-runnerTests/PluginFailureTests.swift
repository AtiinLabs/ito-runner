import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

@Suite("Plugin failures")
struct PluginFailureTests {
    /// Lines the plugin prints, placed in its memory at these offsets.
    private static let lines: [(offset: Int, text: String)] = [
        (16, "Error in get_home: Host error: Add your server URL"),
        (128, "Error in handle_image: Host error: Refused path"),
        (256, "Error in handle_url: Unsupported operation"),
        (384, "Error in parse: no title on the page"),
        (512, "Deserialization error: unexpected end of input")
    ]

    private static func printCall(_ index: Int) -> String {
        "i32.const \(lines[index].offset)\ni32.const \(lines[index].text.utf8.count)\ncall $print"
    }

    /// A plugin shaped like the SDK's exports: failures print "Error in <export>: <reason>" (or a
    /// decoding error) and return 0; "nothing" returns 0, possibly after the plugin's own logging.
    private static let pluginWAT = """
        (module
            (import "ito:core/std" "print" (func $print (param i32 i32)))
            (memory (export "memory") 1)
            \(lines.map { "(data (i32.const \($0.offset)) \"\($0.text)\")" }.joined(separator: "\n"))
            (data (i32.const 900) "\\00\\00")
            (global $next (mut i32) (i32.const 1024))
            (global $deallocs (mut i32) (i32.const 0))
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
            (func (export "get_home") (result i64)
                \(printCall(0))
                i64.const 0)
            (func (export "get_manga_list") (param i32 i32 i32) (result i64)
                i64.const 0)
            (func (export "get_search_manga_list") (param i32 i32 i32 i32 i32) (result i64)
                ;; (900 << 32) | 2: an empty PageResult (no entries, no next page)
                i64.const 3865470566402)
            (func (export "get_page_list") (param i32 i32 i32 i32) (result i64)
                \(printCall(4))
                i64.const 0)
            (func (export "get_settings") (result i64)
                \(printCall(3))
                i64.const 0)
            (func (export "handle_url") (param i32 i32) (result i64)
                \(printCall(2))
                i64.const 0)
            (func (export "handle_image") (param i32 i32) (result i64)
                \(printCall(1))
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

    private func deallocCount(_ runner: ItoRunner) async throws -> UInt32 {
        guard case .i32(let count) = try await runner.executeExport("dealloc_count").first else {
            Issue.record("dealloc_count returned no i32")
            return 0
        }
        return count
    }

    @Test func aFailedExportReportsThePluginsReason() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(function: "get_home", reason: "Host error: Add your server URL")) {
            try await runner.getHome()
        }
    }

    @Test func aFailureWithoutAReasonIsStillAFailure() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(function: "get_manga_list", reason: nil)) {
            try await runner.getMangaList(listing: Listing(id: "all", name: "All", kind: 0), page: 1)
        }
    }

    @Test func aReasonDoesNotLeakIntoTheNextCall() async throws {
        let runner = try await loadRunner()
        _ = try? await runner.getHome()

        await #expect(throws: ItoError.pluginFailed(function: "get_manga_list", reason: nil)) {
            try await runner.getMangaList(listing: Listing(id: "all", name: "All", kind: 0), page: 1)
        }
    }

    @Test func aPluginThatCannotReadItsArgumentsSaysSo() async throws {
        let runner = try await loadRunner()
        let manga = Manga(key: "1", title: "One")
        let chapter = Manga.Chapter(key: "c1")

        await #expect(
            throws: ItoError.pluginFailed(
                function: "get_page_list", reason: "Deserialization error: unexpected end of input")
        ) {
            try await runner.getPageList(manga: manga, chapter: chapter)
        }
    }

    @Test func thePluginsOwnLoggingIsNotAFailure() async throws {
        let runner = try await loadRunner()

        #expect(try await runner.getSettings() == nil)
    }

    @Test func anUnsupportedOptionalExportMeansNotHandled() async throws {
        let runner = try await loadRunner()

        #expect(try await runner.handleUrl("https://example.com") == nil)
    }

    @Test func aRefusedImageIsAFailureNotAFallback() async throws {
        let runner = try await loadRunner()

        await #expect(throws: ItoError.pluginFailed(function: "handle_image", reason: "Host error: Refused path")) {
            try await runner.handleImage("../../etc")
        }
    }

    @Test func aSuccessfulExportDecodesItsResultAndFreesEveryBuffer() async throws {
        let runner = try await loadRunner()

        let result = try await runner.getSearchMangaList(query: "query", page: 1, filters: nil)

        #expect(result.entries.isEmpty)
        #expect(result.hasNextPage == false)
        // The query, the encoded filters and the response.
        #expect(try await deallocCount(runner) == 3)
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
        #expect(throws: ItoError.postcardDecodingError("Value 2147483648 does not fit in Int32.")) {
            try ItoPostcardDecoder().decode(Int32Holder.self, from: [0x80, 0x80, 0x80, 0x80, 0x10])
        }
    }

    @Test func aUInt16OutOfRangeThrowsInsteadOfTrapping() {
        #expect(throws: ItoError.postcardDecodingError("Value 70000 does not fit in UInt16.")) {
            try ItoPostcardDecoder().decode(UInt16Holder.self, from: [0xF0, 0xA2, 0x04])
        }
    }

    @Test func aSequenceLengthBeyondIntThrowsInsteadOfTrapping() {
        // UInt64.max as a varint
        let length: [UInt8] = Array(repeating: 0xFF, count: 9) + [0x01]
        #expect(throws: ItoError.postcardDecodingError("Value 18446744073709551615 does not fit in Int.")) {
            try ItoPostcardDecoder().decode([String].self, from: length)
        }
    }
}
