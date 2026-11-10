import Foundation
import Testing
@testable import ito_runner

private let decoder = ItoPostcardDecoder(abiVersion: 3)
private let encoder = ItoPostcardEncoder(abiVersion: 3)

/// Strings are exact UTF-8 bytes and an option is a 0 or a 1: the runner reads neither more
/// leniently than the plugin SDK does.
@Suite("Postcard exactness")
struct PostcardStrictnessTests {
    private let bom = "\u{FEFF}"
    private let bomBytes: [UInt8] = [0xEF, 0xBB, 0xBF]

    // MARK: Strings

    @Test func aLeadingByteOrderMarkIsPartOfTheString() throws {
        let read = try decoder.decode(String.self, from: [4, 0xEF, 0xBB, 0xBF, 0x61])
        #expect(Array(read.utf8) == bomBytes + [0x61])
        let only = try decoder.decode(String.self, from: [3, 0xEF, 0xBB, 0xBF])
        #expect(Array(only.utf8) == bomBytes)
        #expect(try encoder.encode(only) == [3, 0xEF, 0xBB, 0xBF])
    }

    @Test(arguments: [
        [2, 0xC3, 0x28] as [UInt8],  // a lead byte without its continuation
        [1, 0x80],  // a stray continuation byte
        [2, 0xC0, 0x80],  // an overlong NUL
        [3, 0xED, 0xA0, 0x80],  // a surrogate
        [4, 0xF4, 0x90, 0x80, 0x80],  // past U+10FFFF
        [1, 0xFF]
    ])
    func bytesThatAreNotUTF8AreRefusedNotRepaired(_ wire: [UInt8]) {
        #expect(throws: ItoError.postcardDecodingError("Failed to decode UTF-8 string.")) {
            try decoder.decode(String.self, from: wire)
        }
    }

    private func runner(returning bytes: [UInt8]) async throws -> ItoRunner {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: catalogPlugin(
            exports: """
                (func (export "get_media_update") (param i32 i32 i32 i32) (result i64)
                  i64.const \(catalogPacked(catalogResponseOffset, bytes.count)))
                (func (export "get_chapter_pages") (param i32 i32 i32 i32) (result i64)
                  local.get 2 local.get 3 call $capture i64.const \(catalogPacked(3072, 1)))
                """,
            responses: [(catalogResponseOffset, bytes), (3072, [0])]))
        return runner
    }

    private func keys(_ chapters: [Chapter]?) -> [[UInt8]] { (chapters ?? []).map { Array($0.key.utf8) } }

    /// A key that starts with a byte-order mark is a different key from the one without it, and
    /// the plugin gets back exactly the bytes it chose.
    @Test func keysWithAndWithoutAByteOrderMarkAreTwoKeysSentBackByteForByte() async throws {
        let sent = MediaEntry.manga(Manga(key: "m", title: "M", chapters: [
            Chapter(key: bom + "a", kind: .images), Chapter(key: "a", kind: .images)
        ]))
        let plugin = try await runner(returning: try encoder.encode(sent))

        let updated = try await plugin.getMediaUpdate(.manga(Manga(key: "m", title: "M")), context: .test)
        guard case .manga(let manga) = updated else { Issue.record("not a manga"); return }
        #expect(keys(manga.chapters) == [bomBytes + [0x61], [0x61]])

        for (index, expected) in [bomBytes + [0x61], [0x61]].enumerated() {
            _ = try await plugin.getChapterPages(entry: updated, chapter: manga.chapters![index], context: .test)
            let received = try decoder.decode(Chapter.self, from: try await captured(by: plugin))
            #expect(Array(received.key.utf8) == expected)
        }
    }

    @Test func aKeyThatIsOnlyAByteOrderMarkKeepsItsThreeBytes() async throws {
        let sent = MediaEntry.novel(Novel(key: "n", title: "N", chapters: [Chapter(key: bom, kind: .text)]))
        let plugin = try await runner(returning: try encoder.encode(sent))

        let updated = try await plugin.getMediaUpdate(.novel(Novel(key: "n", title: "N")), context: .test)
        guard case .novel(let novel) = updated else { Issue.record("not a novel"); return }
        #expect(keys(novel.chapters) == [bomBytes])

        _ = try await plugin.getChapterPages(entry: updated, chapter: novel.chapters![0], context: .test)
        let received = try decoder.decode(Chapter.self, from: try await captured(by: plugin))
        #expect(Array(received.key.utf8) == bomBytes)
    }

    // MARK: Options

    /// A chapter with only a key and a kind: its optional title is the byte after the key.
    private var minimalChapter: [UInt8] { [1, 0x6B] + Array(repeating: 0, count: 8) + [0, 0, 0, 0] }

    @Test func anOptionIsAZeroOrAOne() throws {
        #expect(try decoder.decode(Chapter.self, from: minimalChapter).title == nil)
        var present = minimalChapter
        present.replaceSubrange(2..<3, with: [1, 1, 0x74])
        #expect(try decoder.decode(Chapter.self, from: present).title == "t")
        #expect(try decoder.decode(String?.self, from: [0]) == nil)
        #expect(try decoder.decode(String?.self, from: [1, 1, 0x78]) == "x")
    }

    @Test(arguments: [2, 3, 0x7F, 0xFF] as [UInt8])
    func anyOtherOptionTagIsMalformed(_ tag: UInt8) {
        // A field of a struct.
        var chapter = minimalChapter
        chapter[2] = tag
        #expect(throws: ItoError.postcardDecodingError("Invalid option tag.")) {
            try decoder.decode(Chapter.self, from: chapter)
        }
        // A top-level option, and one inside a sequence.
        #expect(throws: ItoError.postcardDecodingError("Invalid option tag.")) {
            try decoder.decode(String?.self, from: [tag, 1, 0x78])
        }
        #expect(throws: ItoError.postcardDecodingError("Invalid option tag.")) {
            try decoder.decode([String?].self, from: [1, tag, 1, 0x78])
        }
    }
}
