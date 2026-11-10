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

    @Test func aPluginImportingWhatThisHostLacksIsRefusedNamingIt() async throws {
        let wasm = try plugin("""
            (import "ito:core/net" "fetch_v9" (func (param i32 i32) (result i32)))
            (import "ito:core/net" "fetch_v9" (func (param i32 i32) (result i32)))
            (import "ito:core/net" "fetch_v2" (func (param i32 i32 i32 i32) (result i32)))
            (import "ito:core/std" "print" (func (param i32) (result i32)))
            (import "wasi_snapshot_preview1" "fd_write" (func (param i32 i32 i32 i32) (result i32)))
            \(abi3Prelude())
            """)

        // A missing function, one with a different signature, and an unknown module, each once.
        await #expect(throws: ItoError.requiresNewerHost(missingImports: [
            "ito:core/net.fetch_v9", "ito:core/std.print", "wasi_snapshot_preview1.fd_write"
        ])) {
            try await ItoRunner().loadPlugin(fromBytes: wasm)
        }
    }

    @Test func importsListedInAManifestAreCheckedBeforeDownloading() {
        #expect(ItoRunner.unsupportedImports([
            "ito:core/net.fetch_v2", "ito:core/net.fetch_v9", "ito:core/html.parse", "wasi.fd_write", "nodot"
        ]) == ["ito:core/net.fetch_v9", "wasi.fd_write", "nodot"])
    }

    @Test func aPluginBuiltForANewerABIIsRefused() async throws {
        let wasm = try plugin(#"(func (export "ito_abi_version") (result i32) i32.const 4)"#)

        await #expect(throws: ItoError.unsupportedABI(version: 4, supported: 3...3)) {
            try await ItoRunner().loadPlugin(fromBytes: wasm)
        }
    }

    @Test func aPluginBuiltForAnOlderABIIsRefusedEvenWhenItLooksCurrent() async throws {
        // Whatever else they export, ABI 2 and ABI 1 plugins and plugins from before the export are
        // told apart by it alone, so none of their payloads is ever decoded.
        for wasm in [
            try plugin(#"""
                (func (export "ito_abi_version") (result i32) i32.const 2)
                (func (export "ito_supported_kinds") (result i32) i32.const 1)
                (func (export "ito_error_version") (result i32) i32.const 2)
                """#),
            try plugin(#"(func (export "ito_abi_version") (result i32) i32.const 1)"#),
            try plugin("")
        ] {
            let binary = try ItoRunner.inspectBinary(wasm)
            await #expect(throws: ItoError.unsupportedABI(version: binary.abiVersion, supported: 3...3)) {
                try await ItoRunner().loadPlugin(fromBytes: wasm)
            }
            #expect(ItoRunner.compatibility(of: binary) == .pluginTooOld(abi: binary.abiVersion))
        }
    }

    @Test func aPluginForThisABIRuns() async throws {
        let runner = ItoRunner()
        try await runner.loadPlugin(fromBytes: plugin(abi3Prelude()))
        #expect(await runner.abiVersion == 3)
        #expect(await runner.supportedKinds == [.manga])
        await #expect(throws: ItoError.pluginFailed(function: "get_home", reason: nil)) {
            try await runner.getHome(context: .test)
        }
        #expect(ItoRunner.compatibility(of: try ItoRunner.inspectBinary(plugin(abi3Prelude()))) == .compatible)
    }
}
