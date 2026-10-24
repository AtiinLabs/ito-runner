import OSLog
import Foundation
import Testing
import WAT
import WasmKit

@testable import ito_runner

// Mock Modules
final class MockStdModule: StdModule, Sendable {
    func print(message: String) {
        // Assertions are tricky without shared state, but we can verify it doesn't crash
    }
}

final class MockDefaultsModule: DefaultsModule, Sendable {
    // using a non-isolated locked state or just mocking isolated behavior.
    // For test simplicity, we just return fixed values
    func set(key: String, value: String) {}
    func setSecret(key: String, value: String) {}
    func get(key: String) -> String? {
        if key == "test_key" {
            return "test_val"
        }
        return nil
    }
    func remove(key: String) {}
}

/// Records which defaults call stored each value.
final class RecordingDefaultsModule: DefaultsModule, @unchecked Sendable {
    private let lock = NSLock()
    private var plain: [String: String] = [:]
    private var secret: [String: String] = [:]

    func set(key: String, value: String) { lock.withLock { plain[key] = value } }
    func setSecret(key: String, value: String) { lock.withLock { secret[key] = value } }
    func get(key: String) -> String? { lock.withLock { secret[key] ?? plain[key] } }
    func remove(key: String) {}

    var plainValues: [String: String] { lock.withLock { plain } }
    var secretValues: [String: String] { lock.withLock { secret } }
}

@Suite("Host Modules - Misc")
struct HostModuleMiscTests {

    @Test func aSecretWriteReachesOnlyTheSecureStore() async throws {
        let wat = """
            (module
                (import "ito:core/defaults" "set_secret" (func $set_secret (param i32 i32 i32 i32)))
                (memory (export "memory") 1)
                (data (i32.const 16) "tok")
                (data (i32.const 32) "abc")
                (func (export "alloc") (param i32) (result i32) (i32.const 1024))
                (func (export "store_token")
                    (call $set_secret (i32.const 16) (i32.const 3) (i32.const 32) (i32.const 3)))
            )
            """
        let defaults = RecordingDefaultsModule()
        let runner = ItoRunner()
        await runner.setDefaultsModule(defaults)
        try await runner.loadPlugin(fromBytes: try wat2wasm(wat))

        _ = try await runner.executeExport("store_token", args: [])

        #expect(defaults.secretValues == ["tok": "abc"])
        #expect(defaults.plainValues.isEmpty)
    }

    /// `defaults.get` hands its answer back through the plugin's `alloc`. When that allocation is
    /// what grows the plugin's memory, the export that asked must keep running against the grown
    /// memory instead of trapping on a stale bound.
    @Test func aValueReturnedThroughAGrowingAllocationReachesThePlugin() async throws {
        let wat = """
            (module
                (import "ito:core/defaults" "get" (func $get (param i32 i32) (result i64)))
                (memory (export "memory") 1)
                (data (i32.const 16) "test_key")
                ;; Grows memory by a page and hands out an address only reachable after growing.
                (func (export "alloc") (param i32) (result i32)
                    (drop (memory.grow (i32.const 1)))
                    (i32.const 70000))
                (func (export "dealloc") (param i32 i32))
                ;; Returns the first byte of the answer (1 = Some).
                (func (export "read_first_byte") (result i32)
                    (i32.load8_u (i32.wrap_i64 (i64.shr_u (call $get (i32.const 16) (i32.const 8)) (i64.const 32)))))
            )
            """
        let runner = ItoRunner()
        await runner.setDefaultsModule(MockDefaultsModule())
        try await runner.loadPlugin(fromBytes: try wat2wasm(wat))

        let result = try await runner.executeExport("read_first_byte", args: [])

        #expect(result == [.i32(1)])
    }

    @Test("DefaultsModule Get FFI Bridge")
    func testDefaultsGetFFI() async throws {
        let wat = """
            (module
                (import "ito:core/defaults" "get" (func $def_get (param i32 i32) (result i64)))
                (memory (export "memory") 1)

                ;; Data string at offset 16: "test_key" -> 8 bytes
                (data (i32.const 16) "test_key")

                (func (export "alloc") (param i32) (result i32)
                    (i32.const 1024)
                )

                (func (export "test_get") (result i64)
                    (call $def_get (i32.const 16) (i32.const 8))
                )
            )
            """

        let wasmBytes = try wat2wasm(wat)
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("testDefGet.wasm")
        try Data(wasmBytes).write(to: file)

        let runner = ItoRunner()
        await runner.setDefaultsModule(MockDefaultsModule())
        try await runner.loadPlugin(from: file)

        let results = try await runner.executeExport("test_get", args: [])

        guard let resultVal = results.first, case .i64(let packed) = resultVal else {
            Issue.record("Expected i64 result from test_get")
            return
        }

        let responseLen = packed & 0xFFFF_FFFF
        let responsePtr = packed >> 32

        let responseBytes = try await runner.readMemory(
            offset: Int(responsePtr), length: Int(responseLen))

        let resultString = try runner.postcardDecoder.decode(String?.self, from: responseBytes)
        #expect(resultString == "test_val")
    }
}
