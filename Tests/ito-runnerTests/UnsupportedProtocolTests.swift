import Foundation
import Testing
import WAT
@testable import ito_runner

@Suite("Unambiguous optional export participation")
struct UnsupportedProtocolTests {
    private func module(version: Int, category: PluginErrorCategory) throws -> [UInt8] {
        let payload = try ItoPostcardEncoder(abiVersion: 3).encode(
            PluginErrorPayload(category: category, message: "Unsupported operation")
        )
        let encoded = payload.map { String(format: "\\%02x", $0) }.joined()
        return try wat2wasm("""
            (module
              (memory (export "memory") 1)
              (data (i32.const 64) "\(encoded)")
              (func (export "alloc") (param i32) (result i32) i32.const 1024)
              (func (export "dealloc") (param i32 i32))
              \(abi3Prelude(errorVersion: version))
              (func (export "get_image_request") (param i32 i32) (result i64) i64.const 0)
              (func (export "ito_last_error") (result i64)
                i64.const \((UInt64(64) << 32) | UInt64(payload.count)))
            )
            """)
    }

    @Test(arguments: [
        (2, PluginErrorCategory.unauthorized, false),
        (2, .other, false),
        (2, .unsupported, true),
        (3, .server, false),
        (3, .other, false),
        (3, .unsupported, true)
    ])
    func textCollisionsDoNotTurnTypedRefusalsIntoFallbacks(
        version: Int, category: PluginErrorCategory, unhandled: Bool
    ) async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: module(version: version, category: category))
        if unhandled {
            #expect(try await runner.getImageRequest("api/v1/cover", context: .test) == nil)
        } else {
            await #expect(throws: ItoError.pluginFailed(
                function: "get_image_request", reason: "Unsupported operation", category: category
            )) {
                try await runner.getImageRequest("api/v1/cover", context: .test)
            }
        }
    }

    /// The module is otherwise a plugin this runner loads, so only the version export can refuse it.
    @Test(arguments: [
        #"(func (export "ito_error_version") (result i32) i32.const 0)"#,
        #"(func (export "ito_error_version") (result i64) i64.const 2)"#,
        #"(func (export "ito_error_version") (param i32) (result i32) i32.const 2)"#,
        #"(func (export "ito_error_version") (result i32) unreachable)"#,
        #"(global (export "ito_error_version") i32 (i32.const 2))"#,
        #"(func (export "ito_error_version") (result i32) i32.const 1)"#,
        ""
    ])
    func invalidVersionExportsCannotSilentlyDowngradeTheProtocol(_ export: String) async throws {
        func module(_ versionExport: String) throws -> [UInt8] {
            try wat2wasm("""
                (module (memory (export "memory") 1)
                  (func (export "ito_abi_version") (result i32) i32.const 3)
                  (func (export "ito_supported_kinds") (result i32) i32.const 1)
                  \(versionExport))
                """)
        }
        // The same module loads with a valid version 2, so the export under test is what refuses it.
        let control = ItoRunner()
        try await control.loadPlugin(fromBytes: module(#"(func (export "ito_error_version") (result i32) i32.const 2)"#))
        #expect(await control.abiVersion == 3)

        let wasm = try module(export)
        await #expect(throws: ItoError.self) { try await ItoRunner().loadPlugin(fromBytes: wasm) }
    }

    @Test func aRefusedReloadLeavesTheLoadedPluginsProtocolInPlace() async throws {
        let runner = ItoRunner()
        let typed = ItoError.pluginFailed(
            function: "get_image_request", reason: "Unsupported operation", category: .other)
        try await runner.loadPlugin(fromBytes: module(version: 2, category: .other))
        await #expect(throws: typed) { try await runner.getImageRequest("cover", context: .test) }
        let broken = try wat2wasm("""
            (module (memory (export "memory") 1)
              (func (export "ito_abi_version") (result i32) i32.const 3)
              (func (export "ito_supported_kinds") (result i32) i32.const 1)
              (func (export "ito_error_version") (result i32) unreachable))
            """)
        await #expect(throws: ItoError.self) { try await runner.loadPlugin(fromBytes: broken) }
        await #expect(throws: typed) { try await runner.getImageRequest("cover", context: .test) }
        // A plugin with the old report format is refused too, so its text convention never applies.
        await #expect(throws: ItoError.self) {
            try await runner.loadPlugin(fromBytes: module(version: 1, category: .other))
        }
        await #expect(throws: typed) { try await runner.getImageRequest("cover", context: .test) }
    }
}
