import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

@Suite("Media and content kinds")
struct ContentKindTests {
    /// Where the plugins below copy the argument they were given: its length, then its bytes.
    private static let capture = 4096
    /// Where they store the kind they were given.
    private static let kindSlot = 4092

    private static func packed(_ pointer: Int, _ length: Int) -> Int64 { Int64(pointer << 32 | length) }

    private static func escaped(_ bytes: [UInt8]) -> String {
        bytes.map { String(format: "\\%02x", $0) }.joined()
    }

    /// A plugin that answers every catalog call with an empty result and records its arguments.
    /// `extra` holds ABI-specific exports; `buffers` places fixed results at the given addresses.
    private func plugin(
        _ extra: String, update: [UInt8] = [0], buffers: [(Int, [UInt8])] = []
    ) async throws -> ItoRunner {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: wat2wasm("""
            (module
              (memory (export "memory") 1)
              (global $next (mut i32) (i32.const 16384))
              (func (export "alloc") (param $size i32) (result i32) (local $pointer i32)
                global.get $next local.set $pointer
                global.get $next local.get $size i32.add global.set $next
                local.get $pointer)
              (func (export "dealloc") (param i32 i32))
              (data (i32.const \(Self.kindSlot)) "\\ff\\ff\\ff\\7f")
              ;; An empty Vec<Page>, an empty page of entries, and `update`'s result.
              (data (i32.const 1024) "\\00")
              (data (i32.const 1032) "\\00\\00")
              (data (i32.const 2048) "\(Self.escaped(update))")
              \(buffers.map { "(data (i32.const \($0.0)) \"\(Self.escaped($0.1))\")" }.joined(separator: "\n"))
              (func $capture (param $pointer i32) (param $length i32)
                i32.const \(Self.capture) local.get $length i32.store
                i32.const \(Self.capture + 4) local.get $pointer local.get $length memory.copy)
              \(extra)
            )
            """))
        return runner
    }

    private func captured(_ runner: ItoRunner) async throws -> [UInt8] {
        let length = try await runner.readMemory(offset: Self.capture, length: 4)
        let count = Int(length[0]) | Int(length[1]) << 8
        return try await runner.readMemory(offset: Self.capture + 4, length: count)
    }

    private func storedKind(_ runner: ItoRunner) async throws -> Int32 {
        let bytes = try await runner.readMemory(offset: Self.kindSlot, length: 4)
        return bytes.reversed().reduce(Int32(0)) { $0 << 8 | Int32($1) }
    }

    private func abi2(kinds: Int) -> String {
        """
        (func (export "ito_abi_version") (result i32) i32.const 2)
        (func (export "ito_supported_kinds") (result i32) i32.const \(kinds))
        (func (export "get_chapter_pages") (param i32 i32 i32 i32) (result i64)
          local.get 2 local.get 3 call $capture
          i64.const \(Self.packed(1024, 1)))
        (func (export "search") (param i32 i32 i32 i32 i32 i32) (result i64)
          i32.const \(Self.kindSlot) local.get 3 i32.store
          i64.const \(Self.packed(1032, 2)))
        (func (export "mark_completed") (param i32 i32 i32 i32 i32) (result i32)
          i32.const \(Self.kindSlot) local.get 0 i32.store
          i32.const 1)
        """
    }

    private static let abi1Manga = """
        (func (export "get_manga_list") (param i32 i32 i32) (result i64) i64.const 0)
        (func (export "get_page_list") (param i32 i32 i32 i32) (result i64)
          local.get 2 local.get 3 call $capture
          i64.const \(packed(1024, 1)))
        (func (export "get_search_manga_list") (param i32 i32 i32 i32 i32) (result i64)
          i32.const \(kindSlot) i32.const 0 i32.store
          i64.const \(packed(1032, 2)))
        """

    private func manga(chapters: [Chapter]? = nil) -> MediaEntry {
        .manga(Manga(key: "s", title: "S", chapters: chapters))
    }

    private func novel() -> MediaEntry {
        .novel(Novel(key: "n", title: "N", chapters: [Chapter(key: "c")]))
    }

    // MARK: - Kinds a plugin serves

    @Test func pluginsDeclareTheirKindsOrAreKnownByTheirExports() async throws {
        #expect(try await plugin(abi2(kinds: 0b101)).supportedKinds == [.manga, .novel])
        #expect(try await plugin(abi2(kinds: 0b010)).supportedKinds == [.anime])
        #expect(try await plugin(Self.abi1Manga).supportedKinds == [.manga])
        let novelExports = #"(func (export "get_novel_list") (param i32 i32 i32) (result i64) i64.const 0)"#
        #expect(try await plugin(novelExports).supportedKinds == [.novel])
    }

    @Test(arguments: [0, 0b1000, 0b1001])
    func anABI2PluginServingNoKnownKindIsRefused(_ mask: Int) async throws {
        await #expect(throws: ItoError.self) { try await plugin(abi2(kinds: mask)) }
    }

    @Test func anABI2PluginThatDoesNotDeclareItsKindsIsRefused() async throws {
        await #expect(throws: ItoError.self) {
            try await plugin(#"(func (export "ito_abi_version") (result i32) i32.const 2)"#)
        }
    }

    // MARK: - Chapter layouts

    @Test func eachABILaysAChapterOutItsOwnWay() throws {
        let fields: [UInt8] = [1, UInt8(ascii: "c"), 0, 0, 0, 0, 0, 0, 0, 0]
        let text = Chapter(key: "c", kind: .text)

        #expect(try ItoPostcardEncoder(abiVersion: 1).encode(text) == fields)
        #expect(try ItoPostcardEncoder(abiVersion: 2).encode(text) == fields + [2])
        #expect(try ItoPostcardDecoder(abiVersion: 1).decode(Chapter.self, from: fields).kind == nil)
        #expect(try ItoPostcardDecoder(abiVersion: 2).decode(Chapter.self, from: fields + [2]).kind == .text)
        #expect(try ItoPostcardDecoder(abiVersion: 2).decode(Chapter.self, from: fields + [0]).kind == .images)
        #expect(throws: (any Error).self) { try ItoPostcardDecoder(abiVersion: 2).decode(Chapter.self, from: fields) }
        // An ABI 2 plugin can't be sent a chapter whose kind nobody knows.
        #expect(throws: ItoError.self) { try ItoPostcardEncoder(abiVersion: 2).encode(Chapter(key: "c")) }
    }

    @Test func storedChaptersKeepTheirKindAndOlderOnesHaveNone() throws {
        let stored = try JSONEncoder().encode(Chapter(key: "c", title: "One", kind: .text))
        #expect(try JSONDecoder().decode(Chapter.self, from: stored).kind == .text)
        let older = Data(#"{"key":"c","title":"One"}"#.utf8)
        let chapter = try JSONDecoder().decode(Chapter.self, from: older)
        #expect(chapter.kind == nil)
        #expect(manga().contentKind(of: chapter) == .images)
        #expect(novel().contentKind(of: chapter) == .text)
    }

    // MARK: - Calls

    @Test func anABI2PluginGetsEveryChapterWithAKnownKind() async throws {
        let runner = try await plugin(abi2(kinds: 0b101))
        let fields: [UInt8] = [1, UInt8(ascii: "c"), 0, 0, 0, 0, 0, 0, 0, 0]

        // The entry's own stored chapters have no kind either; they are resolved too.
        _ = try await runner.getChapterPages(entry: manga(chapters: [Chapter(key: "c")]), chapter: Chapter(key: "c"))
        #expect(try await captured(runner) == fields + [0])
        _ = try await runner.getChapterPages(entry: novel(), chapter: Chapter(key: "c"))
        #expect(try await captured(runner) == fields + [2])
        // A kind the plugin chose is kept, whatever the entry's.
        _ = try await runner.getChapterPages(entry: manga(), chapter: Chapter(key: "c", kind: .text))
        #expect(try await captured(runner) == fields + [2])
    }

    @Test func anABI1PluginGetsChaptersAsItKnowsThem() async throws {
        let runner = try await plugin(Self.abi1Manga)
        _ = try await runner.getChapterPages(entry: manga(), chapter: Chapter(key: "c", kind: .text))
        #expect(try await captured(runner) == [1, UInt8(ascii: "c"), 0, 0, 0, 0, 0, 0, 0, 0])
    }

    @Test func searchesNameTheirKindAndSkipKindsThePluginDoesNotServe() async throws {
        let runner = try await plugin(abi2(kinds: 0b101))
        _ = try await runner.search(query: "q", page: 1, kind: .novel)
        #expect(try await storedKind(runner) == 2)
        _ = try await runner.search(query: "q", page: 1)
        #expect(try await storedKind(runner) == -1)

        let untouched = try await plugin(abi2(kinds: 0b101))
        let result = try await untouched.search(query: "q", page: 1, kind: .anime)
        #expect(result.entries.isEmpty && !result.hasNextPage)
        #expect(try await storedKind(untouched) == Int32.max, "the plugin must not be called")

        let legacy = try await plugin(Self.abi1Manga)
        _ = try await legacy.search(query: "q", page: 1, kind: .novel)
        #expect(try await storedKind(legacy) == Int32.max, "an ABI 1 manga plugin has no novels")
        _ = try await legacy.search(query: "q", page: 1, kind: .manga)
        #expect(try await storedKind(legacy) == 0)
    }

    @Test func completionsNameTheirKind() async throws {
        let runner = try await plugin(abi2(kinds: 0b111))
        #expect(try await runner.markCompleted(kind: .anime, mediaKey: "a", unitKey: "e"))
        #expect(try await storedKind(runner) == 1)
        #expect(try await runner.markCompleted(kind: .novel, mediaKey: "n", unitKey: "c"))
        #expect(try await storedKind(runner) == 2)
    }

    @Test func anUpdateMustKeepTheEntrysKind() async throws {
        let anime = try ItoPostcardEncoder().encode(MediaEntry.anime(Anime(key: "a", title: "A")))
        let runner = try await plugin(abi2(kinds: 0b011) + """
            (func (export "get_media_update") (param i32 i32 i32 i32) (result i64)
              i64.const \(Self.packed(2048, anime.count)))
            """, update: anime)

        let updated = try await runner.getMediaUpdate(.anime(Anime(key: "a", title: "")))
        #expect(updated.kind == .anime && updated.key == "a")
        await #expect(throws: ItoError.pluginFailed(
            function: "get_media_update", reason: "The plugin returned a different kind of entry."
        )) {
            try await runner.getMediaUpdate(manga())
        }
    }

    @Test func mixedEntriesAndHomeComponentsDecodeByVariant() throws {
        let page = MediaPageResult(
            entries: [.novel(Novel(key: "n", title: "N")), .anime(Anime(key: "a", title: "A"))],
            hasNextPage: true)
        let bytes = try ItoPostcardEncoder().encode(page)
        #expect(bytes[0] == 2 && bytes[1] == 2, "two entries, the first a novel (variant 2)")
        let decoded = try ItoPostcardDecoder().decode(MediaPageResult.self, from: bytes)
        #expect(decoded.entries.map(\.kind) == [.novel, .anime] && decoded.hasNextPage)

        let scroller = try ItoPostcardEncoder().encode(HomeComponentValue.mediaScroller([], nil))
        #expect(scroller.first == 14)
        let bigScroller = try ItoPostcardEncoder().encode(HomeComponentValue.mediaBigScroller([], nil))
        #expect(bigScroller.first == 16)
    }

    @Test func chapterKindsAreStoredByName() throws {
        let stored = String(decoding: try JSONEncoder().encode(Chapter(key: "c", kind: .text)), as: UTF8.self)
        #expect(stored.contains(#""kind":"text""#))
        let decoded = try JSONDecoder().decode(Chapter.self, from: Data(#"{"key":"c","kind":"images"}"#.utf8))
        #expect(decoded.kind == .images)
    }

    @Test func anABI2PluginCannotAnswerWithAKindItDoesNotServe() async throws {
        let novel = Novel(key: "n", title: "N")
        let novels = try ItoPostcardEncoder().encode(MediaPageResult(entries: [.novel(novel)], hasNextPage: false))
        let home = try ItoPostcardEncoder().encode(
            HomeLayout(components: [HomeComponent(value: .novelScroller([novel], nil))]))
        let runner = try await plugin("""
            (func (export "ito_abi_version") (result i32) i32.const 2)
            (func (export "ito_supported_kinds") (result i32) i32.const 1)
            (func (export "get_listing") (param i32 i32 i32) (result i64) i64.const \(Self.packed(3072, novels.count)))
            (func (export "search") (param i32 i32 i32 i32 i32 i32) (result i64)
              i64.const \(Self.packed(3072, novels.count)))
            (func (export "get_home") (result i64) i64.const \(Self.packed(3584, home.count)))
            """, buffers: [(3072, novels), (3584, home)])
        let reason = "The plugin returned a kind it doesn't serve (novel)."

        await #expect(throws: ItoError.pluginFailed(function: "get_listing", reason: reason)) {
            try await runner.getListing(Listing(id: "l", name: "L", kind: 0), page: 1)
        }
        await #expect(throws: ItoError.pluginFailed(function: "search", reason: reason)) {
            try await runner.search(query: "q", page: 1)
        }
        await #expect(throws: ItoError.pluginFailed(function: "get_home", reason: reason)) {
            try await runner.getHome()
        }
    }

    @Test func anABI2CompletionRefusalArrivesTyped() async throws {
        // {category: unauthorized (zigzag 2), message: "No"}
        let report: [UInt8] = [2, 2, UInt8(ascii: "N"), UInt8(ascii: "o")]
        let runner = try await plugin("""
            (func (export "ito_abi_version") (result i32) i32.const 2)
            (func (export "ito_supported_kinds") (result i32) i32.const 1)
            (func (export "ito_error_version") (result i32) i32.const 2)
            (func (export "ito_last_error") (result i64) i64.const \(Self.packed(3072, report.count)))
            (func (export "mark_completed") (param i32 i32 i32 i32 i32) (result i32) i32.const 0)
            """, buffers: [(3072, report)])

        await #expect(throws: ItoError.pluginFailed(function: "mark_completed", reason: "No", category: .unauthorized)) {
            try await runner.markCompleted(kind: .manga, mediaKey: "m", unitKey: "c")
        }
    }

    @Test func anABI1NovelPluginListsAndReadsItsNovels() async throws {
        let novels = try ItoPostcardEncoder(abiVersion: 1).encode(
            Novel.PageResult(entries: [Novel(key: "n", title: "N", chapters: [Chapter(key: "c")])], hasNextPage: true))
        let runner = try await plugin("""
            (func (export "get_novel_list") (param i32 i32 i32) (result i64) i64.const \(Self.packed(3072, novels.count)))
            (func (export "get_chapter_content") (param i32 i32 i32 i32) (result i64)
              local.get 2 local.get 3 call $capture
              i64.const \(Self.packed(1024, 1)))
            """, buffers: [(3072, novels)])

        let listed = try await runner.getListing(Listing(id: "l", name: "L", kind: 0), page: 1)
        #expect(listed.entries.map(\.kind) == [.novel] && listed.hasNextPage)
        guard case .novel(let novel)? = listed.entries.first else { return }
        #expect(novel.chapters?.first?.kind == nil, "an ABI 1 chapter has no kind")
        #expect(listed.entries[0].contentKind(of: Chapter(key: "c")) == .text)
        _ = try await runner.getChapterPages(entry: listed.entries[0], chapter: Chapter(key: "c"))
        #expect(try await captured(runner) == [1, UInt8(ascii: "c"), 0, 0, 0, 0, 0, 0, 0, 0])
    }
}
