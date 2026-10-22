import Foundation
import Testing
import WAT
@testable import ito_runner

@Suite("Unambiguous optional export participation")
struct UnsupportedProtocolTests {
    private func module(version: Int, category: PluginErrorCategory) throws -> [UInt8] {
        let payload = try ItoPostcardEncoder().encode(
            PluginErrorPayload(category: category, message: "Unsupported operation")
        )
        let encoded = payload.map { String(format: "\\%02x", $0) }.joined()
        let versionExport = version == 0 ? "" : """
            (func (export "ito_error_version") (result i32) i32.const \(version))
            """
        return try wat2wasm("""
            (module
              (memory (export "memory") 1)
              (data (i32.const 64) "\(encoded)")
              (func (export "alloc") (param i32) (result i32) i32.const 1024)
              (func (export "dealloc") (param i32 i32))
              \(versionExport)
              (func (export "get_image_request") (param i32 i32) (result i64) i64.const 0)
              (func (export "ito_last_error") (result i64)
                i64.const \((UInt64(64) << 32) | UInt64(payload.count)))
            )
            """)
    }

    @Test(arguments: [
        (0, PluginErrorCategory.other, true),
        (1, .other, true),
        (0, .unauthorized, false),
        (1, .server, false),
        (2, .unauthorized, false),
        (2, .other, false),
        (2, .unsupported, true),
        (3, .other, false),
        (3, .unsupported, true)
    ])
    func textCollisionsDoNotTurnTypedRefusalsIntoFallbacks(
        version: Int, category: PluginErrorCategory, unhandled: Bool
    ) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(version: version, category: category))
        if unhandled {
            #expect(try await runner.getImageRequest("api/v1/cover") == nil)
        } else {
            await #expect(throws: ItoError.pluginFailed(
                function: "get_image_request", reason: "Unsupported operation", category: category
            )) {
                try await runner.getImageRequest("api/v1/cover")
            }
        }
    }

    @Test(arguments: [
        #"(func (export "ito_error_version") (result i32) i32.const 0)"#,
        #"(func (export "ito_error_version") (result i64) i64.const 2)"#,
        #"(func (export "ito_error_version") (param i32) (result i32) i32.const 2)"#,
        #"(func (export "ito_error_version") (result i32) unreachable)"#,
        #"(global (export "ito_error_version") i32 (i32.const 2))"#
    ])
    func invalidVersionExportsCannotSilentlyDowngradeTheProtocol(_ export: String) async throws {
        let wasm = try wat2wasm("(module (memory (export \"memory\") 1) \(export))")
        await #expect(throws: ItoError.self) { try await ItoRunner().loadPlugin(fromBytes: wasm) }
    }

    @Test func reloadingAnOlderPluginResetsTheVersionAndFailedLoadsDoNotReplaceIt() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(version: 2, category: .other))
        await #expect(throws: ItoError.self) { try await runner.getImageRequest("cover") }
        let broken = try wat2wasm(#"(module (memory (export "memory") 1) (func (export "ito_error_version") (result i32) unreachable))"#)
        await #expect(throws: ItoError.self) { try await runner.loadPlugin(fromBytes: broken) }
        await #expect(throws: ItoError.self) { try await runner.getImageRequest("cover") }
        try await runner.loadPlugin(fromBytes: module(version: 0, category: .other))
        #expect(try await runner.getImageRequest("cover") == nil)
    }
}
