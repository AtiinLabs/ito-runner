import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

@Suite("Plugins built for a newer host")
struct PluginCompatibilityTests {
    /// A minimal plugin with `body` added inside the module.
    private func plugin(_ body: String) throws -> [UInt8] {
        try wat2wasm("""
            (module
                \(body)
                (memory (export "memory") 1)
                (func (export "alloc") (param i32) (result i32) i32.const 1024)
                (func (export "dealloc") (param i32 i32))
                (func (export "get_home") (result i64) i64.const 0)
            )
            """)
    }

    @Test func aPluginImportingHostFunctionsThisHostLacksIsRefusedNamingThem() async throws {
        let wasm = try plugin("""
            (import "ito:core/net" "fetch_v9" (func (param i32 i32) (result i32)))
            (import "ito:core/net" "fetch_v2" (func (param i32 i32 i32 i32) (result i32)))
            (import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32)))
            """)

        await #expect(throws: ItoError.requiresNewerHost(missingImports: [
            "ito:core/net.fetch_v9", "wasi_snapshot_preview1.fd_write"
        ])) {
            try await ItoRunner().loadPlugin(fromBytes: wasm)
        }
    }

    @Test func aPluginBuiltForANewerABIIsRefused() async throws {
        let wasm = try plugin(#"(func (export "ito_abi_version") (result i32) i32.const 2)"#)

        await #expect(throws: ItoError.unsupportedABI(version: 2, supported: 1...1)) {
            try await ItoRunner().loadPlugin(fromBytes: wasm)
        }
    }

    @Test func pluginsForThisABIAndPluginsFromBeforeTheExportStillRun() async throws {
        for wasm in [
            try plugin(#"(func (export "ito_abi_version") (result i32) i32.const 1)"#),
            try plugin("")
        ] {
            let runner = ItoRunner()
            try await runner.loadPlugin(fromBytes: wasm)
            await #expect(throws: ItoError.pluginFailed(function: "get_home", reason: nil)) {
                try await runner.getHome()
            }
        }
    }
}
