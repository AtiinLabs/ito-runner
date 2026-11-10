import Foundation
import WAT
@testable import ito_runner

/// Where `catalogPlugin` keeps what it was called with: the argument's length (UInt32, little
/// endian), then its bytes.
let catalogCaptureOffset = 800_000
/// Where `catalogPlugin` places the fixed response of an export.
let catalogResponseOffset = 1_024

func catalogHex(_ bytes: [UInt8]) -> String { bytes.map { String(format: "\\%02x", $0) }.joined() }

func catalogPacked(_ pointer: Int, _ length: Int) -> Int64 { Int64(pointer) << 32 | Int64(length) }

/// A plugin of 16 pages of memory that serves every kind and answers each export in `exports`.
/// `(func $capture (param pointer length))` copies an argument to `catalogCaptureOffset`, and
/// `responses` places fixed bytes in memory, by address, for the exports to return.
func catalogPlugin(exports: String, responses: [(offset: Int, bytes: [UInt8])] = []) throws -> [UInt8] {
    try wat2wasm("""
        (module
          (memory (export "memory") 16)
          (global $next (mut i32) (i32.const 400000))
          \(abi3Prelude(kinds: 0b111))
          (func (export "alloc") (param $size i32) (result i32) (local $pointer i32)
            global.get $next local.set $pointer
            global.get $next local.get $size i32.add global.set $next
            local.get $pointer)
          (func (export "dealloc") (param i32 i32))
          \(responses.map { "(data (i32.const \($0.offset)) \"\(catalogHex($0.bytes))\")" }.joined(separator: "\n"))
          (func $capture (param $pointer i32) (param $length i32)
            i32.const \(catalogCaptureOffset) local.get $length i32.store
            i32.const \(catalogCaptureOffset + 4) local.get $pointer local.get $length memory.copy)
          \(exports)
        )
        """)
}

/// What a plugin from `catalogPlugin` captured.
func captured(by runner: ItoRunner) async throws -> [UInt8] {
    let header = try await runner.readMemory(offset: catalogCaptureOffset, length: 4)
    let length = header.reversed().reduce(0) { $0 << 8 | Int($1) }
    return try await runner.readMemory(offset: catalogCaptureOffset + 4, length: length)
}

func decodeHex(_ hex: String) -> [UInt8] {
    stride(from: 0, to: hex.count, by: 2).map { offset in
        let start = hex.index(hex.startIndex, offsetBy: offset)
        return UInt8(hex[start..<hex.index(start, offsetBy: 2)], radix: 16)!
    }
}
