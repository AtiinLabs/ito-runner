import Foundation
import Testing
import WAT
@testable import ito_runner

@Suite("Plugin completion notifications")
struct PluginCompletionTests {
    private func chapter(_ body: String) -> String {
        """
        (func (export "mark_chapter_read")
          (param $media i32) (param $mediaLength i32) (param $unit i32) (param $unitLength i32)
          (result i32) \(body))
        """
    }

    private func runner(
        exports: String,
        version: UInt32 = 2,
        failure: PluginErrorCategory? = nil,
        allocation: String = "global.get $cursor local.tee $pointer local.get $length i32.add global.set $cursor local.get $pointer",
        errorExport: String = ""
    ) async throws -> ItoRunner {
        var error = errorExport
        var data = ""
        if let failure {
            let bytes = try ItoPostcardEncoder().encode(PluginErrorPayload(category: failure, message: "Unsupported operation"))
            data = "(data (i32.const 128) \"\(bytes.map { String(format: "\\%02x", $0) }.joined())\")"
            let packed = (UInt64(128) << 32) | UInt64(bytes.count)
            error = "(func (export \"ito_last_error\") (result i64) i64.const \(packed))"
        }
        let marker = version == 0 ? "" : "(func (export \"ito_error_version\") (result i32) i32.const \(version))"
        let wasm = try wat2wasm("""
        (module
          (memory (export "memory") 1)
          (global $cursor (mut i32) (i32.const 2048))
          (global $allocations (mut i32) (i32.const 0))
          (func (export "alloc") (param $length i32) (result i32) (local $pointer i32)
            global.get $allocations i32.const 1 i32.add global.set $allocations
            i32.const 520 global.get $allocations i32.store
            \(allocation))
          (func (export "dealloc") (param $pointer i32) (param $length i32)
            local.get $pointer i32.const 2048 i32.ge_u
            if
              i32.const 512 i32.const 512 i32.load i32.const 1 i32.add i32.store
              i32.const 516 i32.const 516 i32.load local.get $length i32.add i32.store
            end)
          \(marker) \(data) \(error) \(exports))
        """)
        let result = ItoRunner()
        try await result.loadPlugin(fromBytes: wasm)
        return result
    }

    private func expectFreed(_ runner: ItoRunner, count: UInt8, bytes: UInt8) async throws {
        let counters = try await runner.readMemory(offset: 512, length: 8)
        #expect(counters == [count, 0, 0, 0, bytes, 0, 0, 0])
    }

    @Test func opaqueUnicodeKeysUseByteLengthsAndAcknowledgementsAreProviderSpecific() async throws {
        let acceptsChapter = chapter("""
          local.get $mediaLength i32.const 11 i32.ne if unreachable end
          local.get $unitLength i32.const 11 i32.ne if unreachable end
          local.get $media i32.load8_u offset=1 i32.const 195 i32.ne if unreachable end
          local.get $unit i32.load8_u offset=8 i32.const 228 i32.ne if unreachable end
          i32.const 1
        """)
        let unsupportedEpisode = #"(func (export "mark_episode_watched") (param i32 i32 i32 i32) (result i32) i32.const 0)"#
        let subject = try await runner(exports: acceptsChapter + unsupportedEpisode, failure: .unsupported)
        #expect(try await subject.markChapterRead(mediaKey: "média/🍵", chapterKey: "chapter/七"))
        #expect(try await !subject.markEpisodeWatched(mediaKey: "média/🍵", episodeKey: "chapter/七"))
        try await expectFreed(subject, count: 4, bytes: 44)
    }

    @Test func emptyKeysUseNullEmptyBuffersWithoutAllocations() async throws {
        let subject = try await runner(exports: chapter("""
          local.get $media local.get $mediaLength i32.or
          local.get $unit i32.or local.get $unitLength i32.or i32.eqz
        """))
        #expect(try await subject.markChapterRead(mediaKey: "", chapterKey: ""))
        #expect(try await subject.readMemory(offset: 520, length: 4) == [0, 0, 0, 0])
        try await expectFreed(subject, count: 0, bytes: 0)
    }

    @Test func absentExportsDoNotFabricateDelivery() async throws {
        let subject = try await runner(exports: "")
        #expect(try await !subject.markChapterRead(mediaKey: "m", chapterKey: "c"))
        #expect(try await !subject.markEpisodeWatched(mediaKey: "a", episodeKey: "e"))
        #expect(try await subject.readMemory(offset: 520, length: 4) == [0, 0, 0, 0])
    }

    @Test func anUnhandledZeroWithoutAReportIsNotAnAcknowledgement() async throws {
        let subject = try await runner(exports: chapter("i32.const 0"))
        #expect(try await !subject.markChapterRead(mediaKey: "m", chapterKey: "c"))
        try await expectFreed(subject, count: 2, bytes: 2)
    }

    @Test(arguments: [
        (UInt32(0), PluginErrorCategory.other, true),
        (1, .unauthorized, false),
        (2, .other, false),
        (2, .unsupported, true)
    ])
    func typedRefusalsAreNotUnsupportedJustBecauseTheirTextMatches(
        _ version: UInt32, _ category: PluginErrorCategory, _ unsupported: Bool
    ) async throws {
        let subject = try await runner(exports: chapter("i32.const 0"), version: version, failure: category)
        if unsupported {
            #expect(try await !subject.markChapterRead(mediaKey: "m", chapterKey: "c"))
        } else {
            await #expect(throws: ItoError.pluginFailed(
                function: "mark_chapter_read", reason: "Unsupported operation", category: category
            )) { try await subject.markChapterRead(mediaKey: "m", chapterKey: "c") }
        }
        try await expectFreed(subject, count: 2, bytes: 2)
    }

    @Test(arguments: [
        #"(global (export "mark_chapter_read") i32 (i32.const 1))"#,
        #"(func (export "mark_chapter_read") (result i32) i32.const 1)"#,
        #"(func (export "mark_chapter_read") (param i32 i32 i32 i32) (result i64) i64.const 1)"#
    ])
    func malformedExportsFailBeforeAllocatingArguments(_ exports: String) async throws {
        let subject = try await runner(exports: exports)
        await #expect(throws: ItoError.self) { try await subject.markChapterRead(mediaKey: "m", chapterKey: "c") }
        #expect(try await subject.readMemory(offset: 520, length: 4) == [0, 0, 0, 0])
    }

    @Test(arguments: ["i32.const 2", "i32.const -1", "unreachable"])
    func invalidAcknowledgementsAndTrapsReleaseBothArguments(_ body: String) async throws {
        let subject = try await runner(exports: chapter(body))
        await #expect(throws: ItoError.self) { try await subject.markChapterRead(mediaKey: "m", chapterKey: "c") }
        try await expectFreed(subject, count: 2, bytes: 2)
    }

    @Test func aSecondAllocationTrapReleasesTheFirstArgument() async throws {
        let subject = try await runner(exports: chapter("i32.const 1"), allocation: """
          global.get $allocations i32.const 2 i32.eq if unreachable end
          i32.const 2048
        """)
        await #expect(throws: ItoError.self) { try await subject.markChapterRead(mediaKey: "m", chapterKey: "c") }
        try await expectFreed(subject, count: 1, bytes: 1)
    }

    @Test func anOutOfBoundsSecondBufferReleasesBothAllocatedArguments() async throws {
        let subject = try await runner(exports: chapter("unreachable"), allocation: """
          global.get $allocations i32.const 2 i32.eq
          if (result i32) i32.const 65530 else i32.const 2048 end
        """)
        await #expect(throws: ItoError.memoryOutOfBounds(offset: 65530, length: 11, memorySize: 65536)) {
            try await subject.markChapterRead(mediaKey: "m", chapterKey: "chapter/七")
        }
        try await expectFreed(subject, count: 2, bytes: 12)
    }

    @Test func readingTheFailureReportCannotHideATrapOrLeakTheArguments() async throws {
        let subject = try await runner(
            exports: chapter("i32.const 0"),
            errorExport: #"(func (export "ito_last_error") (result i64) unreachable)"#
        )
        await #expect(throws: ItoError.self) { try await subject.markChapterRead(mediaKey: "m", chapterKey: "c") }
        try await expectFreed(subject, count: 2, bytes: 2)
    }
}
