import Foundation
import WAT
import WasmKit
@testable import ito_runner

let editionsEncoder = ItoPostcardEncoder(abiVersion: 3)
let editionsDecoder = ItoPostcardDecoder(abiVersion: 3)
let editionsEntry = MediaEntry.manga(Manga(key: "exact-series", title: "Series"))

func editionsPage(_ key: String, cursor: String? = nil, scope: CatalogScope = .visible,
                  completeness: CatalogCompleteness = .partial) -> ChapterEditionsPage {
    ChapterEditionsPage(editions: [Chapter(key: key, kind: .images)], nextCursor: cursor,
                        scope: scope, completeness: completeness)
}

struct EditionsTestStep {
    var bytes: [UInt8]?
    var error: PluginErrorPayload?
    init(_ page: ChapterEditionsPage) throws { bytes = try editionsEncoder.encode(page) }
    init(bytes: [UInt8]? = nil, category: PluginErrorCategory? = nil, message: String = "failure") {
        self.bytes = bytes
        error = category.map { PluginErrorPayload(category: $0, message: message) }
    }
}

private let editionsLogOffset = 262_144

/// A sequence of fixed responses. Every request is recorded, and optional host fetches let tests
/// exercise cancellation and host authority. `fetchAt == -1` fetches on every page.
func editionsPlugin(_ steps: [EditionsTestStep], fetchAt: Int? = nil) throws -> [UInt8] {
    var offset = 1_024
    var data: [(Int, [UInt8])] = []
    var answers: [Int64] = [], errors: [Int64] = []
    for step in steps {
        if let bytes = step.bytes {
            data.append((offset, bytes)); answers.append(catalogPacked(offset, bytes.count)); offset += bytes.count + 8
        } else { answers.append(0) }
        if let error = step.error {
            let bytes = try editionsEncoder.encode(error)
            data.append((offset, bytes)); errors.append(catalogPacked(offset, bytes.count)); offset += bytes.count + 8
        } else { errors.append(0) }
    }
    let branches = answers.enumerated().map { index, answer in
        "(if (i32.eq (local.get $index) (i32.const \(index))) (then (return (i64.const \(answer)))))"
    }.joined(separator: "\n")
    let errorBranches = errors.enumerated().map { index, answer in
        "(if (i32.eq (global.get $calls) (i32.const \(index + 1))) (then (return (i64.const \(answer)))))"
    }.joined(separator: "\n")
    let fetch = fetchAt.map { index in
        let body = "(drop (call $fetch (i32.const 64) (i32.const 15)))"
        return index == -1 ? body : "(if (i32.eq (local.get $index) (i32.const \(index))) (then \(body)))"
    } ?? ""
    return try wat2wasm("""
    (module
      (import "ito:core/net" "fetch" (func $fetch (param i32 i32) (result i32)))
      (memory (export "memory") 32)
      \(abi3Prelude(kinds: 0b111))
      (global $calls (mut i32) (i32.const 0))
      (global $heap (mut i32) (i32.const 65536))
      (global $log (mut i32) (i32.const \(editionsLogOffset)))
      (data (i32.const 64) "\\08http://x\\03GET\\00\\00")
      \(data.map { "(data (i32.const \($0.0)) \"\(catalogHex($0.1))\")" }.joined(separator: "\n"))
      (func (export "alloc") (param $n i32) (result i32) (local $p i32)
        global.get $heap local.tee $p local.get $n i32.add global.set $heap local.get $p)
      (func (export "dealloc") (param i32 i32))
      (func (export "calls") (result i32) global.get $calls)
      (func (export "log_end") (result i32) global.get $log)
      (func (export "ito_last_error") (result i64) \(errorBranches) i64.const 0)
      (func (export "get_chapter_editions") (param $p i32) (param $n i32) (result i64) (local $index i32)
        global.get $log local.get $n i32.store
        global.get $log i32.const 4 i32.add local.get $p local.get $n memory.copy
        global.get $log i32.const 4 i32.add local.get $n i32.add global.set $log
        global.get $calls local.set $index
        global.get $calls i32.const 1 i32.add global.set $calls
        \(fetch)
        \(branches)
        i64.const 0))
    """)
}

func editionsCalls(_ runner: ItoRunner) async throws -> Int {
    guard case .i32(let calls)? = try await runner.executeExport("calls").first else { return -1 }
    return Int(calls)
}

func editionsRequests(_ runner: ItoRunner) async throws -> [ChapterEditionsRequest] {
    guard case .i32(let end)? = try await runner.executeExport("log_end").first else { return [] }
    let bytes = try await runner.readMemory(offset: editionsLogOffset, length: Int(end) - editionsLogOffset)
    var offset = 0
    var result: [ChapterEditionsRequest] = []
    while offset < bytes.count {
        let length = bytes[offset..<offset + 4].reversed().reduce(0) { $0 << 8 | Int($1) }
        offset += 4
        result.append(try editionsDecoder.decode(ChapterEditionsRequest.self, from: Array(bytes[offset..<offset + length])))
        offset += length
    }
    return result
}

/// Reuses one encoded page template, stamping the call number into every key and next cursor.
/// No huge static fixture is needed to exercise the real row, page and cumulative byte caps.
func editionsBulkPlugin(rows: Int, titleBytes: Int = 0) throws -> (wasm: [UInt8], pageBytes: Int) {
    let chapters = (0..<rows).map {
        Chapter(key: String(format: "p000-%03d", $0), title: String(repeating: "x", count: titleBytes), kind: .images)
    }
    let page = ChapterEditionsPage(editions: chapters, nextCursor: "p000", scope: .allEligible, completeness: .partial)
    let bytes = try editionsEncoder.encode(page)
    let stride = try editionsEncoder.encode(chapters[0]).count
    // Vec length is one byte (rows <= 100); first key's length is one byte, then 'p'.
    let firstDigits = 1_024 + 3
    let cursorDigits = 1_024 + bytes.count - 5
    let wasm = try wat2wasm("""
    (module
      (memory (export "memory") 32)
      \(abi3Prelude())
      (global $calls (mut i32) (i32.const 0))
      (data (i32.const 1024) "\(catalogHex(bytes))")
      (func (export "alloc") (param i32) (result i32) i32.const 524288)
      (func (export "dealloc") (param i32 i32))
      (func (export "calls") (result i32) global.get $calls)
      (func $stamp (param $p i32)
        local.get $p global.get $calls i32.const 100 i32.div_u i32.const 48 i32.add i32.store8
        local.get $p i32.const 1 i32.add global.get $calls i32.const 10 i32.div_u i32.const 10 i32.rem_u i32.const 48 i32.add i32.store8
        local.get $p i32.const 2 i32.add global.get $calls i32.const 10 i32.rem_u i32.const 48 i32.add i32.store8)
      (func (export "get_chapter_editions") (param i32 i32) (result i64) (local $i i32)
        global.get $calls i32.const 1 i32.add global.set $calls
        (loop $rows
          i32.const \(firstDigits) local.get $i i32.const \(stride) i32.mul i32.add call $stamp
          local.get $i i32.const 1 i32.add local.tee $i i32.const \(rows) i32.lt_u br_if $rows)
        i32.const \(cursorDigits) call $stamp
        i64.const \(catalogPacked(1024, bytes.count))))
    """)
    return (wasm, bytes.count)
}

func editionsViolation(_ rule: ChapterEditionsViolation.Rule) -> ItoError {
    .chapterEditionsViolation(function: "get_chapter_editions", violation: .init(rule))
}

func editionsCatalogViolation(_ rule: CatalogContractViolation.Rule) -> ItoError {
    .catalogContractViolation(function: "get_chapter_editions", violation: .init(rule))
}
